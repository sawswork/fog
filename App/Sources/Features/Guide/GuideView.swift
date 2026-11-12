import SwiftUI
import Charts
import Core

extension GuideEntry: Identifiable {
    public var id: String { species }
}

/// 図鑑（§6）。釣った魚種だけがベストショットのグリッドで並ぶ。この画面だけ縦スクロールを許容する。
struct GuideView: View {
    @Environment(AppServices.self) private var services
    @State private var entries: [GuideEntry] = []
    @State private var sort: GuideEntry.Sort = .maxLength
    @State private var selected: GuideEntry?
    @State private var goCapture = false
    @Environment(\.captureTab) private var captureTab
    /// 釣った魚 / 全国の魚（F-60）
    @State private var mode: Mode = .caught
    /// ほかの人の魚として記録されている釣果（「ねも 4 尾」）。あれば、図鑑に入っていない理由を 1 行で出す
    @State private var othersNote: String?
    @State private var catalog = FishCatalog(entries: [])
    @State private var query = ""
    enum Mode: String, CaseIterable { case caught = "釣った魚", all = "全国の魚" }

    private let columns = [GridItem(.flexible(), spacing: DS.Spacing.m), GridItem(.flexible(), spacing: DS.Spacing.m), GridItem(.flexible(), spacing: DS.Spacing.m)]

    /// 釣果の魚種名 → 図鑑の id（別名も引く）
    private var caughtByID: [String: Int] {
        var out: [String: Int] = [:]
        for e in entries { if let f = catalog.entry(forSpecies: e.species) { out[f.id, default: 0] += e.count } }
        return out
    }

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            header
            if mode == .caught, let othersNote {
                Text("ほかの人の魚（\(othersNote)）は図鑑に入れていません。自分の魚なら、記録の釣行で釣果の行をタップして「釣った人」を自分に直すと入ります")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if mode == .all {
                FishDatabaseSection(catalog: catalog, caughtIDs: Set(caughtByID.keys), caughtCount: caughtByID, query: $query)
            } else if !query.isEmpty {
                // 釣った魚の検索：名前・別名で
                let hits = entries.filter { e in
                    let q = FishSearch.normalize(query)
                    return FishSearch.normalize(e.species).contains(q) || (catalog.entry(forSpecies: e.species)?.searchText.contains(q) ?? false)
                }
                if hits.isEmpty {
                    Spacer(); Text("釣った魚には見つかりません。「全国の魚」で探せます").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary); Spacer()
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Spacing.m) {
                            ForEach(Guide.sorted(hits, by: sort), id: \.species) { e in
                                GuideTile(entry: e, thumbnail: services.store.thumbnail(catchID: e.bestCatchID)).onTapGesture { selected = e }
                            }
                        }
                        .padding(.bottom, DS.Spacing.l)
                    }
                }
            } else if entries.isEmpty {
                Spacer()
                Button { captureTab?() } label: {
                    Image(systemName: "camera.fill").font(.system(size: 44, weight: .semibold)).foregroundStyle(DS.Color.textTertiary)
                }
                .buttonStyle(.plain)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Spacing.m) {
                        ForEach(Guide.sorted(entries, by: sort), id: \.species) { e in
                            GuideTile(entry: e, thumbnail: services.store.thumbnail(catchID: e.bestCatchID))
                                .onTapGesture { selected = e }
                        }
                    }
                    .padding(.bottom, DS.Spacing.l)
                }
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        // テーマのキャラクター（魔導書：右上、縦 3:4）。内容の後ろに置く
        .background(alignment: .topTrailing) {
            GeometryReader { g in
                ThemeCharacter(name: .charGuide, baseWidth: g.size.width * 0.5)
                    .frame(width: g.size.width, height: g.size.height, alignment: .topTrailing)
            }
        }
        .onAppear(perform: reload)
        .task {
            // 同梱の魚データ（約 200 種）は最初の 1 回だけ裏で読む
            guard catalog.entries.isEmpty else { return }
            let c = await Task.detached(priority: .userInitiated) { FishCatalog.bundled() }.value
            catalog = c
        }
        .onReceive(NotificationCenter.default.publisher(for: .fogStoreDidChange)) { _ in reload() }
        .sheet(item: $selected) { SpeciesDetailView(entry: $0).onDisappear(perform: reload) }
    }

    /// 上：魚種数と尾数のチップ、右に並び順。下：見出し「図鑑」（確定画像）＋ 釣った魚/全国の魚 の切替と検索（F-60）
    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                countChip(system: "fish.fill", value: entries.count, unit: "種")
                countChip(system: "heart.fill", value: entries.reduce(0) { $0 + $1.count }, unit: "尾")
                if !catalog.entries.isEmpty { countChip(system: "books.vertical.fill", value: catalog.entries.count, unit: "種を収録") }
                Spacer()
                if mode == .caught {
                    Menu {
                        Button("最大サイズ") { sort = .maxLength }
                        Button("最近") { sort = .recent }
                        Button("尾数") { sort = .count }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 17, weight: .semibold)).foregroundStyle(DS.Color.textSecondary).frame(width: 32, height: 32)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("図鑑").font(.system(size: 34, weight: .bold)).foregroundStyle(DS.Color.textPrimary)
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 190)
            }
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textTertiary)
                TextField(mode == .all ? "名前・場所・特性・時期（例: 北海道 根魚、産卵 春）" : "釣った魚を探す", text: $query)
                    .font(.system(size: 14)).foregroundStyle(DS.Color.textPrimary).submitLabel(.search).autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.Color.textTertiary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Spacing.m).padding(.vertical, 8)
            .background(DS.Color.panel, in: Capsule()).themeOutline(999)
        }
        .padding(.top, DS.Spacing.s)
    }

    private func countChip(system: String, value: Int, unit: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: system).font(.system(size: 11, weight: .semibold))
            Text("\(value)").font(DS.Font.number(13))
            Text(unit).font(DS.Font.caption)
        }
        .foregroundStyle(DS.Color.textSecondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(DS.Color.panel, in: Capsule()).themeOutline(999)
    }

    private func reload() {
        // 図鑑は自分が釣った魚だけ（他の人の魚を自分の端末で撮った分は入れない。F-54）
        let sessions = (try? services.store.ownSessions()) ?? []
        entries = Perf.measure("図鑑の集計") { Guide.entries(sessions: sessions) }
        // ほかの人の魚として記録されている分（図鑑に出ない理由が分かるように数を出す）
        let own = AnglerSettings.ownName
        var counts: [String: Int] = [:]
        for c in ((try? services.store.sessions()) ?? []).flatMap(\.catches) where !c.isOwn(ownName: own) { counts[c.angler ?? "ほかの人", default: 0] += 1 }
        othersNote = counts.isEmpty ? nil : counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value) 尾" }.joined(separator: "、")
    }
}

/// 環境経由で撮影タブへ切り替える（空の状態のカメラアイコン）。
struct CaptureTabKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues { var captureTab: (() -> Void)? { get { self[CaptureTabKey.self] } set { self[CaptureTabKey.self] = newValue } } }

/// タイル：写真（正方形）、魚種名、最大全長。直近 1 週間の記録更新は写真の角にオレンジの点（確定画像のカード型）。
struct GuideTile: View {
    let entry: GuideEntry
    let thumbnail: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // 正方形の枠を先に決め、写真はその中に敷いてはみ出しを切る。
                // 以前は写真に直接 aspectRatio(.fill) を掛けていて、横長・縦長の写真がカードの外まで広がっていた（2026-11-10 開発者の指摘）
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let thumbnail, let ui = UIImage(data: thumbnail) {
                            Image(uiImage: ui).resizable().scaledToFill()
                        } else {
                            ZStack {
                                DS.Color.surfaceRaised
                                Image(systemName: "fish.fill").font(.system(size: 28)).foregroundStyle(DS.Color.faded)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if entry.recentlyUpdated {
                    Circle().fill(DS.Color.accent).frame(width: 10, height: 10).padding(8)
                }
            }
            Text(entry.species).font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Color.textPrimary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(entry.maxLengthCm.map { "\(Int($0.rounded())) cm" } ?? "—").font(DS.Font.number(12)).foregroundStyle(DS.Color.textTertiary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).themeOutline(16)
    }
}

/// 魚種詳細：上半分にベストショット、下半分に数字と条件。写真長押しで魚種・サイズの修正（F-24）。
struct SpeciesDetailView: View {
    let entry: GuideEntry
    @Environment(AppServices.self) private var services
    @State private var catches: [Catch] = []
    @State private var spots: [UUID: Spot] = [:]
    @State private var editing: Catch?
    /// 写真をタップで全画面（ピンチで拡大。F-55）
    @State private var viewing: Catch?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: DS.Spacing.s) {
                // ベストショット（タップで全画面）。左下に魚種名と最大サイズ
                ZStack(alignment: .bottomLeading) {
                    if let data = services.store.thumbnail(catchID: entry.bestCatchID), let ui = UIImage(data: data) {
                        Image(uiImage: ui).resizable().scaledToFill()
                    } else { DS.Color.surface }
                    LinearGradient(colors: [.clear, DS.Color.background.opacity(0.9)], startPoint: .center, endPoint: .bottom)
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                        Text(entry.species).font(DS.Font.number(28)).foregroundStyle(DS.Color.textPrimary)
                        if let l = entry.maxLengthCm {
                            Text("最大 \(Int(l.rounded()))cm").font(DS.Font.number(16)).foregroundStyle(DS.Color.accent)
                            if Species.lookup(entry.species)?.isSquid == true { Text("胴長").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.Color.textSecondary)
                    }
                    .padding(DS.Spacing.l)
                }
                .frame(height: geo.size.height * 0.30).clipped()
                .contentShape(Rectangle())
                .onTapGesture { if let best = catches.first(where: { $0.id == entry.bestCatchID }) { viewing = best } }

                VStack(spacing: DS.Spacing.s) {
                    // 数字 4 つ（ラベルを上に）
                    HStack(spacing: DS.Spacing.s) {
                        stat("尾数", "\(entry.count)", unit: "尾")
                        stat("最大", entry.maxLengthCm.map { "\(Int($0.rounded()))" } ?? "—", unit: "cm")
                        stat("初めて", JPFormat.md(entry.firstCaughtAt))
                        stat("最後", JPFormat.md(entry.lastCaughtAt))
                    }
                    section("サイズの推移（白い点は自己記録）") { sizeTrend }
                    section("釣れやすい条件") {
                        HStack(alignment: .top, spacing: DS.Spacing.m) {
                            distribution("時間帯", entry.conditions.byLight)
                            distribution("潮", entry.conditions.byTide)
                            distribution("水温", Dictionary(uniqueKeysWithValues: entry.conditions.bySeaTemp.map { ("\($0.key)℃", $0.value) }))
                            distribution("月", Dictionary(uniqueKeysWithValues: entry.conditions.byMonth.map { ("\($0.key)月", $0.value) }))
                        }
                    }
                    section("釣れた場所") {
                        HStack(spacing: DS.Spacing.l) {
                            ForEach(entry.topSpots, id: \.spotID) { s in
                                HStack(spacing: DS.Spacing.xs) {
                                    Text(spots[s.spotID]?.name ?? "釣り場").font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                                    Text("\(s.count)尾").font(DS.Font.number(13)).foregroundStyle(DS.Color.textSecondary)
                                }
                            }
                            Spacer()
                        }
                    }
                    section("写真 · タップで拡大、長押しで修正（魚種・サイズ・リグ・釣った人）") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DS.Spacing.s) {
                                ForEach(catches, id: \.id) { c in
                                    VStack(spacing: 3) {
                                        ZStack(alignment: .bottomLeading) {
                                            if let data = services.store.thumbnail(catchID: c.id), let ui = UIImage(data: data) {
                                                Image(uiImage: ui).resizable().scaledToFill()
                                            } else { DS.Color.surface }
                                            Text(c.lengthCm.map { "\(Int($0.rounded()))cm" } ?? "未計測").font(DS.Font.number(11)).foregroundStyle(.white)
                                                .padding(.horizontal, 5).padding(.vertical, 2).background(Color.black.opacity(0.55), in: Capsule()).padding(4)
                                        }
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                                        Text(JPFormat.mdhm(c.at)).font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary)
                                    }
                                    .contentShape(Rectangle())
                                    // タップで拡大（F-55）、長押しで修正（F-24）
                                    .onTapGesture { viewing = c }
                                    .onLongPressGesture { editing = c }
                                }
                            }
                        }
                        .frame(height: 90)
                    }
                }
                .padding(.horizontal, DS.Spacing.l)
                Spacer(minLength: 0)
            }
        }
        .background(ThemeBackground(name: .bgDetail))
        .onAppear { Perf.mark("魚種詳細を開いた"); reload() }
        .onDisappear { Perf.mark("魚種詳細を閉じた") }
        .sheet(item: $editing) { c in CatchEditSheet(catchItem: c) { reload() }.presentationDetents([.large]) }
        .fullScreenCover(item: $viewing) { c in PhotoViewer(catchItem: c) }
    }

    /// 見出し付きの区画（枠線なし、面で区切る）
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(title).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            content()
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)).themeOutline(DS.Radius.chip)
    }

    /// 計測した釣果が全部同じ日か（軸の表記を時刻にする）
    private var sameDay: Bool {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = JPFormat.tz
        let days = Set(catches.compactMap { c in c.lengthCm == nil ? nil : cal.startOfDay(for: c.at) })
        return days.count <= 1
    }

    /// サイズの推移（F-41）：計測した釣果を時系列に。自己記録の更新は白い点
    private var sizeTrend: some View {
        let measured = catches.filter { $0.lengthCm != nil }.sorted { $0.at < $1.at }
        var best = 0.0
        let records: Set<UUID> = Set(measured.compactMap { c -> UUID? in
            guard let l = c.lengthCm else { return nil }
            if l > best { best = l; return c.id }
            return nil
        })
        return Group {
            if measured.count >= 2 {
                Chart(measured, id: \.id) { c in
                    LineMark(x: .value("日", c.at), y: .value("cm", c.lengthCm ?? 0)).foregroundStyle(DS.Color.accent.opacity(0.7))
                    PointMark(x: .value("日", c.at), y: .value("cm", c.lengthCm ?? 0))
                        .foregroundStyle(records.contains(c.id) ? Color.white : DS.Color.accent).symbolSize(records.contains(c.id) ? 40 : 20)
                }
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel().font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary) } }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { v in
                        // 同じ日の釣果なら時刻、またがるなら月/日（「Nov 8」が 5 つ並ぶのをやめる）
                        if let d = v.as(Date.self) {
                            AxisValueLabel { Text(sameDay ? JPFormat.hm(d) : JPFormat.md(d)).font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary) }
                        }
                    }
                }
                .frame(height: 64)
            } else {
                Text("サイズを 2 尾以上計測すると推移が出ます").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func reload() {
        let sessions = (try? services.store.ownSessions()) ?? []
        catches = sessions.flatMap(\.catches).filter { $0.species == entry.species }.sorted { $0.at > $1.at }
        spots = Dictionary(uniqueKeysWithValues: ((try? services.store.spots()) ?? []).map { ($0.id, $0) })
    }

    private func stat(_ label: String, _ value: String, unit: String = "") -> some View {
        VStack(spacing: 2) {
            Text(label).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(DS.Font.number(20)).foregroundStyle(DS.Color.textPrimary)
                if !unit.isEmpty { Text(unit).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.s)
        .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)).themeOutline(DS.Radius.chip)
    }

    /// 小さな分布バー（横並び）
    private func distribution(_ title: String, _ dict: [String: Int]) -> some View {
        let total = max(1, dict.values.reduce(0, +))
        let items = dict.sorted { $0.value > $1.value }.prefix(4)
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            ForEach(Array(items), id: \.key) { k, v in
                HStack(spacing: 4) {
                    Text(k).font(.system(size: 9)).foregroundStyle(DS.Color.textSecondary).frame(width: 36, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        Capsule().fill(DS.Color.accent.opacity(0.9)).frame(width: max(2, g.size.width * CGFloat(v) / CGFloat(total)), height: 4)
                    }
                    .frame(height: 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 魚種・サイズの修正。修正は判定モデルの補正に使う（F-24）。
struct CatchEditSheet: View {
    let catchItem: Catch
    let onDone: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var species: String = ""
    @State private var lengthText: String = ""
    @State private var deleting: Catch?
    @State private var angler: String = AnglerSettings.ownName
    @State private var tackle: TackleKind?
    @State private var rigID: UUID?
    @State private var rigs: [Rig] = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack {
                Text("修正").font(DS.Font.label).foregroundStyle(DS.Color.textTertiary)
                Spacer()
                Button(role: .destructive) { deleting = catchItem } label: {
                    Label("この釣果を削除", systemImage: "trash").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.s) {
                    ForEach(Species.initialCatalog) { s in
                        Button { species = s.name } label: {
                            Text(s.name).font(DS.Font.label)
                                .foregroundStyle(species == s.name ? DS.Color.background : DS.Color.textPrimary)
                                .padding(.horizontal, DS.Spacing.m).padding(.vertical, DS.Spacing.xs)
                                .background(species == s.name ? DS.Color.accent : DS.Color.surface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                TextField("全長 cm", text: $lengthText).keyboardType(.decimalPad)
                    .font(DS.Font.number(20)).foregroundStyle(DS.Color.textPrimary)
                    .padding(DS.Spacing.m).background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip)).themeOutline(DS.Radius.chip)
                Text("cm").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            }
            // タックルとリグ（シンカー・フック・ワーム）を後から設定する
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 11)).foregroundStyle(DS.Color.textTertiary)
                ForEach([TackleKind.spinning, .bait], id: \.self) { k in
                    Button { tackle = tackle == k ? nil : k } label: {
                        Text(k == .spinning ? "スピニング" : "ベイト").font(DS.Font.caption).foregroundStyle(tackle == k ? DS.Color.background : DS.Color.textPrimary)
                            .padding(.horizontal, DS.Spacing.m).padding(.vertical, DS.Spacing.xs)
                            .background(tackle == k ? DS.Color.accent : DS.Color.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.s) {
                    if rigs.isEmpty {
                        Text("リグは 設定 > タックル で登録（シンカー・フック・ワーム）").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                    }
                    ForEach(rigs) { r in
                        Button { rigID = rigID == r.id ? nil : r.id } label: {
                            Text(r.displayName).font(DS.Font.caption).foregroundStyle(rigID == r.id ? DS.Color.background : DS.Color.textPrimary)
                                .padding(.horizontal, DS.Spacing.m).padding(.vertical, DS.Spacing.xs)
                                .background(rigID == r.id ? DS.Color.accent : DS.Color.surface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // 釣った人（F-54）
            if AnglerSettings.candidates.count > 1 {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "person.fill").font(.system(size: 11)).foregroundStyle(DS.Color.textTertiary)
                    ForEach(AnglerSettings.candidates, id: \.self) { name in
                        Button { angler = name } label: {
                            Text(name).font(DS.Font.caption).foregroundStyle(angler == name ? DS.Color.background : DS.Color.textPrimary)
                                .padding(.horizontal, DS.Spacing.m).padding(.vertical, DS.Spacing.xs)
                                .background(angler == name ? DS.Color.accent : DS.Color.surface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                services.capture.setSpecies(catchID: catchItem.id, species: species, corrected: species != catchItem.species)
                if let l = Double(lengthText), l != catchItem.lengthCm { services.capture.setLength(catchID: catchItem.id, lengthCm: l) }
                if angler != AnglerSettings.displayName(for: catchItem.angler) { services.capture.setAngler(catchID: catchItem.id, angler: angler) }
                if tackle != catchItem.tackle || rigID != catchItem.rigID { services.capture.setRig(catchID: catchItem.id, tackle: tackle, rigID: rigID) }
                onDone(); dismiss()
            } label: {
                Text("保存").font(DS.Font.label).foregroundStyle(DS.Color.background)
                    .frame(maxWidth: .infinity).padding(DS.Spacing.m).background(DS.Color.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(DS.Spacing.l)
        .background(ThemeBackground(name: .bgDetail))
        .onAppear {
            species = catchItem.species; lengthText = catchItem.lengthCm.map { String(Int($0.rounded())) } ?? ""
            angler = AnglerSettings.displayName(for: catchItem.angler)
            tackle = catchItem.tackle; rigID = catchItem.rigID; rigs = (try? services.store.rigs()) ?? []
        }
        .catchDeleteDialog(item: $deleting) { _ in onDone(); dismiss() }
    }
}

/// 釣果の削除ダイアログ：記録だけ消すか、フォトライブラリの写真も消すか。
struct CatchDeleteDialog: ViewModifier {
    @Binding var item: Catch?
    let onDeleted: (Catch) -> Void
    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        content.confirmationDialog("この釣果を削除", isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }), titleVisibility: .visible) {
            Button("記録だけ削除", role: .destructive) { run(deletePhoto: false) }
            Button("写真ライブラリからも削除", role: .destructive) { run(deletePhoto: true) }
            Button("キャンセル", role: .cancel) { item = nil }
        } message: {
            Text("削除した釣果は分析からも外れます")
        }
    }

    private func run(deletePhoto: Bool) {
        guard let c = item else { return }
        item = nil
        Task { @MainActor in
            await services.capture.deleteCatch(id: c.id, deletePhoto: deletePhoto)
            onDeleted(c)
        }
    }
}

extension View {
    func catchDeleteDialog(item: Binding<Catch?>, onDeleted: @escaping (Catch) -> Void) -> some View {
        modifier(CatchDeleteDialog(item: item, onDeleted: onDeleted))
    }
}
