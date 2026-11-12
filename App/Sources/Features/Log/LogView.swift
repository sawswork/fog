import SwiftUI
import Charts
import PhotosUI
import Core

/// ログ（§4）。上半分が釣行、下半分が分析。どちらも横スクロールのカードで 1 画面に収める。
struct LogView: View {
    @Environment(AppServices.self) private var services
    private var model: LogViewModel { services.logModel }
    @State private var detail: Core.Session?
    /// 仲間の釣行の詳細（F-62）
    @State private var friendDetail: LogViewModel.FriendTripCard?
    @State private var analysis: AnalysisKind?
    @State private var reportSession: Core.Session?
    @State private var deleting: Core.Session?
    /// 写真の手動取り込み（F-61）
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var importMessage: String?
    /// 魚が写っていないので取り込まなかった写真（「それでも取り込む」で取り込める）
    @State private var noFishPhotos: [String] = []

    /// 取り込みの結果の文
    private static func importText(_ r: PhotoImportService.ManualResult) -> String {
        var parts: [String] = []
        if r.imported > 0 { parts.append("\(r.imported) 枚を取り込みました" + (r.measured > 0 ? "（メジャーから \(r.measured) 枚のサイズを判定）" : "")) }
        if !r.noFish.isEmpty { parts.append("魚が写っていない \(r.noFish.count) 枚は取り込みませんでした") }
        if r.skipped > 0 { parts.append("\(r.skipped) 枚は取り込み済みか読めない写真でした") }
        return parts.isEmpty ? "取り込める写真がありませんでした（取り込み済みか、読めない写真）" : parts.joined(separator: "。")
    }

    enum AnalysisKind: String, Identifiable { case hour, tide, spot, map; var id: String { rawValue } }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: DS.Spacing.s) {
                header.frame(height: geo.size.height * 0.08)
                periodControl.frame(height: geo.size.height * 0.055)
                latestReport.frame(height: geo.size.height * 0.065)
                sessionCards.frame(height: geo.size.height * 0.32)
                Text("分析").font(.system(size: 22, weight: .bold)).foregroundStyle(DS.Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: geo.size.height * 0.045)
                analysisCards.frame(height: geo.size.height * 0.37)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.bottom, DS.Spacing.s)
            // テーマのキャラクター（魔導書：右上、縦 3:4）。内容の後ろに置く
            .background(alignment: .topTrailing) { ThemeCharacter(name: .charLog, baseWidth: geo.size.width * 0.5) }
        }
        .onAppear { model.attach(services) }
        .onReceive(NotificationCenter.default.publisher(for: .fogStoreDidChange)) { _ in model.refresh() }
        // 仲間の釣行（F-62）：開いたら取りに行き、届いたら並べ直す
        // 記録を開いたら、前の同期から 1 分たっていれば仲間の釣果を取り直す（30 分の間隔を待たない）
        .task { await services.party.syncIfStale(store: services.store) }
        .onChange(of: services.party.revision) { _, _ in model.refresh() }
        .sheet(item: $detail) {
            SessionDetailView(session: $0, spotName: model.spots[$0.spotID]?.name ?? "釣り場",
                              companions: model.companions[$0.id] ?? [], friendCatches: model.companionCatches[$0.id] ?? [])
        }
        .sheet(item: $friendDetail) { FriendTripDetailView(card: $0) }
        .sheet(item: $analysis) { AnalysisDetailView(kind: $0, sessions: model.allSessions, spots: model.spots) }
        .sheet(item: $reportSession) { s in
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                Text(s.report?.summary ?? "").font(DS.Font.number(20)).foregroundStyle(DS.Color.textPrimary)
                Text(s.report?.body ?? "").font(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
                Spacer()
            }
            .padding(DS.Spacing.l).frame(maxWidth: .infinity, alignment: .leading).background(ThemeBackground(name: .bgDetail))
            .presentationDetents([.medium, .large])
        }
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            let ids = items.compactMap(\.itemIdentifier)
            pickedPhotos = []
            importing = true
            Task {
                let r = await services.photoImport.importAssets(identifiers: ids)
                importing = false
                importMessage = Self.importText(r)
                noFishPhotos = r.noFish
                model.refresh()
            }
        }
        .alert("写真の取り込み", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            // 魚が写っていないと判定した写真は、確かめたうえで取り込める（判定が外れたとき用。F-67）
            if !noFishPhotos.isEmpty {
                Button("それでも取り込む") {
                    let ids = noFishPhotos
                    noFishPhotos = []
                    importMessage = nil
                    importing = true
                    Task {
                        let r = await services.photoImport.importAssets(identifiers: ids, allowNoFish: true)
                        importing = false
                        importMessage = Self.importText(r)
                        model.refresh()
                    }
                }
            }
            Button("OK", role: .cancel) { importMessage = nil; noFishPhotos = [] }
        } message: { Text(importMessage ?? "") }
        .confirmationDialog("この釣行を削除", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("削除", role: .destructive) { if let d = deleting { model.delete(d) }; deleting = nil }
            Button("キャンセル", role: .cancel) { deleting = nil }
        }
    }

    /// 見出し「ログ」と右の数字 2 つ（確定画像：数字の下に小さなラベル）
    private var header: some View {
        HStack(alignment: .bottom) {
            Text("記録").font(.system(size: 34, weight: .bold)).foregroundStyle(DS.Color.textPrimary)
            // 写真を選んで取り込む（F-61）。標準カメラで撮った過去の写真も釣果にできる。メジャーが写っていればサイズも入る
            PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 20, matching: .images, photoLibrary: .shared()) {
                Group {
                    if importing { ProgressView().tint(DS.Color.textSecondary) } else { Image(systemName: "photo.badge.plus").font(.system(size: 17, weight: .semibold)) }
                }
                .foregroundStyle(DS.Color.textSecondary).frame(width: 32, height: 32)
            }
            .disabled(importing)
            .padding(.bottom, 6)
            Spacer()
            HStack(spacing: DS.Spacing.l) {
                stat(model.sessionCount, "釣行")
                stat(model.catchCount, "尾")
            }
            .padding(.bottom, 6)
        }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text("\(value)").font(DS.Font.number(18)).foregroundStyle(DS.Color.textPrimary)
            Text(label).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
        }
    }

    /// 期間セグメント：選択中はオレンジ地に黒文字、他は暗い面に白文字（確定画像）
    private var periodControl: some View {
        HStack(spacing: 0) {
            ForEach(LogViewModel.Period.allCases) { p in
                Button { model.period = p } label: {
                    Text(p.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(model.period == p ? DS.Color.background : DS.Color.textPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(model.period == p ? DS.Color.accent : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous)).themeOutline(14)
    }

    /// 最新レポートの 1 行（確定画像：グレーの文章。枠なし）
    private var latestReport: some View {
        Group {
            if let r = model.latestReport {
                Button { reportSession = r.session } label: {
                    Text(r.summary).font(.system(size: 15)).foregroundStyle(DS.Color.textSecondary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else {
                Text("釣行が終わるとレポートがここに出ます").font(.system(size: 15)).foregroundStyle(DS.Color.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var sessionCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.m) {
                // 自分の釣行と、仲間の釣行（自分が行っていなくても出る。F-62）を新しい順に
                ForEach(model.items) { item in
                    switch item {
                    case .own(let card):
                        SessionCardView(card: card, duration: model.durationText(card.session))
                            .frame(width: 200)
                            .onTapGesture { detail = card.session }
                            .onLongPressGesture { deleting = card.session }
                    case .friend(let card):
                        FriendTripCardView(card: card, duration: model.durationText(card.trip.duration ?? 0))
                            .frame(width: 200)
                            .onTapGesture { friendDetail = card }
                    }
                }
                if model.items.isEmpty {
                    Text("釣行はまだありません").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).padding()
                }
            }
        }
    }

    private var analysisCards: some View {
        let bestHour = model.byHour.max { $0.count < $1.count }
        let bestTide = model.byTide.max { $0.count < $1.count }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.m) {
                analysisCard(.hour, title: "時間帯", number: bestHour.map { $0.count > 0 ? "\($0.count)" : "—" } ?? "—",
                             sub: bestHour.map { $0.count > 0 ? "\($0.hour)時がいちばん釣れる" : "" } ?? "") {
                    Chart(model.byHour, id: \.hour) { h in
                        BarMark(x: .value("時", h.hour), y: .value("尾", h.count))
                            .foregroundStyle(h.hour == bestHour?.hour && h.count > 0 ? DS.Color.accent : DS.Color.secondary)
                            .cornerRadius(2)
                    }
                    .chartXAxis { AxisMarks(values: [0, 6, 12, 18]) { _ in AxisValueLabel().font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary) } }
                    .chartYAxis(.hidden)
                }
                analysisCard(.tide, title: "潮", number: bestTide.map { $0.count > 0 ? "\($0.count)" : "—" } ?? "—",
                             sub: bestTide.map { $0.count > 0 ? "\($0.label)でよく釣れる" : "" } ?? "") {
                    Chart(model.byTide, id: \.label) { t in
                        BarMark(x: .value("潮", t.label), y: .value("尾", t.count))
                            .foregroundStyle(t.label == bestTide?.label && t.count > 0 ? DS.Color.accent : DS.Color.secondary)
                            .cornerRadius(2)
                    }
                    .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 8)).foregroundStyle(DS.Color.textTertiary) } }
                    .chartYAxis(.hidden)
                }
                analysisCard(.spot, title: "釣り場", number: model.bySpot.first.map { String(format: "%.1f", $0.perHour) } ?? "—",
                             sub: model.bySpot.first.map { "\($0.name) 尾/時" } ?? "") {
                    Chart(model.bySpot.prefix(5), id: \.name) { s in
                        BarMark(x: .value("釣り場", String(s.name.prefix(4))), y: .value("尾/h", s.perHour))
                            .foregroundStyle(s.name == model.bySpot.first?.name ? DS.Color.accent : DS.Color.secondary)
                            .cornerRadius(2)
                    }
                    .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 8)).foregroundStyle(DS.Color.textTertiary) } }
                    .chartYAxis(.hidden)
                }
                // 地図（F-32）：全釣果のヒートマップ
                analysisCard(.map, title: "地図", number: "\(model.catchCount)", sub: "釣れた場所の濃さ") {
                    ZStack {
                        RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).fill(DS.Color.surface)
                        Image(systemName: "map.fill").font(.system(size: 28)).foregroundStyle(DS.Color.accent.opacity(0.8))
                    }
                    .frame(height: 100)
                }
            }
        }
    }

    private func analysisCard<C: View>(_ kind: AnalysisKind, title: String, number: String, sub: String, @ViewBuilder chart: () -> C) -> some View {
        Button { analysis = kind } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(DS.Color.textPrimary)
                Text(sub).font(.system(size: 10)).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                chart()
                Text(number).font(DS.Font.score(36)).foregroundStyle(DS.Color.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(DS.Spacing.m)
            .frame(width: 165)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)).themeOutline(DS.Radius.card)
        }
        .buttonStyle(.plain)
    }
}

/// 釣行カード：ベストショットを背景に、日付・釣り場・尾数・滞在時間。ボウズは写真なしのグレー。
struct SessionCardView: View {
    let card: LogViewModel.SessionCard
    let duration: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // カードの大きさを先に決め、写真はその中に敷く（写真の縦横比でカードが広がらないように）
            Color.clear.overlay {
                if let data = card.thumbnail, let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFill()
                        .overlay(LinearGradient(colors: [.clear, DS.Color.background.opacity(0.85)], startPoint: .center, endPoint: .bottom))
                } else {
                    // ボウズ・写真なしはグレーの面（確定画像）
                    card.session.isBlank ? Color(red: 0.55, green: 0.55, blue: 0.57) : DS.Color.panel
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.session.startedAt, format: .dateTime.year().month(.twoDigits).day(.twoDigits)).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                Text(card.spotName).font(.system(size: 20, weight: .bold)).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                // いっしょに行った人（F-62）
                if !card.companions.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill").font(.system(size: 9, weight: .bold))
                        Text(card.companions.joined(separator: "・")).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(DS.Color.sun)
                }
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                    Text(card.session.isBlank ? "ボウズ" : "\(card.session.catches.count)").font(DS.Font.number(24))
                        .foregroundStyle(card.session.isBlank ? DS.Color.textSecondary : DS.Color.textPrimary)
                    Text(duration).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
            }
            .padding(DS.Spacing.m)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .themeOutline(DS.Radius.card)
    }
}
