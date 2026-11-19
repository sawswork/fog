import Foundation
import CoreLocation
import Core

/// CoreLocation の薄いラッパ（2026-11-09 に省電力化、2026-11-19 に自動検出を境界の見張りへ作り直し）。
/// - 既定は「使用中のみ」の許可。自動検出をオンにしたときだけ「常に許可」を求める
/// - 自動検出の待機中は、登録した釣り場の境界（ジオフェンス）を OS に見張らせるだけ。アプリは位置を取らない。
///   以前の Visits・大きな移動の監視はやめた（どこに居ても起こされて位置を取り、電池を使っていた）
/// - 境界に入ったら、滞在を確かめる間だけ位置を取る（`startCandidate`。長くても十数分）
/// - 釣行の記録中だけ低頻度の更新（100 m 精度・50 m 間隔）。背景でも続く
/// - 撮影・地図を開いている間だけ前面の更新（`beginForegroundUpdates`）。閉じたら止まる。取りっぱなしにしない
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    /// monitoring：境界の見張りだけ（位置は取らない）。candidate：境界に入って滞在を確かめている。tracking：釣行の記録中
    enum Mode { case off, monitoring, candidate, tracking }

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
    /// 境界の出入り（識別子、中に居るか）。アプリが終了していても OS が起こして届ける
    var onRegionEvent: (@MainActor (String, Bool) -> Void)?

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

    /// 待機（自動検出オンのときだけ）：位置の更新を止め、境界の見張り（`setGeofences`）だけにする。
    /// 以前の方式の監視（Visits・大きな移動）が残っていれば止める
    func startMonitoring() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        mode = .monitoring
    }

    /// 釣り場の境界に入った：滞在を確かめる間だけ位置を取る。通過や誤差で始めないために GPS の精度で取る（長くても十数分）。
    /// 背景で続けるには「常に許可」が要る
    func startCandidate() {
        guard mode != .tracking else { return }
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = authorization == .authorizedAlways
        manager.startUpdatingLocation()
        mode = .candidate
    }

    /// 滞在の確認をやめて待機へ戻る（通り過ぎた・時間切れ）
    func stopCandidate() {
        guard mode == .candidate else { return }
        startMonitoring()
        applyForegroundIfNeeded()
    }

    /// 記録中に位置の更新を起こし直す。じっとしていると OS が更新を止めることがあり、そのままだと離れたことに気づけない。
    /// 釣行の境界を出た知らせで呼ぶ
    func nudge() {
        guard mode == .tracking else { return }
        manager.startUpdatingLocation()
    }

    // MARK: 境界（ジオフェンス）

    /// 見張る境界を置き直す。同じ境界は置いたままにし、差だけを足し引きする。空を渡せば全部外す
    func setGeofences(_ regions: [GeofencePlanner.Region]) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let current: [GeofencePlanner.Region] = manager.monitoredRegions.compactMap { r in
            guard r.identifier.hasPrefix(GeofencePlanner.prefix), let c = r as? CLCircularRegion else { return nil }
            return GeofencePlanner.Region(id: c.identifier, center: Coordinate(latitude: c.center.latitude, longitude: c.center.longitude), radiusM: c.radius)
        }
        let change = GeofencePlanner.diff(current: current, wanted: regions)
        for r in manager.monitoredRegions where change.remove.contains(r.identifier) { manager.stopMonitoring(for: r) }
        for w in change.add {
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: w.center.latitude, longitude: w.center.longitude),
                                          radius: min(w.radiusM, manager.maximumRegionMonitoringDistance), identifier: w.id)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
    }

    /// いま置いてある境界の数（設定の表示用）
    var geofenceCount: Int { manager.monitoredRegions.filter { $0.identifier.hasPrefix(GeofencePlanner.prefix) }.count }

    /// 釣行中：背景では 100 m 精度・50 m 間隔の低頻度更新（電池のため）。画面を見ている間（海図・撮影・地図）は高精度に上げる。
    /// 100 m 精度のままだと、現在地が海の上に出たり、立ち位置の線が数百 m 飛んだりする（2026-11-11 実釣で発生）
    func startTracking() {
        guard mode != .tracking else { return }
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        manager.desiredAccuracy = foregroundUsers > 0 ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        manager.distanceFilter = foregroundUsers > 0 ? 5 : 50
        manager.pausesLocationUpdatesAutomatically = true
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
        // 釣行中：画面を見ている間だけ高精度（GPS）。離れたら低頻度に戻す
        if mode == .tracking {
            manager.desiredAccuracy = foregroundUsers > 0 ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
            manager.distanceFilter = foregroundUsers > 0 ? 5 : 50
            // OS が更新を止めていたら起こす（画面を開いたのに現在地が動かないのを防ぐ）
            if foregroundUsers > 0 { manager.startUpdatingLocation() }
            return
        }
        // 滞在の確認中は、その設定のまま（GPS の精度で取っている）
        if mode == .candidate { return }
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
        guard mode != .tracking, mode != .candidate else { return }
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
        for r in manager.monitoredRegions where r.identifier.hasPrefix(GeofencePlanner.prefix) { manager.stopMonitoring(for: r) }
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

    // 境界の出入り。アプリが終了していても OS が起動して届ける（`FogApp.init` で `AppServices` を作った時点で受け取れる）
    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in self.onRegionEvent?(id, true) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in self.onRegionEvent?(id, false) }
    }

    /// 境界を置いた時点ですでに中に居るとき（釣り場で設定をオンにした、釣り場でアプリを入れ直した）は「入った」知らせが来ないので、状態を聞く
    nonisolated func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        manager.requestState(for: region)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard state == .inside else { return }
        let id = region.identifier
        Task { @MainActor in self.onRegionEvent?(id, true) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse, self.wantsAlwaysAuthorization { manager.requestAlwaysAuthorization() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
