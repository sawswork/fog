import Foundation

/// 事前に登録しておくワーム（メーカー・サイズ・色）。撮影画面のリグの選択で選ぶ
public struct WormPreset: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var maker: String
    public var size: String
    public var color: String

    public init(id: UUID = UUID(), maker: String, size: String, color: String) {
        self.id = id; self.maker = maker; self.size = size; self.color = color
    }

    /// 釣果に残す名前（例「エコギア 3インチ グリパン」）。空の項目は飛ばす
    public var label: String {
        [maker, size, color].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// リグの部品の登録（フックの大きさ・シンカーの重さ・ワーム）。撮影画面ではここから選ぶだけで、文字は打たない。
/// 選んだ組み合わせは `Rig` として釣果に付く（同じ組み合わせは 1 つにまとまる）
public struct RigParts: Codable, Hashable, Sendable {
    /// フックの大きさ（「1/0」「2」のように # を付けない形でそろえる）
    public var hooks: [String]
    /// シンカーの重さ（g、軽い順）
    public var sinkers: [Double]
    public var worms: [WormPreset]

    public init(hooks: [String] = [], sinkers: [Double] = [], worms: [WormPreset] = []) {
        self.hooks = hooks; self.sinkers = sinkers; self.worms = worms
    }

    /// 最初から入っている大きさと重さ（よく使うもの。要らなければ設定で消せる）。ワームは人によるので空
    public static let standard = RigParts(hooks: ["4", "2", "1", "1/0", "2/0", "3/0"], sinkers: [3.5, 5, 7, 10, 14, 18, 21, 28], worms: [])

    /// 「#1/0」「＃１／０」「 1/0 」→「1/0」
    public static func normalizeHook(_ text: String) -> String {
        var s = Self.halfWidth(text).trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = s.first, first == "#" || first == "番" { s.removeFirst() }
        if s.hasSuffix("番") { s.removeLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 「14」「14g」「３．５ｇ」「3,5」→ g。読めない・0 以下・500 g 超は nil
    public static func parseGrams(_ text: String) -> Double? {
        var s = Self.halfWidth(text).lowercased().replacingOccurrences(of: ",", with: ".")
        for unit in ["グラム", "g", " "] { s = s.replacingOccurrences(of: unit, with: "") }
        guard let v = Double(s), v > 0, v <= 500 else { return nil }
        return (v * 10).rounded() / 10
    }

    /// 「14」「3.5」
    public static func gramsText(_ grams: Double) -> String {
        grams.rounded() == grams ? String(Int(grams)) : String(grams)
    }

    /// 全角の英数字と記号を半角に（日本語入力のまま打っても読めるように）
    static func halfWidth(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { u -> Unicode.Scalar in
            if (0xFF01...0xFF5E).contains(u.value), let h = Unicode.Scalar(u.value - 0xFEE0) { return h }
            if u.value == 0x3000 { return " " }
            return u
        }))
    }

    /// 足せたら true（空・重複は足さない）
    @discardableResult
    public mutating func addHook(_ text: String) -> Bool {
        let hook = Self.normalizeHook(text)
        guard !hook.isEmpty, !hooks.contains(hook) else { return false }
        hooks.append(hook)
        return true
    }

    @discardableResult
    public mutating func addSinker(_ text: String) -> Bool {
        guard let grams = Self.parseGrams(text), !sinkers.contains(where: { abs($0 - grams) < 0.05 }) else { return false }
        sinkers.append(grams)
        sinkers.sort()
        return true
    }

    /// 足したワーム（3 つとも空・同じ内容がもうあるときは nil）
    @discardableResult
    public mutating func addWorm(maker: String, size: String, color: String) -> WormPreset? {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let worm = WormPreset(maker: clean(maker), size: clean(size), color: clean(color))
        guard !worm.label.isEmpty, !worms.contains(where: { $0.label == worm.label }) else { return nil }
        worms.append(worm)
        return worm
    }

    public mutating func removeHook(_ hook: String) { hooks.removeAll { $0 == hook } }
    public mutating func removeSinker(_ grams: Double) { sinkers.removeAll { abs($0 - grams) < 0.05 } }
    public mutating func removeWorm(id: UUID) { worms.removeAll { $0.id == id } }
}

public extension Rig {
    /// 部品が 1 つも入っていない
    var isEmpty: Bool { sinkerGrams <= 0 && hookSize.isEmpty && worm.isEmpty }

    /// 同じ部品の組み合わせか（名前は見ない）
    func hasSameParts(hook: String, sinkerGrams grams: Double, worm label: String) -> Bool {
        hookSize == hook && abs(sinkerGrams - grams) < 0.05 && worm == label
    }

    /// 選んだ部品の組み合わせに当たるリグ。もうあればそれ（名前を付けていないものを優先）、無ければ新しく作ったもの。
    /// 何も選んでいなければ nil（リグなし）
    static func resolve(hook: String?, sinkerGrams: Double?, worm: String?, in existing: [Rig]) -> (rig: Rig, isNew: Bool)? {
        let hook = hook ?? "", grams = max(0, sinkerGrams ?? 0), label = worm ?? ""
        guard !(hook.isEmpty && grams <= 0 && label.isEmpty) else { return nil }
        let same = existing.filter { $0.hasSameParts(hook: hook, sinkerGrams: grams, worm: label) }
        if let found = same.first(where: { $0.name.isEmpty }) ?? same.first { return (found, false) }
        let order = (existing.map(\.sortOrder).max() ?? -1) + 1
        return (Rig(sinkerGrams: grams, hookSize: hook, worm: label, sortOrder: order), true)
    }
}
