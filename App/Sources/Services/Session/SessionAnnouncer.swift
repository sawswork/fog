import Foundation
import AVFoundation
import Core

/// 釣行中の音声の知らせ（F-70）。記録中だけ、0 分と 30 分ちょうどに、釣り場の今の時刻・釣れ率・潮・30 分後の天気を読み上げる。
/// 文は Core の `VoiceBriefing` が作り、ここは端末の読み上げ（AVSpeechSynthesizer、通信なし）で声にする。
///
/// - 画面を消していても読むので、背景での音声（`UIBackgroundModes` の `audio`）を使う
/// - 消音スイッチに関係なく、メディアの音量で読む。音楽などを流しているときは、読む間だけ音量を下げる
/// - 通話中（LINE などの通話も）でも読む：ほかの音と混ぜて出す設定にして、通話の音は止めない。声は通話の出口（受話口・スピーカー・イヤホン）から出る
/// - 既定はオフ（設定 > 通知 でオンにする）
@MainActor
final class SessionAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    /// 読む時刻から、これ以上遅れていたら読まない（端末が止まっていて、だいぶ過ぎてから動いたとき）
    static let maxLateness: TimeInterval = 5 * 60
    private static let enabledKey = "fog.voice.enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var timer: Timer?
    private var running = false
    /// 読み上げる文を作る（釣行中の釣り場について。作れなければ nil）
    var makeText: (@MainActor () async -> String?)?
    /// 声の入力（相談）の最中か。その間は読み上げない
    var isListening: (@MainActor () -> Bool)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// 釣行の開始：次の 0 分か 30 分ちょうどから読む（0 時、0 時半、1 時…）
    func start() {
        running = true
        scheduleNext()
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    /// 次のちょうどの時刻に 1 回だけ鳴るタイマーを置く。読んだら、また次を置く
    private func scheduleNext(now: Date = .now) {
        timer?.invalidate()
        let slot = VoiceBriefing.nextSlot(after: now)
        let t = Timer(fire: slot, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                // だいぶ遅れて動いたとき（端末が止まっていた）は、その回は読まない
                if Date.now.timeIntervalSince(slot) <= Self.maxLateness { await self.announce() }
                if self.running { self.scheduleNext() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// いまの内容を読む。`force` は設定の「試しに読む」用（オフでも、釣行中でなくても読む）
    func announce(force: Bool = false) async {
        guard force || (Self.isEnabled && running) else { return }
        if isListening?() == true { return }
        guard let text = await makeText?(), !text.isEmpty else { return }
        speak(text)
    }

    func speak(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        // ほかの音（音楽・ラジオ・通話）は止めずに混ぜて出す。まず「読む間だけほかを小さくする」設定で試し、
        // 通話中などでそれが通らなければ「混ぜるだけ」にする。どちらも通らなくても、読み上げは試す
        let attempts: [AVAudioSession.CategoryOptions] = [[.duckOthers, .interruptSpokenAudioAndMixWithOthers], [.mixWithOthers]]
        for options in attempts {
            do {
                try session.setCategory(.playback, mode: .voicePrompt, options: options)
                try session.setActive(true)
                break
            } catch {
                continue
            }
        }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.2
        synthesizer.speak(utterance)
        Perf.mark("音声の知らせ：\(text)")
    }

    // 読み終えたら音声の利用をやめて、ほかの音の音量を戻す
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}
