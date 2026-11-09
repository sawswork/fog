import Foundation
import Core

/// 釣行中のスナップショット取得（30 分ごと＋釣果時）。環境 API は `EnvironmentService` が 1 時間間隔に抑える。
/// 釣行の開始・終了は L4 のセッション検出が呼ぶ。位置は呼び出し側が渡す（最後に分かっている立ち位置）。
@MainActor
@Observable
final class SnapshotScheduler {
    static let interval: TimeInterval = 30 * 60

    private let environment: EnvironmentService
    private let store: FogStore
    private var timer: Timer?
    private var pressureTimer: Timer?
    /// 気圧ログ（F-35）の間隔
    static let pressureInterval: TimeInterval = 5 * 60
    private(set) var activeSessionID: UUID?
    private(set) var lastSnapshotAt: Date?
    var currentCoordinate: Coordinate?

    init(environment: EnvironmentService, store: FogStore) {
        self.environment = environment
        self.store = store
    }

    func start(session: Core.Session, coordinate: Coordinate) {
        activeSessionID = session.id
        currentCoordinate = coordinate
        environment.barometer.start()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.record(reason: .periodic) }
        }
        pressureTimer?.invalidate()
        pressureTimer = Timer.scheduledTimer(withTimeInterval: Self.pressureInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.logPressure() }
        }
        Task { await record(reason: .sessionStart) }
    }

    func stop() {
        logPressure()
        timer?.invalidate()
        timer = nil
        pressureTimer?.invalidate()
        pressureTimer = nil
        environment.barometer.stop()
        activeSessionID = nil
    }

    /// 端末気圧計の最新値を釣行に 1 点追加する（F-35）。気圧計が無い端末や値が無いときは何もしない
    func logPressure(at date: Date = .now) {
        guard let id = activeSessionID, let latest = environment.barometer.latest, var session = try? store.session(id: id) else { return }
        var log = session.pressureLog ?? []
        if let last = log.last, date.timeIntervalSince(last.at) < Self.pressureInterval - 30 { return }
        log.append(PressureSample(at: date, pressureHPa: latest.pressureHPa))
        session.pressureLog = log
        try? store.upsert(session, minor: true)
    }

    enum Reason { case sessionStart, periodic, catchEvent }

    /// スナップショットを 1 件追加して保存する。釣果時は `catchEvent` で呼ぶ（釣果側には別途 `environment.snapshot` を埋め込む）。
    @discardableResult
    func record(reason: Reason, at date: Date = .now) async -> EnvSnapshot? {
        guard let id = activeSessionID, let coordinate = currentCoordinate else { return nil }
        await environment.refreshIfNeeded(at: coordinate, now: date)
        guard var session = try? store.session(id: id) else { return nil }
        let snapshot = environment.snapshot(at: date, coordinate: coordinate)
        session.snapshots.append(snapshot)
        try? store.upsert(session, minor: true)
        lastSnapshotAt = date
        return snapshot
    }
}
