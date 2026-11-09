import SwiftUI
import Core

// MARK: 全国の釣り魚データベース（F-60）

/// 同梱の魚の画像（App/Resources/Fish/<id>.jpg）。グリッド用の縮小はメインスレッドの外で
enum FishImages {
    private static let cache = NSCache<NSString, UIImage>()

    static func url(_ file: String) -> URL? {
        let name = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fish") ?? Bundle.main.url(forResource: name, withExtension: ext)
    }

    /// 長辺 `maxPixel` に縮めた画像（キャッシュ）
    static func thumbnail(_ file: String, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(file)@\(Int(maxPixel))" as NSString
        if let c = cache.object(forKey: key) { return c }
        guard let url = url(file) else { return nil }
        let img = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let full = UIImage(contentsOfFile: url.path) else { return nil }
            let scale = min(1, maxPixel / max(full.size.width, full.size.height))
            let size = CGSize(width: full.size.width * scale, height: full.size.height * scale)
            return full.preparingThumbnail(of: size) ?? full
        }.value
        if let img { cache.setObject(img, forKey: key) }
        return img
    }
}

struct FishImageView: View {
    let file: String?
    var maxPixel: CGFloat = 400
    @State private var image: UIImage?

    var body: some View {
        // 画像の固有サイズを外に伝えない（Color.clear を土台にして overlay で描き、はみ出しは切る）。
        // 2026-11-09：scaledToFill の画像が枠を越えて一覧と詳細の幅を押し広げていた
        Color.clear
            .background(DS.Color.surfaceRaised)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "fish").font(.system(size: 26)).foregroundStyle(DS.Color.faded)
                }
            }
            .clipped()
        .task(id: file) {
            guard let file else { image = nil; return }
            image = await FishImages.thumbnail(file, maxPixel: maxPixel)
        }
    }
}

/// 図鑑の「全国の魚」：検索（名前・場所・特性・時期）、絞り込み（分類・月・水域・釣った魚）、グリッド
struct FishDatabaseSection: View {
    let catalog: FishCatalog
    /// 自分が釣った種（釣果の魚種名 → 図鑑の id）
    let caughtIDs: Set<String>
    let caughtCount: [String: Int]
    @Binding var query: String
    @State private var group: String?
    @State private var family: String?
    @State private var namedOnly = true
    @State private var month: Int?
    @State private var waters: String?
    @State private var caughtOnly = false
    @State private var selected: FishEntry?
    /// 絞り込みの結果（裏で計算して差し替える。入力のたびに 4,000 種を本文で走査しないよう 150 ms 間引く）
    @State private var results: [FishEntry] = []
    @State private var searching = false
    @State private var shown = 240
    @State private var filterTask: Task<Void, Never>?

    private let columns = [GridItem(.flexible(), spacing: DS.Spacing.m), GridItem(.flexible(), spacing: DS.Spacing.m), GridItem(.flexible(), spacing: DS.Spacing.m)]

    /// 絞り込みの鍵（変わったら計算し直す）
    private var filterKey: String { [query, group ?? "", family ?? "", month.map(String.init) ?? "", waters ?? "", namedOnly ? "n" : "", caughtOnly ? "c" : "", String(catalog.entries.count)].joined(separator: "|") }

    private func scheduleFilter(debounce: Bool) {
        filterTask?.cancel()
        let cat = catalog, q = query, g = group, f = family, m = month, w = waters, n = namedOnly && query.isEmpty, c = caughtOnly ? caughtIDs : nil
        searching = true
        filterTask = Task {
            if debounce { try? await Task.sleep(nanoseconds: 150_000_000) }
            if Task.isCancelled { return }
            let out = await Task.detached(priority: .userInitiated) { cat.filtered(query: q, group: g, family: f, month: m, waters: w, namedOnly: n, caughtOnly: c) }.value
            if Task.isCancelled { return }
            results = out; shown = 240; searching = false
        }
    }

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            filters
            if catalog.entries.isEmpty {
                Spacer()
                Text("魚のデータがまだ入っていません").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                Spacer()
            } else {
                let list = results
                HStack {
                    Text("\(list.count) 種").font(DS.Font.number(12)).foregroundStyle(DS.Color.textTertiary)
                    if searching { ProgressView().scaleEffect(0.6).tint(DS.Color.textTertiary) }
                    if !query.isEmpty || group != nil || family != nil || month != nil || waters != nil || caughtOnly || !namedOnly {
                        Button("絞り込みを消す") { query = ""; group = nil; family = nil; month = nil; waters = nil; caughtOnly = false; namedOnly = true }
                            .font(DS.Font.caption).foregroundStyle(DS.Color.accent).buttonStyle(.plain)
                    }
                    Spacer()
                }
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Spacing.m) {
                        ForEach(list.prefix(shown)) { e in
                            FishCard(entry: e, caught: caughtCount[e.id])
                                .onTapGesture { selected = e }
                        }
                    }
                    // 一度に全部並べると差分計算が重いので 240 件ずつ
                    if list.count > shown {
                        Button { shown += 240 } label: {
                            Text("さらに表示（残り \(list.count - shown) 種）").font(DS.Font.caption).foregroundStyle(DS.Color.accent)
                                .padding(.vertical, DS.Spacing.m).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                    Color.clear.frame(height: DS.Spacing.l)
                }
            }
        }
        .onAppear { scheduleFilter(debounce: false) }
        .onChange(of: filterKey) { _, _ in scheduleFilter(debounce: !query.isEmpty) }
        .sheet(item: $selected) { e in FishDetailView(entry: e) }
    }

    /// 絞り込みのチップ（横スクロール）：釣った魚 / 今月 / 水域 / 分類
    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                chip("釣った魚", on: caughtOnly) { caughtOnly.toggle() }
                let now = Calendar(identifier: .gregorian).component(.month, from: Date())
                Menu {
                    Button("指定なし") { month = nil }
                    ForEach(1...12, id: \.self) { m in Button("\(m)月") { month = m } }
                } label: {
                    chipLabel(month.map { "\($0)月" } ?? "時期", on: month != nil, menu: true)
                }
                .onAppear { _ = now }
                ForEach(["海水", "淡水", "汽水"], id: \.self) { w in
                    chip(w, on: waters == w) { waters = (waters == w) ? nil : w }
                }
                Menu {
                    Button("指定なし") { family = nil }
                    ForEach(catalog.families.prefix(120), id: \.self) { f in Button(f) { family = f } }
                } label: {
                    chipLabel(family ?? "科", on: family != nil, menu: true)
                }
                chip("和名なしも", on: !namedOnly) { namedOnly.toggle() }
                ForEach(catalog.groups, id: \.self) { g in
                    chip(g, on: group == g) { group = (group == g) ? nil : g }
                }
            }
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, on: on) }.buttonStyle(.plain)
    }

    private func chipLabel(_ title: String, on: Bool, menu: Bool = false) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if menu { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
        }
        .foregroundStyle(on ? DS.Color.background : DS.Color.textPrimary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(on ? DS.Color.accent : DS.Color.panel, in: Capsule())
    }
}

/// 1 種のカード：画像・名前・最大サイズ。釣った種は角に尾数
struct FishCard: View {
    let entry: FishEntry
    let caught: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                FishImageView(file: entry.image, maxPixel: 360)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if let caught {
                    Text("\(caught)尾").font(DS.Font.number(10)).foregroundStyle(DS.Color.background)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(DS.Color.accent, in: Capsule()).padding(6)
                }
            }
            Text(entry.name).font(.system(size: entry.hasJapaneseName ? 14 : 11, weight: .medium)).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
            HStack(spacing: 4) {
                Text(entry.maxLengthCm.map { "〜\(Int($0.rounded())) cm" } ?? "—").font(DS.Font.number(11)).foregroundStyle(DS.Color.textTertiary)
                if let g = entry.groups.first ?? entry.family { Text(g).font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary).lineLimit(1) }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 1 種の詳細：画像、数字（最大・一般・水深・水温）、旬と産卵期の月、解説（形態・生態・分布・利用）、自分の釣果、出典
struct FishDetailView: View {
    let entry: FishEntry
    @Environment(AppServices.self) private var services
    @State private var own: [Catch] = []
    @State private var ownSpots: [String] = []
    @State private var showOwn = false
    @State private var ownEntry: GuideEntry?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                hero
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    names
                    adviceSection
                    placesSection
                    stats
                    sizeNote
                    months
                    if let t = entry.summary, !t.isEmpty { section("概要") { body(t) } }
                    if let t = entry.morphology, !t.isEmpty { section("形態・特徴") { body(t) } }
                    if let t = entry.ecology, !t.isEmpty { section("生態・習性") { body(t) } }
                    if entry.distributionJa?.isEmpty == false || entry.distribution?.isEmpty == false {
                        section("分布・釣れる場所") {
                            VStack(alignment: .leading, spacing: 4) {
                                if let t = entry.distributionJa, !t.isEmpty { body(t) }
                                if let t = entry.distribution, !t.isEmpty { Text(t).font(.system(size: 11)).foregroundStyle(DS.Color.textTertiary) }
                            }
                        }
                    }
                    if let t = entry.usage, !t.isEmpty { section("釣り・食") { body(t) } }
                    if let t = entry.biology, !t.isEmpty { section("FishBase の記述（英語）") { Text(t).font(.system(size: 11)).foregroundStyle(DS.Color.textSecondary) } }
                    ownSection
                    sourcesSection
                }
                .padding(.horizontal, DS.Spacing.l)
                .padding(.bottom, DS.Spacing.xl)
            }
        }
        .background(ThemeBackground(name: .bgDetail))
        .onAppear(perform: reload)
        .sheet(item: $ownEntry) { SpeciesDetailView(entry: $0) }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            FishImageView(file: entry.image, maxPixel: 1000).frame(maxWidth: .infinity).frame(height: 240).clipped()
            LinearGradient(colors: [.clear, DS.Color.background.opacity(0.9)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(DS.Font.number(28)).foregroundStyle(DS.Color.textPrimary)
                if let s = entry.scientificName { Text(s).font(.system(size: 12, weight: .regular, design: .serif)).italic().foregroundStyle(DS.Color.textSecondary) }
            }
            .padding(DS.Spacing.l)
            if let c = entry.imageCredit, let lic = c.license {
                VStack { HStack { Spacer(); Text("\(c.artist ?? "") \(lic)").font(.system(size: 8)).foregroundStyle(DS.Color.textTertiary).lineLimit(1).padding(6) }; Spacer() }
            }
        }
        .frame(height: 240)
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let f = entry.family ?? entry.familySci { tag(f) }
                if entry.status == "introduced" { tag("外来") } else if entry.status == "endemic" { tag("固有種") }
                if entry.nameEstimated == true { tag("和名は推定") }
                ForEach(entry.watersJa, id: \.self) { tag($0) }
                if let h = entry.habitatTypeJa { tag(h) }
                if let c = entry.climateJa { tag(c) }
            }
            if !entry.aliases.isEmpty {
                Text("別名: " + entry.aliases.joined(separator: "・")).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            }
            if let en = entry.englishName, let o = entry.order {
                Text("\(en) · \(o)").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            } else if let r = entry.nameRomaji, !entry.hasJapaneseName {
                Text("FishBase の和名: \(r)").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            }
            if !entry.groups.isEmpty {
                Text(entry.groups.joined(separator: " · ")).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            }
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, 7).padding(.vertical, 3).background(DS.Color.panel, in: Capsule())
    }

    private var advice: FishAdvice.Output {
        let m = Calendar(identifier: .gregorian).component(.month, from: Date())
        return FishAdvice.make(entry, month: m, ownCount: own.count, ownMaxCm: own.compactMap(\.lengthCm).max())
    }

    /// 釣るためのアドバイス（種のデータから組み立てる。2026-11-09 開発者「1 番上にあなたからのアドバイス」）
    private var adviceSection: some View {
        section("釣るためのアドバイス") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(advice.advice.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(DS.Color.accent).frame(width: 5, height: 5).padding(.top, 6)
                        Text(line).font(.system(size: 12)).foregroundStyle(DS.Color.textPrimary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("出典の数値と解説から機械的に組み立てた目安です").font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary)
            }
        }
    }

    @ViewBuilder private var placesSection: some View {
        let a = advice
        if !a.places.isEmpty || a.distribution != nil || !own.isEmpty {
            section("釣れる場所") {
                VStack(alignment: .leading, spacing: 6) {
                    if !a.places.isEmpty {
                        FlowTags(tags: a.places)
                    }
                    if let d = a.distribution { Text("分布: " + d).font(.system(size: 11)).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true) }
                    if !ownSpots.isEmpty {
                        Text("自分が釣った場所: " + ownSpots.joined(separator: "・")).font(.system(size: 11)).foregroundStyle(DS.Color.accent).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var stats: some View {
        HStack(spacing: DS.Spacing.s) {
            stat("最大", entry.maxLengthCm.map { "\(Int($0.rounded()))" } ?? "—", unit: "cm")
            stat("よくある", (entry.commonLengthCm ?? entry.typicalLengthCm).map { "\(Int($0.rounded()))" } ?? "—", unit: "cm")
            stat("水深", depthText, unit: "m")
            stat("水温", tempText, unit: "℃")
        }
    }

    /// 成熟サイズ・最大体重・出どころ
    @ViewBuilder private var sizeNote: some View {
        let parts: [String] = [
            entry.maturityLengthCm.map { "成熟（持ち帰りの目安）\(Int($0.rounded())) cm 以上" },
            entry.maxWeightKg.map { $0 >= 1 ? String(format: "最大体重 %.1f kg", $0) : "最大体重 \(Int(($0 * 1000).rounded())) g" },
            entry.lengthType.flatMap { $0 == "TL" ? nil : ($0 == "SL" ? "長さは標準体長" : ($0 == "FL" ? "長さは尾叉長" : ($0 == "ML" ? "長さは胴長" : nil))) },
            entry.lengthSource == "wikipedia" ? "サイズは Wikipedia の記述から" : nil,
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(DS.Color.textTertiary).fixedSize(horizontal: false, vertical: true)
        } else if entry.maxLengthCm == nil {
            Text("サイズの記録が出典にありません").font(.system(size: 10)).foregroundStyle(DS.Color.textTertiary)
        }
    }

    private var depthText: String {
        switch (entry.depthMinM, entry.depthMaxM) {
        case let (a?, b?): return "\(a)〜\(b)"
        case let (nil, b?): return "〜\(b)"
        default: return "—"
        }
    }

    private var tempText: String {
        switch (entry.tempMinC, entry.tempMaxC) {
        case let (a?, b?): return "\(Int(a.rounded()))〜\(Int(b.rounded()))"
        default: return "—"
        }
    }

    /// 旬と産卵期の 12 か月バー
    private var months: some View {
        let season = Set(entry.seasonMonths ?? []), spawn = Set(entry.spawningMonths ?? [])
        return section("時期（上：旬　下：産卵期）") {
            VStack(alignment: .leading, spacing: 6) {
                monthRow(season, color: DS.Color.accent, empty: "旬の記述なし")
                monthRow(spawn, color: DS.Color.sun, empty: "産卵期の記述なし")
                if let s = entry.spawning, !s.isEmpty { Text(s).font(.system(size: 11)).foregroundStyle(DS.Color.textSecondary) }
                if let s = entry.seasonNote, s.count > 2 { Text(s).font(.system(size: 11)).foregroundStyle(DS.Color.textSecondary) }
            }
        }
    }

    private func monthRow(_ set: Set<Int>, color: Color, empty: String) -> some View {
        HStack(spacing: 3) {
            ForEach(1...12, id: \.self) { m in
                Text("\(m)").font(DS.Font.number(10)).foregroundStyle(set.contains(m) ? DS.Color.background : DS.Color.textTertiary)
                    .frame(maxWidth: .infinity).frame(height: 18)
                    .background(set.contains(m) ? color : DS.Color.panel, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if set.isEmpty { Text(empty).font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary).fixedSize() }
        }
    }

    @ViewBuilder private var ownSection: some View {
        if !own.isEmpty {
            section("自分の釣果 \(own.count) 尾 · タップで詳細") {
                HStack(spacing: DS.Spacing.s) {
                    ForEach(own.prefix(4), id: \.id) { c in
                        ZStack(alignment: .bottomLeading) {
                            if let data = services.store.thumbnail(catchID: c.id), let ui = UIImage(data: data) {
                                Image(uiImage: ui).resizable().scaledToFill()
                            } else { DS.Color.surface }
                            Text(c.lengthCm.map { "\(Int($0.rounded()))cm" } ?? "").font(DS.Font.number(10)).foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1).background(Color.black.opacity(0.55), in: Capsule()).padding(3)
                        }
                        .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.Color.textTertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    let sessions = (try? services.store.ownSessions()) ?? []
                    if let species = own.first?.species, let g = Guide.entries(sessions: sessions).first(where: { $0.species == species }) { ownEntry = g }
                }
            }
        }
    }

    private var sourcesSection: some View {
        section("出典") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(entry.sources.enumerated()), id: \.offset) { _, s in
                    if let u = s.url.flatMap(URL.init(string:)) {
                        Link(destination: u) {
                            HStack(spacing: 4) {
                                Text(s.name).font(.system(size: 11)).foregroundStyle(DS.Color.textSecondary).multilineTextAlignment(.leading)
                                Image(systemName: "arrow.up.right.square").font(.system(size: 10)).foregroundStyle(DS.Color.textTertiary)
                            }
                        }
                    } else {
                        Text(s.name).font(.system(size: 11)).foregroundStyle(DS.Color.textSecondary)
                    }
                }
                if let c = entry.imageCredit, let lic = c.license {
                    Text("画像: \(c.artist ?? "不明") / \(lic)" + (c.file.map { " / \($0)" } ?? "")).font(.system(size: 10)).foregroundStyle(DS.Color.textTertiary)
                }
                Text("解説は Wikipedia 日本語版（CC BY-SA 4.0）の要約、数値は FishBase（CC BY-NC 3.0）。内容は出典の時点のもの。").font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary)
            }
        }
    }

    private func body(_ t: String) -> some View {
        Text(t).font(.system(size: 12)).foregroundStyle(DS.Color.textPrimary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(title).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            content()
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
    }

    private func stat(_ label: String, _ value: String, unit: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(DS.Font.number(16)).foregroundStyle(DS.Color.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
                Text(unit).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.s)
        .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
    }

    private func reload() {
        let sessions = (try? services.store.ownSessions()) ?? []
        own = sessions.flatMap(\.catches).filter { entry.matches(speciesName: $0.species) }.sorted { $0.at > $1.at }
        let spots = Dictionary(uniqueKeysWithValues: ((try? services.store.spots()) ?? []).map { ($0.id, $0.name) })
        var counts: [String: Int] = [:]
        for s in sessions where s.catches.contains(where: { entry.matches(speciesName: $0.species) }) {
            counts[spots[s.spotID] ?? "釣り場", default: 0] += s.catches.filter { entry.matches(speciesName: $0.species) }.count
        }
        ownSpots = counts.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \($0.value)尾" }
    }
}

/// 語のタグを折り返して並べる
struct FlowTags: View {
    let tags: [String]
    var body: some View {
        // 幅に合わせて折り返す簡易レイアウト（iOS 16+ の Layout）
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { t in
                Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.textPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(DS.Color.surfaceRaised, in: Capsule())
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
