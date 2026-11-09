import Foundation
import CoreLocation
import Core

/// CoreLocation の薄いラッパ（2026-11-09 に省電力化）。
/// - 既定は「使用中のみ」の許可。常時の位置監視（Visits・大きな移動）はしない（自動検出をオンにしたときだけ）
/// - 釣行の記録中だけ低頻度の更新（100 m 精度・50 m 間隔）。背景でも続く
/// - 撮影・地図を開いている間だけ前面の更新（`beginForegroundUpdates`）。閉じたら止まる。取りっぱなしにしない
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    enum Mode { case off, monitoring, tracking }

    private let manager = CLLocationManager()
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var mode: Mode = .off
    private(set) var lastFix: LocationFix?
    private var continuations: [UUID: AsyncStream<LocationFix>.Continuation] = [:]
    /// 前面の更新を求めている画面の数（撮影・地図）。0 になったら止める
    private var foregroundUsers = 0
    private var probeTask: Task<Void, Never>?
    /// 自動検出（位置での開始・終了）をオンにしたときだけ「常に許可」を求める
    var wantsAlwaysAuthorization = false

    override init() {
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = false
        manager.activityType = .otherNavigation
        manager.allowsBackgroundLocationUpdates = false
    }

    /// 位置の流れ。複数の購読者が同じ fix を受け取る。
    func fixes() -> AsyncStream<LocationFix> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: if wantsAlwaysAuthorization { manager.requestAlwaysAuthorization() }
        default: break
        }
    }

    /// 待機：Visits と大きな移動で起こされる（自動検出オンのときだけ）。
    func startMonitoring() {
        guard mode != .monitoring else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.startMonitoringVisits()
        manager.startMonitoringSignificantLocationChanges()
        mode = .monitoring
    }

    /// 釣行中：100 m 精度・50 m 間隔の低頻度更新。背景でも続ける（立ち位置とスナップショットの位置のため）。
    func startTracking() {
        guard mode != .tracking else { return }
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        // 「使用中のみ」の許可でも、前面で始めた更新は背景で続けられる（青い帯が出る）。常に許可なら帯は出ない
        manager.allowsBackgroundLocationUpdates = authorization == .authorizedAlways || authorization == .authorizedWhenInUse
        manager.startUpdatingLocation()
        mode = .tracking
    }

    /// 釣行の終了：待機に戻す（自動検出オンなら監視、オフなら完全に止める）
    func stopTracking(monitor: Bool) {
        if monitor { startMonitoring() } else { stop() }
        applyForegroundIfNeeded()
    }

    /// 撮影・地図を開いている間の更新（前面だけ）。`endForegroundUpdates` と対で呼ぶ
    func beginForegroundUpdates() {
        foregroundUsers += 1
        applyForegroundIfNeeded()
    }

    func endForegroundUpdates() {
        foregroundUsers = max(0, foregroundUsers - 1)
        applyForegroundIfNeeded()
    }

    private func applyForegroundIfNeeded() {
        guard mode != .tracking else { return }
        if foregroundUsers > 0 {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 15
            manager.startUpdatingLocation()
        } else if probeTask == nil {
            manager.stopUpdatingLocation()
        }
    }

    /// 1 回だけ今の位置を取る（手動の開始ボタンなど）。60 秒で自動で止まる（取りっぱなしで電池を使っていたのを修正）
    func probe(seconds: TimeInterval = 60) {
        guard mode != .tracking else { return }
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.startUpdatingLocation()
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.probeTask = nil
            self.applyForegroundIfNeeded()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        mode = .off
    }

    private func publish(_ fix: LocationFix) {
        lastFix = fix
        for c in continuations.values { c.yield(fix) }
    }

    // MARK: CLLocationManagerDelegate（nonisolated → MainActor へ）

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map { l in
            LocationFix(at: l.timestamp, coordinate: Coordinate(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude),
                        horizontalAccuracyM: l.horizontalAccuracy, speedMS: l.speed >= 0 ? l.speed : nil)
        }
        Task { @MainActor in for f in fixes { self.publish(f) } }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        // 到着した Visit は滞在の有力な手がかり。到着時刻を速度 0 の fix として流す
        let fix = LocationFix(at: visit.arrivalDate == .distantPast ? Date() : visit.arrivalDate,
                              coordinate: Coordinate(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude),
                              horizontalAccuracyM: visit.horizontalAccuracy, speedMS: 0)
        Task { @MainActor in
            self.publish(fix)
            self.probe(seconds: 180)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse, self.wantsAlwaysAuthorization { manager.requestAlwaysAuthorization() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
