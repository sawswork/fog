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
