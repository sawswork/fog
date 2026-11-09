import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// RSS 2.0 / Atom の記事（F-27）。
public struct FeedItem: Codable, Identifiable, Hashable, Sendable {
    /// link（無ければ guid/id、それも無ければ title）
    public var id: String
    public var feedURL: String
    public var feedTitle: String
    public var title: String
    public var link: String?
    public var summary: String?
    public var publishedAt: Date?
    public var fetchedAt: Date
    /// 配信側が付けた場所（fog:place / fog:lat / fog:lon。fog-feeds が出す）。無ければ nil
    public var placeName: String?
    public var coordinate: Coordinate?
    /// 配信側が付けた魚種（fog:species、「・」区切り）
    public var speciesHint: [String]?

    public init(id: String, feedURL: String, feedTitle: String, title: String, link: String?, summary: String?, publishedAt: Date?, fetchedAt: Date,
                placeName: String? = nil, coordinate: Coordinate? = nil, speciesHint: [String]? = nil) {
        self.id = id; self.feedURL = feedURL; self.feedTitle = feedTitle; self.title = title; self.link = link
        self.summary = summary; self.publishedAt = publishedAt; self.fetchedAt = fetchedAt
        self.placeName = placeName; self.coordinate = coordinate; self.speciesHint = speciesHint
    }
}

/// RSS 2.0 と Atom を同じ形に読む。通信はしない（App 側が取ったデータを渡す）。
public enum FeedParser {
    public struct Result: Sendable {
        public var title: String
        public var items: [FeedItem]
    }

    public static func parse(_ data: Data, feedURL: String, fetchedAt: Date = .now) -> Result? {
        let delegate = Delegate(feedURL: feedURL, fetchedAt: fetchedAt)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() || !delegate.items.isEmpty else { return nil }
        guard !delegate.items.isEmpty || !delegate.feedTitle.isEmpty else { return nil }
        let title = delegate.feedTitle.isEmpty ? feedURL : delegate.feedTitle
        let items = delegate.items.map { i -> FeedItem in var i = i; i.feedTitle = title; return i }
        return Result(title: title, items: items)
    }

    /// pubDate（RFC 822）と Atom（ISO 8601）の両方を読む
    static func date(from text: String) -> Date? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let d = FogJSON.parse(t) { return d }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd HH:mm:ss"] {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    /// HTML タグと実体参照を落として 1 行にする（要約の表示用）
    public static func plainText(_ html: String, limit: Int = 200) -> String {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] { s = s.replacingOccurrences(of: a, with: b) }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > limit ? String(s.prefix(limit)) + "…" : s
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let feedURL: String
        let fetchedAt: Date
        var feedTitle = ""
        var items: [FeedItem] = []
        private var path: [String] = []
        private var text = ""
        private var inItem = false
        private var cur: (title: String, link: String?, guid: String?, summary: String?, date: String?) = ("", nil, nil, nil, nil)
        private var fog: (place: String?, lat: Double?, lon: Double?, species: String?) = (nil, nil, nil, nil)

        init(feedURL: String, fetchedAt: Date) { self.feedURL = feedURL; self.fetchedAt = fetchedAt }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            path.append(local)
            text = ""
            if local == "item" || local == "entry" { inItem = true; cur = ("", nil, nil, nil, nil); fog = (nil, nil, nil, nil) }
            // Atom の link は属性
            if inItem, local == "link", let href = attributes["href"], attributes["rel"] == nil || attributes["rel"] == "alternate" { cur.link = href }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(data: CDATABlock, encoding: .utf8) ?? "" }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { path.removeLast(); text = "" }
            if inItem {
                switch local {
                case "title": cur.title = value
                case "link": if cur.link == nil, !value.isEmpty { cur.link = value }
                case "guid", "id": cur.guid = value
                case "description", "summary", "content", "encoded": if cur.summary == nil || (cur.summary ?? "").isEmpty { cur.summary = value }
                case "pubDate", "published", "updated", "date": if cur.date == nil { cur.date = value }
                // fog-feeds の拡張（fog:place / fog:lat / fog:lon / fog:species）
                case "place": fog.place = value
                case "lat": fog.lat = Double(value)
                case "lon": fog.lon = Double(value)
                case "species": fog.species = value
                case "item", "entry":
                    inItem = false
                    let id = cur.link ?? cur.guid ?? cur.title
                    guard !cur.title.isEmpty || cur.link != nil else { return }
                    let coordinate = (fog.lat != nil && fog.lon != nil) ? Coordinate(latitude: fog.lat!, longitude: fog.lon!) : nil
                    let species = fog.species.map { $0.split(separator: "・").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    items.append(FeedItem(id: id, feedURL: feedURL, feedTitle: "", title: cur.title.isEmpty ? (cur.link ?? "") : cur.title, link: cur.link,
                                          summary: cur.summary.map { FeedParser.plainText($0) }, publishedAt: cur.date.flatMap(FeedParser.date(from:)), fetchedAt: fetchedAt,
                                          placeName: fog.place, coordinate: coordinate?.isPlausible == true ? coordinate : nil, speciesHint: species))
                default: break
                }
            } else if local == "title", feedTitle.isEmpty, path.count <= 3 {
                feedTitle = value
            }
        }
    }
}

/// 記事と自分の釣り（魚種・釣り場）の関係（F-27 の「関連する情報を先に」）
public enum FeedRelevance {
    /// 記事に含まれるキーワード（魚種名・釣り場名）。多いほど関連が強い
    public static func matches(_ item: FeedItem, keywords: [String]) -> [String] {
        let text = item.title + " " + (item.summary ?? "")
        return keywords.filter { !$0.isEmpty && text.contains($0) }
    }

    /// 関連が強い順 → 新しい順
    public static func sorted(_ items: [FeedItem], keywords: [String]) -> [FeedItem] {
        items.sorted { a, b in
            let ma = matches(a, keywords: keywords).count, mb = matches(b, keywords: keywords).count
            if ma != mb { return ma > mb }
            return (a.publishedAt ?? a.fetchedAt) > (b.publishedAt ?? b.fetchedAt)
        }
    }
}
