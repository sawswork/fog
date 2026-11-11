import Foundation

/// 釣行中の「次の一手」（F-65）。いまの条件・この釣行の経過・この釣り場の実績から、決まった規則で 1〜3 個の提案を出す。
/// 実測の水深や潮流は使わない（データが無い）。言語モデルも使わない（同じ状況なら同じ提案）
public enum SessionAdvisor {
    public struct Input: Sendable {
        public var now: Date
        public var sessionStartedAt: Date?
        /// この釣行の釣果・ロストの時刻
        public var catchTimes: [Date]
        public var lostTimes: [Date]
        public var scoreNow: Int
        /// これからの釣れ率（今から数時間）
        public var timeline: [ScorePoint]
        /// 潮位の変化（cm/時。正で上げ）
        public var tideRateCmPerHour: Double?
        public var windSpeedMS: Double?
        /// いまのシンカーの重さ（g）
        public var sinkerGrams: Double?
        /// 投げる場所の見立ての数
        public var zoneCount: Int
        /// いまの潮の動き（「上げ」「下げ」「潮止まり」）と、この釣り場でいちばん釣れている潮の動き（尾数つき）
        public var tideNow: String?
        public var bestTide: (label: String, count: Int, total: Int)?
        /// 次のマズメの始まり
        public var nextTwilight: Date?
        public var timeZone: TimeZone

        public init(now: Date, sessionStartedAt: Date? = nil, catchTimes: [Date] = [], lostTimes: [Date] = [], scoreNow: Int, timeline: [ScorePoint] = [],
                    tideRateCmPerHour: Double? = nil, windSpeedMS: Double? = nil, sinkerGrams: Double? = nil, zoneCount: Int = 0,
                    tideNow: String? = nil, bestTide: (label: String, count: Int, total: Int)? = nil, nextTwilight: Date? = nil,
                    timeZone: TimeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current) {
            self.now = now; self.sessionStartedAt = sessionStartedAt; self.catchTimes = catchTimes; self.lostTimes = lostTimes; self.scoreNow = scoreNow
            self.timeline = timeline; self.tideRateCmPerHour = tideRateCmPerHour; self.windSpeedMS = windSpeedMS; self.sinkerGrams = sinkerGrams
            self.zoneCount = zoneCount; self.tideNow = tideNow; self.bestTide = bestTide; self.nextTwilight = nextTwilight; self.timeZone = timeZone
        }
    }

    public struct Suggestion: Hashable, Sendable {
        /// 何をするか（短い 1 文）
        public var text: String
        /// 3 = いますぐ、2 = 考える価値あり、1 = 参考
        public var priority: Int
    }

    /// アタリの無い時間（分）。釣果が無ければ開始から。釣行していなければ nil
    public static func quietMinutes(_ i: Input) -> Int? {
        guard let from = i.catchTimes.max() ?? i.sessionStartedAt else { return nil }
        return max(0, Int(i.now.timeIntervalSince(from) / 60))
    }

    /// 優先度の高い順に最大 3 つ。何も無ければ、平均的だという 1 行
    public static func advise(_ i: Input) -> [Suggestion] {
        var out: [Suggestion] = []
        var cal = Calendar(identifier: .gregorian); cal.timeZone = i.timeZone
        func hm(_ d: Date) -> String {
            let c = cal.dateComponents([.hour, .minute], from: d)
            return "\(c.hour ?? 0):" + String(format: "%02d", c.minute ?? 0)
        }
        let quiet = quietMinutes(i)

        // これからの山
        let ahead = i.timeline.filter { $0.at > i.now.addingTimeInterval(10 * 60) && $0.at <= i.now.addingTimeInterval(3 * 3600) }
        if let peak = ahead.max(by: { $0.score < $1.score }), peak.score >= i.scoreNow + 6 {
            let minutes = Int(peak.at.timeIntervalSince(i.now) / 60)
            out.append(Suggestion(text: "\(hm(peak.at)) ごろに山（釣れ率 \(peak.score)）。あと \(minutes) 分、それまでは手返しよく探る", priority: minutes <= 90 ? 3 : 2))
        } else if i.scoreNow >= 60, !(ahead.contains { $0.score > i.scoreNow + 2 }) {
            out.append(Suggestion(text: "いまが山（釣れ率 \(i.scoreNow)）。投げる回数を増やす", priority: 3))
        }

        // 潮止まり
        if let rate = i.tideRateCmPerHour, abs(rate) < 2 {
            out.append(Suggestion(text: "潮が止まっている。動き出すまで休むか、仕掛けを見直す", priority: (quiet ?? 0) >= 20 ? 2 : 1))
        }

        // ロストが続く
        let recentLost = i.lostTimes.filter { $0 > i.now.addingTimeInterval(-3600) }.count
        if recentLost >= 2 {
            if let g = i.sinkerGrams, g >= 10 {
                let lighter = [28.0, 21, 18, 14, 10, 7, 5, 3.5].first { $0 < g } ?? g
                out.append(Suggestion(text: "この 1 時間でロスト \(recentLost) 回。シンカーを \(RigParts.gramsText(g))g から \(RigParts.gramsText(lighter))g に軽くする", priority: 3))
            } else {
                out.append(Suggestion(text: "この 1 時間でロスト \(recentLost) 回。投げる向きを替えるか、根の手前で止める", priority: 3))
            }
        }

        // アタリが無い
        if let quiet {
            if quiet >= 75 {
                out.append(Suggestion(text: "\(quiet) 分アタリなし。釣り座か港を替える", priority: 3))
            } else if quiet >= 40 {
                out.append(Suggestion(text: i.zoneCount >= 2 ? "\(quiet) 分アタリなし。投げる場所を ② に替える" : "\(quiet) 分アタリなし。立ち位置を 20〜30 m ずらす", priority: 2))
            }
        }

        // 風
        if let wind = i.windSpeedMS {
            if wind >= 12 { out.append(Suggestion(text: "風 \(Int(wind.rounded())) m。無理をせず、風裏へ移るか切り上げる", priority: 3)) }
            else if wind >= 8 { out.append(Suggestion(text: "風 \(Int(wind.rounded())) m。シンカーを重くするか、風裏の面を狙う", priority: 2)) }
        }

        // マズメ
        if let twilight = i.nextTwilight, twilight > i.now, twilight <= i.now.addingTimeInterval(90 * 60) {
            out.append(Suggestion(text: "あと \(Int(twilight.timeIntervalSince(i.now) / 60)) 分でマズメ（\(hm(twilight))）。それまでに場所を決めておく", priority: 2))
        }

        // この釣り場の実績
        if let best = i.bestTide, best.total >= 5, best.count * 2 >= best.total {
            if i.tideNow == best.label {
                out.append(Suggestion(text: "この釣り場の実績はいまの潮（\(best.label)）に多い（\(best.total) 尾中 \(best.count) 尾）。続ける", priority: 2))
            } else {
                out.append(Suggestion(text: "この釣り場の実績は\(best.label)に多い（\(best.total) 尾中 \(best.count) 尾）", priority: 1))
            }
        }

        if out.isEmpty { out.append(Suggestion(text: "条件は平均的（釣れ率 \(i.scoreNow)）。見立ての ① を中心に探る", priority: 1)) }
        // 優先度の高い順（同じなら出した順）
        return Array(out.enumerated().sorted { $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset }.map { $0.element }.prefix(3))
    }

    /// 相談の答えにする文
    public static func text(_ suggestions: [Suggestion]) -> String {
        suggestions.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
    }
}
