import Foundation
import os

/// 処理時間と固まりの記録（2026-11-09 開発者「どこでいつ時間がかかったかを記録する仕組み」）。
///
/// - `Perf.measure("名前") { }`：かかった時間を測る。50 ms を超えたら記録に残す（os_signpost にも出すので Instruments でも追える）
/// - `Perf.mark("画面を開いた")`：操作の足あと。固まりやクラッシュの直前に何をしていたかが分かる
/// - 見張り：別スレッドから 0.5 秒ごとにメインスレッドへ合図を送り、返事が 400 ms 以上遅れたら「固まり」として直前の足あとと一緒に記録する
/// - 記録は App Group の `perf.log` に追記（最大 300 行）。設定 > 診断 で見る・コピーする。前回の起動が正常に終わらなかった（クラッシュ）ことも分かる
enum Perf {
    struct Entry: Identifiable, Hashable, Sendable {
        let id = UUID()
        let at: Date
        let kind: Kind
        let name: String
        let ms: Int
        enum Kind: String, Sendable { case mark, slow, stall, launch, crash }
        var line: String {
            let f = Perf.formatter
            switch kind {
            case .mark: return "\(f.string(from: at)) ・ \(name)"
            case .slow: return "\(f.string(from: at)) ⏱ \(name) \(ms) ms"
            case .stall: return "\(f.string(from: at)) ■ 固まり \(ms) ms（直前: \(name)）"
            case .launch: return "\(f.string(from: at)) ▶ 起動"
            case .crash: return "\(f.string(from: at)) ✖ 前回は正常に終わらなかった（\(name)）"
            }
        }
    }

    nonisolated(unsafe) private static var entries: [Entry] = []
    private static let lock = NSLock()
    private static let log = Logger(subsystem: "fog", category: "perf")
    private static let signposter = OSSignposter(subsystem: "fog", category: "perf")
    nonisolated(unsafe) private static var lastMark = "起動"
    nonisolated(unsafe) private static var lastMarkAt = Date()
    static let slowThresholdMS = 50
    static let stallThresholdMS = 400
    static let maxEntries = 300
    private static let runningKey = "fog.perf.running"
    private static let lastMarkKey = "fog.perf.lastMark"
    static let formatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.timeZone = TimeZone(identifier: "Asia/Tokyo"); f.dateFormat = "M/d HH:mm:ss.SSS"; return f
    }()
    private static var fileURL: URL { FogShared.containerURL.appendingPathComponent("perf.log") }

    // MARK: 起動・終了

    /// 起動時に 1 回。前回が正常に終わっていなければ記録に残し、見張りを始める
    static func start() {
        load()
        let d = UserDefaults.standard
        if d.bool(forKey: runningKey) {
            append(Entry(at: Date(), kind: .crash, name: d.string(forKey: lastMarkKey) ?? "不明", ms: 0))
        }
        d.set(true, forKey: runningKey)
        append(Entry(at: Date(), kind: .launch, name: "", ms: 0))
        startWatchdog()
    }

    /// 背景へ行った・終了した（正常）。次に前面へ戻ったら `resume`
    static func suspend() { UserDefaults.standard.set(false, forKey: runningKey); mark("背景へ") }
    static func resume() { UserDefaults.standard.set(true, forKey: runningKey); mark("前面へ") }

    // MARK: 記録

    static func mark(_ name: String) {
        lock.lock(); lastMark = name; lastMarkAt = Date(); lock.unlock()
        UserDefaults.standard.set(name, forKey: lastMarkKey)
        append(Entry(at: Date(), kind: .mark, name: name, ms: 0))
    }

    @discardableResult
    static func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval("measure", id: signposter.makeSignpostID(), "\(name)")
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer {
            signposter.endInterval("measure", state)
            let ms = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            if ms >= slowThresholdMS { append(Entry(at: Date(), kind: .slow, name: name, ms: ms)) }
        }
        return try work()
    }

    static func measure<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            if ms >= slowThresholdMS { append(Entry(at: Date(), kind: .slow, name: name + "（非同期）", ms: ms)) }
        }
        return try await work()
    }

    private static func append(_ e: Entry) {
        lock.lock()
        entries.append(e)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        let snapshot = entries
        lock.unlock()
        switch e.kind {
        case .mark: log.debug("\(e.line, privacy: .public)")
        case .slow: log.notice("\(e.line, privacy: .public)")
        case .stall, .crash, .launch: log.error("\(e.line, privacy: .public)")
        }
        // 書き込みは 1 本の直列キューで（メインを止めない）
        writeQueue.async { persist(snapshot) }
    }

    private static let writeQueue = DispatchQueue(label: "fog.perf.write", qos: .utility)

    private static func persist(_ list: [Entry]) {
        let text = list.map { "\($0.at.timeIntervalSince1970)\t\($0.kind.rawValue)\t\($0.ms)\t\($0.name)" }.joined(separator: "\n")
        try? text.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    private static func load() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        var list: [Entry] = []
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard p.count == 4, let t = Double(p[0]), let kind = Entry.Kind(rawValue: p[1]), let ms = Int(p[2]) else { continue }
            list.append(Entry(at: Date(timeIntervalSince1970: t), kind: kind, name: p[3], ms: ms))
        }
        lock.lock(); entries = Array(list.suffix(maxEntries)); lock.unlock()
    }

    /// 設定 > 診断 用（新しい順）
    static func recent(_ n: Int = 80) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.suffix(n).reversed())
    }

    static func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    static var report: String { recent(300).reversed().map(\.line).joined(separator: "\n") }

    // MARK: 見張り（メインスレッドの固まり）

    nonisolated(unsafe) private static var watchdogStarted = false

    private static func startWatchdog() {
        guard !watchdogStarted else { return }
        watchdogStarted = true
        let thread = Thread {
            while true {
                let sent = DispatchTime.now().uptimeNanoseconds
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                // 400 ms 待っても返事が無ければ固まっている。返事が来るまで待って長さを測る
                if sem.wait(timeout: .now() + .milliseconds(stallThresholdMS)) == .timedOut {
                    sem.wait()
                    let ms = Int((DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000)
                    lock.lock(); let last = lastMark; lock.unlock()
                    append(Entry(at: Date(), kind: .stall, name: last, ms: ms))
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        thread.name = "fog.perf.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}
