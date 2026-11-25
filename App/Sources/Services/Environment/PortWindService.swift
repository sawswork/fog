import Foundation
import Core

/// 漁港を風の弱い順に並べるための風の予報（F-68）。近くの港を約 5 km の升にまとめ、升ごとの風だけを Open-Meteo に聞く。
/// 取得元は地図の風の層（F-43）と同じ。1 時間は取り直さない。保存はしない（開いている間だけ）
@MainActor
@Observable
final class PortWindService {
    static let ttl: TimeInterval = 3600

    private(set) var series: [String: PortWind.Series] = [:]
    private(set) var loading = false
    private(set) var lastError: String?
    private var fetchedAt: [String: Date] = [:]

    private var inFlight: Task<Void, Never>?

    /// まだ無い・古い升だけ取る。
    /// 通信は、呼んだ画面の処理とは切り離して走らせる。以前は画面の処理の中で通信していて、画面を開いた直後に
    /// その処理が切り替わる（港の一覧が入って作り直される）と通信ごと取り消され、「取れませんでした（cancelled）」で
    /// 何も出なかった（2026-11-25 開発者の画面）。取得の最中にもう一度呼ばれたら、終わるのを待ってから足りない分だけ取る
    func load(places: [PortWind.Place], now: Date = .now) async {
        if let running = inFlight { await running.value }
        let stale = PortWind.cells(for: places).filter { (fetchedAt[$0.key] ?? .distantPast) < now.addingTimeInterval(-Self.ttl) }
        guard !stale.isEmpty else { return }
        let requests = PortWind.urls(cells: stale)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetch(requests, now: now)
        }
        inFlight = task
        await task.value
        if inFlight == task { inFlight = nil }
    }

    private func fetch(_ requests: [(keys: [String], url: URL)], now: Date) async {
        loading = true
        defer { loading = false }
        var failure: String?
        for request in requests {
            do {
                var r = URLRequest(url: request.url)
                r.timeoutInterval = 30
                let (data, response) = try await URLSession.shared.data(for: r)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw NSError(domain: "fog.portwind", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                }
                let decoded = try PortWind.decode(data, keys: request.keys)
                if decoded.isEmpty { failure = "予報を読めませんでした" }
                for (key, value) in decoded {
                    series[key] = value
                    fetchedAt[key] = now
                }
            } catch {
                failure = (error as? URLError)?.code == .notConnectedToInternet ? "圏外です" : error.localizedDescription
            }
        }
        lastError = failure
        Perf.mark("港の風：\(requests.count) 回の取得、\(failure ?? "成功")")
    }
}
