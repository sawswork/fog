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

    /// まだ無い・古い升だけ取る
    func load(places: [PortWind.Place], now: Date = .now) async {
        guard !loading else { return }
        let stale = PortWind.cells(for: places).filter { (fetchedAt[$0.key] ?? .distantPast) < now.addingTimeInterval(-Self.ttl) }
        guard !stale.isEmpty else { return }
        loading = true
        defer { loading = false }
        var failure: String?
        for request in PortWind.urls(cells: stale) {
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
                failure = error.localizedDescription
            }
        }
        lastError = failure
    }
}
