import Foundation

/// 相談への入力が「何の話か」（F-65）。決まった言葉から端末内で振り分ける。
/// どれにも当たらないもの（予報の質問、店先で聞いた話）は `.other` で、これまでの流れ（F-53）に渡す
public enum AssistantIntent: Hashable, Sendable {
    /// 記録・操作の命令
    case command(VoiceCommand)
    /// 自分の記録への質問（去年の 11 月は？ いちばん釣れた潮は？）
    case records
    /// いま何をすべきか（アタリが無い、次どうする）
    case advice
    /// 次の釣行の計画（週末の朝、どこがいい？）
    case plan
    /// 魚について（標準和名。空なら「さっき釣れた魚」）
    case fish(String)
    /// ネットの釣果情報の要約
    case feedDigest
    /// 釣行のまとめ（仲間の分も）
    case tripSummary
    case other
}

public enum AssistantRouter {
    /// `species` は「呼び名（別名も）→ 標準和名」
    public static func route(_ raw: String, species: [String: String] = [:], worms: [WormPreset] = []) -> AssistantIntent {
        if let command = VoiceCommand.parse(raw, worms: worms) { return .command(command) }
        let text = VoiceCommand.normalize(raw)
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        // 人から聞いた話（店先の話）は、質問ではなく記録として これまでの流れに渡す
        if has(["らしい", "そうだ", "そうです", "みたい", "って言", "と言って", "聞いた", "とのこと", "だって"]) { return .other }

        if has(["まとめ", "サマリー"]) && has(["釣行", "今日", "きょう", "仲間", "みんな", "共有", "さっき", "今回", "前回"]) && !has(["釣果情報", "ネット", "記事"]) { return .tripSummary }
        if has(["釣果情報", "ネット", "記事", "ニュース", "世間", "みんなは", "巷"]) || (has(["今週", "最近", "このところ"]) && has(["道南", "函館", "北海道", "どこで釣れ", "何が釣れてい", "何が釣れてる", "釣れている魚", "釣れてる魚"])) {
            return .feedDigest
        }
        if has(["アタリがない", "アタリが無い", "あたりがない", "当たりがない", "アタリない", "アタリなし", "釣れない", "釣れん", "渋い", "しぶい", "どうすれば", "どうしたら",
                "次どうする", "次はどう", "何をすべき", "なにをすべき", "場所を替え", "場所を変え", "移動した方", "移動したほう", "粘るべき", "ねばるべき", "次の一手"]) { return .advice }
        if has(["どこがいい", "どこが良い", "どこに行", "どこへ行", "どこ行", "おすすめの場所", "おすすめの釣り場", "計画", "行くなら", "行ける", "出発", "何時に出"]) { return .plan }

        // 魚について：名前（か「これ」）＋食べ方・持ち帰り・旬など
        let fishWords = ["食べ", "料理", "持ち帰", "もちかえ", "リリース", "逃が", "毒", "旬", "どんな魚", "生態", "さばき", "捌", "味", "おいしい", "美味", "刺身", "煮付", "塩焼"]
        if has(fishWords) {
            let named = species.keys.filter { $0.count >= 2 && text.contains($0) }.max { $0.count < $1.count }
            if let named, let name = species[named] { return .fish(name) }
            if has(["これ", "この魚", "さっきの", "今の魚", "釣れた魚"]) { return .fish("") }
        }

        // 自分の記録：過去・集計の言葉があり、これからの話ではない
        let future = has(["明日", "あした", "明後日", "あさって", "釣れそう", "これから", "週末", "来週"])
        let past = has(["去年", "昨年", "今年", "先月", "今月", "先週", "これまで", "今まで", "過去", "通算", "前回", "最大", "自己記録", "記録は", "何尾", "何匹", "一番", "いちばん",
                        "ロスト", "釣れた", "釣った", "実績", "合計", "累計", "ボウズ", "昨日", "きのう"]) || containsMonth(text) || text.contains("年の")
        let asks = has(["?", "何", "なに", "どれ", "どの", "いつ", "どこ", "どっち", "どちら", "教えて", "知りたい", "いくつ", "どのくらい", "どれくらい"])
            || text.hasSuffix("は") || text.hasSuffix("か") || text.hasSuffix("かな") || text.hasSuffix("っけ")
        if past && !future && (asks || text.count <= 14) { return .records }
        return .other
    }

    /// 「11月」のような月の指定があるか
    static func containsMonth(_ text: String) -> Bool {
        guard let r = text.range(of: "月") else { return false }
        guard r.lowerBound > text.startIndex else { return false }
        let prev = text[text.index(before: r.lowerBound)]
        return prev.isNumber && prev.isASCII
    }
}
