import Foundation

/// 図鑑に並べる、自分以外の人の 1 尾（F-66）。自分の端末で撮った仲間の魚か、仲間の端末から届いた魚
public struct GuideFriendCatch: Hashable, Sendable, Identifiable {
    /// 釣果の ID（端末をまたいで同じ）
    public var id: UUID
    public var species: String
    /// 釣った人の表示名
    public var angler: String
    public var lengthCm: Double?
    public var at: Date
    /// この端末で撮った釣果か（写真と修正はこの端末の記録から）。false は仲間の端末の釣果
    public var isLocal: Bool

    public init(id: UUID, species: String, angler: String, lengthCm: Double?, at: Date, isLocal: Bool) {
        self.id = id; self.species = species; self.angler = angler; self.lengthCm = lengthCm; self.at = at; self.isLocal = isLocal
    }
}

/// 図鑑の魚種ごとの「釣った人」（F-66）
public struct GuideAngler: Hashable, Sendable, Identifiable {
    public var name: String
    public var isOwn: Bool
    public var count: Int
    public var maxLengthCm: Double?
    public var lastCaughtAt: Date
    public var id: String { name }

    public init(name: String, isOwn: Bool, count: Int, maxLengthCm: Double?, lastCaughtAt: Date) {
        self.name = name; self.isOwn = isOwn; self.count = count; self.maxLengthCm = maxLengthCm; self.lastCaughtAt = lastCaughtAt
    }
}

/// 図鑑（§5「図鑑の自動更新」）。釣った魚種で構成し、初釣果で自動追加される。
/// 尾数・最大・条件などの数字は自分の釣果だけ。仲間が釣った魚は `anglers` と `friendCatches` に分けて持つ（F-66）
public struct GuideEntry: Hashable, Sendable {
    public var species: String
    public var count: Int
    public var maxLengthCm: Double?
    public var firstCaughtAt: Date
    public var lastCaughtAt: Date
    /// ベストショット（最大サイズの釣果。サイズ未計測なら最新）
    public var bestCatchID: UUID
    public var photoLocalIdentifier: String?
    /// 釣れた釣り場（尾数順 上位 3）
    public var topSpots: [(spotID: UUID, count: Int)]
    /// 釣れやすい条件（分析から自動生成）
    public var conditions: Analytics.ConditionDistribution
    /// 直近 1 週間に記録更新（初釣果・自己記録）があった
    public var recentlyUpdated: Bool
    /// 釣った人ごとの尾数と最大（自分が先頭、あとは尾数の多い順）。`Guide.merged` が入れる。自分だけなら自分の 1 行
    public var anglers: [GuideAngler] = []
    /// 仲間の釣果（新しい順）。`Guide.merged` が入れる
    public var friendCatches: [GuideFriendCatch] = []

    /// 自分は釣っておらず、仲間だけが釣った魚種
    public var isFriendOnly: Bool { count == 0 }
    /// 自分以外の釣った人
    public var friends: [GuideAngler] { anglers.filter { !$0.isOwn } }
    /// 仲間のいちばん大きい 1 尾（未計測だけなら最新）
    public var friendBest: GuideFriendCatch? {
        friendCatches.filter { $0.lengthCm != nil }.max { ($0.lengthCm ?? 0) < ($1.lengthCm ?? 0) } ?? friendCatches.first
    }
    /// 一覧に出す最大サイズ：自分の記録。自分が釣っていない魚種だけ、仲間の記録
    public var shownMaxLengthCm: Double? { isFriendOnly ? friendCatches.compactMap(\.lengthCm).max() : maxLengthCm }
    public var totalCount: Int { count + friendCatches.count }
    public var latestAt: Date { max(lastCaughtAt, friendCatches.first?.at ?? lastCaughtAt) }

    public static func == (l: GuideEntry, r: GuideEntry) -> Bool {
        l.species == r.species && l.count == r.count && l.maxLengthCm == r.maxLengthCm && l.anglers == r.anglers && l.friendCatches == r.friendCatches
    }
    public func hash(into h: inout Hasher) { h.combine(species) }

    public enum Sort: String, CaseIterable, Sendable { case maxLength, recent, count }
}

public enum Guide {
    public static func entries(sessions: [Session], now: Date = .now, timeZone: TimeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current) -> [GuideEntry] {
        let stats = Analytics.speciesStats(sessions: sessions, timeZone: timeZone)
        let allCatches = sessions.flatMap(\.catches)
        return stats.compactMap { s -> GuideEntry? in
            let items = allCatches.filter { $0.species == s.species }.sorted { $0.at < $1.at }
            guard let first = items.first, let last = items.last else { return nil }
            let best = items.filter { $0.lengthCm != nil }.max { ($0.lengthCm ?? 0) < ($1.lengthCm ?? 0) } ?? last
            let weekAgo = now.addingTimeInterval(-7 * 86_400)
            let recently = first.at >= weekAgo || (s.maxLengthHistory.last.map { $0.0 >= weekAgo } ?? false)
            return GuideEntry(
                species: s.species, count: s.count, maxLengthCm: s.maxLengthCm,
                firstCaughtAt: first.at, lastCaughtAt: last.at,
                bestCatchID: best.id, photoLocalIdentifier: best.photoLocalIdentifier ?? items.reversed().compactMap(\.photoLocalIdentifier).first,
                topSpots: s.topSpots.map { (spotID: $0.0, count: $0.1) },
                conditions: s.conditions,
                recentlyUpdated: recently
            )
        }
    }

    /// 自分の図鑑に、仲間が釣った魚を足す（F-66）。
    /// - 同じ魚種は 1 つにまとめ、釣った人ごとの尾数と最大を `anglers` に入れる（自分が先頭）
    /// - 自分が釣っていない魚種は、仲間の釣果だけの項目（`count == 0`）として足す
    /// - 魚種名の無い釣果は入れない。同じ ID の釣果は 1 つに数える（この端末の分を優先）
    /// - 釣った人の名前が自分の名前と同じ釣果（仲間が自分の魚を撮った分）は、自分の行に数える
    public static func merged(own: [GuideEntry], friends: [GuideFriendCatch], ownName: String, now: Date = .now) -> [GuideEntry] {
        var seen = Set<UUID>()
        var bySpecies: [String: [GuideFriendCatch]] = [:]
        for c in friends.sorted(by: { ($0.isLocal ? 0 : 1, $1.at) < ($1.isLocal ? 0 : 1, $0.at) }) {
            let species = c.species.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !species.isEmpty, !c.angler.isEmpty, seen.insert(c.id).inserted else { continue }
            bySpecies[species, default: []].append(c)
        }
        func anglers(ownCount: Int, ownMax: Double?, ownLast: Date?, items: [GuideFriendCatch]) -> [GuideAngler] {
            var mine: GuideAngler? = ownCount > 0 ? GuideAngler(name: ownName, isOwn: true, count: ownCount, maxLengthCm: ownMax, lastCaughtAt: ownLast ?? .distantPast) : nil
            var others: [String: GuideAngler] = [:]
            for c in items {
                if c.angler == ownName {
                    var a = mine ?? GuideAngler(name: ownName, isOwn: true, count: 0, maxLengthCm: nil, lastCaughtAt: c.at)
                    a.count += 1
                    a.maxLengthCm = [a.maxLengthCm, c.lengthCm].compactMap { $0 }.max()
                    a.lastCaughtAt = max(a.lastCaughtAt, c.at)
                    mine = a
                } else {
                    var a = others[c.angler] ?? GuideAngler(name: c.angler, isOwn: false, count: 0, maxLengthCm: nil, lastCaughtAt: c.at)
                    a.count += 1
                    a.maxLengthCm = [a.maxLengthCm, c.lengthCm].compactMap { $0 }.max()
                    a.lastCaughtAt = max(a.lastCaughtAt, c.at)
                    others[c.angler] = a
                }
            }
            let rest = others.values.sorted { ($0.count, $0.lastCaughtAt, $1.name) > ($1.count, $1.lastCaughtAt, $0.name) }
            return (mine.map { [$0] } ?? []) + rest
        }
        var out: [GuideEntry] = own.map { e in
            var e = e
            let items = (bySpecies.removeValue(forKey: e.species) ?? []).sorted { $0.at > $1.at }
            e.friendCatches = items
            e.anglers = anglers(ownCount: e.count, ownMax: e.maxLengthCm, ownLast: e.lastCaughtAt, items: items)
            return e
        }
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        for (species, list) in bySpecies {
            let items = list.sorted { $0.at > $1.at }
            guard let newest = items.first, let oldest = items.last else { continue }
            let best = items.filter { $0.lengthCm != nil }.max { ($0.lengthCm ?? 0) < ($1.lengthCm ?? 0) } ?? newest
            var e = GuideEntry(
                species: species, count: 0, maxLengthCm: nil, firstCaughtAt: oldest.at, lastCaughtAt: newest.at,
                bestCatchID: best.id, photoLocalIdentifier: nil, topSpots: [], conditions: Analytics.ConditionDistribution(),
                recentlyUpdated: oldest.at >= weekAgo
            )
            e.friendCatches = items
            e.anglers = anglers(ownCount: 0, ownMax: nil, ownLast: nil, items: items)
            out.append(e)
        }
        return out
    }

    /// 並べ替え。自分の記録が無い魚種（仲間だけ）は仲間の記録で並べる。同じ値なら名前の順（表示が毎回同じ順になるように）
    public static func sorted(_ entries: [GuideEntry], by sort: GuideEntry.Sort) -> [GuideEntry] {
        switch sort {
        case .maxLength: return entries.sorted { ($0.shownMaxLengthCm ?? -1, $1.species) > ($1.shownMaxLengthCm ?? -1, $0.species) }
        case .recent: return entries.sorted { ($0.latestAt, $1.species) > ($1.latestAt, $0.species) }
        case .count: return entries.sorted { ($0.totalCount, $1.species) > ($1.totalCount, $0.species) }
        }
    }
}
