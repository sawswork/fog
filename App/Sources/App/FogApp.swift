import SwiftUI
import SwiftData
import UserNotifications


@main
struct FogApp: App {
    private let services: AppServices
    private let responder = NotificationResponder()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Perf.start()
        let services = AppServices()
        self.services = services
        responder.services = services
        UNUserNotificationCenter.current().delegate = responder
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(ThemeStore.shared.theme.colorScheme)
                .environment(services)
                .environment(services.store)
                .task { await services.start() }
                .onOpenURL { url in
                    if let link = DeepLink.parse(url) { services.router.pending = link }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: Perf.resume(); Task { await services.didBecomeActive() }
                    case .background: Perf.suspend()
                    default: break
                    }
                }
        }
        .modelContainer(services.persistence.container)
    }
}
