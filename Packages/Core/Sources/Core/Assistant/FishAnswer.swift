import Foundation

/// 魚についての質問への事実（F-65）。同梱の魚データ（F-60）から、食べ方・旬・大きさ・注意を行にする。
/// 持ち帰りの決まり（サイズ・禁漁）はデータに無いので、無いと書く（作らない）
public enum FishAnswer {
    public static func facts(_ e: FishEntry, month: Int, ownCount: Int = 0, ownMaxCm: Double? = nil, lengthCm: Double? = nil) -> [String] {
        var lines: [String] = []
        let names = e.aliases.prefix(3).joined(separator: "・")
        lines.append(e.name + (names.isEmpty ? "" : "（別名 \(names)）") + (e.family.map { "。\($0)" } ?? ""))

        // 旬
        let season = e.seasonMonths ?? []
        if !season.isEmpty {
            lines.append("旬：" + season.map { "\($0)月" }.joined(separator: "・") + (season.contains(month) ? "（今月は旬）" : ""))
        } else if let note = e.seasonNote, !note.isEmpty {
            lines.append("旬：" + clip(note, 60))
        }
        // 食べ方
        if let usage = e.usage, !usage.isEmpty { lines.append("食べ方：" + clip(usage, 140)) }
        // 毒・とげなどの注意（本文に書いてあるときだけ）
        let all = [e.usage, e.ecology, e.summary, e.morphology].compactMap { $0 }.joined(separator: "。")
        for word in ["毒", "アニサキス", "寄生虫", "とげ", "棘"] {
            if let sentence = sentence(containing: word, in: all) { lines.append("注意：" + clip(sentence, 90)); break }
        }
        // 大きさとリリースの目安
        var size: [String] = []
        if let c = e.commonLengthCm ?? e.typicalLengthCm { size.append("よく釣れるのは \(Int(c.rounded())) cm 前後") }
        if let m = e.maxLengthCm { size.append("最大 \(Int(m.rounded())) cm") }
        if !size.isEmpty { lines.append("大きさ：" + size.joined(separator: "、")) }
        if let mature = e.maturityLengthCm {
            var text = "成熟する大きさは約 \(Int(mature.rounded())) cm。これより小さければリリースの目安"
            if let len = lengthCm { text += len < mature ? "（今回の \(Int(len.rounded())) cm はまだ小さい）" : "（今回の \(Int(len.rounded())) cm は成熟サイズ以上）" }
            lines.append(text)
        }
        if let spawn = e.spawningMonths, !spawn.isEmpty { lines.append("産卵期：" + spawn.map { "\($0)月" }.joined(separator: "・")) }
        // 釣り方（データから組み立てた助言の先頭 2 つ）
        let advice = FishAdvice.make(e, month: month, ownCount: ownCount, ownMaxCm: ownMaxCm).advice.prefix(2)
        if !advice.isEmpty { lines.append("釣り方：" + advice.joined()) }
        if ownCount > 0 { lines.append("自分の記録：\(ownCount) 尾" + (ownMaxCm.map { "、最大 \(Int($0.rounded())) cm" } ?? "")) }
        lines.append("持ち帰りの決まり（サイズ・禁漁期間・地域の規則）は、このアプリのデータにありません")
        return lines
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= limit ? t : String(t.prefix(limit)) + "…"
    }

    /// その言葉を含む 1 文
    static func sentence(containing word: String, in text: String) -> String? {
        text.split(separator: "。").map(String.init).first { $0.contains(word) }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// ネットの釣果情報の要約（F-65）。この 1 週間の記事から、魚種ごとの件数と場所を数える
public enum FeedDigest {
    public struct Output: Hashable, Sendable {
        public var lines: [String]
        public var articleCount: Int
        public var text: String { lines.joined(separator: "\n") }
    }

    /// `species` は「呼び名（別名も）→ 標準和名」。記事に魚種の手がかりが無ければ、題と要約から名前を探す
    public static func make(items: [FeedItem], species: [String: String], now: Date, days: Int = 7) -> Output {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let recent = items.filter { ($0.publishedAt ?? $0.fetchedAt) >= since }.sorted { ($0.publishedAt ?? $0.fetchedAt) > ($1.publishedAt ?? $1.fetchedAt) }
        guard !recent.isEmpty else { return Output(lines: ["この \(days) 日の釣果情報の記事がありません（設定 > 釣果情報 で取得元を確かめてください）"], articleCount: 0) }
        var counts: [String: Int] = [:], places: [String: [String]] = [:]
        let keys = species.keys.filter { $0.count >= 2 }.sorted { $0.count > $1.count }
        for item in recent {
            var found = Set(item.speciesHint ?? [])
            if found.isEmpty {
                let text = item.title + " " + (item.summary ?? "")
                for key in keys where text.contains(key) { if let name = species[key] { found.insert(name) } }
            }
            for name in found {
                counts[name, default: 0] += 1
                if let place = item.placeName, !place.isEmpty, !(places[name] ?? []).contains(place) { places[name, default: []].append(place) }
            }
        }
        var lines = ["この \(days) 日の釣果情報：\(recent.count) 件"]
        let top = counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(5)
        for (name, count) in top {
            let where_ = (places[name] ?? []).prefix(3).joined(separator: "・")
            lines.append("・\(name) \(count) 件" + (where_.isEmpty ? "" : "（\(where_)）"))
        }
        if top.isEmpty { lines.append("魚種の読み取れる記事がありませんでした") }
        lines.append("新しい記事：")
        for item in recent.prefix(3) { lines.append("・" + FishAnswer.clip(item.title, 44)) }
        return Output(lines: lines, articleCount: recent.count)
    }
}

/// 釣行のまとめ（F-65）。自分と仲間の釣果を、人ごとの尾数・魚種・最大にして、共有できる文にする
public enum TripSummary {
    public struct Item: Hashable, Sendable {
        public var angler: String
        public var species: String
        public var lengthCm: Double?
        public var at: Date
        public init(angler: String, species: String, lengthCm: Double?, at: Date) { self.angler = angler; self.species = species; self.lengthCm = lengthCm; self.at = at }
    }

    public static func make(spotName: String, startedAt: Date, endedAt: Date?, items: [Item], members: [String] = [], lost: Int = 0, tideName: String? = nil,
                            timeZone: TimeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        func hm(_ d: Date) -> String {
            let c = cal.dateComponents([.hour, .minute], from: d)
            return "\(c.hour ?? 0):" + String(format: "%02d", c.minute ?? 0)
        }
        let c = cal.dateComponents([.month, .day, .weekday], from: startedAt)
        var head = "\(c.month ?? 0)/\(c.day ?? 0)（\(["", "日", "月", "火", "水", "木", "金", "土"][c.weekday ?? 0])）\(spotName) \(hm(startedAt))"
        if let endedAt {
            let minutes = max(0, Int(endedAt.timeIntervalSince(startedAt) / 60))
            head += "〜\(hm(endedAt))（\(minutes >= 60 ? "\(minutes / 60) 時間 \(minutes % 60) 分" : "\(minutes) 分")）"
        } else { head += "〜（釣行中）" }
        var lines = [head]
        if let tideName, !tideName.isEmpty { lines.append("潮：\(tideName)") }
        lines.append(items.isEmpty ? "釣果：なし" : "合計 \(items.count) 尾")

        // 人ごと（釣った順ではなく尾数の多い順。釣れなかった同行者も 0 尾で出す）
        var names: [String] = []
        for i in items where !names.contains(i.angler) { names.append(i.angler) }
        for m in members where !names.contains(m) { names.append(m) }
        let byAngler = Dictionary(grouping: items, by: \.angler)
        for name in names.sorted(by: { (byAngler[$0]?.count ?? 0) > (byAngler[$1]?.count ?? 0) }) {
            let list = byAngler[name] ?? []
            guard !list.isEmpty else { lines.append("・\(name) 0 尾"); continue }
            let species = Dictionary(grouping: list, by: { $0.species.isEmpty ? "魚" : $0.species })
                .sorted { $0.value.count > $1.value.count || ($0.value.count == $1.value.count && $0.key < $1.key) }
                .map { "\($0.key) \($0.value.count)" }.joined(separator: "、")
            var line = "・\(name) \(list.count) 尾（\(species)）"
            if let best = list.filter({ $0.lengthCm != nil }).max(by: { ($0.lengthCm ?? 0) < ($1.lengthCm ?? 0) }), let len = best.lengthCm {
                line += " 最大 \(best.species.isEmpty ? "" : best.species + " ")\(Int(len.rounded())) cm"
            }
            lines.append(line)
        }
        if items.count >= 3 {
            var hours: [Int: Int] = [:]
            for i in items { hours[cal.component(.hour, from: i.at), default: 0] += 1 }
            if let top = hours.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) { lines.append("いちばん釣れた時間：\(top.key) 時台（\(top.value) 尾）") }
        }
        if lost > 0 { lines.append("ロスト \(lost) 回") }
        return lines.joined(separator: "\n")
    }
}
