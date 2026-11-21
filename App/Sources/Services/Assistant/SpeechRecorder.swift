import Foundation
import AVFoundation
import Speech

/// 音声の書き起こし（F-53）。端末内の認識を優先し、マイクの音をそのまま文字にする。録音は保存しない。
@MainActor
@Observable
final class SpeechRecorder {
    private(set) var transcript = ""
    private(set) var isRecording = false
    private(set) var error: String?
    /// どこかで声の入力をしている最中か（その間は、釣行中の音声の知らせを読まない。F-70）
    static private(set) var activeCount = 0

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// マイクと音声認識の許可
    func requestPermissions() async -> Bool {
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { error = "マイクの使用を許可してください（設定 > Fog）"; return false }
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { error = "音声認識を許可してください（設定 > Fog）"; return false }
        return true
    }

    func start() async {
        guard !isRecording else { return }
        guard await requestPermissions() else { return }
        guard let recognizer, recognizer.isAvailable else { error = "音声認識が使えません"; return }
        error = nil
        transcript = ""
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            engine.prepare()
            try engine.start()
            isRecording = true
            Self.activeCount += 1
            task = recognizer.recognitionTask(with: request) { [weak self] result, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if err != nil || (result?.isFinal ?? false) { self.finish() }
                }
            }
        } catch {
            self.error = "録音を始められませんでした"
            finish()
        }
    }

    func stop() {
        request?.endAudio()
        finish()
    }

    private func finish() {
        guard isRecording || engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        task?.cancel()
        task = nil
        request = nil
        if isRecording { Self.activeCount = max(0, Self.activeCount - 1) }
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
