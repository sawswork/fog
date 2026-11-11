import Foundation

/// 自分の記録への質問（F-65）。質問の言葉から期間・釣り場・魚種を読み取り、当てはまる釣行だけを集計して「事実の行」を作る。
/// 数字はすべてここで計算する（言語モデルには、この行の中から選んで言い直させるだけ。作らせない）
public struct RecordFilter: Hashable, Sendable {
    public var from: Date?
    public var to: Date?
    /// 年をまたいだ「11 月」のような月だけの指定
    public var month: Int?
    public var spotID: UUID?
    public var species: String?
    /// いちばん新しい釣行だけ（「前回」）
    public var lastOnly = false
    /// 答えの頭に付ける言葉（「去年の 11 月・鹿部漁港」）
    public var label = ""

    public init() {}
}

public struct RecordFacts: Hashable, Sendable {
    public var headline: String
    public var lines: [String]
    public var catchCount: Int
    /// 言語モデルを使わないときの答え（見出し＋質問に近い行から 5 行）
    public var text: String { ([headline] + lines.prefix(5)).joined(separator: "\n") }
    /// 言語モデルに渡す事実（全部の行）
    public var context: String { ([headline] + lines).joined(separator: "\n") }
}

public enum RecordQuery {
    public static let tokyo = TimeZone(identifier: "Asia/Tokyo") ?? .current

    /// 質問から絞り込みを読む。`species` は「呼び名（別名も）→ 標準和名」
    public static func filter(for question: String, spots: [Spot], species: [String: String], now: Date, timeZone: TimeZone = tokyo) -> RecordFilter {
        let text = VoiceCommand.normalize(question)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        var f = RecordFilter()
        var labels: [String] = []
        let today = cal.startOfDay(for: now)
        let year = cal.component(.year, from: now)
        func startOfYear(_ y: Int) -> Date { cal.date(from: DateComponents(year: y, month: 1, day: 1)) ?? today }
        func startOfMonth(_ y: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: 1)) ?? today }
        func monthRange(_ y: Int, _ m: Int) -> (Date, Date) { (startOfMonth(y, m), cal.date(byAdding: .month, value: 1, to: startOfMonth(y, m)) ?? today) }

        // 年
        var yearValue: Int?
        if text.contains("一昨年") || text.contains("おととし") { yearValue = year - 2; labels.append("一昨年") }
        else if text.contains("去年") || text.contains("昨年") { yearValue = year - 1; labels.append("去年") }
        else if text.contains("今年") { yearValue = year; labels.append("今年") }
        else if let y = number(before: "年", in: text), y >= 2000, y <= year { yearValue = y; labels.append("\(y)年") }

        // 月（「11月」）
        let monthValue = number(before: "月", in: text).flatMap { (1...12).contains($0) ? $0 : nil }

        if text.contains("先月") {
            let m = cal.date(byAdding: .month, value: -1, to: startOfMonth(year, cal.component(.month, from: now))) ?? today
            f.from = m; f.to = startOfMonth(year, cal.component(.month, from: now)); labels.append("先月")
        } else if text.contains("今月") {
            f.from = startOfMonth(year, cal.component(.month, from: now)); labels.append("今月")
        } else if text.contains("先週") {
            let week = startOfWeek(today, cal)
            f.from = week.addingTimeInterval(-7 * 86_400); f.to = week; labels.append("先週")
        } else if text.contains("今週") {
            f.from = startOfWeek(today, cal); labels.append("今週")
        } else if text.contains("昨日") || text.contains("きのう") {
            f.from = today.addingTimeInterval(-86_400); f.to = today; labels.append("昨日")
        } else if text.contains("今日") || text.contains("きょう") {
            f.from = today; labels.append("今日")
        } else if text.contains("最近") {
            f.from = today.addingTimeInterval(-30 * 86_400); labels.append("この 30 日")
        } else if let y = yearValue, let m = monthValue {
            let range = monthRange(y, m)
            f.from = range.0; f.to = range.1; labels.append("\(m)月")
        } else if let y = yearValue {
            f.from = startOfYear(y); f.to = startOfYear(y + 1)
        } else if let m = monthValue {
            f.month = m; labels.append("\(m)月（毎年）")
        }
        if text.contains("前回") || text.contains("この前") { f.lastOnly = true; labels.append("前回") }

        // 釣り場：名前（「漁港」「港」を除いた部分でも）が質問に入っているもの。長い名前を優先
        let hit = spots.filter { s in
            let base = s.name.replacingOccurrences(of: "漁港", with: "").replacingOccurrences(of: "港", with: "")
            return (s.name.count >= 2 && text.contains(s.name)) || (base.count >= 2 && text.contains(base))
        }.max { $0.name.count < $1.name.count }
        if let hit { f.spotID = hit.id; labels.append(hit.name) }

        // 魚種
        if let key = species.keys.filter({ $0.count >= 2 && text.contains($0) }).max(by: { $0.count < $1.count }), let name = species[key] {
            f.species = name; labels.append(name)
        }
        f.label = labels.joined(separator: "・")
        return f
    }

    /// 絞り込んだ釣行を集計して事実の行にする。`ownName` は自分の名前（他の人の魚は数えない）。`rigNames` はリグの表示名
    public static func facts(question: String, sessions: [Session], spots: [Spot], rigNames: [UUID: String], filter f: RecordFilter,
                             ownName: String? = nil, timeZone: TimeZone = tokyo) -> RecordFacts {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let spotName: (UUID) -> String = { id in spots.first { $0.id == id }?.name ?? "釣り場" }
        func inRange(_ d: Date) -> Bool {
            if let from = f.from, d < from { return false }
            if let to = f.to, d >= to { return false }
            if let m = f.month, cal.component(.month, from: d) != m { return false }
            return true
        }
        var picked = sessions.filter { !$0.isActive || !$0.catches.isEmpty }.filter { inRange($0.startedAt) }
        if let id = f.spotID { picked = picked.filter { $0.spotID == id } }
        picked.sort { $0.startedAt > $1.startedAt }
        if f.lastOnly { picked = Array(picked.prefix(1)) }
        var catches = picked.flatMap(\.catches).filter { $0.isOwn(ownName: ownName) }
        if let sp = f.species { catches = catches.filter { $0.species == sp } }
        let sessionsWithHit = f.species == nil ? picked : picked.filter { s in s.catches.contains { $0.species == f.species && $0.isOwn(ownName: ownName) } }

        let head = f.label.isEmpty ? "これまでの記録" : f.label
        guard !picked.isEmpty else { return RecordFacts(headline: "\(head)：当てはまる釣行の記録がありません", lines: [], catchCount: 0) }
        let blank = picked.filter { s in !s.catches.contains { $0.isOwn(ownName: ownName) } }.count
        var headline = "\(head)：\(picked.count) 釣行で \(catches.count) 尾"
        if f.species == nil, blank > 0 { headline += "（ボウズ \(blank) 回）" }
        if f.species != nil { headline += "（釣れた釣行は \(sessionsWithHit.count) 回）" }

        // 年をまたぐ集計のときだけ、日付に年を付ける
        let manyYears = Set(picked.map { cal.component(.year, from: $0.startedAt) }).count > 1
        func day(_ d: Date) -> String {
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return (manyYears ? "\(c.year ?? 0)/" : "") + "\(c.month ?? 0)/\(c.day ?? 0)"
        }
        func cm(_ v: Double) -> String { "\(Int(v.rounded())) cm" }
        func ranked(_ d: [String: Int], limit: Int = 4) -> String {
            d.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(limit).map { "\($0.key) \($0.value) 尾" }.joined(separator: "、")
        }

        // 行は「種類」つきで作り、質問の言葉に近いものを前へ出す
        var rows: [(kind: String, text: String)] = []
        if f.species == nil {
            let by = Dictionary(grouping: catches, by: { $0.species.isEmpty ? "魚" : $0.species })
            let list = by.sorted { $0.value.count > $1.value.count || ($0.value.count == $1.value.count && $0.key < $1.key) }.prefix(6).map { name, items -> String in
                let top = items.compactMap(\.lengthCm).max()
                return "\(name) \(items.count) 尾" + (top.map { "（最大 \(cm($0))）" } ?? "")
            }
            if !list.isEmpty { rows.append(("species", "魚種：" + list.joined(separator: "、"))) }
        }
        if let best = catches.filter({ $0.lengthCm != nil }).max(by: { ($0.lengthCm ?? 0) < ($1.lengthCm ?? 0) }), let len = best.lengthCm {
            let where_ = picked.first { $0.id == best.sessionID }.map { spotName($0.spotID) } ?? ""
            rows.append(("max", "最大：\(best.species.isEmpty ? "魚" : best.species) \(cm(len))（\(day(best.at)) \(where_)）"))
        }
        let dist = Analytics.conditionDistribution(of: catches, timeZone: timeZone)
        if dist.total > 0 {
            let phase = dist.byTide.filter { $0.key != "不明" }
            if !phase.isEmpty { rows.append(("tide", "潮の動き：" + ranked(phase))) }
            if !dist.byTideName.isEmpty { rows.append(("tide", "潮回り：" + ranked(dist.byTideName))) }
            if !dist.byLight.isEmpty { rows.append(("time", "時間帯：" + ranked(dist.byLight))) }
        }
        let hours = Analytics.catchesByHour(catches: catches, timeZone: timeZone)
        if let top = hours.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }), catches.count >= 3 {
            rows.append(("time", "いちばん釣れた時刻：\(top.key) 時台（\(top.value) 尾）"))
        }
        if f.spotID == nil {
            var bySpot: [String: Int] = [:]
            for s in picked { bySpot[spotName(s.spotID), default: 0] += s.catches.filter { c in c.isOwn(ownName: ownName) && (f.species == nil || c.species == f.species) }.count }
            let list = bySpot.filter { $0.value > 0 }
            if list.count >= 1 { rows.append(("spot", "釣り場：" + ranked(list, limit: 5))) }
        }
        if f.from == nil, f.month == nil, !f.lastOnly {
            var byMonth: [String: Int] = [:]
            for c in catches { byMonth["\(cal.component(.month, from: c.at))月", default: 0] += 1 }
            if byMonth.count >= 2 { rows.append(("month", "月：" + ranked(byMonth, limit: 5))) }
        }
        // リグ別（釣果とロスト）
        let stats = Analytics.rigStats(sessions: picked).filter { $0.rigID != nil && ($0.catches > 0 || $0.hookLosses > 0) }
        if !stats.isEmpty {
            let list = stats.prefix(5).map { s -> String in
                let name = s.rigID.flatMap { rigNames[$0] } ?? "リグ"
                return "\(name) \(s.catches) 尾・ロスト \(s.hookLosses) 回"
            }
            rows.append(("rig", "リグ：" + list.joined(separator: "、")))
        }
        let lost = picked.flatMap(\.hookEvents).filter { $0.kind == .lost }.count
        if lost > 0 { rows.append(("rig", "ロスト：合計 \(lost) 回")) }
        // 直近の釣行
        for s in sessionsWithHit.prefix(3) {
            let own = s.catches.filter { $0.isOwn(ownName: ownName) && (f.species == nil || $0.species == f.species) }
            let species = Dictionary(grouping: own, by: { $0.species.isEmpty ? "魚" : $0.species }).sorted { $0.value.count > $1.value.count }.map { "\($0.key) \($0.value.count)" }.joined(separator: " ")
            rows.append(("recent", "\(day(s.startedAt)) \(spotName(s.spotID))：" + (own.isEmpty ? "ボウズ" : species)))
        }

        let wanted = kinds(for: question)
        let ordered = rows.enumerated().sorted { a, b in
            let pa = wanted.firstIndex(of: a.element.kind) ?? 99, pb = wanted.firstIndex(of: b.element.kind) ?? 99
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map { $0.element.text }
        return RecordFacts(headline: headline, lines: ordered, catchCount: catches.count)
    }

    /// 質問の言葉 → 前に出す行の種類
    static func kinds(for question: String) -> [String] {
        let t = VoiceCommand.normalize(question)
        var out: [String] = []
        func add(_ kind: String, _ words: [String]) { if words.contains(where: { t.contains($0) }), !out.contains(kind) { out.append(kind) } }
        add("tide", ["潮"])
        add("time", ["時間", "何時", "マズメ", "朝", "夕", "夜"])
        add("rig", ["ロスト", "リグ", "シンカー", "ワーム", "フック", "g", "グラム"])
        add("max", ["最大", "大き", "自己記録", "サイズ", "何センチ"])
        add("spot", ["どこ", "場所", "釣り場", "港"])
        add("month", ["季節", "時期", "何月"])
        add("species", ["何が", "なにが", "魚種", "どんな魚"])
        add("recent", ["前回", "この前", "最近", "昨日", "今日"])
        return out
    }

    /// その言葉の直前の整数（「11月」→ 11、「2025年」→ 2025）。「今月」「先月」「何月」は nil
    static func number(before unit: String, in text: String) -> Int? {
        var search = text[...]
        while let r = search.range(of: unit) {
            var start = r.lowerBound
            while start > text.startIndex {
                let prev = text.index(before: start)
                if text[prev].isNumber, text[prev].isASCII { start = prev } else { break }
            }
            if start < r.lowerBound, let v = Int(text[start..<r.lowerBound]) { return v }
            search = search[r.upperBound...]
        }
        return nil
    }

    /// その週の月曜 0 時
    static func startOfWeek(_ day: Date, _ cal: Calendar) -> Date {
        let weekday = cal.component(.weekday, from: day)      // 日曜 = 1
        let back = (weekday + 5) % 7                           // 月曜からの日数
        return day.addingTimeInterval(-Double(back) * 86_400)
    }
}
