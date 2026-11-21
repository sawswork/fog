import Foundation
import SwiftData
import UserNotifications
import Core

/// アプリ全体で共有するサービス群。`FogApp` が生成し、環境に流す。
@MainActor
@Observable
final class AppServices {
    let persistence: PersistenceController
    let store: FogStore
    let environment: EnvironmentService
    let location: LocationService
    let scheduler: SnapshotScheduler
    let detection: SessionDetectionService
    let capture: CaptureService
    let photoImport: PhotoImportService
    let report: ReportService
    let feeds = FeedService()
    let assistant = AssistantService()
    let inventory = InventoryStore()
    let gridForecast = GridForecastService()
    let portWind = PortWindService()
    /// 釣行中の音声の知らせ（F-70）
    let announcer = SessionAnnouncer()
    /// 仲間との釣果共有（F-54）
    let party = PartyService()
    let router = Router()
    var dataManager: DataManager { DataManager(store: store) }
    /// 画面の状態はタブを切り替えても捨てない（タブに戻るたびに全部計算し直していたのが「重い」の一因。2026-11-09）
    let homeModel = HomeViewModel()
    let logModel = LogViewModel()
    let spotsModel = SpotsViewModel()

    init() {
        let persistence = PersistenceController.live()
        let store = FogStore(container: persistence.container)
        let environment = EnvironmentService.live()
        let location = LocationService()
        let scheduler = SnapshotScheduler(environment: environment, store: store)
        self.persistence = persistence
        self.store = store
        self.environment = environment
        self.location = location
        self.scheduler = scheduler
        let detection = SessionDetectionService(location: location, store: store, scheduler: scheduler, environment: environment)
        self.detection = detection
        // 釣り場の境界の出入り（自動開始・終了）。アプリが OS に起こされた直後（画面なし）にも届くので、ここでつなぐ
        location.onRegionEvent = { [weak detection] identifier, inside in
            detection?.regionEvent(identifier: identifier, inside: inside)
        }
        let capture = CaptureService(store: store, environment: environment, detection: detection)
        self.capture = capture
        self.photoImport = PhotoImportService(store: store, capture: capture)
        let report = ReportService(store: store)
        self.report = report
        detection.onSessionEnded = { [photoImport] id in
            Task { @MainActor in
                await photoImport.importPhotos(for: id)
                if let s = await report.attachReport(to: id) {
                    SessionNotifications.sessionEnded(spotName: (try? store.spot(id: s.spotID))?.name ?? "釣り場", catches: s.catches.count, summary: s.report?.summary, sessionID: id)
                }
            }
        }
        // 釣果の保存・削除を仲間へ（F-54）
        let party = self.party
        capture.onCatchSaved = { [weak store] item in
            guard let store else { return }
            Task { @MainActor in await party.upload(item, store: store) }
        }
        capture.onCatchDeleted = { id in Task { @MainActor in await party.delete(catchID: id) } }
        // 釣果を後から直した・消したとき：その釣行を参照しているものを作り直す。
        // レポートの文章（終わった釣行だけ）と、仲間へ送る釣行の要約。続けて直しても 1 回で済むよう、最後の修正から 1.5 秒待つ
        let debouncer = SessionEditDebouncer()
        capture.onSessionEdited = { [weak store] id in
            Task { @MainActor in
                debouncer.schedule(id) {
                    guard let store else { return }
                    _ = await report.attachReport(to: id)
                    await party.refreshSummary(sessionID: id, store: store)
                }
            }
        }
        // 釣行中の音声の知らせ（F-70）：記録の開始で動き出し、終了で止まる。文はそのときの釣り場の状況から作る
        let announcer = self.announcer
        location.keepsRunningWhileTracking = SessionAnnouncer.isEnabled
        scheduler.onStart = { announcer.start() }
        scheduler.onStop = { announcer.stop() }
        announcer.isListening = { SpeechRecorder.activeCount > 0 }
        announcer.makeText = { [weak self] in await self?.voiceBriefing() }
    }

    /// 音声の知らせ（F-70）の文：記録中の釣り場（無ければホームの釣り場・登録した釣り場）の今の時刻・釣れ率・潮・30 分後の天気
    func voiceBriefing(now: Date = .now) async -> String? {
        let spots = (try? store.spots()) ?? []
        let active = try? store.activeSession()
        let spot: Spot? = active.flatMap { s in spots.first { $0.id == s.spotID } }
            ?? UserDefaults.standard.string(forKey: "fog.homeSpotID").flatMap(UUID.init(uuidString:)).flatMap { id in spots.first { $0.id == id } }
            ?? spots.first { $0.isRegistered && $0.coordinate.isPlausible }
        let candidates: [Coordinate?] = [active != nil ? scheduler.currentCoordinate : nil, spot?.coordinate, location.lastFix?.coordinate]
        guard let coordinate = candidates.compactMap({ $0 }).first(where: { $0.isPlausible }) else { return nil }
        await environment.refreshIfNeeded(at: coordinate, now: now)
        let current = environment.snapshot(at: now, coordinate: coordinate)
        let laterMinutes = 30
        let later = environment.weatherSnapshot(at: now.addingTimeInterval(Double(laterMinutes) * 60), coordinate: coordinate)
        // 釣れ率は画面と同じ計算（自分の記録の傾向を入れる）
        let ownSessions = (try? store.ownSessions()) ?? []
        let personal = PersonalModel.learn(from: ownSessions.filter { !$0.isActive }, coordinateOf: { s in spots.first { $0.id == s.spotID }?.coordinate })
        let engine = ScoreEngine(personal: personal.total.hours >= 1 ? personal : nil)
        let score = engine.score(ScoreInput(at: now, coordinate: coordinate, env: current)).score
        let input = VoiceBriefing.Input(
            now: now, spotName: (active != nil ? detection.activeSpotName : nil) ?? spot?.name ?? "", score: score,
            tideLevelCm: current.tideLevelCm, tideRateCmPerHour: current.tideRateCmPerHour, tideName: current.tideName,
            nextHighTideAt: current.nextHighTideAt, nextLowTideAt: current.nextLowTideAt, laterMinutes: laterMinutes,
            weatherLater: later.conditionCode == nil ? nil : HomeViewModel.weatherName(later.conditionCode, precipitation: later.precipitationMM),
            precipitationChanceLater: later.precipitationChance, temperatureLaterC: later.airTemperatureC,
            windLaterMS: later.windSpeedMS, windDirectionLaterDeg: later.windDirectionDeg)
        return VoiceBriefing.text(input)
    }

    var hookRecorder: HookEventRecorder { HookEventRecorder(store: store, detection: detection, scheduler: scheduler, capture: capture, inventory: inventory) }

    /// 起動時：カタログ、保存データの補正、通知、釣行の引き継ぎ。
    func start() async {
        RouterHolder.shared.router = router
        CatalogSeeder.seedIfNeeded(store: store)
        feeds.migrateRepositoryOwnerIfNeeded()
        // 潮名の規則を直した分、過去の記録を揃える。直した釣行はレポートも作り直す（文中の潮名が変わるため）
        let repaired = DataRepairs.run(store: store)
        await SessionNotifications.requestAuthorization()
        detection.start()
        drainPendingHookEvents()
        _ = await PhotoLibraryService.requestAuthorization()
        if !repaired.isEmpty {
            let report = self.report
            Task { @MainActor in for id in repaired { _ = await report.attachReport(to: id) } }
        }
        let store = self.store, party = self.party
        Task { @MainActor in await party.syncIfNeeded(store: store) }
    }

    /// フォアグラウンド復帰：ウィジェットからの針ロストを取り込み、釣行中なら標準カメラの写真を取り込む（F-08）。仲間の釣果も取りに行く
    func didBecomeActive() async {
        drainPendingHookEvents()
        detection.endStaleSessionIfNeeded()
        // 釣り場が増えた・動いたあとの境界を置き直す（自動検出オンのときだけ働く）
        detection.refreshGeofences()
        // 釣行中なら、雨の予報を見直す（F-69）
        await scheduler.rain.check()
        if let active = try? store.activeSession() {
            await photoImport.importPhotos(for: active.id)
        }
        await party.syncIfNeeded(store: store)
    }

    /// ウィジェットの「針ロスト」はアプリを開かずに時刻だけ記録される。ここで釣行・位置を補って保存する（F-15）。
    func drainPendingHookEvents() {
        for date in FogShared.takePendingHookLost() {
            hookRecorder.record(.lost, at: date)
        }
    }
}

/// 通知のアクション（停止・破棄）を受ける。
/// デリゲートはどのスレッドで呼ばれるか決まっていないので、ここでは何も触らず MainActor へ渡してから `AppServices` を使う
/// （2026-11-09：通知のタイミングで落ちる報告への対処。完了ハンドラ型にして、必ず呼び終える）
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    weak var services: AppServices?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let idString = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            Perf.mark("通知を開いた: \(action)")
            guard let services = self?.services, let idString, let sessionID = UUID(uuidString: idString) else { return }
            switch action {
            case SessionNotifications.stopAction:
                await services.detection.stopNow()
            case SessionNotifications.discardAction:
                services.detection.discard(sessionID: sessionID)
            default:
                break
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// 釣行ごとに、最後の修正から少し待ってから 1 回だけ処理する（続けて直したとき、レポートを何度も作らない）
@MainActor
final class SessionEditDebouncer {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func schedule(_ id: UUID, delay: TimeInterval = 1.5, _ work: @escaping @MainActor () async -> Void) {
        tasks[id]?.cancel()
        tasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.tasks[id] = nil
            await work()
        }
    }
}

