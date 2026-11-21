import Foundation

/// 雨（雪）が降り出す前の通知（F-69）。釣行中に、分単位の降水予報から「約 N 分後に雨が降りそうです」と知らせる。
///
/// - 降り出し：降水確率 50% 以上・強さ 0.1 mm/h 以上が 3 分以上続く最初の時刻。1〜2 分だけの反応は拾わない
/// - いま降っているときは知らせない（降る「前」の通知）
/// - 降り出しの `lead`（既定 30 分）前に知らせる。それより近ければ、すぐ知らせる
/// - 分単位の予報が無い地域・時間では、1 時間ごとの予報で代える（「14 時ごろから」。2 時間先まで）
/// - 同じ降り出し（45 分以内のずれ）を 2 度は知らせない。予報から雨が消えたら、予約した通知を取り消す
public enum RainPlanner {
    public enum Kind: String, Sendable, Codable {
        case rain, snow, sleet
        public var word: String {
            switch self {
            case .rain: return "雨"
            case .snow: return "雪"
            case .sleet: return "みぞれ"
            }
        }
    }

    /// 1 分ごとの予報
    public struct Minute: Hashable, Sendable {
        public var at: Date
        /// 降水確率 0〜1
        public var chance: Double
        /// 強さ（mm/h）
        public var intensityMMH: Double
        public var kind: Kind
        public init(at: Date, chance: Double, intensityMMH: Double, kind: Kind = .rain) {
            self.at = at; self.chance = chance; self.intensityMMH = intensityMMH; self.kind = kind
        }
        var isWet: Bool { chance >= RainPlanner.minChance && intensityMMH >= RainPlanner.minIntensityMMH }
    }

    /// 1 時間ごとの予報（その時刻から 1 時間の値）
    public struct Hour: Hashable, Sendable {
        public var at: Date
        public var chance: Double
        /// 1 時間の降水量（mm）
        public var amountMM: Double
        public var kind: Kind
        public init(at: Date, chance: Double, amountMM: Double, kind: Kind = .rain) {
            self.at = at; self.chance = chance; self.amountMM = amountMM; self.kind = kind
        }
        var isWet: Bool { chance >= RainPlanner.minChance && amountMM >= RainPlanner.minHourlyMM }
    }

    public struct Alert: Hashable, Sendable, Codable {
        /// 降り出しの時刻
        public var onset: Date
        /// 知らせる時刻
        public var fireAt: Date
        public var kind: Kind
        /// 降り出しから 30 分の強さの最大（mm/h。1 時間ごとの予報では 1 時間の降水量）
        public var peakMMH: Double
        /// 1 時間ごとの予報から作った（分までは分からない）
        public var coarse: Bool

        /// 知らせる時点で、降り出しまで何分か
        public var minutesAhead: Int { max(0, Int((onset.timeIntervalSince(fireAt) / 60).rounded())) }

        public var title: String { "まもなく\(kind.word)" }

        /// 「約 20 分後に雨が降りそうです（弱い雨）」。10 分以上は 5 分刻みに丸める
        public func body(timeZone: TimeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current) -> String {
            let strength = RainPlanner.strengthWord(peakMMH, kind: kind)
            if coarse {
                var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
                let hour = cal.component(.hour, from: onset)
                return "\(hour) 時ごろから\(kind.word)の予報です（約 \(RainPlanner.rounded(minutesAhead)) 分後）"
            }
            if minutesAhead <= 2 { return "まもなく\(kind.word)が降りそうです（\(strength)）" }
            return "約 \(RainPlanner.rounded(minutesAhead)) 分後に\(kind.word)が降りそうです（\(strength)）"
        }
    }

    public enum Decision: Equatable, Sendable {
        /// 何もしない（予約済みの通知があればそのまま）
        case nothing
        /// 予約した通知を取り消す（予報から雨が消えた）
        case cancel
        /// 知らせる（予約済みの通知は置き換える）
        case notify(Alert)
    }

    public static let minChance = 0.5
    public static let minIntensityMMH = 0.1
    public static let minHourlyMM = 0.2
    /// 降り出しとみなす連続の分数
    public static let minRunMinutes = 3
    /// 同じ雨とみなす降り出しのずれ
    public static let sameOnsetWindow: TimeInterval = 45 * 60

    static func rounded(_ minutes: Int) -> Int { minutes < 10 ? minutes : Int((Double(minutes) / 5).rounded()) * 5 }

    static func strengthWord(_ mmh: Double, kind: Kind) -> String {
        switch kind {
        case .snow: return mmh >= 3 ? "強い雪" : (mmh >= 1 ? "雪" : "弱い雪")
        case .sleet: return "みぞれ"
        case .rain: return mmh >= 10 ? "強い雨" : (mmh >= 1 ? "雨" : "弱い雨")
        }
    }

    /// 分単位の予報から降り出しを探す。いま降っている（`now` から 3 分以内に降水がある）なら `raining` が true
    static func onset(minutes: [Minute], now: Date) -> (raining: Bool, alert: (onset: Date, kind: Kind, peak: Double)?) {
        let future = minutes.filter { $0.at >= now.addingTimeInterval(-60) }.sorted { $0.at < $1.at }
        guard !future.isEmpty else { return (false, nil) }
        if future.prefix(3).contains(where: \.isWet) { return (true, nil) }
        var i = 0
        while i < future.count {
            guard future[i].isWet else { i += 1; continue }
            var j = i
            while j < future.count, future[j].isWet { j += 1 }
            // 3 分以上続く、または予報の終わりまで続いている
            if j - i >= minRunMinutes || j == future.count {
                let start = future[i].at
                let window = future[i..<j].filter { $0.at < start.addingTimeInterval(30 * 60) }
                let peak = window.map(\.intensityMMH).max() ?? future[i].intensityMMH
                return (false, (start, future[i].kind, peak))
            }
            i = j
        }
        return (false, nil)
    }

    /// 知らせるかを決める。
    /// - Parameters:
    ///   - minutes: 分単位の予報（無ければ空）
    ///   - hours: 1 時間ごとの予報（分単位の予報の先・代わりに使う）
    ///   - previous: 前に知らせた・予約した通知
    public static func decide(now: Date, minutes: [Minute], hours: [Hour], previous: Alert?, lead: TimeInterval = 30 * 60) -> Decision {
        let pending = previous.map { $0.fireAt > now } ?? false
        var found: Alert?
        let fine = onset(minutes: minutes, now: now)
        if fine.raining { return pending ? .cancel : .nothing }
        if let a = fine.alert {
            found = Alert(onset: a.onset, fireAt: max(now, a.onset.addingTimeInterval(-lead)), kind: a.kind, peakMMH: a.peak, coarse: false)
        } else {
            // 分単位の予報が届く範囲（無ければ今）より先を、1 時間ごとの予報で見る。2 時間先まで
            let covered = minutes.map(\.at).max() ?? now
            let currentHourWet = hours.contains { $0.at <= now && now < $0.at.addingTimeInterval(3600) && $0.isWet }
            // 分単位の予報が無く、いまの 1 時間がすでに雨の予報なら、降り出しの時刻は分からないので知らせない
            if minutes.isEmpty, currentHourWet { return pending ? .cancel : .nothing }
            if let h = hours.filter({ $0.at > covered && $0.at > now && $0.at <= now.addingTimeInterval(2 * 3600) && $0.isWet }).min(by: { $0.at < $1.at }) {
                found = Alert(onset: h.at, fireAt: max(now, h.at.addingTimeInterval(-lead)), kind: h.kind, peakMMH: h.amountMM, coarse: true)
            }
        }
        guard let alert = found else { return pending ? .cancel : .nothing }
        if let previous {
            let sameRain = abs(alert.onset.timeIntervalSince(previous.onset)) < sameOnsetWindow
            // もう知らせた雨は、もう一度は知らせない
            if !pending, sameRain { return .nothing }
            // 予約済みで、ほとんど変わらないなら置き換えない
            if pending, abs(alert.onset.timeIntervalSince(previous.onset)) < 5 * 60, abs(alert.fireAt.timeIntervalSince(previous.fireAt)) < 5 * 60, alert.kind == previous.kind {
                return .nothing
            }
        }
        return .notify(alert)
    }
}
