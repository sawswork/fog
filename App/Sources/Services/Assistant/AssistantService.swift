import Foundation
import os
import Core
#if canImport(FoundationModels)
import FoundationModels
#endif

/// アプリ内の相談役（F-53）。端末内の言語モデル（Apple Intelligence）に、アプリの記録を渡して日本語で答えさせる。
/// 店先で聞いた話（音声の書き起こし）は場所ごとに整理して地図のメモにする。通信はしない。
@MainActor
@Observable
final class AssistantService {
    struct Message: Identifiable, Hashable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        /// 共有できる文（釣行のまとめなど）。あれば吹き出しの下に共有ボタンを出す
        var share: String? = nil
    }

    private(set) var messages: [Message] = []
    private(set) var isResponding = false
    private static let log = Logger(subsystem: "fog", category: "assistant")

    #if canImport(FoundationModels)
    private var session: LanguageModelSession?
    #endif

    /// 使えないときの理由（使えるときは nil）
    var unavailableReason: String? {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "この端末では Apple Intelligence が使えません"
            case .appleIntelligenceNotEnabled: return "設定 > Apple Intelligence と Siri をオンにしてください"
            case .modelNotReady: return "モデルを準備中です。しばらくしてからもう一度"
            @unknown default: return "Apple Intelligence が使えません"
            }
        }
        #else
        return "この OS では使えません"
        #endif
    }

    private static let instructions = """
    あなたは釣りアプリ「Fog」の相談役です。渡された【アプリの記録】を根拠に、日本語で短く（3 文以内を目安に）答えます。
    「釣れそうか」「どう？」と聞かれたら、記録の中の「釣り場ごとの予報」（釣れ率 0〜100、最良の時間帯、天気）を使って、数値と時間帯を挙げて答えます。
    聞かれた日や場所の予報が記録に無いときだけ「予報がありません」と言います。推測で数値や魚種を作らないでください。釣りの一般的な助言は求められたときだけ添えます。
    """

    func clear() {
        messages = []
        #if canImport(FoundationModels)
        session = nil
        #endif
    }

    /// 質問に答える。`context` はアプリの記録の要約（毎回最新を渡す）
    func ask(_ text: String, context: String) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isResponding else { return }
        messages.append(Message(role: .user, text: q))
        if let reason = unavailableReason {
            messages.append(Message(role: .assistant, text: reason))
            return
        }
        isResponding = true
        defer { isResponding = false }
        #if canImport(FoundationModels)
        if session == nil { session = LanguageModelSession(instructions: Self.instructions) }
        let prompt = "【アプリの記録】\n\(context)\n\n【質問】\n\(q)"
        do {
            let response = try await session!.respond(to: prompt)
            messages.append(Message(role: .assistant, text: response.content.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch {
            Self.log.notice("assistant failed: \(error.localizedDescription, privacy: .public)")
            // 文脈が長すぎたときは会話を新しくして 1 回だけやり直す
            session = LanguageModelSession(instructions: Self.instructions)
            if let response = try? await session!.respond(to: prompt) {
                messages.append(Message(role: .assistant, text: response.content.trimmingCharacters(in: .whitespacesAndNewlines)))
            } else {
                messages.append(Message(role: .assistant, text: "うまく答えられませんでした。短く言い換えてもう一度試してください"))
            }
        }
        #endif
    }

    /// 店先で聞いた話を場所ごとに整理した結果
    struct ShopItem: Hashable {
        var place: String
        var summary: String
        var species: [String]
    }

    /// 書き起こし（または打ち込んだ話）を場所ごとの要点に整理する。整理できなければ全体を 1 件にする
    func organizeShopTalk(_ transcript: String, hintPlaces: [String]) async -> [ShopItem] {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        #if canImport(FoundationModels)
        guard unavailableReason == nil else { return [ShopItem(place: "", summary: t, species: [])] }
        let instructions = """
        あなたは釣具店や漁港で聞いた話をメモに整理する係です。入力は会話の書き起こしです。
        場所（漁港名・地名）ごとに項目を分け、要点を 1〜2 文の日本語でまとめ、出てきた魚種を列挙します。
        場所が分からない項目は place を空にします。話に無いことは書かないでください。
        よく出る場所の名前：\(hintPlaces.prefix(30).joined(separator: "、"))
        """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "書き起こし:\n\(t)", generating: ShopTalk.self)
            let items = response.content.items.map { ShopItem(place: $0.place.trimmingCharacters(in: .whitespaces), summary: $0.summary.trimmingCharacters(in: .whitespacesAndNewlines), species: $0.species) }
                .filter { !$0.summary.isEmpty }
            return items.isEmpty ? [ShopItem(place: "", summary: t, species: [])] : items
        } catch {
            Self.log.notice("organize failed: \(error.localizedDescription, privacy: .public)")
            return [ShopItem(place: "", summary: t, species: [])]
        }
        #else
        return [ShopItem(place: "", summary: t, species: [])]
        #endif
    }

    /// 入力が「質問」か「記録したい情報（店で聞いた話など）」かを判定する。言語モデルが使えなければ言葉で判定
    enum Intent { case question, record }

    func classify(_ text: String) async -> Intent {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #if canImport(FoundationModels)
        if unavailableReason == nil {
            let instructions = """
            入力を 2 種類に分けます。question：釣りアプリの記録や予報について知りたい質問（例「明日の鹿部はどう？」「先月の釣果は？」）。
            record：釣具店や漁港で聞いた話・自分の覚え書きなど、アプリに残したい情報（例「鹿部で先週ホッケが好調らしい」「店の人がサビキは朝がいいと言ってた」）。
            迷ったら、文末が疑問なら question、事実や伝聞なら record にします。
            """
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: "入力:\n\(t)", generating: IntentGuess.self)
                return response.content.kind.lowercased().hasPrefix("r") ? .record : .question
            } catch {
                Self.log.notice("classify failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
        return Self.heuristicIntent(t)
    }

    nonisolated static func heuristicIntent(_ t: String) -> Intent {
        let questionMarks = ["？", "?", "どう", "教えて", "かな", "ですか", "何が", "いつ", "どこ", "いくつ", "何尾", "釣れる"]
        let recordMarks = ["らしい", "と言って", "って言って", "聞いた", "好調", "釣れてる", "釣れている", "そうだ", "とのこと", "だって", "メモ", "覚え"]
        if questionMarks.contains(where: { t.hasSuffix($0) || t.contains($0 + "？") || t.contains($0 + "?") }) { return .question }
        if recordMarks.contains(where: { t.contains($0) }) { return .record }
        return t.hasSuffix("？") || t.hasSuffix("?") ? .question : (t.count > 25 ? .record : .question)
    }

    func append(assistant text: String, share: String? = nil) { messages.append(Message(role: .assistant, text: text, share: share)) }

    /// アプリが計算した「事実の行」から、質問に合うところを選んで短く答えさせる（F-65）。
    /// 言語モデルが使えない・失敗した・事実に無い数字を言ったときは、`fallback`（事実の行そのまま）を返す。数字は作らせない
    func rephrase(question: String, facts: String, fallback: String) async -> String {
        #if canImport(FoundationModels)
        guard unavailableReason == nil else { return fallback }
        let instructions = """
        あなたは釣りアプリ「Fog」の相談役です。【事実】はアプリが記録から計算した結果です。【質問】に、【事実】に書いてあることだけを使って日本語で短く（3 文以内）答えます。
        数字・魚の名前・場所・日付は【事実】のものをそのまま使い、足したり変えたりしません。【事実】に無いことは「記録にありません」と言います。前置きや挨拶は要りません。
        """
        isResponding = true
        defer { isResponding = false }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "【事実】\n\(facts)\n\n【質問】\n\(question)")
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, AnswerCheck.isGrounded(text, facts: facts + "\n" + question) { return text }
            Self.log.notice("rephrase rejected (empty or ungrounded numbers)")
        } catch {
            Self.log.notice("rephrase failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
        return fallback
    }
    func append(user text: String) { messages.append(Message(role: .user, text: text)) }
}

#if canImport(FoundationModels)
/// 入力の種類（言語モデルに判定させる型）
@Generable
struct IntentGuess {
    @Guide(description: "question か record のどちらか")
    var kind: String
}

/// 店先の話の整理結果（言語モデルに作らせる型）
@Generable
struct ShopTalk {
    @Guide(description: "聞いた話を場所ごとにまとめた項目。場所が同じ話は 1 つにまとめる")
    var items: [ShopTalkItem]
}

@Generable
struct ShopTalkItem {
    @Guide(description: "場所の名前（漁港名・地名）。分からなければ空文字")
    var place: String
    @Guide(description: "その場所について聞いた要点を 1〜2 文の日本語で")
    var summary: String
    @Guide(description: "話に出てきた魚の名前。無ければ空")
    var species: [String]
}
#endif
