import Foundation

/// RSS の記事から「どこで何が釣れたか」を取り出す（F-44）。見出しと要約だけを使い、通信はしない。
/// 場所は同梱の港名と登録釣り場の名前、魚種は図鑑の標準和名と別名を文中から探す。
public struct FeedCatch: Hashable, Sendable, Identifiable {
    public var id: String { itemID + "@" + placeName }
    public var itemID: String
    public var title: String
    public var link: String?
    public var publishedAt: Date?
    public var feedTitle: String
    public var placeName: String
    public var coordinate: Coordinate
    /// 文中に出た順。書かれた言葉のまま（アブラコ など）
    public var species: [String]

    /// RSS の記事か（false は自分の記録・仲間の釣果）
    public var isArticle: Bool { !(itemID.hasPrefix("own:") || itemID.hasPrefix("shared:")) }

    public init(itemID: String, title: String, link: String?, publishedAt: Date?, feedTitle: String, placeName: String, coordinate: Coordinate, species: [String]) {
        self.itemID = itemID; self.title = title; self.link = link; self.publishedAt = publishedAt; self.feedTitle = feedTitle
        self.placeName = placeName; self.coordinate = coordinate; self.species = species
    }
}

public enum FeedCatchExtractor {
    public struct Place: Hashable, Sendable {
        public var name: String
        public var coordinate: Coordinate
        public init(name: String, coordinate: Coordinate) { self.name = name; self.coordinate = coordinate }
    }

    /// 場所の候補を作る：登録釣り場（2 文字以上）＋港（3 文字以上）。同じ名前の港が複数あれば `near` に近いものだけ残す
    public static func places(spots: [(name: String, coordinate: Coordinate)], ports: [Port], near: Coordinate?) -> [Place] {
        var byName: [String: Place] = [:]
        for p in ports where p.name.count >= 3 {
            let cand = Place(name: p.name, coordinate: p.coordinate)
            if let existing = byName[p.name] {
                if let near, Geo.distanceMeters(cand.coordinate, near) < Geo.distanceMeters(existing.coordinate, near) { byName[p.name] = cand }
            } else { byName[p.name] = cand }
        }
        // 登録釣り場は港より優先（自分の呼び名で上書き）
        for s in spots where s.name.count >= 2 && s.name != "釣り場" && s.name != "位置不明" {
            byName[s.name] = Place(name: s.name, coordinate: s.coordinate)
        }
        // 港の中の施設（「函館港 北ふ頭」）は後ろの名前（「北ふ頭」）でも当てる。記事は施設名だけで書くことが多い（F-47）
        let generic: Set<String> = ["漁港", "ふ頭", "埠頭", "岸壁", "防波堤", "船だまり", "港"]
        for (name, place) in byName {
            let parts = name.split(separator: " ").map(String.init)
            guard parts.count >= 2, let last = parts.last, last.count >= 3, !generic.contains(last), byName[last] == nil else { continue }
            if let near, Geo.distanceMeters(place.coordinate, near) > 150_000 { continue }
            byName[last] = Place(name: last, coordinate: place.coordinate)
        }
        // 長い名前から当てる（「函館港」より「函館漁港」を先に）
        return byName.values.sorted { $0.name.count > $1.name.count }
    }

    /// 魚種の語：標準和名と別名。長い順
    public static func speciesWords(_ catalog: [Species]) -> [String] {
        Array(Set(catalog.flatMap { [$0.name] + $0.aliases })).filter { $0.count >= 2 }.sorted { $0.count > $1.count }
    }

    /// 1 記事から、文中に出た場所ごとに 1 件。配信側が座標を付けていれば（fog-feeds）それも使う。場所が無ければ空
    public static func extract(_ item: FeedItem, places: [Place], speciesWords: [String]) -> [FeedCatch] {
        let text = item.title + " " + (item.summary ?? "")
        guard !text.isEmpty else { return [] }
        // 場所：長い名前から。見つけた名前を含む短い名前は重複として除く（「函館漁港」があれば「函館港」は別物なので除かないが、「鹿部漁港」→「鹿部」のような包含だけ除く）
        var found: [Place] = []
        var consumed = text
        for p in places where consumed.contains(p.name) {
            found.append(p)
            consumed = consumed.replacingOccurrences(of: p.name, with: String(repeating: "　", count: p.name.count))
        }
        // 配信側の場所：文中の港名が無いときの置き場所（市町村名など、アプリの辞書に無い地名も置ける）
        if found.isEmpty, let name = item.placeName, let c = item.coordinate {
            found.append(Place(name: name, coordinate: c))
        }
        guard !found.isEmpty else { return [] }
        // 魚種：出た順。同じ語は 1 回
        var species: [(Int, String)] = []
        var remaining = text
        for w in speciesWords {
            if let r = remaining.range(of: w) {
                species.append((remaining.distance(from: remaining.startIndex, to: r.lowerBound), w))
                remaining = remaining.replacingOccurrences(of: w, with: String(repeating: "　", count: w.count))
            }
        }
        var names = species.sorted { $0.0 < $1.0 }.map(\.1)
        // 配信側の魚種を補う（文中から拾えなかったもの）
        for s in item.speciesHint ?? [] where !names.contains(s) { names.append(s) }
        return found.map { p in
            FeedCatch(itemID: item.id, title: item.title, link: item.link, publishedAt: item.publishedAt, feedTitle: item.feedTitle,
                      placeName: p.name, coordinate: p.coordinate, species: names)
        }
    }

    /// 釣果（仲間の端末の釣果など）の場所を、自分の登録釣り場に合わせる。
    /// 位置から `radiusM` 以内でいちばん近い登録釣り場があれば、その名前と位置。無ければ相手の付けた名前と釣果の位置。
    /// 相手の端末が同じ場所を別の名前（最寄りの港名など）で登録していても、自分の地図では自分の釣り場にまとまる
    public static func localPlace(for coordinate: Coordinate, fallbackName: String, spots: [(name: String, coordinate: Coordinate)],
                                  radiusM: Double = 300) -> Place {
        let fallback = Place(name: fallbackName.isEmpty ? "釣り場" : fallbackName, coordinate: coordinate)
        guard coordinate.isPlausible else { return fallback }
        var nearest: (name: String, coordinate: Coordinate, d: Double)?
        for s in spots where s.coordinate.isPlausible && !s.name.isEmpty {
            let d = Geo.distanceMeters(s.coordinate, coordinate)
            if d <= radiusM, d < (nearest?.d ?? .infinity) { nearest = (name: s.name, coordinate: s.coordinate, d: d) }
        }
        guard let hit = nearest else { return fallback }
        return Place(name: hit.name, coordinate: hit.coordinate)
    }

    /// 場所ごとにまとめたピン（新しい順の記事を持つ）
    public struct Pin: Hashable, Sendable, Identifiable {
        public var id: String { placeName }
        public var placeName: String
        public var coordinate: Coordinate
        public var entries: [FeedCatch]
        /// 直近の記事の日付
        public var latestAt: Date? { entries.compactMap(\.publishedAt).max() }
        /// 魚種の集計（多い順）
        public var speciesCounts: [(String, Int)] {
            var c: [String: Int] = [:]
            for e in entries { for s in Set(e.species) { c[s, default: 0] += 1 } }
            return c.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map { ($0.key, $0.value) }
        }
        public static func == (l: Pin, r: Pin) -> Bool { l.placeName == r.placeName && l.entries == r.entries }
        public func hash(into h: inout Hasher) { h.combine(placeName) }
    }

    public static func pins(_ catches: [FeedCatch]) -> [Pin] {
        var byPlace: [String: [FeedCatch]] = [:]
        for c in catches { byPlace[c.placeName, default: []].append(c) }
        return byPlace.map { name, list in
            Pin(placeName: name, coordinate: list[0].coordinate, entries: list.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) })
        }.sorted { ($0.latestAt ?? .distantPast) > ($1.latestAt ?? .distantPast) }
    }
}
