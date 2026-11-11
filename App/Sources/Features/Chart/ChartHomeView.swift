import SwiftUI
import Core

/// 新しい 1 画面「海図」（F-63）。着いたら開始、釣れたら撮影、帰るとき終了。その間は港の図が風と見立てを映し続ける。
/// ログ・図鑑・地図・設定などは右上のメニューから開く。テーマ「海図」を選んだときの画面（`AppTheme.isChart`）
struct ChartHomeView: View {
    @Environment(AppServices.self) private var services
    /// 撮影画面を開く（ウィジェットや通知からの撮影もここに来る）
    @Binding var cameraOpen: Bool

    enum MenuItem: String, Identifiable {
        case log, guide, spots, feed, assistant, settings
        var id: String { rawValue }
    }

    struct CatchToast: Identifiable, Equatable {
        let id: UUID
        let species: String
        let lengthCm: Double?
        let at: Date
        let number: Int
    }

    @State private var vm = ChartViewModel()
    @State private var sheet: MenuItem?
    @State private var showSpots = false
    @State private var showStartFailed = false
    @State private var busy = false
    @State private var toast: CatchToast?
    @State private var note: String?
    @State private var knownCatchIDs: Set<UUID>?
    @State private var endProgress: CGFloat = 0
    @State private var orbPulse = false

    private var home: HomeViewModel { services.homeModel }
    private var scrubBinding: Binding<Date?> { Binding(get: { vm.scrub }, set: { vm.scrub = $0 }) }

    var body: some View {
        ZStack {
            ChartStyle.bg.ignoresSafeArea()
            if home.isRecording { recording } else { idle }
            if let note { noteView(note) }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            home.attach(services)
            vm.update(services: services)
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { orbPulse = true }
        }
        .task { await reload() }
        .task {
            // 30 秒ごとに「今」を更新
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await reload()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fogStoreDidChange)) { _ in Task { await reload() } }
        .sheet(item: $sheet) { item in
            switch item {
            case .log: LogView().background(ThemeBackground(name: .bgLog))
            case .guide: GuideView().background(ThemeBackground(name: .bgGuide))
            case .spots: SpotsView()
            case .feed: FeedView(keywords: home.feedKeywords())
            case .assistant: AssistantView(home: home)
            case .settings: SettingsView()
            }
        }
        .sheet(isPresented: $showSpots) { SpotSwitchSheet(model: home) { showSpots = false }.presentationDetents([.large]) }
        .fullScreenCover(isPresented: $cameraOpen) { cameraCover }
        .onChange(of: cameraOpen) { _, open in
            if !open { Task { await reload() } }
        }
        .alert("位置が分かりません", isPresented: $showStartFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("位置情報を許可するか、左上の釣り場を選んでからもう一度押してください")
        }
    }

    private func reload() async {
        await home.refresh()
        vm.update(services: services)
        detectNewCatch()
    }

    /// 記録中に釣果が増えたら、確認のカードを出す（撮影画面から戻ったとき・標準カメラの写真の取り込み）
    private func detectNewCatch() {
        // 撮影画面を開いている間は待つ（閉じて海図に戻ったときに出す）
        guard !cameraOpen else { return }
        let ids = Set(vm.today.map(\.id))
        defer { knownCatchIDs = ids }
        guard home.isRecording, let known = knownCatchIDs else { return }
        guard let newest = vm.today.last(where: { !known.contains($0.id) }) else { return }
        let shown = CatchToast(id: newest.id, species: newest.species, lengthCm: newest.lengthCm, at: newest.at, number: vm.today.count)
        withAnimation(.easeOut(duration: 0.25)) { toast = shown }
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if toast?.id == shown.id { withAnimation(.easeIn(duration: 0.25)) { toast = nil } }
        }
    }

    // MARK: 上の行（釣り場・メニュー・経過時間）

    private var topBar: some View {
        HStack(alignment: .center, spacing: 6) {
            Button { showSpots = true } label: {
                HStack(spacing: 5) {
                    Text(home.spot?.name ?? "現在地").font(.system(size: 20, weight: .bold)).foregroundStyle(ChartStyle.white).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(ChartStyle.gray2)
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            if home.isRecording, let live = home.liveSession {
                Circle().fill(ChartStyle.orange).frame(width: 8, height: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(from: live.startedAt, to: context.date))
                        .font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(ChartStyle.white)
                }
            }
            menu
        }
        .frame(height: 40)
    }

    private var menu: some View {
        Menu {
            Button { sheet = .log } label: { Label("ログ", systemImage: "list.bullet.rectangle") }
            Button { sheet = .guide } label: { Label("図鑑", systemImage: "book") }
            Button { sheet = .spots } label: { Label("釣り場の地図", systemImage: "map") }
            Button { sheet = .feed } label: { Label("釣果情報", systemImage: "newspaper") }
            Button { sheet = .assistant } label: { Label("相談", systemImage: "bubble.left.and.text.bubble.right") }
            Button { sheet = .settings } label: { Label("設定", systemImage: "gearshape") }
        } label: {
            Image(systemName: "line.3.horizontal").font(.system(size: 19, weight: .semibold)).foregroundStyle(ChartStyle.gray1)
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .accessibilityLabel("メニュー")
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /// 潮・風・波・気温・天気（なぞっている間はその時刻の値）。上げ下げと風向は文字でなくマークで出す
    private var metrics: some View {
        let c = vm.conditions
        let tideWord: String
        switch c.tideState {
        case .rising: tideWord = "上げ"
        case .falling: tideWord = "下げ"
        case .slack: tideWord = "潮止まり"
        case nil: tideWord = ""
        }
        return HStack(spacing: 0) {
            metric("潮", c.tide) { ChartTideMark(state: c.tideState) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("潮 \(tideWord) \(c.tide)")
            Spacer(minLength: 4)
            metric("風", c.wind) { ChartWindMark(fromDeg: c.windFromDeg) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("風 " + (c.windName.map { $0 + "から " } ?? "") + c.wind)
            Spacer(minLength: 4)
            metric("波", c.wave) { EmptyView() }
            Spacer(minLength: 4)
            metric("気温", c.temp) { EmptyView() }
            Spacer(minLength: 4)
            metric("", c.rain) {
                Image(systemName: c.weatherSymbol ?? "cloud.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(c.weatherSymbol == nil ? ChartStyle.gray2 : ChartStyle.white).frame(width: 20)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("降水確率 " + c.rain)
        }
        .frame(height: 24)
    }

    private func metric<Mark: View>(_ label: String, _ value: String, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(alignment: .center, spacing: 4) {
            if !label.isEmpty {
                Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(ChartStyle.gray1)
            }
            mark()
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(ChartStyle.white).lineLimit(1)
        }
        .fixedSize()
    }

    // MARK: 釣れ率と予報

    /// 左：今（かなぞった時刻）の釣れ率と次の山。右：9 時間の線
    private var forecastRow: some View {
        HStack(alignment: .center, spacing: 14) {
            scoreBlock(size: 46).frame(width: 112, alignment: .leading)
            ChartForecastStrip(points: vm.points, tide: vm.tide, tideRange: vm.tideRange, now: vm.now, horizon: ChartViewModel.horizon, extremes: home.tideExtremes, scrub: scrubBinding)
        }
    }

    private func scoreBlock(size: CGFloat) -> some View {
        let scrubbing = vm.scrub != nil
        return VStack(alignment: .leading, spacing: 0) {
            Text(scrubbing ? JPFormat.hm(vm.scrub ?? vm.now) + " の釣れ率" : "いまの釣れ率")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(ChartStyle.gray1)
            Text("\(vm.shownScore)").font(.system(size: size, weight: .bold)).monospacedDigit()
                .foregroundStyle(scrubbing ? ChartStyle.orange : ChartStyle.white)
                .contentTransition(.numericText())
            nextPeak
        }
    }

    @ViewBuilder
    private var nextPeak: some View {
        if vm.scrub != nil {
            Text("離すと いま に戻る").font(.system(size: 10.5, weight: .medium)).foregroundStyle(ChartStyle.gray2)
        } else if let p = vm.peak {
            HStack(spacing: 4) {
                Circle().fill(ChartStyle.orange).frame(width: 6, height: 6)
                Text(JPFormat.hm(p.at) + " に").font(.system(size: 11.5, weight: .medium)).foregroundStyle(ChartStyle.gray1)
                Text("\(p.score)").font(.system(size: 13, weight: .bold)).foregroundStyle(ChartStyle.orange)
            }
        } else {
            Text("いまが山").font(.system(size: 11.5, weight: .medium)).foregroundStyle(ChartStyle.gray1)
        }
    }

    // MARK: 待機（着いたら）

    private var idle: some View {
        GeometryReader { geo in
            ZStack {
                if let background = ChartAssets.ui("bg_idle.jpg") {
                    Image(uiImage: background).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
                        .clipped().ignoresSafeArea()
                        .overlay(ChartStyle.bg.opacity(0.25).ignoresSafeArea())
                        .overlay(alignment: .bottom) {
                            LinearGradient(colors: [ChartStyle.bg.opacity(0), ChartStyle.bg], startPoint: .top, endPoint: .bottom)
                                .frame(height: geo.size.height * 0.4).ignoresSafeArea()
                        }
                }
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 8)
                    VStack(spacing: 2) {
                        Text(vm.scrub != nil ? JPFormat.hm(vm.scrub ?? vm.now) + " の釣れ率" : "いまの釣れ率")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(ChartStyle.gray1)
                        Text("\(vm.shownScore)").font(.system(size: 124, weight: .bold)).monospacedDigit()
                            .foregroundStyle(vm.scrub != nil ? ChartStyle.orange : ChartStyle.white)
                            .contentTransition(.numericText()).minimumScaleFactor(0.6).lineLimit(1)
                        nextPeak
                    }
                    Spacer(minLength: 12)
                    metrics
                    ChartForecastStrip(points: vm.points, tide: vm.tide, tideRange: vm.tideRange, now: vm.now, horizon: ChartViewModel.horizon, extremes: home.tideExtremes, scrub: scrubBinding)
                        .frame(height: 124).padding(.top, 14)
                    Spacer(minLength: 12)
                    startOrb
                    Text("押すと釣行が始まり、この港の図が開きます").font(.system(size: 11.5, weight: .medium)).foregroundStyle(ChartStyle.gray2)
                        .padding(.top, 14)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
        }
    }

    private var startOrb: some View {
        Button {
            guard !busy else { return }
            busy = true
            Task {
                let ok = await home.toggleSession()
                busy = false
                if ok { knownCatchIDs = nil; vm.update(services: services) } else { showStartFailed = true }
            }
        } label: {
            ZStack {
                Circle().fill(RadialGradient(colors: [ChartStyle.orange.opacity(0.32), ChartStyle.orange.opacity(0)], center: .center, startRadius: 40, endRadius: 104))
                    .frame(width: 208, height: 208).scaleEffect(orbPulse ? 1.05 : 0.95)
                if let orb = ChartAssets.ui("orb_start.png") {
                    Image(uiImage: orb).resizable().scaledToFit().frame(width: 152, height: 152)
                } else {
                    Circle().fill(ChartStyle.panel).frame(width: 140, height: 140).overlay(Circle().stroke(ChartStyle.orange, lineWidth: 2.5))
                }
                Text("開始").font(.system(size: 30, weight: .bold)).foregroundStyle(ChartStyle.white)
            }
            .frame(width: 168, height: 168)
            .opacity(busy ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("釣行を開始")
    }

    // MARK: 釣行中

    private var recording: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                metrics
            }
            .padding(.horizontal, 24)
            ZStack(alignment: .bottom) {
                ChartMapView(model: vm, newestCatchID: toast?.id)
                VStack(alignment: .leading, spacing: 8) {
                    if vm.scrub != nil {
                        Text(JPFormat.hm(vm.scrub ?? vm.now) + " の予測").font(.system(size: 12, weight: .bold)).foregroundStyle(ChartStyle.bg)
                            .padding(.horizontal, 12).padding(.vertical, 5).background(ChartStyle.orange, in: Capsule())
                    }
                    if let toast { toastCard(toast) } else { thumbnails }
                    adviceLine
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: .infinity)
            forecastRow.frame(height: 92).padding(.horizontal, 24).padding(.top, 2)
            actions.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 10)
        }
    }

    /// 見立ての一言（規則から組み立てる）
    private var adviceLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "sparkle").font(.system(size: 11, weight: .bold)).foregroundStyle(ChartStyle.orange)
            Text("AI").font(.system(size: 11, weight: .bold)).foregroundStyle(ChartStyle.orange)
            Text(vm.advice).font(.system(size: 12.5, weight: .medium)).foregroundStyle(ChartStyle.white).lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
    }

    /// 今日釣れた魚の小さな写真（新しい 3 尾）
    private var thumbnails: some View {
        let pins = Array(vm.today.suffix(3))
        return HStack(spacing: 6) {
            Spacer(minLength: 0)
            if !vm.today.isEmpty {
                Text("\(vm.today.count) 尾").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ChartStyle.white)
                    .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
            }
            ForEach(pins) { pin in
                thumbnail(for: pin.id, size: 34, radius: 9)
            }
        }
        .frame(height: 34)
    }

    private func thumbnail(for id: UUID, size: CGFloat, radius: CGFloat) -> some View {
        Color.clear.frame(width: size, height: size)
            .overlay {
                if let data = services.store.thumbnail(catchID: id), let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFill()
                } else {
                    ZStack {
                        ChartStyle.panel
                        Image(systemName: "fish.fill").font(.system(size: size * 0.4)).foregroundStyle(ChartStyle.gray2)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
    }

    /// 釣れた直後の確認。間違いなら取り消せる
    private func toastCard(_ t: CatchToast) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: t.id, size: 44, radius: 11)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(t.species.isEmpty ? "魚" : t.species).font(.system(size: 15.5, weight: .bold)).foregroundStyle(ChartStyle.white).lineLimit(1)
                    if let cm = t.lengthCm {
                        Text("\(Int(cm.rounded())) cm").font(.system(size: 15.5, weight: .bold)).foregroundStyle(ChartStyle.orange)
                    }
                }
                Text("\(t.number) 尾目 · \(JPFormat.hm(t.at)) · 記録しました").font(.system(size: 11, weight: .medium)).foregroundStyle(ChartStyle.gray1)
            }
            Spacer(minLength: 0)
            Button {
                let id = t.id
                withAnimation { toast = nil }
                Task { await services.capture.deleteCatch(id: id, deletePhoto: false) }
            } label: {
                Text("取り消す").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ChartStyle.gray1).padding(.vertical, 10).padding(.leading, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(ChartStyle.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// 下の操作：ロスト・撮影・終了（長押し）
    private var actions: some View {
        HStack(spacing: 14) {
            Button {
                if services.hookRecorder.record(.lost) != nil {
                    vm.update(services: services)
                    show(note: "ロストを記録しました")
                } else {
                    show(note: "位置が分からず記録できませんでした")
                }
            } label: {
                pill {
                    Image(systemName: "arrow.uturn.down").font(.system(size: 14, weight: .semibold)).foregroundStyle(ChartStyle.gray1)
                    Text("ロスト \(vm.lostCount)").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(ChartStyle.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("針のロストを記録")

            Button { cameraOpen = true } label: {
                ZStack {
                    Circle().fill(RadialGradient(colors: [ChartStyle.orange.opacity(0.45), ChartStyle.orange.opacity(0)], center: .center, startRadius: 30, endRadius: 78))
                        .frame(width: 156, height: 156).scaleEffect(orbPulse ? 1.06 : 0.94)
                    if let orb = ChartAssets.ui("orb_shutter.png") {
                        Image(uiImage: orb).resizable().scaledToFit().frame(width: 108, height: 108)
                    } else {
                        Circle().fill(ChartStyle.orange).frame(width: 96, height: 96)
                        Image(systemName: "camera.fill").font(.system(size: 34, weight: .bold)).foregroundStyle(ChartStyle.bg)
                    }
                }
                .frame(width: 108, height: 108)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("撮影")

            pill {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(ChartStyle.gray1).frame(width: 11, height: 11)
                VStack(spacing: 0) {
                    Text("終了").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(ChartStyle.white)
                    Text("長押し").font(.system(size: 9, weight: .medium)).foregroundStyle(ChartStyle.gray2)
                }
            }
            .overlay(alignment: .leading) {
                // 長押しの進み
                GeometryReader { g in
                    Capsule().fill(ChartStyle.orange.opacity(0.35)).frame(width: g.size.width * endProgress)
                }
                .clipShape(Capsule())
                .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: 0.8, maximumDistance: 40) {
                endProgress = 0
                guard !busy else { return }
                busy = true
                Task {
                    _ = await home.toggleSession()
                    busy = false
                    toast = nil
                    vm.update(services: services)
                }
            } onPressingChanged: { pressing in
                withAnimation(.linear(duration: pressing ? 0.8 : 0.15)) { endProgress = pressing ? 1 : 0 }
            }
            .accessibilityLabel("釣行を終了（長押し）")
        }
        .frame(height: 112)
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(ChartStyle.panel.opacity(0.8), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    // MARK: 小さな知らせ

    private func show(note text: String) {
        withAnimation { note = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if note == text { withAnimation { note = nil } }
        }
    }

    private func noteView(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(ChartStyle.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(ChartStyle.panel.opacity(0.95), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                .padding(.bottom, 150)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    // MARK: 撮影

    /// これまでの撮影画面をそのまま全画面で出し、左上に閉じるボタンを足す
    private var cameraCover: some View {
        ZStack(alignment: .topLeading) {
            CaptureView(onResultDismissed: { cameraOpen = false })
            Button { cameraOpen = false } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 16).padding(.top, 8)
            .accessibilityLabel("閉じる")
        }
        .environment(services)
        .preferredColorScheme(.dark)
    }
}
