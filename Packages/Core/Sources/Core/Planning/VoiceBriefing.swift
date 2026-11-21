import Foundation

/// 釣行中の音声の知らせ（F-70）。30 分ごとに、釣り場の今の時刻・釣れ率・潮の状況・少し先の天気を読み上げる文を作る。
///
/// 例：「9時30分。森港。釣れ率は62。若潮の上げ潮、潮位58センチ。次の満潮は12時28分。30分後は雪、降水確率80パーセント、気温2度、西の風3メートル。」
/// 分からない項目は言わない。読み上げで聞き取りやすいよう、数字は整数にし、単位は言葉で書く
public enum VoiceBriefing {
    public struct Input: Sendable {
        public var now: Date
        public var spotName: String
        /// 釣れ率（0〜100）
        public var score: Int?
        public var tideLevelCm: Double?
        /// 潮位の変化（cm/時。正で上げ）
        public var tideRateCmPerHour: Double?
        /// 大潮・中潮・小潮・長潮・若潮
        public var tideName: String?
        public var nextHighTideAt: Date?
        public var nextLowTideAt: Date?
        /// 何分先の天気を言うか
        public var laterMinutes: Int
        /// 先の天気の言葉（「晴れ」「雪」など）
        public var weatherLater: String?
        /// 先の降水確率 0〜1
        public var precipitationChanceLater: Double?
        public var temperatureLaterC: Double?
        public var windLaterMS: Double?
        /// 風が吹いてくる向き（度）
        public var windDirectionLaterDeg: Double?

        public init(now: Date, spotName: String, score: Int? = nil, tideLevelCm: Double? = nil, tideRateCmPerHour: Double? = nil, tideName: String? = nil,
                    nextHighTideAt: Date? = nil, nextLowTideAt: Date? = nil, laterMinutes: Int = 30, weatherLater: String? = nil,
                    precipitationChanceLater: Double? = nil, temperatureLaterC: Double? = nil, windLaterMS: Double? = nil, windDirectionLaterDeg: Double? = nil) {
            self.now = now; self.spotName = spotName; self.score = score; self.tideLevelCm = tideLevelCm; self.tideRateCmPerHour = tideRateCmPerHour
            self.tideName = tideName; self.nextHighTideAt = nextHighTideAt; self.nextLowTideAt = nextLowTideAt; self.laterMinutes = laterMinutes
            self.weatherLater = weatherLater; self.precipitationChanceLater = precipitationChanceLater; self.temperatureLaterC = temperatureLaterC
            self.windLaterMS = windLaterMS; self.windDirectionLaterDeg = windDirectionLaterDeg
        }
    }

    /// 次に読む時刻：0 分か 30 分ちょうど（`now` より後で最初のもの）。日本時間は 30 分単位のずれなので、時刻の数字で切ってよい
    public static func nextSlot(after now: Date, everyMinutes: Int = 30) -> Date {
        let step = Double(max(1, everyMinutes)) * 60
        let t = now.timeIntervalSince1970
        return Date(timeIntervalSince1970: ((t / step).rounded(.down) + 1) * step)
    }

    /// 潮が動いているとみなす変化の速さ（cm/時）。これより遅ければ「潮止まり」
    public static let slackRate = 3.0

    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        let h = c.hour ?? 0, m = c.minute ?? 0
        return m == 0 ? "\(h)時" : "\(h)時\(m)分"
    }

    /// 潮の動きの言葉
    public static func tideWord(rateCmPerHour: Double) -> String {
        if rateCmPerHour >= slackRate { return "上げ潮" }
        if rateCmPerHour <= -slackRate { return "下げ潮" }
        return "潮止まり"
    }

    public static func text(_ i: Input, timeZone: TimeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current) -> String {
        var parts: [String] = [clock(i.now, timeZone: timeZone)]
        let name = i.spotName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { parts.append(name) }
        if let s = i.score { parts.append("釣れ率は\(max(0, min(100, s)))") }

        // 潮：「若潮の上げ潮、潮位58センチ」「次の満潮は12時28分」
        var tide: [String] = []
        if let rate = i.tideRateCmPerHour {
            let word = tideWord(rateCmPerHour: rate)
            tide.append((i.tideName.map { $0.isEmpty ? "" : "\($0)の" } ?? "") + word)
        } else if let n = i.tideName, !n.isEmpty {
            tide.append(n)
        }
        if let level = i.tideLevelCm { tide.append("潮位\(Int(level.rounded()))センチ") }
        if !tide.isEmpty { parts.append(tide.joined(separator: "、")) }
        let high = i.nextHighTideAt.flatMap { $0 > i.now ? $0 : nil }, low = i.nextLowTideAt.flatMap { $0 > i.now ? $0 : nil }
        switch (high, low) {
        case let (h?, l?): parts.append(h <= l ? "次の満潮は\(clock(h, timeZone: timeZone))" : "次の干潮は\(clock(l, timeZone: timeZone))")
        case let (h?, nil): parts.append("次の満潮は\(clock(h, timeZone: timeZone))")
        case let (nil, l?): parts.append("次の干潮は\(clock(l, timeZone: timeZone))")
        default: break
        }

        // 天気：「30分後は雪、降水確率80パーセント、気温2度、西の風3メートル」
        var weather: [String] = []
        if let w = i.weatherLater, !w.isEmpty { weather.append(w) }
        if let p = i.precipitationChanceLater { weather.append("降水確率\(Int((p * 100).rounded()))パーセント") }
        if let t = i.temperatureLaterC {
            let v = Int(t.rounded())
            weather.append(v < 0 ? "気温マイナス\(-v)度" : "気温\(v)度")
        }
        if let wind = i.windLaterMS {
            let v = Int(wind.rounded())
            if v < 1 {
                weather.append("風は弱い")
            } else if let d = i.windDirectionLaterDeg {
                weather.append("\(CastPredictor.compassName(d))の風\(v)メートル")
            } else {
                weather.append("風\(v)メートル")
            }
        }
        if !weather.isEmpty { parts.append("\(i.laterMinutes)分後は" + weather.joined(separator: "、")) }
        return parts.joined(separator: "。") + "。"
    }
}
