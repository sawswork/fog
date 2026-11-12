import Foundation

/// 写真に魚が写っているかの判定（F-67）。標準カメラの写真の取り込みと、仲間から届いた釣果の表示で使う。
///
/// 端末内の画像分類のラベル（識別子と信頼度）と、前景の被写体があるかどうかから決める。
/// 釣果を落とすほうが害が大きいので、「魚ではない」とするのは、魚のラベルが無く、かつ魚以外だとはっきり分かるときだけ：
/// - 人が大きく写っている
/// - 前景の被写体が無く、景色（空・海・夜景など）が写っている
/// - 画面の写し・書類・車
/// どれでもなければ魚として扱う（迷ったら残す）。
public enum FishPresence {
    public enum Reason: String, Sendable {
        /// 魚のラベルがある
        case fishLabel
        /// 人が写っていて、魚のラベルが無い
        case people
        /// 被写体が無く、景色が写っている
        case scenery
        /// 画面の写し・書類・車など
        case other
        /// はっきりしない（残す）
        case unsure
    }

    public struct Result: Hashable, Sendable {
        public var hasFish: Bool
        public var reason: Reason
        /// 魚のラベルの信頼度（最大）
        public var fishScore: Double
        /// 判定に効いたラベル（診断の表示用。「sky 0.92」）
        public var evidence: String

        public init(hasFish: Bool, reason: Reason, fishScore: Double, evidence: String) {
            self.hasFish = hasFish; self.reason = reason; self.fishScore = fishScore; self.evidence = evidence
        }
    }

    /// 魚介のラベル（語単位で比べる。"fishing" や "starfish" には反応しない）
    static let fishWords: Set<String> = [
        "fish", "seafood", "shellfish", "squid", "octopus", "cuttlefish", "crab", "shrimp", "prawn", "lobster", "eel", "shark",
        "stingray", "salmon", "trout", "tuna", "carp", "koi", "goldfish", "flatfish", "flounder", "mackerel", "sardine", "rockfish", "cod",
        "sashimi", "sushi",
    ]
    static let peopleWords: Set<String> = [
        "people", "person", "adult", "child", "baby", "man", "woman", "boy", "girl", "teen", "face", "portrait", "selfie", "crowd",
    ]
    static let sceneryWords: Set<String> = [
        "sky", "cloud", "clouds", "cloudy", "sunset", "sunrise", "night", "landscape", "cityscape", "skyline", "ocean", "sea", "beach",
        "shore", "coast", "horizon", "mountain", "hill", "harbor", "port", "bridge", "city", "lake", "river",
    ]
    static let otherWords: Set<String> = ["screenshot", "document", "receipt", "car", "vehicle", "automobile", "truck"]

    public static let fishThreshold = 0.10
    public static let peopleThreshold = 0.5
    public static let sceneryThreshold = 0.4
    public static let otherThreshold = 0.6

    /// - Parameters:
    ///   - labels: 画像分類の (識別子, 信頼度 0〜1)
    ///   - hasSubject: 前景の被写体があるか。分からなければ nil（あるものとして扱う）
    public static func judge(labels: [(String, Double)], hasSubject: Bool?) -> Result {
        func best(_ words: Set<String>) -> (String, Double)? {
            var top: (String, Double)?
            for (raw, confidence) in labels {
                let id = raw.lowercased()
                let tokens = id.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).map(String.init)
                guard words.contains(id) || tokens.contains(where: { words.contains($0) }) else { continue }
                if confidence > (top?.1 ?? 0) { top = (id, confidence) }
            }
            return top
        }
        func text(_ l: (String, Double)) -> String { "\(l.0) \(String(format: "%.2f", l.1))" }

        let fish = best(fishWords)
        let fishScore = fish?.1 ?? 0
        if let fish, fish.1 >= fishThreshold {
            return Result(hasFish: true, reason: .fishLabel, fishScore: fishScore, evidence: text(fish))
        }
        if let people = best(peopleWords), people.1 >= peopleThreshold {
            return Result(hasFish: false, reason: .people, fishScore: fishScore, evidence: text(people))
        }
        if hasSubject == false, let scenery = best(sceneryWords), scenery.1 >= sceneryThreshold {
            return Result(hasFish: false, reason: .scenery, fishScore: fishScore, evidence: text(scenery))
        }
        if let other = best(otherWords), other.1 >= otherThreshold {
            return Result(hasFish: false, reason: .other, fishScore: fishScore, evidence: text(other))
        }
        let top = labels.max { $0.1 < $1.1 }
        return Result(hasFish: true, reason: .unsure, fishScore: fishScore, evidence: top.map(text) ?? "ラベルなし")
    }
}
