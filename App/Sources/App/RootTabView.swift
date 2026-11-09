import SwiftUI
import Core

/// 5タブ。文字ラベルなし、中央は撮影（オレンジの円）。
/// L0 ではプレースホルダー。各画面は Features/ 配下のループで実装する。
struct RootTabView: View {
    enum Tab: Hashable { case home, log, capture, guide, spots }
    @State private var selected: Tab = .home
    @Environment(AppServices.self) private var services

    /// テーマの配置がタブバーを消しているか（F-58）。画面の行き来はホームの部品（nav / button）と、他の画面の右下のホームボタン
    private var hidesTabBar: Bool { ThemeStore.shared.theme.home?.hidesTabBar == true }

    var body: some View {
        Group {
            switch selected {
            case .home: HomeView()
            case .log: LogView()
            case .capture: CaptureView()
            case .guide: GuideView()
            case .spots: SpotsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(screenBackground)
        .environment(\.captureTab, { selected = .capture })
        .environment(\.switchTab, { selected = $0 })
        // タブバーは下のセーフエリアとして置く。各画面はタブバーを除いた高さを 100% として使える
        .safeAreaInset(edge: .bottom, spacing: 0) { if !hidesTabBar { tabBar } }
        // タブバーが無いテーマ：ホーム以外の画面では右下にホームへ戻るボタン
        .overlay(alignment: .bottomTrailing) {
            if hidesTabBar, selected != .home {
                Button { selected = .home } label: {
                    Image(systemName: "house.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(DS.Color.textPrimary)
                        .frame(width: 48, height: 48).background(DS.Color.panel.opacity(0.95), in: Circle())
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .padding(DS.Spacing.l)
            }
        }
        .ignoresSafeArea(.keyboard)
        .onChange(of: services.router.pending) { _, link in
            guard let link else { return }
            switch link {
            case .capture: selected = .capture
            case .home: selected = .home
            case .toggleTackle: services.capture.currentTackle = (services.capture.currentTackle ?? .spinning) == .spinning ? .bait : .spinning
            case .hookLost: services.hookRecorder.record(.lost)
            }
            services.router.pending = nil
        }
        .onAppear {
            if services.router.pending == .capture { selected = .capture; services.router.pending = nil }
        }
        // テーマ切替（F-49）で全画面を作り直す
        .id(ThemeStore.shared.theme)
    }

    /// 画面ごとの背景（テーマ画像があればそれ、無ければ背景色）。地図と撮影は画像を敷かない
    @ViewBuilder private var screenBackground: some View {
        switch selected {
        // 配置のあるテーマはホームが自分で層を描く
        case .home: if ThemeStore.shared.theme.home == nil { ThemeBackground(name: .bgHome) } else { DS.Color.background.ignoresSafeArea() }
        case .log: ThemeBackground(name: .bgLog)
        case .guide: ThemeBackground(name: .bgGuide)
        case .capture, .spots: DS.Color.background.ignoresSafeArea()
        }
    }

    private var tabBar: some View {
        TabIconsRow(selected: selected) { tab in
            if selected == tab { NotificationCenter.default.post(name: .fogHomeReselected, object: tab == .home ? tab : nil) }
            selected = tab
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(tabBarBackground)
    }

    /// タブバーの帯。テーマ画像（tabbar）があればそれを横いっぱいに敷く
    private var tabBarBackground: some View {
        ZStack {
            DS.Color.surface
            if let image = ThemeAssets.image(.tabbar) {
                GeometryReader { geo in
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                }
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 28, style: .continuous))
        .ignoresSafeArea(edges: .bottom)
    }
}

/// 5 つの画面のアイコン（タブバーと、テーマの配置の `nav` 部品で共用）。文字ラベルなし、中央は撮影
struct TabIconsRow: View {
    let selected: RootTabView.Tab
    var compact = false
    let onSelect: (RootTabView.Tab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            tabButton(.home, system: "house")
            tabButton(.log, system: "doc.text")
            captureButton
            tabButton(.guide, system: "book")
            tabButton(.spots, system: "map")
        }
    }

    private static func ornament(for tab: RootTabView.Tab) -> ThemeAssets.Name {
        switch tab {
        case .home: return .tabHome
        case .log: return .tabLog
        case .capture: return .tabCamera
        case .guide: return .tabGuide
        case .spots: return .tabSpots
        }
    }

    private func tabButton(_ tab: RootTabView.Tab, system: String) -> some View {
        Button { onSelect(tab) } label: {
            Group {
                if ThemeAssets.has(Self.ornament(for: tab)) {
                    // テーマのアイコン。選択中はテーマ色の丸い座布団と影で持ち上げ、他は少し薄く
                    ZStack {
                        if selected == tab {
                            Circle().fill(DS.Color.accent.opacity(0.22)).frame(width: compact ? 40 : 50, height: compact ? 40 : 50)
                        }
                        ThemeOrnament(name: Self.ornament(for: tab))
                            .frame(width: compact ? 32 : 40, height: compact ? 32 : 40)
                            .saturation(selected == tab ? 1 : 0.7)
                            .opacity(selected == tab ? 1 : 0.7)
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    }
                } else {
                    Image(systemName: selected == tab ? system + ".fill" : system)
                        .font(.system(size: compact ? 18 : 22, weight: .regular))
                        .foregroundStyle(selected == tab ? DS.Color.textPrimary : DS.Color.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 32 : 40)
        }
        .buttonStyle(.plain)
    }

    private var captureButton: some View {
        Button { onSelect(.capture) } label: {
            ZStack {
                if ThemeAssets.has(.tabCamera) {
                    // 明るいテーマはテーマ色の丸、暗いテーマは黒い丸にテーマ色の光（スライムが発光して見える）
                    Circle().fill(ThemeStore.shared.theme.isLight ? DS.Color.accent : DS.Color.surfaceRaised).frame(width: compact ? 48 : 58, height: compact ? 48 : 58)
                        .shadow(color: DS.Color.accent.opacity(ThemeStore.shared.theme.isLight ? 0.55 : 0.8), radius: 14)
                    ThemeOrnament(name: .tabCamera).frame(width: compact ? 38 : 46, height: compact ? 38 : 46)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                } else {
                    Circle().fill(DS.Color.accent).frame(width: compact ? 46 : 56, height: compact ? 46 : 56)
                        .shadow(color: DS.Color.accent.opacity(0.55), radius: 12)
                    Image(systemName: "camera.fill")
                        .font(.system(size: compact ? 18 : 22, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("撮影")
    }
}

/// 環境経由で画面を切り替える（テーマの配置の部品が使う）
struct SwitchTabKey: EnvironmentKey { static let defaultValue: ((RootTabView.Tab) -> Void)? = nil }
extension EnvironmentValues { var switchTab: ((RootTabView.Tab) -> Void)? { get { self[SwitchTabKey.self] } set { self[SwitchTabKey.self] = newValue } } }

extension Notification.Name {
    /// 表示中のタブをもう一度押したとき（ホームは今日に戻る）
    static let fogHomeReselected = Notification.Name("fog.tabReselected")
}
