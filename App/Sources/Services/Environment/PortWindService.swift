import Foundation
import CoreLocation
import WeatherKit
import Core

/// 漁港を風の弱い順に並べるための風の予報（F-68）。近くの港を約 10 km の升にまとめ、升ごとの風を取る。
/// 取得元は WeatherKit（釣り場の詳細に出る風速と同じ出どころ）。取れなかった升だけ Open-Meteo で補う。
/// 2026-11-25：はじめは Open-Meteo だけだったが、実機で「HTTP 429」（回数の上限。携帯の回線は多くの人と同じ出口を
/// 共有するので当たりやすい）になり何も出なかったので、WeatherKit を先にした。1 時間は取り直さない。保存はしない
@MainActor
@Observable
final class PortWindService {
    static let ttl: TimeInterval = 3600
    /// 同時に聞く升の数
    static let concurrency = 6

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
        let cells = stale.map { Cell(key: $0.key, center: $0.center) }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetch(cells, now: now)
        }
        inFlight = task
        await task.value
        if inFlight == task { inFlight = nil }
    }

    private struct Cell: Sendable {
        let key: String
        let center: Coordinate
    }

    private func fetch(_ cells: [Cell], now: Date) async {
        loading = true
        defer { loading = false }
        // 1. WeatherKit：升ごとに 1 回。取れた升から順に画面に出る
        var failed: [Cell] = []
        await withTaskGroup(of: (Cell, PortWind.Series?).self) { group in
            var next = 0
            while next < min(Self.concurrency, cells.count) {
                let c = cells[next]; next += 1
                group.addTask { (c, await Self.weatherKitSeries(at: c.center, now: now)) }
            }
            for await (cell, result) in group {
                if let result {
                    self.series[cell.key] = result
                    self.fetchedAt[cell.key] = now
                } else {
                    failed.append(cell)
                }
                if next < cells.count {
                    let c = cells[next]; next += 1
                    group.addTask { (c, await Self.weatherKitSeries(at: c.center, now: now)) }
                }
            }
        }
        // 2. 取れなかった升だけ Open-Meteo で補う
        var failure: String?
        if !failed.isEmpty {
            for request in PortWind.urls(cells: failed.map { (key: $0.key, center: $0.center) }) {
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
        }
        // 一部でも取れていれば、並べられるので失敗とは言わない
        let got = cells.filter { fetchedAt[$0.key] == now }.count
        lastError = got == 0 ? (failure ?? "予報を取れませんでした") : nil
        Perf.mark("港の風：\(cells.count) 升のうち \(got) 升を取得（Apple の天気で \(cells.count - failed.count)）\(failure.map { "、補いは失敗：\($0)" } ?? "")")
    }

    /// WeatherKit の 1 時間ごとの風（いまの 1 時間前から 48 時間先まで）。位置は升の中心（0.1° 単位）。取れなければ nil
    nonisolated private static func weatherKitSeries(at c: Coordinate, now: Date) async -> PortWind.Series? {
        let location = CLLocation(latitude: c.latitude, longitude: c.longitude)
        guard let hourly = try? await WeatherService.shared.weather(
            for: location, including: .hourly(startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(48 * 3600))) else { return nil }
        let items = hourly.forecast
        guard !items.isEmpty else { return nil }
        return PortWind.Series(
            times: items.map(\.date),
            speed: items.map { $0.wind.speed.converted(to: .metersPerSecond).value },
            direction: items.map { $0.wind.direction.converted(to: .degrees).value },
            gust: items.map { $0.wind.gust?.converted(to: .metersPerSecond).value })
    }
}
