import Foundation
import Core
import os

/// 保存済みデータの補正（起動時に 1 回ずつ）。計算規則を直したときに、過去の記録もその規則に揃える。
enum DataRepairs {
    private static let log = Logger(subsystem: "fog", category: "repair")
    /// 潮名の規則を直した（月齢の整数部の表。2026-11-09）。過去の釣果・スナップショットの潮名を計算し直す
    static let tideNameKey = "fog.repair.tideName.v2"

    /// 直した釣行の ID（レポートを作り直す対象）
    @MainActor
    @discardableResult
    static func run(store: FogStore) -> [UUID] {
        var changed: [UUID] = []
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: tideNameKey) {
            changed += repairTideNames(store: store)
            defaults.set(true, forKey: tideNameKey)
        }
        return changed
    }

    @MainActor
    static func repairTideNames(store: FogStore) -> [UUID] {
        guard let sessions = try? store.sessions() else { return [] }
        var changed: [UUID] = []
        for var session in sessions {
            var touched = false
            session.snapshots = session.snapshots.map { s in
                var s = s
                let name = TideName.on(s.at).rawValue
                if s.tideName != name { s.tideName = name; touched = true }
                return s
            }
            session.catches = session.catches.map { c in
                var c = c
                if var env = c.env {
                    let name = TideName.on(env.at).rawValue
                    if env.tideName != name { env.tideName = name; c.env = env; touched = true }
                }
                return c
            }
            guard touched else { continue }
            do {
                try store.upsert(session, minor: true)
                changed.append(session.id)
            } catch {
                log.error("tide name repair failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !changed.isEmpty { log.notice("tide names repaired in \(changed.count) sessions") }
        return changed
    }
}
