import Foundation

/// 魚種。`id` はローマ字の安定キー、`name` は標準和名。釣果は `name` で参照する（図鑑は釣った魚種だけを name で集約）。
public struct Species: Codable, Identifiable, Hashable, Sendable {
    public enum Priority: String, Codable, Sendable { case high, medium, low }

    public var id: String
    public var name: String
    /// 地方名・別名（函館: アブラコ、ガヤ、ハチガラ など）。
    public var aliases: [String]
    public var priority: Priority

    public init(id: String, name: String, aliases: [String] = [], priority: Priority = .medium) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.priority = priority
    }

    /// 標準和名または別名で検索する。
    public static func lookup(_ text: String, in catalog: [Species] = initialCatalog) -> Species? {
        catalog.first { $0.name == text || $0.aliases.contains(text) }
    }

    /// docs/species.md の初期リスト。L6 で学習データに合わせて増減する。
    public static let initialCatalog: [Species] = [
        Species(id: "ainame", name: "アイナメ", aliases: ["アブラコ"], priority: .high),
        Species(id: "kurosoi", name: "クロソイ", aliases: ["ソイ"], priority: .high),
        Species(id: "mazoi", name: "マゾイ", aliases: ["キツネメバル"], priority: .high),
        Species(id: "shimazoi", name: "シマゾイ", priority: .high),
        Species(id: "ezomebaru", name: "エゾメバル", aliases: ["ガヤ"], priority: .high),
        Species(id: "murasoi", name: "ムラソイ", aliases: ["ハチガラ"], priority: .high),
        Species(id: "kajika", name: "カジカ", aliases: ["トゲカジカ", "ギスカジカ", "ナベコワシ"], priority: .medium),
        Species(id: "hokke", name: "ホッケ", priority: .medium),
        Species(id: "kujime", name: "クジメ", priority: .medium),
        Species(id: "makogarei", name: "マコガレイ", aliases: ["カレイ"], priority: .medium),
        Species(id: "kurogashira", name: "クロガシラガレイ", aliases: ["カレイ"], priority: .medium),
        Species(id: "ugui", name: "ウグイ", priority: .low),
        Species(id: "hirame", name: "ヒラメ", priority: .low),
        Species(id: "buri", name: "ブリ", aliases: ["イナダ", "フクラギ"], priority: .low),
        Species(id: "sakuramasu", name: "サクラマス", priority: .low),
        // イカ（2026-11-09 開発者の指示で追加。道南の岸から釣れる 3 種）
        Species(id: "yariika", name: "ヤリイカ", aliases: ["ヤリ", "テナシ"], priority: .medium),
        Species(id: "surumeika", name: "スルメイカ", aliases: ["マイカ", "イカ"], priority: .medium),
        Species(id: "hiika", name: "ヒイカ", aliases: ["ジンドウイカ", "コイカ"], priority: .low),
    ]

    /// イカ類か（全長の計測は胴長になるので、サイズの表示に「胴長」と添える）
    public var isSquid: Bool { name.hasSuffix("イカ") }
}

/// 魚種判定の候補（低確信度時に3種を出す。F-10）。
public struct SpeciesCandidate: Codable, Hashable, Sendable {
    public var species: String
    public var confidence: Double

    public init(species: String, confidence: Double) {
        self.species = species
        self.confidence = confidence
    }
}
