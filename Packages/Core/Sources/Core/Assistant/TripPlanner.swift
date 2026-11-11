import Foundation

/// 次の釣行の計画（F-65）。「今週末、朝だけ」のような言葉から日と時間の枠を読み、釣り場ごとの釣れ率の推移から
/// 枠の中でいちばん良い時間帯を出して並べる。車の所要時間があれば出発時刻も出す
public enum TripPlanner {
    public struct Request: Hashable, Sendable {
        /// 候補の日（その日の 0 時）
        public var days: [Date]
        /// 行ける時間の枠（時。0〜24）
        public var fromHour: Int
        public var toHour: Int
        /// 「今週末の朝」
        public var label: String
    }

    public struct Candidate: Hashable, Sendable {
        public var spotName: String
        public var dayStart: Date
        public var start: Date
        public var end: Date
        public var score: Int
        /// 車の所要時間（秒）。分からなければ nil
        public var driveSeconds: Double?
        /// その時間の天気（「風 3m 気温 5° 降水 10%」）
        public var weather: String?

        public init(spotName: String, dayStart: Date, start: Date, end: Date, score: Int, driveSeconds: Double? = nil, weather: String? = nil) {
            self.spotName = spotName; self.dayStart = dayStart; self.start = start; self.end = end; self.score = score; self.driveSeconds = driveSeconds; self.weather = weather
        }
    }

    /// 言葉から日と時間の枠を読む。日の指定が無ければ「今日（15 時前なら）と明日」
    public static func parse(_ raw: String, now: Date, timeZone: TimeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current) -> Request {
        let text = VoiceCommand.normalize(raw)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today)        // 日曜 = 1 … 土曜 = 7
        func day(_ offset: Int) -> Date { today.addingTimeInterval(Double(offset) * 86_400) }
        func next(_ target: Int) -> Date { day((target - weekday + 7) % 7) }
        var days: [Date] = [], labels: [String] = []

        if text.contains("週末") || text.contains("土日") {
            // 土曜なら今日と明日、日曜なら今日だけ
            if weekday == 1 { days = [today] } else { days = [next(7), next(7).addingTimeInterval(86_400)] }
            if text.contains("来週") { days = days.map { $0.addingTimeInterval(7 * 86_400) }; labels.append("来週末") } else { labels.append("今週末") }
        } else {
            if text.contains("今日") || text.contains("きょう") || text.contains("これから") { days.append(today); labels.append("今日") }
            if text.contains("明後日") || text.contains("あさって") { days.append(day(2)); labels.append("明後日") }
            else if text.contains("明日") || text.contains("あした") { days.append(day(1)); labels.append("明日") }
            for (name, target) in [("日曜", 1), ("月曜", 2), ("火曜", 3), ("水曜", 4), ("木曜", 5), ("金曜", 6), ("土曜", 7)] where text.contains(name) {
                var d = next(target)
                if text.contains("来週") { d = d.addingTimeInterval(7 * 86_400) }
                if !days.contains(d) { days.append(d); labels.append(name) }
            }
        }
        if days.isEmpty {
            let hour = cal.component(.hour, from: now)
            days = hour < 15 ? [today, day(1)] : [day(1)]
            labels.append(hour < 15 ? "今日と明日" : "明日")
        }

        // 時間の枠
        var from = 0, to = 24, slot: String?
        if let a = RecordQuery.number(before: "時から", in: text), let b = RecordQuery.number(before: "時まで", in: text), a < b, b <= 24 { from = a; to = b; slot = "\(a)〜\(b)時" }
        else if let b = RecordQuery.number(before: "時まで", in: text), b >= 1, b <= 24 { to = b; slot = "\(b)時まで" }
        else if let a = RecordQuery.number(before: "時から", in: text), a >= 0, a < 24 { from = a; slot = "\(a)時から" }
        else if text.contains("朝マズメ") { from = 3; to = 8; slot = "朝マズメ" }
        else if text.contains("夕マズメ") { from = 15; to = 20; slot = "夕マズメ" }
        else if text.contains("深夜") || text.contains("夜中") { from = 0; to = 4; slot = "深夜" }
        else if text.contains("朝") || text.contains("午前") { from = 4; to = 11; slot = text.contains("午前") ? "午前" : "朝" }
        else if text.contains("夕方") || text.contains("夕") { from = 15; to = 20; slot = "夕方" }
        else if text.contains("午後") { from = 12; to = 19; slot = "午後" }
        else if text.contains("昼") || text.contains("日中") { from = 9; to = 16; slot = "日中" }
        else if text.contains("夜") { from = 18; to = 24; slot = "夜" }
        let label = labels.joined(separator: "・") + (slot.map { "の" + $0 } ?? "")
        return Request(days: days.sorted(), fromHour: from, toHour: to, label: label)
    }

    /// 1 つの釣り場・1 日の推移から、枠の中でいちばん良い時間帯。過ぎた時刻は見ない
    public static func best(spotName: String, dayStart: Date, points: [ScorePoint], request: Request, now: Date) -> Candidate? {
        let lo = dayStart.addingTimeInterval(Double(request.fromHour) * 3600), hi = dayStart.addingTimeInterval(Double(request.toHour) * 3600)
        let inWindow = points.filter { $0.at >= lo && $0.at <= hi && $0.at >= now }
        guard let top = inWindow.max(by: { $0.score < $1.score }) else { return nil }
        // 最高点から 6 点以内が続く範囲（最低でも前後 30 分）
        let sorted = inWindow.sorted { $0.at < $1.at }
        guard let index = sorted.firstIndex(where: { $0.at == top.at }) else { return nil }
        var a = index, b = index
        while a > 0, sorted[a - 1].score >= top.score - 6 { a -= 1 }
        while b < sorted.count - 1, sorted[b + 1].score >= top.score - 6 { b += 1 }
        let start = min(sorted[a].at, max(lo, top.at.addingTimeInterval(-1800))), end = max(sorted[b].at, min(hi, top.at.addingTimeInterval(1800)))
        return Candidate(spotName: spotName, dayStart: dayStart, start: start, end: end, score: top.score)
    }

    /// 釣れ率の高い順。差が 3 点以内なら車で近いほうを先に
    public static func rank(_ candidates: [Candidate]) -> [Candidate] {
        candidates.sorted { a, b in
            if abs(a.score - b.score) > 3 { return a.score > b.score }
            let da = a.driveSeconds ?? .greatestFiniteMagnitude, db = b.driveSeconds ?? .greatestFiniteMagnitude
            if da != db { return da < db }
            return a.score != b.score ? a.score > b.score : a.start < b.start
        }
    }

    /// 相談の答え。上位 3 件。出発は「着いて 15 分で始められる」時刻
    public static func text(request: Request, ranked: [Candidate], timeZone: TimeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current) -> String {
        guard !ranked.isEmpty else { return "\(request.label)に当てはまる予報がありません。釣り場を登録しているか、日と時間を確かめてください" }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        func hm(_ d: Date) -> String {
            let c = cal.dateComponents([.hour, .minute], from: d)
            return "\(c.hour ?? 0):" + String(format: "%02d", c.minute ?? 0)
        }
        func dayName(_ d: Date) -> String {
            let c = cal.dateComponents([.month, .day, .weekday], from: d)
            return "\(c.month ?? 0)/\(c.day ?? 0)（\(["", "日", "月", "火", "水", "木", "金", "土"][c.weekday ?? 0])）"
        }
        var lines = ["\(request.label)のおすすめ"]
        for (i, c) in ranked.prefix(3).enumerated() {
            var line = "\(i + 1). \(c.spotName) \(dayName(c.dayStart)) \(hm(c.start))〜\(hm(c.end))　釣れ率 \(c.score)"
            if let drive = c.driveSeconds {
                let minutes = Int((drive / 60).rounded())
                line += "\n　車で \(minutes >= 60 ? "\(minutes / 60) 時間 \(minutes % 60) 分" : "\(minutes) 分") → \(hm(c.start.addingTimeInterval(-drive - 15 * 60))) に出発"
            }
            if let w = c.weather, !w.isEmpty { line += "\n　" + w }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
