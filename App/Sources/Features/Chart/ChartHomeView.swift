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
    @State private var menuOpen = false
    /// この釣行の釣果の一覧と、1 尾の修正
    @State private var showCatches = false
    @State private var editingCatch: Catch?
    /// 釣行中に画面を見ている間は、位置を高精度で取る（現在地と立ち位置のため）。離れたら戻す
    @State private var holdingLocation = false
    @Environment(\.scenePhase) private var scenePhase
    /// 声で記録・相談（F-65）
    @State private var voice = SpeechRecorder()
    @State private var voiceOpen = false
    @State private var voiceBusy = false
    @State private var voiceReply: String?
    @State private var voiceTask: Task<Void, Never>?

    private var home: HomeViewModel { services.homeModel }
    private var scrubBinding: Binding<Date?> { Binding(get: { vm.scrub }, set: { vm.scrub = $0 }) }

    var body: some View {
        ZStack {
            ChartStyle.bg.ignoresSafeArea()
            if home.isRecording { recording } else { idle }
            if let note { noteView(note) }
            if menuOpen { menuPanel.transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing))) }
            if voiceOpen { voiceCard.transition(.opacity.combined(with: .move(edge: .bottom))) }
        }
        .preferredColorScheme(.dark)
        .onDisappear { stopVoice(); syncLocationHold(visible: false) }
        .onChange(of: scenePhase) { _, _ in syncLocationHold(visible: true) }
        .onChange(of: home.isRecording) { _, _ in syncLocationHold(visible: true) }
        .sheet(isPresented: $showCatches) { ChartCatchesSheet().presentationDetents([.medium, .large]) }
        .sheet(item: $editingCatch) { item in
            CatchEditSheet(catchItem: item) { Task { await reload() } }.presentationDetents([.large])
        }
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
        syncLocationHold(visible: true)
    }

    /// 釣行中で、この画面が前面にある間だけ高精度の位置を使う
    private func syncLocationHold(visible: Bool) {
        let want = visible && home.isRecording && scenePhase == .active
        guard want != holdingLocation else { return }
        holdingLocation = want
        if want { services.location.beginForegroundUpdates() } else { services.location.endForegroundUpdates() }
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
                    Text(home.spot?.name ?? "現在地").font(ChartStyle.font(20, .bold)).foregroundStyle(ChartStyle.white).lineLimit(1)
                    Image(systemName: "chevron.right").font(ChartStyle.font(12, .bold)).foregroundStyle(ChartStyle.gray2)
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            if home.isRecording, let live = home.liveSession {
                Circle().fill(ChartStyle.orange).frame(width: 8, height: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(from: live.startedAt, to: context.date))
                        .font(ChartStyle.number(17, .semibold)).monospacedDigit().foregroundStyle(ChartStyle.white)
                }
            }
            voiceButton
            menu
        }
        .frame(height: 40)
    }

    // MARK: 声で記録・相談（F-65）

    /// マイク：押して話すと、記録（ロスト・リグ・開始/終了・撮影）か相談（次の一手・記録への質問など）になる。話し終えると自動で止まる
    private var voiceButton: some View {
        Button { voiceOpen ? stopVoice() : startVoice() } label: {
            ZStack {
                Circle().fill(voice.isRecording ? ChartStyle.orange : ChartStyle.panel.opacity(0.62))
                Circle().strokeBorder(ChartStyle.border, lineWidth: 1)
                Image(systemName: "mic.fill").font(ChartStyle.font(14, .bold)).foregroundStyle(voice.isRecording ? ChartStyle.onAccent : ChartStyle.white)
            }
            .frame(width: 36, height: 36)
            .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("声で記録・相談")
    }

    /// 聞いている間は書き起こし、終わったら結果。タップで閉じる
    private var voiceCard: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: voice.isRecording ? "waveform" : (voiceBusy ? "ellipsis" : "sparkle")).font(ChartStyle.font(13, .bold)).foregroundStyle(ChartStyle.orange)
                    Text(voice.isRecording ? "聞いています（話し終えると止まります）" : (voiceBusy ? "考えています" : "結果"))
                        .font(ChartStyle.font(11.5, .semibold)).foregroundStyle(ChartStyle.gray1)
                    Spacer()
                    Button { stopVoice() } label: {
                        Image(systemName: "xmark").font(ChartStyle.font(12, .bold)).foregroundStyle(ChartStyle.gray1).frame(width: 30, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let error = voice.error {
                    Text(error).font(ChartStyle.font(13, .medium)).foregroundStyle(ChartStyle.white)
                } else if let reply = voiceReply {
                    if !voice.transcript.isEmpty { Text("「\(voice.transcript)」").font(ChartStyle.font(11.5, .medium)).foregroundStyle(ChartStyle.gray2).lineLimit(2) }
                    Text(reply).font(ChartStyle.font(14, .semibold)).foregroundStyle(ChartStyle.white).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(voice.transcript.isEmpty ? "例：「ロスト」「シンカー 14 グラムに替えた」「次どうする？」「終了」" : voice.transcript)
                        .font(ChartStyle.font(14, .medium)).foregroundStyle(voice.transcript.isEmpty ? ChartStyle.gray2 : ChartStyle.white).lineLimit(4)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChartStyle.panel.opacity(0.97), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(ChartStyle.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            .padding(.horizontal, 16).padding(.bottom, home.isRecording ? 132 : 236)
        }
    }

    private func startVoice() {
        voiceTask?.cancel()
        voiceReply = nil
        voiceBusy = false
        withAnimation(.easeOut(duration: 0.2)) { voiceOpen = true }
        voiceTask = Task {
            await voice.start()
            guard voice.isRecording else { return }
            // 話し終わり：文字が 1.6 秒変わらなければ止める。何も話さなければ 8 秒、長くても 20 秒
            var last = "", still = 0.0, total = 0.0
            while !Task.isCancelled, voice.isRecording {
                try? await Task.sleep(nanoseconds: 300_000_000)
                total += 0.3
                if voice.transcript == last { still += 0.3 } else { last = voice.transcript; still = 0 }
                if (!last.isEmpty && still >= 1.6) || (last.isEmpty && total >= 8) || total >= 20 { break }
            }
            guard !Task.isCancelled else { return }
            voice.stop()
            let text = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { withAnimation { voiceOpen = false }; return }
            voiceBusy = true
            let reply = await answer(text)
            guard !Task.isCancelled else { return }
            voiceBusy = false
            voiceReply = reply.text
            vm.update(services: services)
            if reply.openCamera {
                withAnimation { voiceOpen = false }
                cameraOpen = true
            } else if case .command = AssistantActions.route(text) {
                // 記録の確認は 4 秒で消す（相談の答えは、読めるように残す）
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled { withAnimation { voiceOpen = false } }
            }
        }
    }

    private func stopVoice() {
        voiceTask?.cancel()
        voiceTask = nil
        if voice.isRecording { voice.stop() }
        voiceBusy = false
        withAnimation(.easeIn(duration: 0.15)) { voiceOpen = false }
    }

    /// 話した言葉を、記録・操作か相談として処理する（相談の画面と同じ振り分け）
    private func answer(_ text: String) async -> AssistantActions.Reply {
        let intent = AssistantActions.route(text)
        if let reply = await AssistantActions.run(intent, text: text, services: services, home: home) { return reply }
        // 予報の質問など：これまでの相談役に聞く
        let assistant = services.assistant
        let context = await AssistantContext.build(services: services, home: home, question: text)
        await assistant.ask(text, context: context)
        return AssistantActions.Reply(text: assistant.messages.last(where: { $0.role == .assistant })?.text ?? "うまく答えられませんでした")
    }

    private static let menuItems: [(item: MenuItem, title: String, symbol: String)] = [
        (.log, "記録", "list.bullet.rectangle"), (.guide, "図鑑", "book"), (.spots, "釣り場の地図", "map"),
        (.feed, "釣果情報", "newspaper"), (.assistant, "相談", "bubble.left.and.text.bubble.right"), (.settings, "設定", "gearshape"),
    ]

    /// 右上のメニュー。標準は iOS の一覧、着せ替え（`chart.menu: "panel"`）はテーマの色と印のパネル
    @ViewBuilder
    private var menu: some View {
        if ChartStyle.skin.menuPanel {
            Button { withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { menuOpen.toggle() } } label: {
                ZStack {
                    Circle().fill(ChartStyle.panel.opacity(0.62))
                    Circle().strokeBorder(ChartStyle.border, lineWidth: 1)
                    Image(systemName: menuOpen ? "xmark" : "line.3.horizontal").font(ChartStyle.font(14, .bold)).foregroundStyle(ChartStyle.white)
                }
                .frame(width: 36, height: 36)
                .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("メニュー")
        } else {
            Menu {
                ForEach(Array(Self.menuItems.enumerated()), id: \.offset) { _, entry in
                    Button { sheet = entry.item } label: { Label(entry.title, systemImage: entry.symbol) }
                }
            } label: {
                Image(systemName: "line.3.horizontal").font(ChartStyle.font(19, .semibold)).foregroundStyle(ChartStyle.gray1)
                    .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("メニュー")
        }
    }

    /// テーマの形のメニュー：右上から開く札。外を触ると閉じる
    private var menuPanel: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.32).ignoresSafeArea()
                .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { menuOpen = false } }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.menuItems.enumerated()), id: \.offset) { index, entry in
                    Button {
                        menuOpen = false
                        sheet = entry.item
                    } label: {
                        HStack(spacing: 12) {
                            if let icon = ChartAssets.ui("menu_" + entry.item.rawValue) {
                                Image(uiImage: icon).resizable().scaledToFit().frame(width: 36, height: 36)
                            } else {
                                Image(systemName: entry.symbol).font(ChartStyle.font(16, .semibold)).foregroundStyle(ChartStyle.orange).frame(width: 36, height: 36)
                            }
                            Text(entry.title).font(ChartStyle.font(15.5, .semibold)).foregroundStyle(ChartStyle.white)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(ChartStyle.font(10.5, .bold)).foregroundStyle(ChartStyle.gray2)
                        }
                        .padding(.horizontal, 14).frame(height: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < Self.menuItems.count - 1 {
                        Rectangle().fill(ChartStyle.border.opacity(0.4)).frame(height: 0.5).padding(.leading, 62).padding(.trailing, 14)
                    }
                }
            }
            .padding(.vertical, 9)
            .frame(width: 228)
            .background(ChartStyle.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(ChartFrame(radius: 10, cornerSize: 28))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            .padding(.trailing, 20).padding(.top, 46)
        }
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
                Image(systemName: c.weatherSymbol ?? "cloud.fill").font(ChartStyle.font(13, .semibold))
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
                Text(label).font(ChartStyle.font(10.5, .medium)).foregroundStyle(ChartStyle.gray1)
            }
            mark()
            Text(value).font(ChartStyle.font(13, .semibold)).monospacedDigit().foregroundStyle(ChartStyle.white).lineLimit(1)
        }
        .fixedSize()
    }

    // MARK: 釣れ率と予報

    /// 左：今（かなぞった時刻）の釣れ率と次の山。右：9 時間の線
    private var forecastRow: some View {
        HStack(alignment: .center, spacing: 14) {
            scoreBlock(size: 46).frame(width: 112, alignment: .leading)
            ChartForecastStrip(points: vm.points, tide: vm.tide, tideRange: vm.tideRange, now: vm.now, horizon: ChartViewModel.horizon, extremes: home.tideExtremes, twilight: vm.twilight, scrub: scrubBinding)
        }
    }

    private func scoreBlock(size: CGFloat) -> some View {
        let scrubbing = vm.scrub != nil
        return VStack(alignment: .leading, spacing: 0) {
            Text(scrubbing ? JPFormat.hm(vm.scrub ?? vm.now) + " の釣れ率" : "いまの釣れ率")
                .font(ChartStyle.font(11, .medium)).foregroundStyle(ChartStyle.gray1)
            Text("\(vm.shownScore)").font(ChartStyle.number(size, .bold)).monospacedDigit()
                .foregroundStyle(scrubbing ? ChartStyle.orange : ChartStyle.white)
                .contentTransition(.numericText())
            nextPeak
        }
    }

    @ViewBuilder
    private var nextPeak: some View {
        if vm.scrub != nil {
            Text("離すと いま に戻る").font(ChartStyle.font(10.5, .medium)).foregroundStyle(ChartStyle.gray2)
        } else if let p = vm.peak {
            HStack(spacing: 4) {
                Circle().fill(ChartStyle.orange).frame(width: 6, height: 6)
                Text(JPFormat.hm(p.at) + " に").font(ChartStyle.font(11.5, .medium)).foregroundStyle(ChartStyle.gray1)
                Text("\(p.score)").font(ChartStyle.font(13, .bold)).foregroundStyle(ChartStyle.orange)
            }
        } else {
            Text("いまが山").font(ChartStyle.font(11.5, .medium)).foregroundStyle(ChartStyle.gray1)
        }
    }

    // MARK: 待機（着いたら）

    private var idle: some View {
        let skin = ChartStyle.skin
        return GeometryReader { geo in
            let full = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            idleContent(skin: skin, full: full)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                // 中身は安全領域の高さにぴったり収める。背景は下に敷くだけで、並べ方には関わらせない
                // （背景を同じ重ねに入れると、中身まで画面全体の高さで並び、下のボタンが切れていた。2026-11-11 開発者の指摘）
                .frame(width: geo.size.width, height: geo.size.height)
                .background(alignment: .top) {
                    idleBackdrop(skin: skin, width: geo.size.width, full: full)
                        .offset(y: -geo.safeAreaInsets.top)
                }
        }
    }

    /// 待機中の背景：絵、上下の幕、効果。画面全体（安全領域の外まで）
    private func idleBackdrop(skin: ChartSkinValues, width: CGFloat, full: CGFloat) -> some View {
        ZStack {
            if let background = ChartAssets.ui("bg_idle") {
                Image(uiImage: background).resizable().scaledToFill()
                    .frame(width: width, height: full)
                    .clipped()
                    .overlay(ChartStyle.bg.opacity(skin.idleDim))
                    .overlay(alignment: .top) {
                        // 上の幕：明るい空の上でも釣り場名と数字が読めるように
                        LinearGradient(colors: [ChartStyle.bg.opacity(skin.idleTopScrim), ChartStyle.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                            .frame(height: full * 0.36)
                    }
                    .overlay(alignment: .bottom) {
                        LinearGradient(stops: [.init(color: ChartStyle.bg.opacity(0), location: 0),
                                               .init(color: ChartStyle.bg.opacity(skin.idleBottomScrim * 0.82), location: 0.5),
                                               .init(color: ChartStyle.bg.opacity(skin.idleBottomScrim), location: 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: full * (skin.idleFaceGap == nil ? 0.4 : 0.58))
                    }
            }
            ForEach(skin.idleEffects, id: \.self) { effect in
                HomeEffectField(kind: effect, count: effect == "fireflies" ? 16 : 10, color: ChartStyle.orange, speed: 0.8, amount: 0.8)
            }
        }
        .frame(width: width, height: full)
        .allowsHitTesting(false)
    }

    private func idleContent(skin: ChartSkinValues, full: CGFloat) -> some View {
                VStack(spacing: 0) {
                    topBar
                    // 顔を見せるテーマ：数字は上へ寄せ、数字の下を空ける。標準は均等
                    if skin.idleFaceGap == nil { Spacer(minLength: 8) } else { Color.clear.frame(height: 2) }
                    VStack(spacing: 2) {
                        if skin.idleCaptions {
                            Text(vm.scrub != nil ? JPFormat.hm(vm.scrub ?? vm.now) + " の釣れ率" : "いまの釣れ率")
                                .font(ChartStyle.font(12.5, .medium)).foregroundStyle(skin.idleFaceGap == nil ? ChartStyle.gray1 : ChartStyle.white.opacity(0.9))
                        }
                        Text("\(vm.shownScore)").font(ChartStyle.number(skin.idleNumberSize, .bold)).monospacedDigit()
                            .foregroundStyle(vm.scrub != nil ? ChartStyle.orange : ChartStyle.white)
                            .contentTransition(.numericText()).minimumScaleFactor(0.6).lineLimit(1)
                        if skin.idleFaceGap == nil {
                            nextPeak
                        } else {
                            // 絵の上では、次の山を小さな札に入れて読めるようにする
                            nextPeak.padding(.horizontal, 11).padding(.vertical, 4)
                                .background(ChartStyle.panel.opacity(0.58), in: Capsule())
                                .overlay(Capsule().strokeBorder(ChartStyle.border.opacity(0.7), lineWidth: 0.7))
                        }
                    }
                    .shadow(color: ChartStyle.bg.opacity(skin.idleFaceGap == nil ? 0 : 0.55), radius: 8, y: 1)
                    if let gap = skin.idleFaceGap { Spacer(minLength: min(full * gap, 150)) } else { Spacer(minLength: 12) }
                    if skin.idleFaceGap == nil {
                        metrics
                    } else {
                        // 絵の上では、数字の行を細い帯（半透明の面と縁）に載せる
                        metrics.padding(.horizontal, 13).frame(height: 36)
                            .background(ChartStyle.panel.opacity(0.6), in: Capsule())
                            .overlay(Capsule().strokeBorder(ChartStyle.border.opacity(0.75), lineWidth: 0.8))
                            .padding(.horizontal, -10)
                    }
                    ChartForecastStrip(points: vm.points, tide: vm.tide, tideRange: vm.tideRange, now: vm.now, horizon: ChartViewModel.horizon, extremes: home.tideExtremes, twilight: vm.twilight, scrub: scrubBinding)
                        .frame(height: 124).padding(.top, 14)
                    if skin.idleFaceGap == nil { Spacer(minLength: 12) } else { Color.clear.frame(height: 12) }
                    startOrb
                    if skin.idleCaptions {
                        Text("押すと釣行が始まり、この港の図が開きます").font(ChartStyle.font(11.5, .medium)).foregroundStyle(ChartStyle.gray2)
                            .padding(.top, 14)
                    } else {
                        Color.clear.frame(height: 18)
                    }
                    if skin.idleFaceGap == nil { Spacer(minLength: 8) } else { Color.clear.frame(height: 6) }
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
                Circle().fill(RadialGradient(colors: [ChartStyle.orange.opacity(0.32 * ChartStyle.skin.glow), ChartStyle.orange.opacity(0)], center: .center, startRadius: 40, endRadius: 104))
                    .frame(width: 208, height: 208).scaleEffect(orbPulse ? 1.05 : 0.95)
                if let orb = ChartAssets.ui("orb_start") {
                    Image(uiImage: orb).resizable().scaledToFit().frame(width: 152, height: 152)
                } else {
                    Circle().fill(ChartStyle.panel).frame(width: 140, height: 140).overlay(Circle().stroke(ChartStyle.orange, lineWidth: 2.5))
                }
                Text("開始").font(ChartStyle.font(30, .bold)).foregroundStyle(ChartStyle.white)
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
            mapArea
            forecastRow.frame(height: 92).padding(.horizontal, 24).padding(.top, 2)
            actions.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 10)
        }
    }

    /// 港の図と、その下端に重ねる釣果・ひとこと。着せ替え（`chart.mapFrame`）は額のような枠と角飾りで囲む
    @ViewBuilder
    private var mapArea: some View {
        let framed = ChartStyle.skin.mapFrame
        let content = ZStack(alignment: .bottom) {
            ChartMapView(model: vm, newestCatchID: toast?.id, framed: framed)
            VStack(alignment: .leading, spacing: 8) {
                if vm.scrub != nil {
                    Text(JPFormat.hm(vm.scrub ?? vm.now) + " の予測").font(ChartStyle.font(12, .bold)).foregroundStyle(ChartStyle.onAccent)
                        .padding(.horizontal, 12).padding(.vertical, 5).background(ChartStyle.orange, in: Capsule())
                }
                if let toast { toastCard(toast) } else { thumbnails }
                // 枠のあるテーマ：下の角飾りに文字がかからないよう、ひとことは内側へ寄せる
                adviceLine.padding(.horizontal, framed ? 18 : 0)
            }
            .padding(.horizontal, framed ? 16 : 20)
            .padding(.bottom, framed ? 12 : 6)
        }
        if framed {
            content
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(ChartFrame(radius: 8, cornerSize: 46))
                .padding(.horizontal, 10).padding(.top, 6)
                .frame(maxHeight: .infinity)
        } else {
            content.frame(maxHeight: .infinity)
        }
    }

    /// 見立ての一言（規則から組み立てる）
    private var adviceLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "sparkle").font(ChartStyle.font(11, .bold)).foregroundStyle(ChartStyle.orange)
            Text("AI").font(ChartStyle.font(11, .bold)).foregroundStyle(ChartStyle.orange)
            Text(vm.advice).font(ChartStyle.font(12.5, .medium)).foregroundStyle(ChartStyle.white).lineLimit(2).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
    }

    /// 今日釣れた魚の小さな写真（新しい 3 尾）
    private var thumbnails: some View {
        let pins = Array(vm.today.suffix(3))
        // タップで、この釣行の釣果の一覧（写真を見る・魚種やサイズを直す）
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button { showCatches = true } label: { thumbnailRow(pins) }
                .buttonStyle(.plain)
                .disabled(vm.today.isEmpty)
                .accessibilityLabel("この釣行の釣果を見る")
        }
    }

    private func thumbnailRow(_ pins: [ChartViewModel.CatchPin]) -> some View {
        HStack(spacing: 6) {
            if !vm.today.isEmpty {
                Text("\(vm.today.count) 尾").font(ChartStyle.font(11.5, .semibold)).foregroundStyle(ChartStyle.white)
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
                    Text(t.species.isEmpty ? "魚" : t.species).font(ChartStyle.font(15.5, .bold)).foregroundStyle(ChartStyle.white).lineLimit(1)
                    if let cm = t.lengthCm {
                        Text("\(Int(cm.rounded())) cm").font(ChartStyle.font(15.5, .bold)).foregroundStyle(ChartStyle.orange)
                    }
                }
                Text("\(t.number) 尾目 · \(JPFormat.hm(t.at)) · 記録しました").font(ChartStyle.font(11, .medium)).foregroundStyle(ChartStyle.gray1)
            }
            Spacer(minLength: 0)
            Button {
                if let item = home.liveSession?.catches.first(where: { $0.id == t.id }) ?? (try? services.store.activeSession())?.catches.first(where: { $0.id == t.id }) {
                    editingCatch = item
                }
            } label: {
                Text("直す").font(ChartStyle.font(11.5, .semibold)).foregroundStyle(ChartStyle.orange).padding(.vertical, 10).padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
            Button {
                let id = t.id
                withAnimation { toast = nil }
                Task { await services.capture.deleteCatch(id: id, deletePhoto: false) }
            } label: {
                Text("取り消す").font(ChartStyle.font(11.5, .semibold)).foregroundStyle(ChartStyle.gray1).padding(.vertical, 10).padding(.leading, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(ChartStyle.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ChartStyle.border, lineWidth: 1))
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
                    Image(systemName: "arrow.uturn.down").font(ChartStyle.font(14, .semibold)).foregroundStyle(ChartStyle.gray1)
                    Text("ロスト \(vm.lostCount)").font(ChartStyle.font(14.5, .semibold)).foregroundStyle(ChartStyle.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("針のロストを記録")

            Button { cameraOpen = true } label: {
                ZStack {
                    Circle().fill(RadialGradient(colors: [ChartStyle.orange.opacity(0.45 * ChartStyle.skin.glow), ChartStyle.orange.opacity(0)], center: .center, startRadius: 30, endRadius: 78))
                        .frame(width: 156, height: 156).scaleEffect(orbPulse ? 1.06 : 0.94)
                    if let orb = ChartAssets.ui("orb_shutter") {
                        Image(uiImage: orb).resizable().scaledToFit().frame(width: 108, height: 108)
                    } else {
                        Circle().fill(ChartStyle.orange).frame(width: 96, height: 96)
                        Image(systemName: "camera.fill").font(ChartStyle.font(34, .bold)).foregroundStyle(ChartStyle.onAccent)
                    }
                }
                .frame(width: 108, height: 108)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("撮影")

            pill {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(ChartStyle.gray1).frame(width: 11, height: 11)
                VStack(spacing: 0) {
                    Text("終了").font(ChartStyle.font(14.5, .semibold)).foregroundStyle(ChartStyle.white)
                    Text("長押し").font(ChartStyle.font(9, .medium)).foregroundStyle(ChartStyle.gray2)
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
            .overlay(Capsule().strokeBorder(ChartStyle.border, lineWidth: 1))
            // 着せ替え：内側にもう 1 本の細い線（二重の縁）
            .overlay(Capsule().inset(by: 3.5).stroke(ChartStyle.border.opacity(ChartStyle.skin.border == nil ? 0 : 0.38), lineWidth: 0.6))
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
            Text(text).font(ChartStyle.font(13, .semibold)).foregroundStyle(ChartStyle.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(ChartStyle.panel.opacity(0.95), in: Capsule())
                .overlay(Capsule().stroke(ChartStyle.border, lineWidth: 1))
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
                Image(systemName: "xmark").font(ChartStyle.font(16, .bold)).foregroundStyle(.white)
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

/// この釣行の釣果の一覧（釣行中に、撮った魚を見たり直したりする）。写真をタップで拡大、行をタップで修正
struct ChartCatchesSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var catches: [Catch] = []
    @State private var editing: Catch?
    @State private var viewing: Catch?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack {
                Text("この釣行の釣果 \(catches.count) 尾").font(.system(size: 18, weight: .bold)).foregroundStyle(DS.Color.textPrimary)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(DS.Color.textSecondary).frame(width: 32, height: 32) }.buttonStyle(.plain)
            }
            Text("写真をタップで拡大、行をタップで魚種・サイズ・釣った人・リグを直せます").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            ScrollView {
                VStack(spacing: DS.Spacing.s) {
                    ForEach(catches) { c in CatchRow(item: c, onPhoto: { viewing = c }, onEdit: { editing = c }) }
                    if catches.isEmpty { Text("まだ釣果がありません").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).padding(.top, DS.Spacing.l) }
                }
            }
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ThemeBackground(name: .bgDetail))
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .fogStoreDidChange)) { _ in reload() }
        .sheet(item: $editing) { item in CatchEditSheet(catchItem: item) { reload() }.presentationDetents([.large]) }
        .fullScreenCover(item: $viewing) { item in PhotoViewer(catchItem: item) }
    }

    private func reload() {
        catches = ((try? services.store.activeSession())?.catches ?? []).sorted { $0.at > $1.at }
    }
}

/// 釣果 1 尾の行：写真・時刻・魚種・サイズ・釣った人。写真はタップで拡大、行はタップで修正（海図の一覧とログの釣行詳細で使う）
struct CatchRow: View {
    let item: Catch
    let onPhoto: () -> Void
    let onEdit: () -> Void
    @Environment(AppServices.self) private var services

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Group {
                if let data = services.store.thumbnail(catchID: item.id), let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
                } else {
                    RoundedRectangle(cornerRadius: DS.Radius.chip).fill(DS.Color.surface).frame(width: 56, height: 56)
                        .overlay(Image(systemName: "fish.fill").foregroundStyle(DS.Color.textTertiary))
                }
            }
            .onTapGesture(perform: onPhoto)
            Button(action: onEdit) {
                HStack(spacing: DS.Spacing.s) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: DS.Spacing.s) {
                            Text(item.species.isEmpty ? "魚種なし" : item.species).font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.Color.textPrimary)
                            if let a = item.angler, !a.isEmpty {
                                Text(a).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Color.background)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(DS.Color.sun, in: Capsule())
                            }
                        }
                        HStack(spacing: DS.Spacing.s) {
                            Text(JPFormat.hm(item.at)).font(DS.Font.number(13)).foregroundStyle(DS.Color.textSecondary)
                            Text(item.lengthCm.map { "\(Int($0.rounded())) cm" } ?? "未計測").font(DS.Font.number(15)).foregroundStyle(item.lengthCm == nil ? DS.Color.textTertiary : DS.Color.accent)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "pencil").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(DS.Spacing.s)
        .background(DS.Color.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
    }
}

