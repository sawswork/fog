import Foundation
import Core

/// 雨（雪）が降り出す前の通知（F-69）。釣行の記録中だけ、10 分ごとに降水の予報を見て、
/// 降り出しの 30 分ほど前に「約 N 分後に雨が降りそうです」と知らせる。判定は Core の `RainPlanner`。
/// 釣行の開始で動き出し、終了で止まる（`SnapshotScheduler` が呼ぶ）。予約した通知は終了で取り消す
@MainActor
final class RainWatcher {
    static let interval: TimeInterval = 10 * 60
    private static let previousKey = "fog.rain.previousAlert"

    private var timer: Timer?
    private var coordinate: (() -> Coordinate?)?
    private var checking = false

    /// 前に知らせた・予約した通知（アプリが起こし直されても同じ雨を 2 度知らせないように覚えておく）
    private var previous: RainPlanner.Alert? {
        get { UserDefaults.standard.data(forKey: Self.previousKey).flatMap { try? JSONDecoder().decode(RainPlanner.Alert.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: Self.previousKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.previousKey) }
        }
    }

    func start(coordinate: @escaping () -> Coordinate?) {
        self.coordinate = coordinate
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        Task { await check() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        coordinate = nil
        // まだ鳴っていない予約は取り消す（釣りを終えたあとに鳴らさない）
        if let p = previous, p.fireAt > .now {
            SessionNotifications.cancelRain()
            previous = nil
        }
    }

    /// 予報を取り直して、知らせるかを決める。前面に戻ったときにも呼ぶ
    func check(now: Date = .now) async {
        guard timer != nil, !checking else { return }
        guard NotificationSettings.isEnabled(.rain) else { SessionNotifications.cancelRain(); return }
        guard let c = coordinate?(), c.isPlausible else { return }
        checking = true
        defer { checking = false }
        // 取れなかったとき（圏外など）は、予約済みの通知をそのままにする
        guard let forecast = await RainForecastProvider.fetch(at: c, now: now) else { return }
        guard timer != nil else { return }
        switch RainPlanner.decide(now: now, minutes: forecast.minutes, hours: forecast.hours, previous: previous) {
        case .nothing:
            break
        case .cancel:
            SessionNotifications.cancelRain()
            previous = nil
        case .notify(let alert):
            SessionNotifications.rain(alert, now: now)
            previous = alert
            Perf.mark("雨の通知：\(alert.body())")
        }
    }
}
