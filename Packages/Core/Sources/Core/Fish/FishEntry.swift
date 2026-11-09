import Foundation

/// 全国の釣り魚データベースの 1 種（F-60）。`scripts/fetch_fish_db.py` が Wikidata / Wikipedia / Wikimedia Commons / FishBase から作る `fish.json` の 1 要素
public struct FishEntry: Codable, Identifiable, Hashable, Sendable {
    public struct Source: Codable, Hashable, Sendable {
        public var name: String
        public var url: String?
        public init(name: String, url: String? = nil) { self.name = name; self.url = url }
    }
    public struct ImageCredit: Codable, Hashable, Sendable {
        public var file: String?
        public var license: String?
        public var artist: String?
        public var url: String?
        public var licenseURL: String?
        public init(file: String? = nil, license: String? = nil, artist: String? = nil, url: String? = nil, licenseURL: String? = nil) {
            self.file = file; self.license = license; self.artist = artist; self.url = url; self.licenseURL = licenseURL
        }
    }

    public var id: String
    /// 標準和名
    public var name: String
    /// 地方名・別名
    public var aliases: [String]
    /// 釣りの分類（根魚・青物・カレイ・淡水・北の魚 …）
    public var groups: [String]
    public var scientificName: String?
    public var englishName: String?
    /// 和名のローマ字（FishBase。和名が無い種の手がかり）
    public var nameRomaji: String?
    /// 和名が出典に無く、FishBase のローマ字から推定したカタカナ
    public var nameEstimated: Bool?
    /// 科（日本語）
    public var family: String?
    /// 科・目（学名）
    public var familySci: String?
    public var order: String?
    /// native / introduced / endemic（FishBase の日本での位置づけ）
    public var status: String?
    /// 画像ファイル名（App/Resources/Fish/）
    public var image: String?
    public var imageCredit: ImageCredit?
    // Wikipedia 日本語版（CC BY-SA）
    public var summary: String?
    public var morphology: String?
    public var ecology: String?
    public var distributionJa: String?
    public var usage: String?
    public var spawning: String?
    public var spawningMonths: [Int]?
    public var seasonNote: String?
    public var seasonMonths: [Int]?
    // FishBase（CC BY-NC）
    public var maxLengthCm: Double?
    public var lengthType: String?
    public var commonLengthCm: Double?
    public var maxWeightKg: Double?
    public var environment: String?
    public var waters: [String]?
    public var habitatType: String?
    public var depthMinM: Int?
    public var depthMaxM: Int?
    public var climate: String?
    public var tempMinC: Double?
    public var tempMaxC: Double?
    public var distribution: String?
    public var description: String?
    public var biology: String?
    public var reproduction: String?
    public var sources: [Source]
    /// 出典で見つからなかった（名前だけ）
    public var missing: Bool?

    public init(id: String, name: String, aliases: [String] = [], groups: [String] = [], scientificName: String? = nil, family: String? = nil, image: String? = nil,
                summary: String? = nil, maxLengthCm: Double? = nil, seasonMonths: [Int]? = nil, spawningMonths: [Int]? = nil, waters: [String]? = nil,
                distributionJa: String? = nil, ecology: String? = nil, sources: [Source] = []) {
        self.id = id; self.name = name; self.aliases = aliases; self.groups = groups; self.scientificName = scientificName; self.family = family; self.image = image
        self.summary = summary; self.maxLengthCm = maxLengthCm; self.seasonMonths = seasonMonths; self.spawningMonths = spawningMonths; self.waters = waters
        self.distributionJa = distributionJa; self.ecology = ecology; self.sources = sources
    }

    enum CodingKeys: String, CodingKey {
        case id, name, aliases, groups, scientificName, englishName, nameRomaji, nameEstimated, family, familySci, order, status, image, imageCredit
        case summary, morphology, ecology, distributionJa, usage, spawning, spawningMonths, seasonNote, seasonMonths
        case maxLengthCm, lengthType, commonLengthCm, maxWeightKg, environment, waters, habitatType, depthMinM, depthMaxM, climate, tempMinC, tempMaxC
        case distribution, description, biology, reproduction, sources, missing
    }

    /// 無いキーは空として読む（出典や別名が無い種は JSON にキーが無い。1 件でも読めないと全体が空になるため）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        scientificName = try c.decodeIfPresent(String.self, forKey: .scientificName)
        englishName = try c.decodeIfPresent(String.self, forKey: .englishName)
        nameRomaji = try c.decodeIfPresent(String.self, forKey: .nameRomaji)
        nameEstimated = try c.decodeIfPresent(Bool.self, forKey: .nameEstimated)
        family = try c.decodeIfPresent(String.self, forKey: .family)
        familySci = try c.decodeIfPresent(String.self, forKey: .familySci)
        order = try c.decodeIfPresent(String.self, forKey: .order)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        imageCredit = try? c.decodeIfPresent(ImageCredit.self, forKey: .imageCredit)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        morphology = try c.decodeIfPresent(String.self, forKey: .morphology)
        ecology = try c.decodeIfPresent(String.self, forKey: .ecology)
        distributionJa = try c.decodeIfPresent(String.self, forKey: .distributionJa)
        usage = try c.decodeIfPresent(String.self, forKey: .usage)
        spawning = try c.decodeIfPresent(String.self, forKey: .spawning)
        spawningMonths = try c.decodeIfPresent([Int].self, forKey: .spawningMonths)
        seasonNote = try c.decodeIfPresent(String.self, forKey: .seasonNote)
        seasonMonths = try c.decodeIfPresent([Int].self, forKey: .seasonMonths)
        maxLengthCm = try c.decodeIfPresent(Double.self, forKey: .maxLengthCm)
        lengthType = try c.decodeIfPresent(String.self, forKey: .lengthType)
        commonLengthCm = try c.decodeIfPresent(Double.self, forKey: .commonLengthCm)
        maxWeightKg = try c.decodeIfPresent(Double.self, forKey: .maxWeightKg)
        environment = try c.decodeIfPresent(String.self, forKey: .environment)
        waters = try c.decodeIfPresent([String].self, forKey: .waters)
        habitatType = try c.decodeIfPresent(String.self, forKey: .habitatType)
        depthMinM = try? c.decodeIfPresent(Double.self, forKey: .depthMinM).map { Int($0) }
        depthMaxM = try? c.decodeIfPresent(Double.self, forKey: .depthMaxM).map { Int($0) }
        climate = try c.decodeIfPresent(String.self, forKey: .climate)
        tempMinC = try c.decodeIfPresent(Double.self, forKey: .tempMinC)
        tempMaxC = try c.decodeIfPresent(Double.self, forKey: .tempMaxC)
        distribution = try c.decodeIfPresent(String.self, forKey: .distribution)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        biology = try c.decodeIfPresent(String.self, forKey: .biology)
        reproduction = try c.decodeIfPresent(String.self, forKey: .reproduction)
        sources = (try? c.decodeIfPresent([Source].self, forKey: .sources)) ?? []
        missing = try c.decodeIfPresent(Bool.self, forKey: .missing)
    }

    /// 海・淡水・汽水の日本語
    public var watersJa: [String] {
        (waters ?? []).compactMap { w in
            switch w.lowercased() {
            case "marine": return "海水"
            case "freshwater": return "淡水"
            case "brackish": return "汽水"
            default: return nil
            }
        }
    }

    /// 生息層の日本語
    public var habitatTypeJa: String? {
        switch (habitatType ?? "").lowercased() {
        case "demersal": return "底生"
        case "benthopelagic": return "底層〜中層"
        case "pelagic", "pelagic-neritic": return "表層・中層（回遊）"
        case "pelagic-oceanic": return "外洋の表層"
        case "reef-associated": return "岩礁・サンゴ礁"
        case "bathydemersal": return "深海の底生"
        case "bathypelagic": return "深海の中層"
        case "": return nil
        default: return habitatType
        }
    }

    /// 気候帯の日本語
    public var climateJa: String? {
        switch (climate ?? "").lowercased() {
        case "tropical": return "熱帯"
        case "subtropical": return "亜熱帯"
        case "temperate": return "温帯"
        case "boreal": return "亜寒帯"
        case "polar": return "寒帯"
        case "deep-water": return "深海"
        case "": return nil
        default: return climate
        }
    }

    /// 和名があるか（無い種は学名で表示）
    public var hasJapaneseName: Bool { !name.isEmpty && name != scientificName }

    /// 釣果の魚種名（`Catch.species`）がこの種か（標準和名・別名で一致）
    public func matches(speciesName: String) -> Bool {
        let n = FishSearch.normalize(speciesName)
        if FishSearch.normalize(name) == n { return true }
        return aliases.contains { FishSearch.normalize($0) == n }
    }

    /// 検索の対象になる文字（正規化済み）。名前・学名・科・分類・分布・生態・形態・利用
    public var searchText: String {
        let parts: [String?] = [name, aliases.joined(separator: " "), groups.joined(separator: " "), scientificName, englishName, nameRomaji, family, familySci, order,
                                summary, morphology, ecology, distributionJa, usage, spawning, seasonNote, watersJa.joined(separator: " "), habitatTypeJa, climateJa,
                                status == "introduced" ? "外来 移入" : (status == "endemic" ? "固有種" : nil)]
        return FishSearch.normalize(parts.compactMap { $0 }.joined(separator: "\n"))
    }
}

/// 図鑑の検索（名前・場所・特性・時期）。ひらがな／カタカナ・全角／半角・大小の違いを吸収する
public enum FishSearch {
    public static func normalize(_ s: String) -> String {
        // 半角カナ → 全角カナ（ASCII も全角になる）→ 全角 ASCII だけ半角に戻す → ひらがな → カタカナ → 小文字
        // （`fullwidthToHalfwidth` を順方向にかけるとカタカナまで半角になり、ひらがな由来のカタカナと食い違う）
        var out = s.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? s
        out = String(String.UnicodeScalarView(out.unicodeScalars.map { sc -> Unicode.Scalar in
            if (0xFF01...0xFF5E).contains(sc.value), let h = Unicode.Scalar(sc.value - 0xFEE0) { return h }
            if sc.value == 0x3000 { return " " }
            return sc
        }))
        out = out.applyingTransform(.hiraganaToKatakana, reverse: false) ?? out
        return out.lowercased()
    }

    /// 語を空白で分け、全部の語が含まれるものだけ残す
    public static func filter(_ entries: [FishEntry], query: String) -> [FishEntry] {
        let tokens = normalize(query).split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return entries }
        return entries.filter { e in
            let text = e.searchText
            return tokens.allSatisfy { text.contains($0) }
        }
    }

    /// 名前の一致を先に、次に別名、その後は元の順
    public static func ranked(_ entries: [FishEntry], query: String) -> [FishEntry] {
        let q = normalize(query).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        func rank(_ e: FishEntry) -> Int {
            let n = normalize(e.name)
            if n == q { return 0 }
            if n.hasPrefix(q) { return 1 }
            if e.aliases.contains(where: { normalize($0).hasPrefix(q) }) { return 2 }
            if n.contains(q) { return 3 }
            return 4
        }
        return filter(entries, query: q).enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
}

/// 同梱の fish.json
public struct FishCatalog: Codable, Sendable {
    public var generatedAt: String?
    public var entries: [FishEntry] { didSet { index = entries.map(\.searchText) } }
    /// 検索用の正規化済み文字（entries と同じ順。数千種を毎回正規化しないための作り置き）
    private var index: [String] = []

    enum CodingKeys: String, CodingKey { case generatedAt, entries }

    public init(generatedAt: String? = nil, entries: [FishEntry]) { self.generatedAt = generatedAt; self.entries = entries; index = entries.map(\.searchText) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt)
        entries = try c.decodeIfPresent([FishEntry].self, forKey: .entries) ?? []
        index = entries.map(\.searchText)
    }

    /// 和名のある種の数
    public var namedCount: Int { entries.filter(\.hasJapaneseName).count }

    /// 科（日本語があればそれ、無ければ学名）の一覧（出現数順）
    public var families: [String] {
        var counts: [String: Int] = [:]
        for e in entries { if let f = e.family ?? e.familySci { counts[f, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    public static func bundled() -> FishCatalog { bundledCache }
    private static let bundledCache: FishCatalog = {
        guard let url = Bundle.module.url(forResource: "fish", withExtension: "json", subdirectory: "Data"),
              let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(FishCatalog.self, from: data) else { return FishCatalog(entries: []) }
        return c
    }()

    public func entry(id: String) -> FishEntry? { entries.first { $0.id == id } }

    /// 釣果の魚種名に対応する種
    public func entry(forSpecies name: String) -> FishEntry? {
        entries.first { $0.name == name } ?? entries.first { $0.matches(speciesName: name) }
    }

    /// 釣りの分類（出現数の多い順）
    public var groups: [String] {
        var counts: [String: Int] = [:]
        for e in entries { for g in e.groups { counts[g, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// 絞り込み：分類・科・月（旬か産卵期）・水域・和名のある種だけ・自分が釣った種だけ。検索語は作り置きの索引で引く
    public func filtered(query: String = "", group: String? = nil, family: String? = nil, month: Int? = nil, waters: String? = nil,
                         namedOnly: Bool = false, caughtOnly: Set<String>? = nil) -> [FishEntry] {
        let tokens = FishSearch.normalize(query).split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init).filter { !$0.isEmpty }
        var out: [FishEntry] = []
        out.reserveCapacity(64)
        for (i, e) in entries.enumerated() {
            if let group, !e.groups.contains(group) { continue }
            if let family, (e.family ?? e.familySci) != family { continue }
            if let month, !((e.seasonMonths ?? []).contains(month) || (e.spawningMonths ?? []).contains(month)) { continue }
            if let waters, !e.watersJa.contains(waters) { continue }
            if namedOnly, !e.hasJapaneseName { continue }
            if let caughtOnly, !caughtOnly.contains(e.id) { continue }
            if !tokens.isEmpty {
                let text = i < index.count ? index[i] : e.searchText
                if !tokens.allSatisfy({ text.contains($0) }) { continue }
            }
            out.append(e)
        }
        guard !tokens.isEmpty else { return out }
        // 名前の一致を先に
        let q = tokens.joined(separator: " ")
        func rank(_ e: FishEntry) -> Int {
            let n = FishSearch.normalize(e.name)
            if n == q { return 0 }
            if n.hasPrefix(q) { return 1 }
            if e.aliases.contains(where: { FishSearch.normalize($0).hasPrefix(q) }) { return 2 }
            if n.contains(q) { return 3 }
            return 4
        }
        return out.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
}
