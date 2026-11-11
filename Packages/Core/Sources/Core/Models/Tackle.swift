import Foundation

/// タックルの種別。例外的入力（撮影画面・ウィジェットの1タップ切替）の単位（F-14）。
public enum TackleKind: String, Codable, Sendable, CaseIterable {
    case spinning
    case bait
}

/// 登録タックル（ロッド・リール・ラインの組）。設定画面で「スピニング」「ベイト」として登録する（§8）。
public struct Tackle: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: TackleKind
    public var name: String
    public var rod: String
    public var reel: String
    public var line: String
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: TackleKind, name: String, rod: String = "", reel: String = "", line: String = "", createdAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.name = name
        self.rod = rod
        self.reel = reel
        self.line = line
        self.createdAt = createdAt
    }
}

/// リグプリセット（シンカー重さ・フックサイズ・ワーム）。最大10個を設定画面で登録する（§8）。
public struct Rig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// 任意の名前。空なら `displayName` が重さとワームから組み立てる。
    public var name: String
    public var sinkerGrams: Double
    public var hookSize: String
    public var worm: String
    public var sortOrder: Int

    public init(id: UUID = UUID(), name: String = "", sinkerGrams: Double, hookSize: String, worm: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.sinkerGrams = sinkerGrams
        self.hookSize = hookSize
        self.worm = worm
        self.sortOrder = sortOrder
    }

    /// 撮影画面のリグチップ表示（例: 「14g バグアンツ3"」）。シンカーが無ければ重さは出さず、
    /// 重さもワームも無いフックだけの組み合わせは「#1/0」
    public var displayName: String {
        if !name.isEmpty { return name }
        var parts: [String] = []
        if sinkerGrams > 0 { parts.append((sinkerGrams.rounded() == sinkerGrams ? String(Int(sinkerGrams)) : String(sinkerGrams)) + "g") }
        if !worm.isEmpty { parts.append(worm) }
        if parts.isEmpty, !hookSize.isEmpty { parts.append(hookSize.hasPrefix("#") ? hookSize : "#" + hookSize) }
        return parts.isEmpty ? "リグ" : parts.joined(separator: " ")
    }
}
