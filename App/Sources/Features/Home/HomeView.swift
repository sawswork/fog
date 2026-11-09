import SwiftUI
import Charts
import Core

/// ホーム（§3）。開いた瞬間に「今釣れるか」を数字で、「なぜか」を 4 チップで、「次に何が変わるか」をイベント列で示す。
struct HomeView: View {
    @Environment(AppServices.self) private var services
    private var model: HomeViewModel { services.homeModel }
    @State private var showBreakdown = false
    @State private var showSpots = false
    @State private var showSettings = false
    @State private var showMoon = false
    @State private var showFeed = false
    @State private var showAssistant = false
    @State private var chipDetail: HomeViewModel.Chip?
    @State private var showStartFailed = false
    @State private var toggling = false

    @Environment(\.switchTab) private var switchTab
    @State private var showYear = false

    var body: some View {
        Group {
            // テーマに「ホームの配置」があれば 1 枚の画面に部品を並べる（F-58）。無ければ従来の縦積み
            if let home = ThemeStore.shared.theme.home { composed(home) } else { standard }
        }
        .onAppear { model.attach(services) }
        .task { await model.refresh() }
        .task {
            // 30 秒ごとに「今」を更新（釣れ率・チップ・次のイベント）
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await model.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fogStoreDidChange)) { _ in Task { await model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .fogHomeReselected)) { _ in
            // ホームを表示中にホームのタブを押したら今日に戻す
            withAnimation(.easeInOut(duration: 0.2)) { model.dayOffset = 0 }
            Task { await model.refresh() }
        }
        .sheet(isPresented: $showBreakdown) { BreakdownSheet(result: model.score).presentationDetents([.medium]) }
        .sheet(isPresented: $showSpots) { SpotSwitchSheet(model: model) { showSpots = false }.presentationDetents([.large]) }
        .sheet(item: $chipDetail) { ChipDetailSheet(chip: $0, model: model).presentationDetents([.medium]) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showMoon) { MoonSheet(model: model).presentationDetents([.medium]) }
        .sheet(isPresented: $showFeed) { FeedView(keywords: model.feedKeywords()).presentationDetents([.large]) }
        .sheet(isPresented: $showAssistant) { AssistantView(home: model).presentationDetents([.large]) }
        .sheet(isPresented: $showYear) {
            YearCalendarSheet(model: model) { date in showYear = false; model.show(date: date) }.presentationDetents([.large])
        }
        .alert("位置が分かりません", isPresented: $showStartFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("位置情報を許可するか、ホームの釣り場を選んでからもう一度押してください")
        }
    }

    /// 従来の縦積み（タブ版）
    private var standard: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header.frame(height: geo.size.height * 0.08)
                Group {
                    if model.isRecording, let live = model.liveSession { livePanel(live) } else { scoreArea }
                }
                .frame(height: geo.size.height * 0.20)
                chipsRow.frame(height: geo.size.height * 0.12)
                feedLine.frame(height: geo.size.height * 0.03)
                ForecastChart(model: model).frame(height: geo.size.height * 0.555)
                    .padding(.top, DS.Spacing.xs)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.bottom, DS.Spacing.s)
        }
    }

    // MARK: テーマの配置（F-58）：画像の層と部品を、画面に対する割合の座標に置く

    private func composed(_ home: HomeLayout) -> some View {
        GeometryReader { outer in
            let safeTop = outer.safeAreaInsets.top
            let safeBottom = outer.safeAreaInsets.bottom
            GeometryReader { geo in
                let size = geo.size
                ZStack(alignment: .topLeading) {
                    DS.Color.background
                    ForEach(Array(home.layers.enumerated()), id: \.offset) { _, layer in
                        layerView(layer, size: size)
                    }
                    if !home.layers.isEmpty {
                        (home.scrim.map { Color.black.opacity($0) } ?? ThemeStore.shared.theme.palette.scrim).allowsHitTesting(false)
                    }
                    ForEach(Array(home.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block, size: size, safeTop: safeTop, safeBottom: safeBottom)
                    }
                }
                .frame(width: size.width, height: size.height)
            }
            .ignoresSafeArea()
        }
    }

    private func place<V: View>(_ v: V, _ r: LayoutRect, in size: CGSize) -> some View {
        v.frame(width: r.w * size.width, height: r.h * size.height)
            .position(x: (r.x + r.w / 2) * size.width, y: (r.y + r.h / 2) * size.height)
    }

    @ViewBuilder private func layerView(_ layer: HomeLayout.Layer, size: CGSize) -> some View {
        if let effect = layer.effect {
            // 画像の無い効果の層（光の粒・舞う葉・きらめき）。ずっと眺めていられるホームのため（2026-11-09 開発者の要望）
            let color = layer.parsedColor.map { Color(red: $0.r, green: $0.g, blue: $0.b, opacity: $0.a) } ?? DS.Color.accent
            place(HomeEffectField(kind: effect, count: layer.count, color: color, speed: layer.speed, amount: layer.amount)
                    .opacity(layer.opacity).allowsHitTesting(false),
                  layer.rect, in: size)
        } else if let loaded = ThemeAssets.load(named: layer.image) {
            place(
                Image(uiImage: loaded.image).resizable()
                    .aspectRatio(contentMode: layer.fit == "fit" ? .fit : .fill)
                    .frame(width: layer.rect.w * size.width, height: layer.rect.h * size.height)
                    .clipped()
                    .blendMode(layer.blend == "auto" && loaded.blend == .screen ? .screen : .normal)
                    .opacity(layer.opacity)
                    .modifier(HomeLayerMotion(kind: layer.motion ?? "", speed: layer.speed, amount: layer.amount))
                    .allowsHitTesting(false),
                layer.rect, in: size)
        }
    }

    @ViewBuilder private func blockView(_ b: HomeLayout.Block, size: CGSize, safeTop: CGFloat, safeBottom: CGFloat) -> some View {
        let content = blockContent(b, safeTop: safeTop, safeBottom: safeBottom)
            .padding(b.padding)
            .background(blockBackground(b.background), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .opacity(b.opacity)
        if let action = b.action.flatMap(HomeLayout.Action.init(rawValue:)) ?? defaultAction(b.kind), !selfInteractive(b.kind) {
            place(content.contentShape(Rectangle()).onTapGesture { perform(action) }, b.rect, in: size)
        } else {
            place(content, b.rect, in: size)
        }
    }

    private func blockBackground(_ kind: String) -> AnyShapeStyle {
        switch kind {
        case "panel": return AnyShapeStyle(DS.Color.panel)
        case "glass": return AnyShapeStyle(.ultraThinMaterial)
        default: return AnyShapeStyle(Color.clear)
        }
    }

    /// 部品自身がボタンを持つ（まとめてタップにしない）
    private func selfInteractive(_ kind: HomeLayout.Block.Kind?) -> Bool {
        switch kind {
        case .header, .chips, .forecast, .chart, .table, .week, .nav, .score, .feedLine: return true
        default: return false
        }
    }

    private func defaultAction(_ kind: HomeLayout.Block.Kind?) -> HomeLayout.Action? {
        switch kind {
        case .recentCatches: return .log
        case .miniMap: return .spots
        case .date: return .year
        default: return nil
        }
    }

    private func perform(_ action: HomeLayout.Action) {
        switch action {
        case .home: switchTab?(.home)
        case .log: switchTab?(.log)
        case .capture: switchTab?(.capture)
        case .guide: switchTab?(.guide)
        case .spots: switchTab?(.spots)
        case .settings: showSettings = true
        case .breakdown: showBreakdown = true
        case .feed: showFeed = true
        case .assistant: showAssistant = true
        case .spotSwitch: showSpots = true
        case .moon: showMoon = true
        case .year: showYear = true
        case .toggleSession:
            guard !toggling else { return }
            toggling = true
            Task { let ok = await model.toggleSession(); toggling = false; if !ok { showStartFailed = true } }
        case .none: break
        }
    }

    @ViewBuilder private func blockContent(_ b: HomeLayout.Block, safeTop: CGFloat, safeBottom: CGFloat) -> some View {
        switch b.kind {
        case .header: header.padding(.top, safeTop)
        case .score:
            if model.isRecording, let live = model.liveSession { livePanel(live) } else { scoreArea }
        case .chips: chipsRow
        case .feedLine: feedLine
        case .forecast: ForecastChart(model: model, parts: .all, showsPanel: b.background != "none")
        case .chart: ForecastChart(model: model, parts: [.dayHeader, .chart], showsPanel: false)
        case .table: ForecastChart(model: model, parts: [.table], showsPanel: false)
        case .week: ForecastChart(model: model, parts: [.week], showsPanel: false)
        case .recentCatches: RecentCatchesStrip()
        case .miniMap: HomeMiniMap(model: model)
        case .nav: TabIconsRow(selected: .home, compact: b.style == "compact") { switchTab?($0) }.padding(.bottom, safeBottom)
        case .button:
            Group {
                if let name = b.image, let loaded = ThemeAssets.load(named: name) {
                    Image(uiImage: loaded.image).resizable().aspectRatio(contentMode: .fit)
                        .blendMode(loaded.blend == .screen ? .screen : .normal)
                } else {
                    Image(systemName: b.symbol ?? "circle").font(.system(size: 20, weight: .semibold)).foregroundStyle(DS.Color.textPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .text:
            Text(b.text ?? "").font(b.style == "caption" ? DS.Font.caption : (b.style == "title" ? DS.Font.number(22) : DS.Font.label))
                .foregroundStyle(b.style == "caption" ? DS.Color.textTertiary : DS.Color.textPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).minimumScaleFactor(0.6)
        case .date:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.dayOffset == 0 ? "今日" : "").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                Text(JPFormat.mdw(model.dayStart)).font(DS.Font.number(16)).foregroundStyle(DS.Color.textPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .spacer, .none: Color.clear
        }
    }

    // MARK: ワンタップの開始・終了（F-48）

    private var sessionButton: some View {
        Button {
            guard !toggling else { return }
            toggling = true
            Task {
                let ok = await model.toggleSession()
                toggling = false
                if !ok { showStartFailed = true }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.isRecording ? "stop.fill" : "play.fill").font(.system(size: 9, weight: .bold))
                Text(model.isRecording ? "終了" : "開始").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(model.isRecording ? DS.Color.textPrimary : DS.Color.background)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(model.isRecording ? DS.Color.panel : DS.Color.accent, in: Capsule())
            .opacity(toggling ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isRecording ? "釣行を終了" : "釣行を開始")
    }

    // MARK: 釣果情報（F-27）の 1 行。タップで一覧

    private var feedLine: some View {
        Button { showFeed = true } label: {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "newspaper").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Color.accent)
                if let h = model.feedHeadline {
                    Text(h.title).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                } else {
                    Text(services.feeds.urls.isEmpty ? "釣果情報：設定 > 情報源 で RSS を登録" : "釣果情報を取得中").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, DS.Spacing.xs)
        }
        .buttonStyle(.plain)
    }

    // MARK: 釣行中のライブ画面（F-38）：経過・尾数・直近の釣果・次の変化

    private func livePanel(_ live: Core.Session) -> some View {
        let last = live.catches.max { $0.at < $1.at }
        return HStack(spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("釣行中").font(DS.Font.caption).foregroundStyle(DS.Color.accent)
                Text(HomeViewModel.hm(model.now.timeIntervalSince(live.startedAt))).font(DS.Font.score(40)).foregroundStyle(DS.Color.textPrimary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(live.catches.count)").font(DS.Font.number(22)).foregroundStyle(DS.Color.textPrimary)
                    Text("尾").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                    if let last {
                        Text("直近 \(HomeViewModel.clock(last.at, timeZone: model.timeZone)) \(last.species.isEmpty ? "魚" : last.species)" + (last.lengthCm.map { " \(Int($0.rounded()))cm" } ?? ""))
                            .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button { showBreakdown = true } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(model.score?.score ?? 0)").font(DS.Font.score(30)).foregroundStyle(DS.Color.accent)
                        Text("釣れ率").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                if let t = model.liveNextTide {
                    liveCountdown(t.kind == .high ? "満潮" : "干潮", t.at, color: DS.Color.sea)
                }
                if let m = model.liveNextTwilight {
                    liveCountdown(m.label, m.at, color: DS.Color.sun)
                }
            }
        }
        .padding(.vertical, DS.Spacing.s)
    }

    private func liveCountdown(_ label: String, _ at: Date, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(DS.Font.caption).foregroundStyle(color)
            Text("まで \(HomeViewModel.hm(at.timeIntervalSince(model.now)))").font(DS.Font.number(13)).foregroundStyle(DS.Color.textPrimary)
        }
    }

    // MARK: ヘッダー

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Spacing.s) {
                    if model.isRecording { PulsingDot() }
                    Button { showSpots = true } label: {
                        HStack(spacing: 6) {
                            Text(model.spot?.name ?? "釣り場").font(.system(size: 24, weight: .bold)).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                            Image(systemName: "location.north.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.textSecondary).rotationEffect(.degrees(45))
                        }
                    }
                    .buttonStyle(.plain)
                }
                Text(model.now, format: .dateTime.hour().minute()).font(DS.Font.number(14)).foregroundStyle(DS.Color.textTertiary)
            }
            Spacer()
            sessionButton.frame(height: 32)
            // 相談（F-53）：アプリの記録について聞く・店先の話を声で記録
            Button { showAssistant = true } label: {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 18)).foregroundStyle(DS.Color.textSecondary).frame(height: 32)
            }
            .buttonStyle(.plain)
            Button { showMoon = true } label: {
                Image(systemName: MoonSymbol.name(age: model.moonAge)).font(.system(size: 20)).foregroundStyle(DS.Color.moon).frame(height: 32)
            }
            .buttonStyle(.plain)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 20)).foregroundStyle(DS.Color.textSecondary).frame(height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, DS.Spacing.s)
    }

    // MARK: 釣れ率

    private var scoreArea: some View {
        Button { showBreakdown = true } label: {
            ZStack {
                // 円は常に画面中央（魚種別の数字があっても動かさない）
                ZStack {
                    // 魔法の光と飾り枠はキャラクターより後ろ（顔を隠さない）
                    if ThemeStore.shared.theme.hasAssets { MagicGlow().padding(-DS.Spacing.xl) }
                    ThemeOrnament(name: .ringHome).padding(-DS.Spacing.l)
                    // テーマのキャラクター（円を両手で囲む）。画像の中の円（char_home.json の cx/cy/d）が釣れ率の円に重なるように拡大と位置を決める。
                    // 円を少し大きめ（1.12 倍）に合わせ、手が輪の外側を抱えて顔が輪の上に出るようにする
                    GeometryReader { g in
                        let spec = ThemeAssets.circle(.charHome)
                        let size = ThemeAssets.image(.charHome)?.size ?? CGSize(width: 16, height: 9)
                        let imageH = g.size.height * 1.12 / spec.d
                        let imageW = imageH * size.width / size.height
                        ThemeCharacter(name: .charHome, baseWidth: imageW)
                            .position(x: g.size.width / 2 + (0.5 - spec.cx) * imageW, y: g.size.height / 2 + (0.5 - spec.cy) * imageH)
                    }
                    // 下が開いた 270° のゲージ（確定画像）。トラックは暗いグレー
                    Circle().trim(from: 0, to: 0.75)
                        .stroke(DS.Color.textPrimary.opacity(0.16), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(135))
                    Circle().trim(from: 0, to: 0.75 * CGFloat(model.score?.score ?? 0) / 100)
                        .stroke(model.score?.isForecast == true ? DS.Color.accent.opacity(0.6) : DS.Color.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(135))
                        .animation(.easeOut(duration: 0.6), value: model.score?.score)
                    Text("\(model.score?.score ?? 0)")
                        .font(DS.Font.score(76))
                        .foregroundStyle(DS.Color.textPrimary)
                        .contentTransition(.numericText())
                }
                .aspectRatio(1, contentMode: .fit)
                .padding(.vertical, DS.Spacing.s)
                // 魚種別スコア（右脇の「89 アイナメ」）は 2026-11-09 開発者の指示で外した。魚種別は年間カレンダーの切替に残る
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: 今（4 チップ）

    private var chipsRow: some View {
        let style = ThemeStore.shared.theme.spec?.style
        let glass = style?.glass == true
        return HStack(spacing: DS.Spacing.s) {
            ForEach(model.chips) { chip in
                Button { chipDetail = chip } label: {
                    VStack(spacing: 3) {
                        Image(systemName: chip.symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(iconColor(chip))
                            .rotationEffect(chip.kind == .wind ? .degrees((model.windDirectionDeg ?? 0) + 180) : .zero)
                            .frame(height: 22)
                        Text(chip.value).font(DS.Font.number(19)).foregroundStyle(DS.Color.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
                        Text(chip.label).font(.system(size: 10, weight: .medium)).foregroundStyle(DS.Color.textTertiary).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, DS.Spacing.s)
                    .padding(.horizontal, DS.Spacing.xs)
                    .background {
                        // テーマの style.glass：すりガラス＋薄い白い枠（F-58、紫のテーマ）。無ければ従来の面
                        if glass {
                            // style.glassOpacity で面の濃さ（小さいほど背景が透ける）。style.glassBlur が false ならぼかし無しで背景がそのまま透ける
                            GlassShape(cornerRadius: 18, opacity: style?.glassOpacity ?? 0.35, blur: style?.glassBlur ?? true)
                        } else {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.Color.panel)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let o = style?.chipOrnament, !o.isEmpty { Text(o).font(.system(size: 9)).foregroundStyle(DS.Color.textPrimary.opacity(0.7)).padding(5) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let o = style?.chipOrnament, !o.isEmpty { Text(o).font(.system(size: 9)).foregroundStyle(DS.Color.textPrimary.opacity(0.45)).padding(5) }
                    }
                    // 傾き（style.chipTilt：面内、style.chipPerspective：縦軸まわり）
                    .rotation3DEffect(.degrees(style?.chipPerspective ?? 0), axis: (x: 0, y: 1, z: 0), perspective: 0.7)
                    .rotationEffect(.degrees(style?.chipTilt ?? 0))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// アイコンの色（確定画像：潮と光はオレンジ、風は緑、天気は白。悪い状態はグレー）
    private func iconColor(_ chip: HomeViewModel.Chip) -> Color {
        if chip.tone == .bad { return DS.Color.textTertiary }
        switch chip.kind {
        case .tide: return DS.Color.sea
        case .light: return DS.Color.sun
        case .wind, .weather: return DS.Color.textPrimary
        }
    }

    // MARK: 次（イベント列）

    private var eventsRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.events.prefix(3).enumerated()), id: \.element.at) { i, e in
                if i > 0 { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1).padding(.vertical, DS.Spacing.s) }
                Button { model.show(date: e.at) } label: {
                    VStack(spacing: 2) {
                        Text(e.label).font(DS.Font.caption).foregroundStyle(e.isPositive ? DS.Color.accent : DS.Color.textTertiary)
                        Text(e.at, format: .dateTime.hour().minute()).font(DS.Font.number(15)).foregroundStyle(e.isPositive ? DS.Color.accent : DS.Color.textPrimary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
            }
            if model.events.isEmpty {
                Text("—").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.vertical, DS.Spacing.xs)
    }
}

/// 釣れ率の後ろで脈動するエメラルドの光（画像テーマ）。
struct MagicGlow: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [DS.Color.secondary.opacity(0.55), DS.Color.secondary.opacity(0.12), .clear], center: .center, startRadius: 0, endRadius: 120))
            .scaleEffect(on ? 1.08 : 0.92).opacity(on ? 1 : 0.7)
            .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .allowsHitTesting(false)
    }
}

/// 記録中のテーマ色の点（脈動）。
struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(DS.Color.accent).frame(width: 8, height: 8)
            .scaleEffect(on ? 1.3 : 0.8).opacity(on ? 1 : 0.5)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// 月の詳細（ヘッダーの月相アイコンをタップ）：月相名、月齢、輝面比、今日の月の出・月の入、次の満月・新月。
struct MoonSheet: View {
    let model: HomeViewModel

    var body: some View {
        let age = model.moonAge
        let times = MoonCalculator.times(on: model.now, at: model.coordinate, timeZone: model.timeZone)
        let fraction = MoonCalculator.illuminatedFraction(at: model.now)
        let synodic = 29.530589
        let toFull = ((14.765 - age) + synodic).truncatingRemainder(dividingBy: synodic)
        let toNew = (synodic - age).truncatingRemainder(dividingBy: synodic)
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: MoonSymbol.name(age: age)).font(.system(size: 40)).foregroundStyle(DS.Color.moon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MoonSymbol.phaseName(age: age)).font(DS.Font.number(24)).foregroundStyle(DS.Color.textPrimary)
                    Text(String(format: "月齢 %.1f · 輝面 %d%%", age, Int((fraction * 100).rounded()))).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
                Spacer()
            }
            row("月の出", times.moonrise.map { $0.formatted(.dateTime.hour().minute()) } ?? "—")
            row("月の入", times.moonset.map { $0.formatted(.dateTime.hour().minute()) } ?? "—")
            row("次の満月", model.now.addingTimeInterval(toFull * 86_400).formatted(.dateTime.month().day()) + "（\(Int(toFull.rounded())) 日後）")
            row("次の新月", model.now.addingTimeInterval(toNew * 86_400).formatted(.dateTime.month().day()) + "（\(Int(toNew.rounded())) 日後）")
            if let moon = model.score?.breakdown.first(where: { $0.factor == .moon }) {
                row("釣れ率への影響", (moon.points > 0 ? "+" : "") + "\(Int(moon.points)) " + moon.detail)
            }
            Text("潮の大きさ（大潮・小潮）は月齢から決まります。月相の加点は満月・新月の前後で +2 です。")
                .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeBackground(name: .bgDetail))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(DS.Font.label).foregroundStyle(DS.Color.textTertiary)
            Spacer()
            Text(value).font(DS.Font.number(16)).foregroundStyle(DS.Color.textPrimary)
        }
    }
}

enum MoonSymbol {
    /// 月齢から日本語の月相名
    static func phaseName(age: Double) -> String {
        switch age {
        case ..<1.8, 27.7...: return "新月"
        case ..<5.5: return "三日月"
        case ..<9.2: return "上弦"
        case ..<12.9: return "十三夜"
        case ..<16.6: return "満月"
        case ..<20.3: return "十六夜"
        case ..<24: return "下弦"
        default: return "有明"
        }
    }

    static func name(age: Double) -> String {
        switch age {
        case ..<1.8, 27.7...: return "moonphase.new.moon"
        case ..<5.5: return "moonphase.waxing.crescent"
        case ..<9.2: return "moonphase.first.quarter"
        case ..<12.9: return "moonphase.waxing.gibbous"
        case ..<16.6: return "moonphase.full.moon"
        case ..<20.3: return "moonphase.waning.gibbous"
        case ..<24: return "moonphase.last.quarter"
        default: return "moonphase.waning.crescent"
        }
    }
}

/// 先の推移：1 日ずつ表示し、左右スワイプ（または矢印）で日を送る。
/// 上：釣れ率（オレンジ、左軸 0〜100）と潮位（海の青、満干の時刻）。下：3 時間ごとの天気・気温・雨・風向・風速・波高の表。
struct ForecastChart: View {
    let model: HomeViewModel
    /// 出す部分（テーマの配置では「グラフだけ」「表だけ」のように分けて置ける。F-58）
    var parts: Parts = .all
    /// 後ろの面を描くか（画像テーマの配置では自前の泡を描くので消す）
    var showsPanel = true
    /// 潮位曲線を置く高さ（釣れ率の目盛りで 4〜40 の帯）
    private let tideBand: ClosedRange<Double> = 4...62
    private let hours = Array(stride(from: 0, to: 24, by: 3))

    struct Parts: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let dayHeader = Parts(rawValue: 1), chart = Parts(rawValue: 2), table = Parts(rawValue: 4), week = Parts(rawValue: 8), footer = Parts(rawValue: 16)
        static let all: Parts = [.dayHeader, .chart, .table, .week, .footer]
    }

    @State private var tapped: Date?
    @State private var showYear = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: DS.Spacing.xs) {
                if parts.contains(.dayHeader) { dayHeader.frame(height: 22) }
                if parts.contains(.chart) {
                    chart
                        .chartOverlay { proxy in
                            GeometryReader { g in
                                Rectangle().fill(.clear).contentShape(Rectangle())
                                    .onTapGesture { location in
                                        let origin = g[proxy.plotFrame!].origin
                                        if let d: Date = proxy.value(atX: location.x - origin.x) { tapped = min(max(d, model.dayStart), model.dayEnd) }
                                    }
                            }
                        }
                        // 表・週と一緒のときは 37%、グラフだけのときは残り全部
                        .frame(height: parts.contains(.table) || parts.contains(.week) ? geo.size.height * 0.37 : nil)
                        .frame(maxHeight: .infinity)
                }
                if parts.contains(.table) { detailTable }
                if parts.contains(.week) {
                    weekRow.frame(height: 44)
                        // 週行の上のスワイプは週送り（±7 日）。それ以外のスワイプは日送り
                        .highPriorityGesture(DragGesture(minimumDistance: 30).onEnded { v in
                            if v.translation.width < -30 { step(+7, clamp: true) } else if v.translation.width > 30 { step(-7, clamp: true) }
                        })
                }
                if parts.contains(.footer) { footer.frame(height: 16) }
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .frame(width: geo.size.width, height: geo.size.height)
            .background {
                if showsPanel, let style = ThemeStore.shared.theme.spec?.style, style.glass == true {
                    GlassShape(cornerRadius: DS.Radius.card, opacity: style.glassOpacity ?? 0.3, blur: style.glassBlur ?? true)
                } else if showsPanel {
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Color.panel)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                if v.translation.width < -30 { step(+1) } else if v.translation.width > 30 { step(-1) }
            })
            .sheet(item: Binding(get: { tapped.map { TappedTime(date: $0) } }, set: { tapped = $0?.date })) { t in
                DayDetailSheet(model: model, at: t.date, twilights: twilightBands.map { ($0.label, $0.start, $0.end) }).presentationDetents([.large])
            }
            .sheet(isPresented: $showYear) {
                YearCalendarSheet(model: model) { date in
                    showYear = false
                    model.show(date: date)
                }
                .presentationDetents([.large])
            }
        }
    }

    private struct TappedTime: Identifiable { let date: Date; var id: Date { date } }

    /// 「2026/11/04(水)」
    static func dayLabel(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = timeZone
        f.dateFormat = "yyyy/MM/dd(E)"
        return f.string(from: date)
    }

    /// 日送り。`clamp` なら範囲を超える分は端に寄せる（週送りで残りが 7 日未満でも端まで動く）
    private func step(_ d: Int, clamp: Bool = false) {
        let range = model.dayOffsetRange
        var next = model.dayOffset + d
        if clamp { next = min(max(next, range.lowerBound), range.upperBound) }
        guard range.contains(next), next != model.dayOffset else { return }
        withAnimation(.easeInOut(duration: 0.2)) { model.dayOffset = next }
    }

    private var dayHeader: some View {
        HStack {
            Button { step(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(model.dayOffset > model.dayOffsetRange.lowerBound ? DS.Color.textSecondary : DS.Color.faded).frame(width: 28, height: 22) }
                .buttonStyle(.plain)
            Spacer()
            // 日付をタップすると年間カレンダー（F-33）
            Button { showYear = true } label: {
                HStack(spacing: 6) {
                    Text(Self.dayLabel(model.dayStart, timeZone: model.timeZone)).font(DS.Font.number(14)).foregroundStyle(DS.Color.textPrimary)
                    Text(model.dayOffset == 0 ? "今日" : (model.dayOffset == 1 ? "明日" : (model.dayOffset == -1 ? "昨日" : ""))).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button { step(+1) } label: { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(model.dayOffset < model.dayOffsetRange.upperBound ? DS.Color.textSecondary : DS.Color.faded).frame(width: 28, height: 22) }
                .buttonStyle(.plain)
        }
    }

    private var chart: some View {
        Chart {
            // 夜の濃い背景は出さない（日の出入は線で分かる。2026-11-04 実機フィードバック）
            // 潮止まりの帯（満干の前後 30 分、薄いグレー）。文字なし
            ForEach(model.dayExtremes, id: \.at) { e in
                RectangleMark(xStart: .value("s", e.at.addingTimeInterval(-30 * 60)), xEnd: .value("e", e.at.addingTimeInterval(30 * 60)), yStart: .value("y0", 0), yEnd: .value("y1", 100))
                    .foregroundStyle(DS.Color.textPrimary.opacity(0.07))
            }
            // 朝マズメ・夕マズメの帯（黄）。文字なし。時刻はグラフをタップした詳細で
            ForEach(twilightBands, id: \.start) { b in
                RectangleMark(xStart: .value("s", b.start), xEnd: .value("e", b.end), yStart: .value("y0", 0), yEnd: .value("y1", 100))
                    .foregroundStyle(DS.Color.sun.opacity(0.18))
            }
            // 太陽が出ている時間（黄の横線、両端が日の出・日の入）と月が出ている時間（紫の横線）
            ForEach(skySpans, id: \.start) { span in
                RuleMark(xStart: .value("s", span.start), xEnd: .value("e", span.end), y: .value("y", span.isSun ? 91 : 83))
                    .foregroundStyle((span.isSun ? DS.Color.daylight : DS.Color.moon).opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            ForEach(model.dayTide) { p in
                AreaMark(x: .value("時刻", p.at), yStart: .value("底", 0), yEnd: .value("潮位", tideY(p.levelCm)), series: .value("系列", "潮位面"))
                    .foregroundStyle(LinearGradient(colors: [DS.Color.sea.opacity(0.35), DS.Color.sea.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("時刻", p.at), y: .value("潮位", tideY(p.levelCm)), series: .value("系列", "潮位"))
                    .foregroundStyle(DS.Color.sea)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(model.dayTimeline, id: \.at) { p in
                AreaMark(x: .value("時刻", p.at), yStart: .value("底", 0), yEnd: .value("釣れ率", p.score), series: .value("系列", "釣れ率面"))
                    .foregroundStyle(LinearGradient(colors: [DS.Color.accent.opacity(0.18), DS.Color.accent.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("時刻", p.at), y: .value("釣れ率", p.score), series: .value("系列", "釣れ率"))
                    .foregroundStyle(p.isForecast && model.forecastHorizon.map { p.at > $0 } == true ? DS.Color.accent.opacity(0.35) : DS.Color.accent)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
            // 良い時間帯の帯：グラフの底にぴったり付ける（55 以上オレンジ、40 未満は暗いグレー）
            ForEach(Array(model.dayTimeline.enumerated()), id: \.element.at) { i, p in
                let next = i + 1 < model.dayTimeline.count ? model.dayTimeline[i + 1].at : p.at.addingTimeInterval(15 * 60)
                RectangleMark(xStart: .value("s", p.at), xEnd: .value("e", next), yStart: .value("y0", 0), yEnd: .value("y1", 3.5))
                    .foregroundStyle(p.score >= 55 ? DS.Color.accent : (p.score < 40 ? Color.white.opacity(0.10) : Color.white.opacity(0.28)))
            }
            // 日の出入（オレンジ）と月の出入（紫）
            ForEach(sunMoonMarks, id: \.at) { m in
                PointMark(x: .value("時刻", m.at), y: .value("y", m.y))
                    .symbolSize(0)
                    .annotation(position: .bottom, spacing: 0) {
                        HStack(spacing: 1) {
                            Image(systemName: m.isSun ? "sun.max.fill" : "moon.fill").font(.system(size: 7))
                            Text(m.at, format: .dateTime.hour().minute()).font(DS.Font.number(8))
                        }
                        .foregroundStyle(m.isSun ? DS.Color.daylight : DS.Color.moon)
                    }
            }
            if model.now >= model.dayStart && model.now <= model.dayEnd {
                RuleMark(x: .value("今", model.now)).foregroundStyle(DS.Color.textPrimary.opacity(0.9)).lineStyle(StrokeStyle(lineWidth: 1.5))
                if let level = model.nowTideLevelCm {
                    PointMark(x: .value("今", model.now), y: .value("潮位", tideY(level)))
                        .foregroundStyle(DS.Color.sea)
                        .symbolSize(40)
                        .annotation(position: .topLeading, spacing: 4, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                            HStack(spacing: 2) {
                                Text("\(Int(level.rounded()))cm").font(DS.Font.number(10))
                                Image(systemName: (model.nowTideRateCmPerHour ?? 0) > 0 ? "arrow.up" : ((model.nowTideRateCmPerHour ?? 0) < 0 ? "arrow.down" : "minus")).font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(DS.Color.sea)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(DS.Color.background.opacity(0.9), in: Capsule())
                        }
                }
            }
            // 満干の点と時刻。最後に描いて必ず最前面に。「満」「干」は書かない（上下で分かる）
            ForEach(model.dayExtremes, id: \.at) { e in
                PointMark(x: .value("時刻", e.at), y: .value("潮位", tideY(e.levelCm)))
                    .foregroundStyle(DS.Color.textPrimary)
                    .symbolSize(16)
                    .annotation(position: e.kind == .high ? .top : .bottom, spacing: 3, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                        Text(e.at, format: .dateTime.hour().minute()).font(DS.Font.number(9)).foregroundStyle(DS.Color.textPrimary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(DS.Color.background.opacity(0.9), in: Capsule())
                    }
            }
        }
        .chartXScale(domain: model.dayStart...model.dayEnd)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            // 左軸：釣れ率（テーマ色の緑。右軸の潮位は海の青）
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(DS.Color.faded.opacity(0.5))
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)").font(DS.Font.number(9)).foregroundStyle(DS.Color.accent) }
                }
            }
            // 右軸：潮位 cm（釣れ率の目盛りに写した位置に、元の cm を書く）
            AxisMarks(position: .trailing, values: tideTicks.map { tideY($0) }) { value in
                AxisValueLabel {
                    if let y = value.as(Double.self), let cm = tideTicks.min(by: { abs(tideY($0) - y) < abs(tideY($1) - y) }) {
                        Text("\(Int(cm))").font(DS.Font.number(9)).foregroundStyle(DS.Color.sea)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                AxisGridLine().foregroundStyle(DS.Color.faded.opacity(0.3))
                if let d = value.as(Date.self) {
                    AxisValueLabel(centered: false) {
                        Text("\(Calendar.current.component(.hour, from: d))").font(DS.Font.number(9)).foregroundStyle(DS.Color.textTertiary)
                    }
                }
            }
        }
    }

    /// 3 時間ごとの詳細（天気・気温・雨・風向・風速・波高）
    private var detailTable: some View {
        let cols = model.dayDetail
        return VStack(spacing: 1) {
            tableRow("時刻") { i in Text("\(hours[i])").font(DS.Font.number(10)).foregroundStyle(DS.Color.textSecondary) }
            tableRow("天気") { i in
                Image(systemName: HomeViewModel.weatherSymbol(cols[i].conditionCode))
                    .font(.system(size: 12)).symbolRenderingMode(.multicolor)
                    .foregroundStyle(cols[i].conditionCode == nil ? DS.Color.faded : DS.Color.textPrimary)
            }
            tableRow("気温") { i in Text(cols[i].airTemperatureC.map { "\(Int($0.rounded()))°" } ?? "—").font(DS.Font.number(10)).foregroundStyle(DS.Color.textPrimary) }
            tableRow("降水") { i in
                let chance = cols[i].precipitationChance
                Text(chance.map { "\(Int(($0 * 100).rounded()))%" } ?? "—").font(DS.Font.number(10))
                    .foregroundStyle((chance ?? 0) >= 0.5 ? DS.Color.sea : DS.Color.textSecondary)
            }
            tableRow("風向") { i in
                VStack(spacing: 0) {
                    Image(systemName: "location.north.fill").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees((cols[i].windDirectionDeg ?? 0) + 180))
                        .foregroundStyle(cols[i].windDirectionDeg == nil ? DS.Color.faded : DS.Color.textPrimary)
                    Text(cols[i].windDirectionDeg.map { HomeViewModel.compass($0) } ?? "").font(.system(size: 8)).foregroundStyle(DS.Color.textTertiary)
                }
            }
            tableRow("風速") { i in Text(cols[i].windSpeedMS.map { String(format: "%.1f", $0) } ?? "—").font(DS.Font.number(10)).foregroundStyle((cols[i].windSpeedMS ?? 0) > 8 ? DS.Color.accent : DS.Color.textPrimary) }
            tableRow("波高") { i in Text(cols[i].waveHeightM.map { String(format: "%.1fm", $0) } ?? "—").font(DS.Font.number(10)).foregroundStyle(DS.Color.textPrimary) }
        }
    }

    private func tableRow<C: View>(_ label: String, @ViewBuilder cell: @escaping (Int) -> C) -> some View {
        HStack(spacing: 0) {
            Text(label).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).frame(width: 30, alignment: .leading)
            ForEach(0..<hours.count, id: \.self) { i in
                Group {
                    if i < model.dayDetail.count { cell(i) } else { Text("—").font(DS.Font.caption).foregroundStyle(DS.Color.faded) }
                }
                .frame(maxWidth: .infinity)
                .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium").font(.system(size: 10)).foregroundStyle(DS.Color.sea)
                Text(model.seaSurfaceTempC.map { String(format: "水温 %.1f°", $0) } ?? "水温 —").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            }
            Spacer()
            if let n = model.nextFetchAt {
                Text("次回更新 ").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) + Text(n, format: .dateTime.hour().minute()).font(DS.Font.number(10)).foregroundStyle(DS.Color.textTertiary)
            }
        }
    }

    private struct SkyMark { let at: Date; let y: Double; let isSun: Bool }

    /// 表示中の日の日の出入・月の出入（上端の少し下に置く）
    private var sunMoonMarks: [SkyMark] {
        var out: [SkyMark] = []
        let r = model.dayStart...model.dayEnd
        for d in [model.daySun?.sunrise, model.daySun?.sunset].compactMap({ $0 }) where r.contains(d) { out.append(SkyMark(at: d, y: 91, isSun: true)) }
        for d in [model.dayMoon?.moonrise, model.dayMoon?.moonset].compactMap({ $0 }) where r.contains(d) { out.append(SkyMark(at: d, y: 83, isSun: false)) }
        return out
    }

    private struct SkySpan { let start: Date; let end: Date; let isSun: Bool }

    /// 太陽・月が出ている区間（表示中の日に切り詰める。月は日をまたぐことがある）
    private var skySpans: [SkySpan] {
        var out: [SkySpan] = []
        let r = model.dayStart...model.dayEnd
        func clip(_ a: Date, _ b: Date, sun: Bool) {
            let s = max(a, r.lowerBound), e = min(b, r.upperBound)
            if s < e { out.append(SkySpan(start: s, end: e, isSun: sun)) }
        }
        if let rise = model.daySun?.sunrise, let set = model.daySun?.sunset { clip(rise, set, sun: true) }
        if let rise = model.dayMoon?.moonrise, let set = model.dayMoon?.moonset {
            if rise < set { clip(rise, set, sun: false) } else { clip(model.dayStart, set, sun: false); clip(rise, model.dayEnd, sun: false) }
        } else if let rise = model.dayMoon?.moonrise {
            clip(rise, model.dayEnd, sun: false)
        } else if let set = model.dayMoon?.moonset {
            clip(model.dayStart, set, sun: false)
        }
        return out
    }

    private struct TwilightBand { let start: Date; let end: Date; let label: String }

    /// 朝マズメ（市民薄明の始まり〜日の出 30 分後）と夕マズメ（日の入 30 分前〜市民薄明の終わり）。チップと同じ定義
    private var twilightBands: [TwilightBand] {
        guard let sun = model.daySun else { return [] }
        var out: [TwilightBand] = []
        if let dawn = sun.civilDawn, let rise = sun.sunrise { out.append(TwilightBand(start: dawn, end: rise.addingTimeInterval(30 * 60), label: "朝マズメ")) }
        if let set = sun.sunset, let dusk = sun.civilDusk { out.append(TwilightBand(start: set.addingTimeInterval(-30 * 60), end: dusk, label: "夕マズメ")) }
        let r = model.dayStart...model.dayEnd
        return out.filter { r.contains($0.start) || r.contains($0.end) }
    }

    /// 右軸の目盛り（潮位 cm の切りのよい値）
    private var tideTicks: [Double] {
        let r = tideRange
        let span = r.upperBound - r.lowerBound
        // 潮位は目盛りの下 4〜62 の帯に写す。目盛りは 3〜4 本まで
        let step = [10.0, 20, 30, 50, 100, 200].first { span / $0 <= 3.6 } ?? 200
        var ticks: [Double] = []
        var v = (r.lowerBound / step).rounded(.up) * step
        while v <= r.upperBound { ticks.append(v); v += step }
        return ticks
    }

    /// 週間の見通し：月〜日の固定並びで、日付(曜)・昼の天気・最高釣れ率。選択中はテーマ色の背景。タップでその日へ。
    /// 日付(曜)だけ色を付ける：土曜は青、日曜と祝日は赤。範囲外の日は日付だけ薄く出す
    private var weekRow: some View {
        HStack(spacing: 4) {
            ForEach(model.weekOutlook) { d in
                let selected = d.offset == model.dayOffset
                Button { withAnimation(.easeInOut(duration: 0.2)) { model.dayOffset = d.offset } } label: {
                    VStack(spacing: 1) {
                        Text(Self.shortDay(d.dayStart, timeZone: model.timeZone)).font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Self.dayColor(d, selected: selected))
                        Image(systemName: d.conditionCode.map { HomeViewModel.weatherSymbol($0) } ?? "minus")
                            .font(.system(size: 11)).foregroundStyle(selected ? DS.Color.background : (d.available ? DS.Color.textSecondary : DS.Color.faded))
                        Text(d.maxScore.map { "\($0)" } ?? "–").font(DS.Font.number(14)).foregroundStyle(selected ? DS.Color.background : (d.available ? DS.Color.textPrimary : DS.Color.faded))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(selected ? DS.Color.accent : DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!d.available)
            }
        }
    }

    /// 週行の日付(曜)の色。日曜・祝日は赤、土曜は青、平日は薄い白。選択中の平日は背景色（テーマ色の上に乗る）
    static func dayColor(_ d: HomeViewModel.DayOutlook, selected: Bool) -> SwiftUI.Color {
        if d.weekday == 1 || d.isHoliday { return DS.Color.holiday }
        if d.weekday == 7 { return DS.Color.saturday }
        if !d.available { return DS.Color.faded }
        return selected ? DS.Color.background : DS.Color.textTertiary
    }

    /// 「04(水)」
    static func shortDay(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.timeZone = timeZone; f.dateFormat = "dd(E)"
        return f.string(from: date)
    }

    /// 潮位（cm）を釣れ率の目盛りの下帯に写す
    private func tideY(_ level: Double) -> Double {
        let lo = tideRange.lowerBound, hi = tideRange.upperBound
        let t = (level - lo) / (hi - lo)
        return tideBand.lowerBound + t * (tideBand.upperBound - tideBand.lowerBound)
    }

    private var tideRange: ClosedRange<Double> { model.tideRangeCm }

    /// 夜の区間（日の入〜翌日の出）。表示中の日に重なるものだけ
    private var dayShading: [(Date, Date)] {
        var out: [(Date, Date)] = []
        let days = model.sunTimesByDay
        for (i, d) in days.enumerated() {
            guard let sunset = d.sunset else { continue }
            let nextRise = i + 1 < days.count ? days[i + 1].sunrise : nil
            out.append((sunset, nextRise ?? sunset.addingTimeInterval(12 * 3600)))
        }
        if let first = days.first?.sunrise { out.append((model.rangeStart, first)) }
        return out.compactMap { (s, e) in
            let a = max(s, model.dayStart), b = min(e, model.dayEnd)
            return a < b ? (a, b) : nil
        }
    }
}

/// グラフをタップしたときの詳細：その時刻の数値と、その日の時刻一覧（マズメ・日の出入・月の出入・満干）。
struct DayDetailSheet: View {
    let model: HomeViewModel
    let initial: Date
    let twilights: [(String, Date, Date)]
    @Environment(AppServices.self) private var services
    @State private var at: Date = .now

    init(model: HomeViewModel, at: Date, twilights: [(String, Date, Date)]) {
        self.model = model
        self.initial = at
        self.twilights = twilights
        _at = State(initialValue: at)
    }

    var body: some View {
        let env = services.environment.snapshot(at: at, coordinate: model.coordinate)
        let score = model.dayTimeline.min { abs($0.at.timeIntervalSince(at)) < abs($1.at.timeIntervalSince(at)) }?.score
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(ForecastChart.dayLabel(at, timeZone: model.timeZone)).font(DS.Font.label).foregroundStyle(DS.Color.textTertiary)
                Text(at, format: .dateTime.hour().minute()).font(DS.Font.number(24)).foregroundStyle(DS.Color.textPrimary)
                Spacer()
                if let score { Text("\(score)").font(DS.Font.score(32)).foregroundStyle(DS.Color.accent) }
            }
            VStack(spacing: DS.Spacing.s) {
                row("潮位", env.tideLevelCm.map { "\(Int($0.rounded())) cm " + (((env.tideRateCmPerHour ?? 0) > 2) ? "上げ" : ((env.tideRateCmPerHour ?? 0) < -2 ? "下げ" : "潮止まり")) }, color: DS.Color.sea)
                row("潮", env.tideName, color: DS.Color.sea)
                row("気温", env.airTemperatureC.map { String(format: "%.1f°", $0) })
                row("風", env.windSpeedMS.map { String(format: "%.1f m/s ", $0) + (env.windDirectionDeg.map { HomeViewModel.compass($0) } ?? "") })
                row("降水確率", env.precipitationChance.map { "\(Int(($0 * 100).rounded()))%" })
                row("波高", env.waveHeightM.map { String(format: "%.1f m", $0) })
                row("水温", env.seaSurfaceTempC.map { String(format: "%.1f°", $0) })
                row("気圧", env.pressureHPa.map { String(format: "%.0f hPa", $0) })
            }
            Divider().overlay(DS.Color.faded)
            VStack(spacing: DS.Spacing.s) {
                ForEach(twilights, id: \.1) { t in row(t.0, time(t.1) + "〜" + time(t.2), color: DS.Color.sun) }
                row("日の出 / 日の入", [model.daySun?.sunrise, model.daySun?.sunset].map { $0.map(time) ?? "—" }.joined(separator: " / "), color: DS.Color.daylight)
                row("月の出 / 月の入", [model.dayMoon?.moonrise, model.dayMoon?.moonset].map { $0.map(time) ?? "—" }.joined(separator: " / "), color: DS.Color.moon)
                ForEach(model.dayExtremes, id: \.at) { e in row(e.kind == .high ? "満潮" : "干潮", time(e.at) + "  \(Int(e.levelCm.rounded())) cm", color: DS.Color.sea) }
            }
            Spacer()
            // 時刻の横棒はシートの一番下（親指で届く位置）。タップかドラッグで 15 分刻みに動かす
            TimeScrubber(date: $at, dayStart: model.dayStart, dayEnd: model.dayEnd)
                .frame(height: 44)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeBackground(name: .bgDetail))
    }

    private func time(_ d: Date) -> String { HomeViewModel.clock(d, timeZone: model.timeZone) }

    private func row(_ label: String, _ value: String?, color: Color? = nil) -> some View {
        HStack {
            Text(label).font(DS.Font.label).foregroundStyle(DS.Color.textTertiary)
            Spacer()
            Text(value ?? "—").font(DS.Font.number(15)).foregroundStyle(value == nil ? DS.Color.textTertiary : (color ?? DS.Color.textPrimary))
        }
    }
}

/// 1 日の時刻を選ぶ横棒。タップで移動、ドラッグで連続して動く。15 分刻み
struct TimeScrubber: View {
    @Binding var date: Date
    let dayStart: Date
    let dayEnd: Date

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = CGFloat(date.timeIntervalSince(dayStart) / dayEnd.timeIntervalSince(dayStart))
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Color.surfaceRaised).frame(height: 8).frame(maxHeight: .infinity, alignment: .center)
                Capsule().fill(DS.Color.accent).frame(width: max(0, min(w, w * frac)), height: 8).frame(maxHeight: .infinity, alignment: .center)
                Circle().fill(DS.Color.textPrimary).frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: max(0, min(w - 22, w * frac - 11)))
                    .frame(maxHeight: .infinity, alignment: .center)
                HStack {
                    ForEach([0, 6, 12, 18, 24], id: \.self) { h in
                        Text("\(h)").font(DS.Font.number(9)).foregroundStyle(DS.Color.textTertiary)
                        if h < 24 { Spacer() }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = max(0, min(1, v.location.x / w))
                let seconds = (Double(f) * dayEnd.timeIntervalSince(dayStart) / 900).rounded() * 900
                date = dayStart.addingTimeInterval(min(seconds, dayEnd.timeIntervalSince(dayStart) - 900))
            })
        }
    }
}

/// 内訳シート：どの要素が何点上げ下げしているか。
struct BreakdownSheet: View {
    let result: ScoreResult?
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack {
                Text("\(result?.score ?? 0)").font(DS.Font.score(48)).foregroundStyle(DS.Color.textPrimary)
                Text(result?.confidence == .forecast ? "予報" : (result?.confidence == .noWeather ? "気象なし" : "実況")).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                Spacer()
            }
            ForEach(Array((result?.breakdown ?? []).enumerated()), id: \.offset) { _, b in
                HStack {
                    Text(label(b.factor)).font(DS.Font.label).foregroundStyle(DS.Color.textSecondary).frame(width: 64, alignment: .leading)
                    Text(b.detail).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                    Spacer()
                    Text(b.points > 0 ? "+\(Int(b.points))" : "\(Int(b.points))")
                        .font(DS.Font.number(16))
                        .foregroundStyle(b.points > 0 ? DS.Color.accent : (b.points < 0 ? DS.Color.textTertiary : DS.Color.textSecondary))
                }
            }
            Spacer()
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeBackground(name: .bgDetail))
    }

    func label(_ f: ScoreBreakdown.Factor) -> String {
        switch f {
        case .light: return "光"
        case .tide: return "潮"
        case .pressure: return "気圧"
        case .wind: return "風"
        case .wave: return "波"
        case .water: return "水温"
        case .moon: return "月"
        case .personal: return "実績"
        }
    }
}

/// チップ詳細：その要素の数値と直近の推移。
struct ChipDetailSheet: View {
    let chip: HomeViewModel.Chip
    let model: HomeViewModel
    @Environment(AppServices.self) private var services
    @State private var refreshing = false

    var body: some View {
        let env = services.environment.snapshot(at: model.now, coordinate: model.coordinate)
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Text(chip.value).font(DS.Font.number(28)).foregroundStyle(DS.Color.textPrimary)
                Text(chip.label).font(DS.Font.label).foregroundStyle(DS.Color.textTertiary)
            }
            switch chip.kind {
            case .tide:
                row("潮位", env.tideLevelCm.map { "\(Int($0.rounded())) cm" })
                row("変化率", env.tideRateCmPerHour.map { String(format: "%+.1f cm/h", $0) })
                row("次の満潮", env.nextHighTideAt.map { $0.formatted(.dateTime.hour().minute()) })
                row("次の干潮", env.nextLowTideAt.map { $0.formatted(.dateTime.hour().minute()) })
                row("月齢", env.moonAge.map { String(format: "%.1f", $0) })
            case .light:
                row("日の出", env.sunriseAt.map { $0.formatted(.dateTime.hour().minute()) })
                row("日の入", env.sunsetAt.map { $0.formatted(.dateTime.hour().minute()) })
            case .wind:
                row("風速", env.windSpeedMS.map { String(format: "%.1f m/s", $0) })
                row("最大瞬間", env.windGustMS.map { String(format: "%.1f m/s", $0) })
                row("風向", env.windDirectionDeg.map { "\(Int($0.rounded()))°" })
                row("波高", env.waveHeightM.map { String(format: "%.1f m", $0) })
                row("周期", env.wavePeriodS.map { String(format: "%.0f s", $0) })
            case .weather:
                row("気温", env.airTemperatureC.map { String(format: "%.1f℃", $0) })
                row("水温", env.seaSurfaceTempC.map { String(format: "%.1f℃", $0) })
                row("気圧", (env.measuredPressureHPa ?? env.pressureHPa).map { String(format: "%.1f hPa", $0) })
                row("気圧傾向", env.pressureTrend3hHPa.map { String(format: "%+.1f hPa/3h", $0) })
                row("湿度", env.humidity.map { "\(Int(($0 * 100).rounded()))%" })
                row("降水", env.precipitationMM.map { String(format: "%.1f mm", $0) })
            }
            if chip.kind == .wind || chip.kind == .weather {
                fetchStatus
            }
            Spacer()
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeBackground(name: .bgDetail))
    }

    /// 気象の取得状態：取得元、最後に取れた時刻、失敗の内容、再取得ボタン（実機での切り分け用）
    private var fetchStatus: some View {
        let env = services.environment
        let key = ForecastCache.key(for: model.coordinate)
        let last = env.cache.entry(for: model.coordinate)?.weatherFetchedAt
        return VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Divider().overlay(DS.Color.faded)
            row("取得元", "Apple Weather（WeatherKit）")
            row("最後の取得", last.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "まだ取れていません")
            row("位置", String(format: "%.3f, %.3f", model.coordinate.latitude, model.coordinate.longitude))
            if let err = env.lastError {
                Text(err).font(DS.Font.caption).foregroundStyle(DS.Color.accent).fixedSize(horizontal: false, vertical: true)
            } else if last == nil, env.gate.lastFetch["weather:" + key] != nil {
                Text("取得中…").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            }
            Button {
                refreshing = true
                Task { await model.forceRefreshEnvironment(); refreshing = false }
            } label: {
                Text(refreshing ? "取得中…" : "いま再取得").font(DS.Font.label).foregroundStyle(DS.Color.background)
                    .padding(.horizontal, DS.Spacing.l).padding(.vertical, DS.Spacing.s).background(DS.Color.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(refreshing)
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).font(DS.Font.label).foregroundStyle(DS.Color.textTertiary)
            Spacer()
            Text(value ?? "—").font(DS.Font.number(16)).foregroundStyle(DS.Color.textPrimary)
        }
    }
}

/// 釣り場切替：現在地、登録済みの釣り場、近い順の漁港（検索で全国）。漁港を選ぶと登録してホームの釣り場になる。
struct SpotSwitchSheet: View {
    let model: HomeViewModel
    let onDone: () -> Void
    @State private var query = ""

    var body: some View {
        let registered = model.availableSpots
        let ports = model.ports(matching: query)
        let origin = model.currentLocation
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("釣り場").font(.system(size: 22, weight: .bold)).foregroundStyle(DS.Color.textPrimary)
            TextField("漁港名で探す（全国、かな・ローマ字でも）", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onAppear { PortReadingIndex.shared.prepare(catalog: PortCatalog.bundled()) }
                .font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                .padding(DS.Spacing.m).background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    if query.isEmpty {
                        rowButton(title: "現在地", subtitle: "今いる場所の情報を出す", selected: model.isUsingCurrentLocation, accent: true) {
                            model.selectCurrentLocation(); onDone()
                        }
                        if !registered.isEmpty {
                            Text("登録した釣り場").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).padding(.top, DS.Spacing.s)
                            ForEach(registered) { s in
                                rowButton(title: s.name, subtitle: origin.map { Self.distance($0, s.coordinate) } ?? "", selected: !model.isUsingCurrentLocation && s.id == model.spot?.id, accent: false) {
                                    model.select(spot: s); onDone()
                                }
                            }
                        }
                        Text("近くの漁港").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).padding(.top, DS.Spacing.s)
                    }
                    ForEach(ports.filter { p in !registered.contains { Geo.distanceMeters($0.coordinate, p.coordinate) < 300 } }) { p in
                        rowButton(title: p.name, subtitle: origin.map { Self.distance($0, p.coordinate) } ?? (p.pref ?? ""), selected: false, accent: false) {
                            model.select(port: p); onDone()
                        }
                    }
                    if ports.isEmpty {
                        Text("見つかりません").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                    }
                }
                .padding(.bottom, DS.Spacing.xl)
            }
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ThemeBackground(name: .bgDetail))
    }

    private func rowButton(title: String, subtitle: String, selected: Bool, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                    if !subtitle.isEmpty { Text(subtitle).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
                }
                Spacer()
                if selected { Circle().fill(DS.Color.accent).frame(width: 8, height: 8) }
                else if accent { Image(systemName: "location.fill").font(.system(size: 12)).foregroundStyle(DS.Color.textSecondary) }
            }
            .padding(DS.Spacing.m)
            .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private static func distance(_ a: Coordinate, _ b: Coordinate) -> String {
        let m = Geo.distanceMeters(a, b)
        return m < 1000 ? "\(Int(m)) m" : String(format: "%.1f km", m / 1000)
    }
}
