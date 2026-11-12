import Foundation
import Core
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 釣行後レポート（F-21）。Foundation Models（Apple Intelligence）で文章を作り、使えない・遅い（10 秒）ときは Core の定型文にする。
@MainActor
final class ReportGenerator {
    static let timeout: TimeInterval = 10
    private static let log = Logger(subsystem: "fog", category: "report")

    /// 材料から要約 1 行と本文を作る。常に成功する（フォールバックあり）。
    func generate(facts: ReportFacts, timeZone: TimeZone = .current) async -> SessionReport {
        let fallbackSummary = ReportTemplate.summary(facts)
        let fallbackBody = ReportTemplate.body(facts, timeZone: timeZone)
        let generated = await withTimeout(Self.timeout) { await Self.generateWithFoundationModels(facts: facts, template: fallbackBody) }
        return SessionReport(summary: generated?.summary ?? fallbackSummary, body: generated?.body ?? fallbackBody, generatedAt: .now)
    }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// 使えるときだけ。`template` を事実の出典として渡し、創作させない。
    nonisolated static func generateWithFoundationModels(facts: ReportFacts, template: String) async -> (summary: String, body: String)? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            log.notice("Foundation Models unavailable: \(String(describing: model.availability), privacy: .public)")
            return nil
        }
        let instructions = """
        あなたは釣り日誌の書き手です。渡された事実だけを使い、日本語で簡潔に書きます。数値や魚種名を変えたり増やしたりしないでください。
        出力は 2 行構成：1 行目は 20 文字以内の要約（例「下げ潮の2時間に集中」）、2 行目以降は 3〜5 文の本文（釣果、条件の推移、釣れた時間帯と潮の関係、前回比、次回への一言）。
        """
        let prompt = "事実:\n" + template
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let lines = response.content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let first = lines.first, lines.count >= 2 else { return nil }
            let summary = String(first.prefix(24)).trimmingCharacters(in: .whitespaces)
            let body = lines.dropFirst().joined(separator: "\n")
            return (summary, body)
        } catch {
            log.notice("Foundation Models failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }
}

/// 釣行終了時にレポートを作って保存し、記録更新を判定する。
@MainActor
final class ReportService {
    private let store: FogStore
    private let generator = ReportGenerator()

    init(store: FogStore) { self.store = store }

    /// 終了した釣行にレポートを付けて保存し、保存後の釣行を返す。
    func attachReport(to sessionID: UUID) async -> Core.Session? {
        guard let session = try? store.session(id: sessionID), session.endedAt != nil else { return nil }
        let spotName = (try? store.spot(id: session.spotID))?.name ?? "釣り場"
        let all = (try? store.sessions()) ?? []
        let previous = all.filter { $0.spotID == session.spotID && $0.id != session.id && $0.startedAt < session.startedAt }.max { $0.startedAt < $1.startedAt }
        let before = all.filter { $0.startedAt < session.startedAt }.flatMap { s in s.catches.map { ($0, s.spotID) } }
        let facts = ReportFacts.make(session: session, spotName: spotName, previous: previous, allCatchesBefore: before, ownName: AnglerSettings.ownName)
        let report = await generator.generate(facts: facts)
        // 文章を作っている間（数秒）に釣果が直されていることがあるので、保存の直前に読み直してレポートだけ入れる（古い内容で上書きしない）
        guard var latest = try? store.session(id: sessionID) else { return nil }
        latest.report = report
        try? store.upsert(latest)
        return latest
    }

    /// 釣果を記録した直後の記録更新判定（撮影の結果シート・通知用）。
    func judge(_ new: Catch, spotID: UUID) -> Analytics.RecordJudgement {
        let all = (try? store.sessions()) ?? []
        let existing = all.flatMap { s in s.catches.map { ($0, s.spotID) } }
        return Analytics.judge(new: new, newSpotID: spotID, existing: existing)
    }
}
