import Foundation

/// 声（か文字）での記録・操作（F-65）。短い言い切りだけを命令として読む。質問や長い話は命令にしない。
/// 端末内の決まった規則だけで解釈する（言語モデルは使わない。速く、同じ言葉は必ず同じ結果）
public enum VoiceCommand: Hashable, Sendable {
    /// 釣行を始める／終える
    case start
    case end
    /// 針・仕掛けのロスト（回数）
    case lost(count: Int)
    /// 針を足した
    case hookAdded
    /// リグの部品を替えた（言われた項目だけ。ほかは今のまま）
    case rig(hook: String?, sinkerGrams: Double?, worm: String?)
    case tackle(TackleKind)
    /// 撮影画面を開く
    case camera

    /// 命令として読めなければ nil。`worms` は登録してあるワーム（メーカーか色の一致で選ぶ）
    public static func parse(_ raw: String, worms: [WormPreset] = []) -> VoiceCommand? {
        let text = normalize(raw)
        guard !text.isEmpty, text.count <= 40 else { return nil }
        // 質問は命令にしない
        for q in ["?", "どう", "何", "なに", "どっち", "どちら", "多い", "いつ", "教えて", "どこ", "なぜ", "ですか", "ますか", "かな"] where text.contains(q) { return nil }

        let changeWords = ["替え", "変え", "かえ", "にした", "にする", "変更", "交換", "チェンジ", "付け", "つけ"]
        let changes = changeWords.contains { text.contains($0) }

        // リグ：シンカー・フック・ワーム（1 つの言葉に複数あってよい）
        var hook: String?, sinker: Double?, worm: String?
        if let g = grams(in: text), text.contains("シンカー") || text.contains("オモリ") || text.contains("おもり") || text.contains("重り") || text.contains("錘") || changes || text.count <= 8 {
            sinker = g
        }
        if text.contains("フック") || text.contains("針") || text.contains("ハリ") {
            if let h = hookSize(in: text) { hook = h }
        }
        if text.contains("ワーム"), let w = worms.first(where: { matches($0, text) }) { worm = w.label }
        if hook != nil || sinker != nil || worm != nil { return .rig(hook: hook, sinkerGrams: sinker, worm: worm) }

        if text.contains("針追加") || text.contains("針を追加") || text.contains("針を足") || text.contains("フック追加") || text.contains("フックを追加") { return .hookAdded }
        for word in ["ロスト", "根掛", "根がかり", "ねがかり", "切れた", "ラインブレイク", "高切れ"] where text.contains(word) {
            return .lost(count: min(9, max(1, count(in: text) ?? 1)))
        }
        if text.contains("ベイト"), changes || text.count <= 8 { return .tackle(.bait) }
        if text.contains("スピニング"), changes || text.count <= 10 { return .tackle(.spinning) }

        let short = text.count <= 12
        if short || text.contains("釣行") {
            for word in ["終了", "終わり", "おわり", "終える", "納竿", "ストップ"] where text.contains(word) { return .end }
            for word in ["開始", "スタート", "始め", "はじめ"] where text.contains(word) { return .start }
        }
        if short { for word in ["撮影", "写真", "カメラ", "撮る", "撮って"] where text.contains(word) { return .camera } }
        return nil
    }

    /// 全角→半角、空白を除く、漢数字の一〜十を数字に（「十四グラム」も読めるように）
    static func normalize(_ raw: String) -> String {
        var s = RigParts.halfWidth(raw).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "、", with: "").replacingOccurrences(of: "。", with: "")
        s = s.replacingOccurrences(of: "？", with: "?")
        // 漢数字（二十一まで。シンカーの重さと回数に足りる）
        let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var out = "", chars = Array(s), i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "十" {
                let next = i + 1 < chars.count ? digits[chars[i + 1]] : nil
                out += String(10 + (next ?? 0)); i += next == nil ? 1 : 2
            } else if let d = digits[c], i + 1 < chars.count, chars[i + 1] == "十" {
                let next = i + 2 < chars.count ? digits[chars[i + 2]] : nil
                out += String(d * 10 + (next ?? 0)); i += next == nil ? 2 : 3
            } else if let d = digits[c], isCounter(after: i, in: chars) {
                out += String(d); i += 1
            } else {
                out.append(c); i += 1
            }
        }
        return out
    }

    /// 一〜九のあとが単位（グラム・回・番・号）のときだけ数字として読む（「一番」「三平」などの語を壊さない）
    private static func isCounter(after i: Int, in chars: [Character]) -> Bool {
        guard i + 1 < chars.count else { return false }
        let rest = String(chars[(i + 1)...])
        return ["グラム", "g", "回", "個", "号"].contains { rest.hasPrefix($0) }
    }

    /// 「14グラム」「3.5g」→ 14, 3.5
    static func grams(in text: String) -> Double? {
        for unit in ["グラム", "g", "ｇ"] {
            var search = text[...]
            while let r = search.range(of: unit) {
                if let n = number(before: r.lowerBound, in: text), n > 0, n <= 200 { return n }
                search = search[r.upperBound...]
            }
        }
        return nil
    }

    /// 「2回」「3個」→ 2, 3
    static func count(in text: String) -> Int? {
        for unit in ["回", "個", "本"] {
            if let r = text.range(of: unit), let n = number(before: r.lowerBound, in: text), n >= 1 { return Int(n) }
        }
        return nil
    }

    /// 「フック1/0」「針を2番に」「#4」→ 1/0, 2, 4
    static func hookSize(in text: String) -> String? {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i].isNumber, chars[i].isASCII {
                var j = i
                while j < chars.count, chars[j].isNumber, chars[j].isASCII { j += 1 }
                let n = String(chars[i..<j])
                if j + 1 < chars.count, chars[j] == "/", chars[j + 1] == "0" { return n + "/0" }
                let rest = String(chars[j...])
                // 重さ・回数の数字は針の大きさではない
                if !["グラム", "g", "回", "個", ".", "時", "分", "尾"].contains(where: { rest.hasPrefix($0) }) { return n }
                i = j
            } else { i += 1 }
        }
        return nil
    }

    /// その位置の直前にある数（小数可）
    private static func number(before index: String.Index, in text: String) -> Double? {
        var start = index
        while start > text.startIndex {
            let prev = text.index(before: start)
            let c = text[prev]
            if (c.isNumber && c.isASCII) || c == "." { start = prev } else { break }
        }
        guard start < index else { return nil }
        return Double(text[start..<index])
    }

    private static func matches(_ worm: WormPreset, _ text: String) -> Bool {
        let maker = worm.maker.trimmingCharacters(in: .whitespaces), color = worm.color.trimmingCharacters(in: .whitespaces)
        if maker.count >= 2, text.contains(RigParts.halfWidth(maker).replacingOccurrences(of: " ", with: "")) { return color.isEmpty || !anyOtherColor(text, except: color) }
        return color.count >= 2 && text.contains(RigParts.halfWidth(color).replacingOccurrences(of: " ", with: ""))
    }

    /// メーカーが同じワームが複数あるとき用：言葉に色が入っていれば、その色のものだけを当てる
    private static func anyOtherColor(_ text: String, except color: String) -> Bool {
        !text.contains(RigParts.halfWidth(color).replacingOccurrences(of: " ", with: "")) && ["赤", "青", "緑", "黒", "白", "グリーン", "レッド", "ブラック", "ホワイト", "オレンジ", "ピンク", "チャート", "グロー"].contains { text.contains($0) }
    }
}
