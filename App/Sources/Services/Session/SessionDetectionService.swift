import Foundation
import CoreLocation
import Core
import os

/// 釣行の開始・終了、釣り場の自動登録（F-02）、立ち位置のポイント化（§3）。
/// 位置は `LocationService`、判定は Core の `SessionDetector`、保存は `FogStore`、環境は `SnapshotScheduler`。
///
/// 2026-11-09：位置情報での自動開始・終了（F-01）は既定でオフ（精度と電池の問題。開発者の指示）。
/// 開始・終了はホームのボタン（F-48）か撮影で行い、記録中の立ち位置だけ低頻度で記録する。自動検出は 設定 > 自動検出 でオンにできる。
///
/// 2026-11-19：自動検出を作り直した（開発者「釣り場についたら自動で開始、離れたら終了。精度と電池を改善できる？」）。
/// - **始めるのは登録した釣り場だけ**。海のそばかどうかを調べて「どこでも」始める方式はやめた（自宅や店で始まった原因）
/// - 待機中は釣り場の境界（半径 300 m のジオフェンス）を OS に見張らせるだけで、アプリは位置を取らない
/// - 境界に入ったら、滞在（感度に応じて 5〜20 分）を確かめる間だけ位置を取り、確かめられたら着いた時刻にさかのぼって始める
/// - 記録中は、始めた場所を中心にした境界をもう 1 つ置く。出たら位置の更新を起こして、離れた時刻で終える
/// - 境界の知らせは、アプリが終了していても OS が起動して届ける。画面が無くても動くよう、ここで必要な準備をする（`start` は何度呼んでもよい）
@MainActor
@Observable
final class SessionDetectionService {
    static let sensitivityKey = "fog.detectionSensitivity"
    static let autoDetectKey = "fog.detection.autoEnabled"
    static let registeredSpotRadiusM: Double = 300
    /// 手動で始めた（撮影で始まった）釣行を忘れていたとき、最後の動き（開始・釣果・針）からこの時間で自動的に終える
    static let staleSessionAfter: TimeInterval = 8 * 3600

    /// 位置情報での自動開始・終了。既定はオフ
    static var autoDetectionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoDetectKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoDetectKey) }
    }

    private(set) var detector: SessionDetector
    private(set) var activeSessionID: UUID?
    private(set) var activeSpotName: String?
    private var lastEndedSessionID: UUID?
    /// 根掛かり注意（F-39）：直近に知らせたメッシュ
    private var snagMeshKey: String?

    private let location: LocationService
    private let store: FogStore
    private let scheduler: SnapshotScheduler
    private let environment: EnvironmentService
    private let shore = ShoreOracle()
    private var task: Task<Void, Never>?
    private var started = false
    /// 境界に入ってから、滞在を確かめている間の見張り（時間切れで待機へ戻す）
    private var candidateTask: Task<Void, Never>?
    private var awayCheckTask: Task<Void, Never>?
    /// 滞在の確認中に処理した最後の位置の時刻（1 秒ごとに届くので間引く）
    private var lastCandidateFixAt: Date?
    /// 最後に処理した位置の時刻（長く途切れたら、数えかけの滞在を捨てる）
    private var lastHandledAt: Date?
    /// 終了直後に呼ばれる（写真の取り込み・レポート生成など）。保存済みの釣行 ID を渡す
    var onSessionEnded: ((UUID) -> Void)?
    private static let log = Logger(subsystem: "fog", category: "session")

    init(location: LocationService, store: FogStore, scheduler: SnapshotScheduler, environment: EnvironmentService) {
        self.location = location
        self.store = store
        self.scheduler = scheduler
        self.environment = environment
        detector = SessionDetector(settings: .forSensitivity(Self.sensitivity))
    }

    static var sensitivity: DetectionSettings.Sensitivity {
        get { DetectionSettings.Sensitivity(rawValue: UserDefaults.standard.string(forKey: sensitivityKey) ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sensitivityKey) }
    }

    func applySensitivity(_ s: DetectionSettings.Sensitivity) {
        Self.sensitivity = s
        detector.settings = .forSensitivity(s)
    }

    /// 設定 > 自動検出 のオンオフ。オンにしたら「常に許可」を求めて釣り場の境界を置き、オフにしたら境界を外す
    func applyAutoDetection(_ enabled: Bool) {
        Self.autoDetectionEnabled = enabled
        location.wantsAlwaysAuthorization = enabled
        if enabled {
            location.requestAuthorization()
            if activeSessionID == nil { location.startMonitoring() }
        } else {
            endCandidate()
            if activeSessionID == nil {
                detector.reset()
                location.stopTracking(monitor: false)
            }
        }
        refreshGeofences()
    }

    // MARK: 自動で始める釣り場と境界

    static let disabledSpotsKey = "fog.detection.disabledSpots"
    private static let suppressedKey = "fog.detection.suppressed"

    /// 自動で始めない釣り場（設定 > 自動検出 で外した、または「誤検出なので破棄」した）
    static var disabledSpotIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledSpotsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: disabledSpotsKey) }
    }

    static func isArmed(spotID: UUID) -> Bool { !disabledSpotIDs.contains(spotID.uuidString) }

    func setArmed(_ armed: Bool, spotID: UUID) {
        var ids = Self.disabledSpotIDs
        if armed { ids.remove(spotID.uuidString) } else { ids.insert(spotID.uuidString) }
        Self.disabledSpotIDs = ids
        refreshGeofences()
    }

    /// 自動で始める候補になる釣り場：登録済みで位置があり、外していないもの
    func registeredSpots() -> [Spot] {
        ((try? store.spots()) ?? []).filter { $0.isRegistered && $0.coordinate.isPlausible }
    }

    private func armedSpots() -> [Spot] { registeredSpots().filter { Self.isArmed(spotID: $0.id) } }

    /// 境界を置き直す：自動検出オンなら、近い順に 19 個までの釣り場と、記録中なら始めた場所。オフなら全部外す。
    /// 釣り場が増えた・消えた・動いたあと、釣行の開始と終了のあと、前面に戻ったときに呼ぶ
    func refreshGeofences() {
        guard Self.autoDetectionEnabled else { location.setGeofences([]); return }
        // 近さの基準：最後に分かっている位置 → 直近の釣行の釣り場
        let spots = armedSpots()
        var near = location.lastFix?.coordinate
        if near == nil, let last = (try? store.sessions())?.first {
            near = spots.first { $0.id == last.spotID }?.coordinate
        }
        var regions = GeofencePlanner.regions(spots: spots.map { (id: $0.id, coordinate: $0.coordinate) }, near: near, radiusM: Self.registeredSpotRadiusM)
        if activeSessionID != nil, let anchor = detector.activeAnchor, anchor.isPlausible {
            regions.append(GeofencePlanner.Region(id: GeofencePlanner.sessionID, center: anchor, radiusM: max(detector.settings.awayDistanceM, 150)))
        }
        location.setGeofences(regions)
    }

    /// 境界の出入り（`LocationService.onRegionEvent`）。アプリが OS に起こされた直後にも呼ばれる
    func regionEvent(identifier: String, inside: Bool) {
        start()
        guard Self.autoDetectionEnabled else { return }
        Perf.mark("境界：\(identifier == GeofencePlanner.sessionID ? "釣行" : "釣り場") \(inside ? "入った" : "出た")")
        if identifier == GeofencePlanner.sessionID {
            // 記録中に始めた場所から離れた：位置の更新を起こして、離れた時刻で終える判定を動かす
            if !inside, activeSessionID != nil { location.nudge(); scheduleAwayCheck() }
            return
        }
        guard let spotID = GeofencePlanner.spotID(from: identifier) else { return }
        if inside {
            guard activeSessionID == nil, Self.isArmed(spotID: spotID) else { return }
            beginCandidate()
        } else if activeSessionID == nil {
            // 通り過ぎた、または手動で終えてから立ち去った：数えかけの滞在と「開始を止めている」状態を戻す
            detector.leftPlace()
            Self.clearSuppressed()
            endCandidate()
        } else {
            location.nudge()
        }
    }

    /// 釣り場の境界に入った：滞在を確かめる間だけ位置を取る。確かめられなければ（滞在時間 + 3 分で）待機へ戻る
    private func beginCandidate() {
        guard activeSessionID == nil, candidateTask == nil else { return }
        location.startCandidate()
        lastCandidateFixAt = nil
        let limit = detector.settings.dwellToStart + 180
        candidateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.candidateTask = nil
            guard self.activeSessionID == nil else { return }
            self.detector.leftPlace()
            self.location.stopCandidate()
        }
    }

    private func endCandidate() {
        candidateTask?.cancel()
        candidateTask = nil
        location.stopCandidate()
    }

    /// 釣行の境界を出たあと、離れたまま位置が届かないとき（立ち止まっている・更新が止まった）の保険：
    /// 終了までの時間がたったら、もう一度位置を取り直して判定させる
    private func scheduleAwayCheck() {
        awayCheckTask?.cancel()
        let wait = detector.settings.awayToEnd + 60
        awayCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled, self.activeSessionID != nil else { return }
            self.location.nudge()
        }
    }

    // 手動で終えたあとの「開始を止めている」状態は、アプリが終了しても 6 時間は覚えておく
    // （その場に居るうちに OS に起こし直されて、また始まってしまうのを防ぐ）
    private static func saveSuppressed(_ anchor: Coordinate) {
        UserDefaults.standard.set([anchor.latitude, anchor.longitude, Date.now.timeIntervalSince1970], forKey: suppressedKey)
    }
    private static func clearSuppressed() { UserDefaults.standard.removeObject(forKey: suppressedKey) }
    private static func loadSuppressed(now: Date = .now) -> Coordinate? {
        guard let v = UserDefaults.standard.array(forKey: suppressedKey) as? [Double], v.count == 3,
              now.timeIntervalSince1970 - v[2] < 6 * 3600 else { return nil }
        return Coordinate(latitude: v[0], longitude: v[1])
    }

    // MARK: 起動

    /// 何度呼んでもよい（画面からの起動と、境界の知らせで OS に起こされたときの両方から呼ばれる）
    func start() {
        guard !started else { return }
        started = true
        if let anchor = Self.loadSuppressed() { detector.endManually(anchor: anchor) }
        SessionNotifications.registerCategories()
        location.wantsAlwaysAuthorization = Self.autoDetectionEnabled
        location.requestAuthorization()
        endStaleSessionIfNeeded()
        // 記録中の釣行が残っていれば引き継ぐ（アプリ再起動後）
        if let active = try? store.activeSession() {
            resumeTracking(session: active)
        } else if Self.autoDetectionEnabled {
            location.startMonitoring()
        }
        refreshGeofences()
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            for await fix in location.fixes() {
                await self.handle(fix)
            }
        }
    }

    /// 忘れられた釣行を終える：最後の動きから 8 時間以上たった記録中の釣行は、最後の動きの 1 時間後に終わったことにする
    /// （自動検出をやめたので、位置で終わらない。起動時と前面復帰時に呼ぶ）
    func endStaleSessionIfNeeded(now: Date = .now) {
        guard let active = try? store.activeSession() else { return }
        let lastActivity = ([active.startedAt] + active.catches.map(\.at) + active.hookEvents.map(\.at)).max() ?? active.startedAt
        guard now.timeIntervalSince(lastActivity) > Self.staleSessionAfter else { return }
        activeSessionID = active.id
        activeSpotName = (try? store.spot(id: active.spotID))?.name
        Task { await endSession(at: lastActivity.addingTimeInterval(3600)) }
    }

    private func resumeTracking(session: Core.Session) {
        activeSessionID = session.id
        activeSpotName = (try? store.spot(id: session.spotID))?.name
        // 判定の状態は覚えていないので、記録中に戻す（これが無いと、起こし直されたあと「離れたら終了」が働かない）
        if !detector.isActive, let anchor = session.track.first?.coordinate ?? (try? store.spot(id: session.spotID))?.coordinate, anchor.isPlausible {
            detector.beginManually(at: session.startedAt, anchor: anchor)
        }
        location.startTracking()
        if let coordinate = session.track.last?.coordinate ?? (try? store.spot(id: session.spotID))?.coordinate {
            scheduler.start(session: session, coordinate: coordinate)
        }
    }

    // MARK: 位置の処理

    func handle(_ fix: LocationFix) async {
        // 起動直後に届く古い位置（前回の記憶）は捨てる。これを候補の開始時刻にすると、次の位置で滞在時間が一気に満たされて即開始してしまう
        guard Date.now.timeIntervalSince(fix.at) < 120 else { return }
        // 自動検出オフ：記録中なら立ち位置だけ記録する（逆ジオコーディングも状態機械も使わない）
        guard Self.autoDetectionEnabled else {
            // 精度の悪い位置（Wi-Fi・基地局の推定。数百 m ずれる）は立ち位置に使わない。
            // 立ち位置の記録は 35 m 以内、スナップショット・ロストの位置は 65 m 以内の位置だけ
            if activeSessionID != nil {
                if fix.horizontalAccuracyM <= Self.snapshotAccuracyM { scheduler.currentCoordinate = fix.coordinate }
                if fix.horizontalAccuracyM <= Self.trackAccuracyM { recordTrackIfMoved(fix) }
            }
            return
        }
        // 滞在の確認中は GPS が毎秒届く。10 秒に 1 回だけ見る
        if location.mode == .candidate {
            if let last = lastCandidateFixAt, fix.at.timeIntervalSince(last) < 10 { return }
            lastCandidateFixAt = fix.at
        }
        // 位置が 10 分以上途切れたあとは、数えかけの滞在を捨てる（古い開始時刻のまま「着いた瞬間に開始」しないように）
        if let last = lastHandledAt, fix.at.timeIntervalSince(last) > 600, detector.isCandidate { detector.leftPlace() }
        lastHandledAt = fix.at
        let context = await context(for: fix)
        let events = detector.handle(fix, context: context)
        for event in events {
            switch event {
            case .start(let at, let anchor, let spotID):
                guard activeSessionID == nil else { continue }
                await startSession(at: at, anchor: anchor, spotID: spotID)
            case .resume(_, let at, let anchor):
                guard activeSessionID == nil else { continue }
                await resumeSession(at: at, anchor: anchor)
            case .end(let at):
                await endSession(at: at)
            case .track(let sample):
                if fix.horizontalAccuracyM <= Self.trackAccuracyM { recordTrack(sample) }
            }
        }
        if activeSessionID != nil, fix.horizontalAccuracyM <= Self.snapshotAccuracyM { scheduler.currentCoordinate = fix.coordinate }
    }

    /// 立ち位置として記録する位置の精度（m）と、スナップショット・ロストの位置に使う精度（m）
    static let trackAccuracyM = 35.0
    static let snapshotAccuracyM = 65.0

    /// 始めてよい場所か：自動で始める釣り場（登録済みで、外していないもの）の 300 m 以内だけ。
    /// 以前は、登録していない場所でも海のそばなら始めていた（逆ジオコーディングで判定）。自宅や店で始まる原因だったのでやめた（2026-11-19）
    private func context(for fix: LocationFix) async -> SessionDetector.Context {
        let registered = armedSpots()
            .min { Geo.distanceMeters($0.coordinate, fix.coordinate) < Geo.distanceMeters($1.coordinate, fix.coordinate) }
        if let registered, Geo.distanceMeters(registered.coordinate, fix.coordinate) <= Self.registeredSpotRadiusM {
            return .init(registeredSpotID: registered.id, nearShore: true)
        }
        return .init(registeredSpotID: nil, nearShore: false)
    }

    // MARK: 開始・再開・終了

    private func startSession(at: Date, anchor: Coordinate, spotID: UUID?, manual: Bool = false) async {
        var spot: Spot
        if let spotID, let existing = try? store.spot(id: spotID) {
            spot = existing
        } else {
            let info = await shore.info(for: anchor)
            spot = Spot(name: info?.nameCandidate ?? "釣り場", coordinate: anchor, isRegistered: true, createdAt: at)
            try? store.upsert(spot)
        }
        // 前回のタックル・リグを引き継ぐ（F-14）
        let previous = (try? store.sessions())?.first
        let session = Core.Session(spotID: spot.id, startedAt: at, tackle: previous?.tackle, rigID: previous?.rigID,
                                   track: [TrackSample(at: at, coordinate: anchor)], tackleID: previous?.tackleID, isAutoDetected: !manual)
        do {
            try store.upsert(session)
        } catch {
            Self.log.error("session start save failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        activeSessionID = session.id
        activeSpotName = spot.name
        WidgetSync.setRecording(true)
        candidateTask?.cancel()
        candidateTask = nil
        Self.clearSuppressed()
        location.startTracking()
        refreshGeofences()
        scheduler.start(session: session, coordinate: anchor)
        // 開始の通知は自動検出のときだけ（自分で押したときに「始めました」と言われても意味がない）
        if !manual { SessionNotifications.sessionStarted(spotName: spot.name, sessionID: session.id) }
        SafetyNotifier.schedule(at: at, coordinate: anchor, environment: environment)
        Self.log.info("session started at \(spot.name, privacy: .public)")
    }

    private func resumeSession(at: Date, anchor: Coordinate) async {
        guard let id = lastEndedSessionID, var session = try? store.session(id: id) else {
            await startSession(at: at, anchor: anchor, spotID: nil)
            return
        }
        session.endedAt = nil
        session.track.append(TrackSample(at: at, coordinate: anchor))
        try? store.upsert(session)
        activeSessionID = session.id
        candidateTask?.cancel()
        candidateTask = nil
        location.startTracking()
        refreshGeofences()
        WidgetSync.setRecording(true)
        scheduler.start(session: session, coordinate: anchor)
        SafetyNotifier.schedule(at: at, coordinate: anchor, environment: environment)
        Self.log.info("session resumed (run and gun)")
    }

    func endSession(at: Date) async {
        guard let id = activeSessionID, var session = try? store.session(id: id) else { return }
        session.endedAt = at
        session.activity = await PedometerService().activity(from: session.startedAt, to: at)
        session = await environment.backfill(session)
        try? store.upsert(session)
        onSessionEnded?(id)
        scheduler.stop()
        SafetyNotifier.cancel()
        if snagMeshKey != nil { snagMeshKey = nil; WidgetSync.setSnagZone(false) }
        location.stopTracking(monitor: Self.autoDetectionEnabled)
        lastEndedSessionID = id
        activeSessionID = nil
        awayCheckTask?.cancel()
        awayCheckTask = nil
        // 釣行の境界を外す。この釣行で釣り場が増えていれば、その境界を置く
        refreshGeofences()
        WidgetSync.setRecording(false)
        let spotName = (try? store.spot(id: session.spotID))?.name ?? "釣り場"
        SessionNotifications.sessionEnded(spotName: spotName, catches: session.catches.count, summary: session.report?.summary, sessionID: id)
        Self.log.info("session ended with \(session.catches.count) catches")
    }

    /// 手動運用の立ち位置：前の点から 25 m 以上か 10 分以上たったときだけ追加
    private func recordTrackIfMoved(_ fix: LocationFix) {
        guard let id = activeSessionID, let session = try? store.session(id: id) else { return }
        if let last = session.track.last, Geo.distanceMeters(last.coordinate, fix.coordinate) < 25, fix.at.timeIntervalSince(last.at) < 600 { return }
        recordTrack(TrackSample(at: fix.at, coordinate: fix.coordinate))
    }

    private func recordTrack(_ sample: TrackSample) {
        guard let id = activeSessionID, var session = try? store.session(id: id) else { return }
        session.track.append(sample)
        // 立ち位置の追記は分析に影響しない（画面の再計算を起こさない）
        try? store.upsert(session, minor: true)
        // メッシュのポイントを用意しておく（釣果・針ロストが紐付く単位）
        let key = Mesh.key(for: sample.coordinate)
        if let points = try? store.points(spotID: session.spotID), !points.contains(where: { $0.meshKey == key }) {
            try? store.upsert(Point(spotID: session.spotID, coordinate: Mesh.center(for: sample.coordinate), meshKey: key, createdAt: sample.at))
        }
        warnSnag(meshKey: key, spotID: session.spotID)
    }

    /// 根掛かり注意（F-39）：過去に針を失ったメッシュに入ったら 1 回知らせ、ウィジェットの背景を変える。出たら戻す
    private func warnSnag(meshKey: String, spotID: UUID) {
        guard meshKey != snagMeshKey else { return }
        let losses = Analytics.spotStats(sessions: (try? store.sessions(spotID: spotID)) ?? []).hookLossHeatmap[meshKey] ?? 0
        let wasSnag = snagMeshKey != nil
        if losses > 0 {
            snagMeshKey = meshKey
            SessionNotifications.snag(losses: losses, meshKey: meshKey)
            WidgetSync.setSnagZone(true)
        } else if wasSnag {
            snagMeshKey = nil
            WidgetSync.setSnagZone(false)
        }
    }

    // MARK: ワンタップの開始・終了（F-48）

    /// 手動開始に使う位置：現在地 → ホームで選んでいる釣り場 → 直近の釣行の釣り場。どれも無ければ nil
    func manualStartCoordinate() -> (coordinate: Coordinate, spotID: UUID?)? {
        let spots = ((try? store.spots()) ?? []).filter { $0.coordinate.isPlausible }
        if let fix = location.lastFix, fix.coordinate.isPlausible, Date.now.timeIntervalSince(fix.at) < 30 * 60 {
            let near = spots.filter(\.isRegistered)
                .min { Geo.distanceMeters($0.coordinate, fix.coordinate) < Geo.distanceMeters($1.coordinate, fix.coordinate) }
            if let near, Geo.distanceMeters(near.coordinate, fix.coordinate) <= Self.registeredSpotRadiusM {
                return (fix.coordinate, near.id)
            }
            return (fix.coordinate, nil)
        }
        if let id = UserDefaults.standard.string(forKey: "fog.homeSpotID").flatMap(UUID.init(uuidString:)),
           let home = spots.first(where: { $0.id == id }) {
            return (home.coordinate, home.id)
        }
        if let last = (try? store.sessions())?.first, let spot = spots.first(where: { $0.id == last.spotID }) {
            return (spot.coordinate, spot.id)
        }
        return nil
    }

    /// ワンタップで今すぐ釣行を始める。滞在判定は待たない。以後の終了判定・立ち位置の記録・環境スナップショットは自動検出と同じ。
    /// 位置が決められないときは false
    @discardableResult
    func startManually() async -> Bool {
        guard activeSessionID == nil else { return true }
        location.requestAuthorization()
        // 最近の位置が無ければ数秒だけ待って取る（開いた直後に押されることが多い）
        if location.lastFix.map({ Date.now.timeIntervalSince($0.at) > 30 * 60 }) ?? true {
            location.probe(seconds: 20)
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let f = location.lastFix, Date.now.timeIntervalSince(f.at) < 60 { break }
            }
        }
        guard let target = manualStartCoordinate() else { return false }
        let now = Date.now
        detector.beginManually(at: now, anchor: target.coordinate)
        await startSession(at: now, anchor: target.coordinate, spotID: target.spotID, manual: true)
        return activeSessionID != nil
    }

    /// 撮影で釣行が始まったとき（`CaptureService.ensureSession`）に呼ぶ：立ち位置の記録と環境スナップショットを始める
    func adopt(session: Core.Session, coordinate: Coordinate) {
        guard activeSessionID == nil, session.isActive else { return }
        detector.beginManually(at: session.startedAt, anchor: coordinate)
        activeSessionID = session.id
        activeSpotName = (try? store.spot(id: session.spotID))?.name
        WidgetSync.setRecording(true)
        candidateTask?.cancel()
        candidateTask = nil
        location.startTracking()
        refreshGeofences()
        scheduler.start(session: session, coordinate: coordinate)
        SafetyNotifier.schedule(at: session.startedAt, coordinate: coordinate, environment: environment)
    }

    /// ワンタップで今すぐ終える。その場に居続けても自動では再開しない（離れるまで開始判定を止める）
    func endManually() async {
        let anchor = scheduler.currentCoordinate ?? location.lastFix?.coordinate
        await endSession(at: .now)
        detector.endManually(anchor: anchor)
        if let anchor { Self.saveSuppressed(anchor) }
    }

    // MARK: 通知からの操作

    /// 「停止」：今すぐ終了する（ワンタップの終了と同じ）。
    func stopNow() async {
        await endManually()
    }

    // MARK: 除外した場所（誤検出の学習）

    static let excludedKey = "fog.detection.excludedPoints"
    static let exclusionRadiusM: Double = 400

    /// 除外した地点（緯度・経度の組）。この地点から 400 m 以内では自動で始めない
    static var excludedPoints: [Coordinate] {
        get { (UserDefaults.standard.array(forKey: excludedKey) as? [[Double]])?.compactMap { $0.count == 2 ? Coordinate(latitude: $0[0], longitude: $0[1]) : nil } ?? [] }
        set { UserDefaults.standard.set(newValue.map { [$0.latitude, $0.longitude] }, forKey: excludedKey) }
    }
    static var excludedMeshes: [Coordinate] { excludedPoints }
    static func isExcluded(_ c: Coordinate) -> Bool { excludedPoints.contains { Geo.distanceMeters($0, c) <= exclusionRadiusM } }
    /// 自動検出の釣行を破棄・削除したら、その場所（釣り場の中心と立ち位置）を除外に加える（近い点はまとめる）
    static func exclude(session: Core.Session, spot: Spot?) {
        var points = excludedPoints
        for c in [spot?.coordinate].compactMap({ $0 }) + session.track.map(\.coordinate) where c.isPlausible {
            if !points.contains(where: { Geo.distanceMeters($0, c) <= 150 }) { points.append(c) }
        }
        excludedPoints = points
    }
    static func clearExclusions() { excludedPoints = [] }

    /// 「誤検出なので破棄」：釣行を削除し、その場所では自動で始めないようにする（削除は分析に即時反映）。
    func discard(sessionID: UUID) {
        if let session = try? store.session(id: sessionID), session.isAutoDetected {
            Self.exclude(session: session, spot: try? store.spot(id: session.spotID))
            // 「誤検出」と言われた場所に、釣果の記録が 1 つも無ければ、以後は自動で始めない（設定 > 自動検出 で戻せる）。
            // 釣果のある釣り場は、たまたまの誤検出 1 回で止めない
            let proven = ((try? store.sessions(spotID: session.spotID)) ?? []).contains { $0.id != sessionID && !$0.catches.isEmpty }
            if !proven {
                var ids = Self.disabledSpotIDs
                ids.insert(session.spotID.uuidString)
                Self.disabledSpotIDs = ids
            }
        }
        if activeSessionID == sessionID {
            scheduler.stop()
            SafetyNotifier.cancel()
            location.stopTracking(monitor: Self.autoDetectionEnabled)
            activeSessionID = nil
            detector.reset()
            WidgetSync.setRecording(false)
        }
        try? store.deleteSession(id: sessionID)
        refreshGeofences()
    }

    /// 現在の立ち位置に対応するポイント ID（撮影時の紐付けに使う）。
    func currentPointID() -> UUID? {
        guard let id = activeSessionID, let session = try? store.session(id: id),
              let coordinate = scheduler.currentCoordinate ?? session.track.last?.coordinate else { return nil }
        let key = Mesh.key(for: coordinate)
        return (try? store.points(spotID: session.spotID))?.first { $0.meshKey == key }?.id
    }
}
