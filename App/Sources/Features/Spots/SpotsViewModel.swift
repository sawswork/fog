import Foundation
import SwiftUI
import MapKit
import Core

@MainActor
@Observable
final class SpotsViewModel {
    struct Card: Identifiable {
        let spot: Spot
        let stats: Analytics.SpotStats
        let score: Int
        let distanceM: Double?
        /// 地図検索で見つけた漁港（まだストアに無い）。「登録」で自分の釣り場になる
        var isCandidate: Bool = false
        /// 自分の釣果と針ロストの位置（カードの航空写真に点で出す。F-47）
        var catchPoints: [Coordinate] = []
        var lossPoints: [Coordinate] = []
        var id: UUID { spot.id }
    }

    private(set) var cards: [Card] = []
    /// 表示中の地図範囲の漁港・港（未登録）。同梱データ（国土数値情報）＋地図検索の補完。カードにも並べる
    var portCandidates: [Card] {
        catalogPorts + searchPorts.filter { sp in !catalogPorts.contains { Geo.distanceMeters($0.spot.coordinate, sp.spot.coordinate) < 500 } }
    }
    private var catalogPorts: [Card] = []
    private var searchPorts: [Card] = []
    /// 現在地（`LocationService` の最新の位置。地図を開いている間は前面の更新で動く）
    var currentLocation: Coordinate? { services?.location.lastFix?.coordinate }
    private var services: AppServices?
    /// 車での所要時間・距離（MapKit の経路検索。F-56）。鍵は「出発地（500 m 単位）→釣り場」
    private(set) var etas: [String: DriveETA] = [:]
    private var etaInFlight: Set<String> = []
    /// 表示中の経路（F-57）
    private(set) var route: MKRoute?
    private(set) var routeTarget: Spot?
    private(set) var routeError: String?
    private let cache = AnalysisCache()
    private var candidateIDs: [String: UUID] = [:]
    private let portCatalog = PortCatalog.bundled()

    /// 近く（300 m）の登録釣り場か港の名前。メモの場所欄の初期値に使う（F-52）
    func placeName(near c: Coordinate) -> String? {
        if let spot = allCards.map(\.spot).filter({ $0.coordinate.isPlausible }).min(by: { Geo.distanceMeters($0.coordinate, c) < Geo.distanceMeters($1.coordinate, c) }),
           Geo.distanceMeters(spot.coordinate, c) <= 300 { return spot.name }
        return portCatalog.nearest(to: c, within: 300)?.name
    }
    private var lastSearchedRegion: MKCoordinateRegion?
    private var searchTask: Task<Void, Never>?

    /// 登録済み＋候補（近い順）
    var allCards: [Card] { (cards + portCandidates).sorted { ($0.distanceM ?? .infinity) < ($1.distanceM ?? .infinity) } }

    func attach(_ services: AppServices) {
        self.services = services
        refresh()
    }

    func refresh() {
        guard let services else { return }
        let store = services.store
        let spots = (try? store.spots()) ?? []
        let sessions = (try? store.sessions()) ?? []
        let bySpot = Analytics.statsBySpot(sessions: sessions)
        let now = Date()
        let engine = scoreEngine()
        let currentLocation = self.currentLocation
        cards = spots.map { spot in
            let env = services.environment.scoreSnapshot(at: now, coordinate: spot.coordinate)
            let score = engine.score(ScoreInput(at: now, coordinate: spot.coordinate, env: env)).score
            let stats = bySpot[spot.id] ?? Analytics.spotStats(sessions: [])
            let d = currentLocation.map { Geo.distanceMeters($0, spot.coordinate) }
            let mine = sessions.filter { $0.spotID == spot.id }
            return Card(spot: spot, stats: stats, score: score, distanceM: d,
                        catchPoints: mine.flatMap(\.catches).map(\.coordinate).filter(\.isPlausible),
                        lossPoints: mine.flatMap(\.hookEvents).filter { $0.kind == .lost }.map(\.coordinate).filter(\.isPlausible))
        }.sorted { ($0.distanceM ?? .infinity) < ($1.distanceM ?? .infinity) }
    }

    // MARK: 漁港の自動表示（§7「自動検出した未登録の漁港・岸壁はグレーの点」）

    /// 地図の表示範囲が変わったら、その範囲の漁港・港を MapKit で探して候補にする。範囲が広すぎるときは探さない。
    func searchPorts(in region: MKCoordinateRegion) {
        guard region.span.latitudeDelta < 1.5 else { return }
        // 同梱の港データ（国土数値情報）を先に置く。通信なしで確実に出る
        catalogCandidates(in: region)
        if let last = lastSearchedRegion {
            let moved = Geo.distanceMeters(Coordinate(latitude: last.center.latitude, longitude: last.center.longitude),
                                           Coordinate(latitude: region.center.latitude, longitude: region.center.longitude))
            let spanRatio = region.span.latitudeDelta / max(0.0001, last.span.latitudeDelta)
            if moved < region.span.latitudeDelta * 111_000 * 0.2, spanRatio > 0.6, spanRatio < 1.6 { return }
        }
        lastSearchedRegion = region
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            var found: [MKMapItem] = []
            for query in ["漁港", "港"] {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.region = region
                request.resultTypes = .pointOfInterest
                if let items = try? await MKLocalSearch(request: request).start().mapItems { found += items }
                if Task.isCancelled { return }
            }
            await MainActor.run { self?.setPortCandidates(found) }
        }
    }

    /// 同梱の港データから表示範囲の候補を作る
    private func catalogCandidates(in region: MKCoordinateRegion) {
        guard let services, !portCatalog.isEmpty else { return }
        let latR = (region.center.latitude - region.span.latitudeDelta / 2)...(region.center.latitude + region.span.latitudeDelta / 2)
        let lonR = (region.center.longitude - region.span.longitudeDelta / 2)...(region.center.longitude + region.span.longitudeDelta / 2)
        let existing = (try? services.store.spots()) ?? []
        let engine = scoreEngine()
        let now = Date()
        var out: [Card] = []
        for port in portCatalog.ports(latitude: latR, longitude: lonR, limit: 60) {
            let c = port.coordinate
            if existing.contains(where: { Geo.distanceMeters($0.coordinate, c) < 300 }) { continue }
            let key = "\(port.name)@\(Int(c.latitude * 1000)),\(Int(c.longitude * 1000))"
            let id = candidateIDs[key] ?? UUID()
            candidateIDs[key] = id
            let env = services.environment.scoreSnapshot(at: now, coordinate: c)
            let score = engine.score(ScoreInput(at: now, coordinate: c, env: env)).score
            out.append(Card(spot: Spot(id: id, name: port.name, coordinate: c, isRegistered: false), stats: Analytics.spotStats(sessions: []), score: score,
                            distanceM: currentLocation.map { Geo.distanceMeters($0, c) }, isCandidate: true))
        }
        catalogPorts = out
    }

    // MARK: 釣果情報のピン（F-44）

    /// RSS の記事から取り出した「どこで何が釣れたか」。場所は同梱の港名と登録釣り場、魚種は図鑑の名前と別名
    func feedPins() -> [FeedCatchExtractor.Pin] {
        guard let services else { return [] }
        let spots = ((try? services.store.spots()) ?? []).filter { $0.isRegistered && $0.coordinate.isPlausible }.map { (name: $0.name, coordinate: $0.coordinate) }
        let near = currentLocation ?? spots.first?.coordinate
        let places = FeedCatchExtractor.places(spots: spots, ports: portCatalog.ports, near: near)
        let words = FeedCatchExtractor.speciesWords((try? services.store.species()) ?? Species.initialCatalog)
        var catches = services.feeds.items.flatMap { FeedCatchExtractor.extract($0, places: places, speciesWords: words) }
        // 仲間の釣果（F-54）も同じピンに載せる（場所は釣り場名、座標は撮影位置）
        catches += services.party.others.filter { $0.coordinate.isPlausible }.map { $0.feedCatch() }
        return FeedCatchExtractor.pins(catches)
    }

    // MARK: 車の所要時間・距離（F-56）と経路（F-57）

    struct DriveETA: Sendable { let seconds: TimeInterval; let meters: Double; let at: Date }

    private func etaKey(from origin: Coordinate, to spot: Spot) -> String {
        "\(Int(origin.latitude * 200)),\(Int(origin.longitude * 200))>\(spot.id.uuidString)"
    }

    /// 取得済みの所要時間（無ければ nil。`requestETA` で取りに行く）
    func eta(for spot: Spot) -> DriveETA? {
        guard let origin = currentLocation else { return nil }
        return etas[etaKey(from: origin, to: spot)]
    }

    /// MapKit に車の所要時間を聞く（同じ出発地・釣り場は 1 回だけ。同時に 3 件まで、圏外なら黙って諦める）
    func requestETA(for spot: Spot) async {
        guard let origin = currentLocation, spot.coordinate.isPlausible, Geo.distanceMeters(origin, spot.coordinate) > 200 else { return }
        let key = etaKey(from: origin, to: spot)
        guard etas[key] == nil, !etaInFlight.contains(key), etaInFlight.count < 3 else { return }
        etaInFlight.insert(key)
        defer { etaInFlight.remove(key) }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.cl))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: spot.coordinate.cl))
        request.transportType = .automobile
        guard let r = try? await MKDirections(request: request).calculateETA() else { return }
        etas[key] = DriveETA(seconds: r.expectedTravelTime, meters: r.distance, at: Date())
        if etas.count > 200 { etas = etas.filter { Date().timeIntervalSince($0.value.at) < 3600 } }
    }

    static func etaText(_ e: DriveETA) -> String {
        let m = Int((e.seconds / 60).rounded())
        let time = m >= 60 ? "\(m / 60)時間\(m % 60 == 0 ? "" : "\(m % 60)分")" : "\(m)分"
        let km = e.meters >= 10_000 ? String(format: "%.0f km", e.meters / 1000) : String(format: "%.1f km", e.meters / 1000)
        return "車 \(time) · \(km)"
    }

    /// 現在地からの車の経路を地図に出す（同じ釣り場をもう一度なら消す）
    func toggleRoute(to spot: Spot) async {
        if routeTarget?.id == spot.id { clearRoute(); return }
        guard let origin = currentLocation else { routeError = "現在地が分かりません"; return }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.cl))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: spot.coordinate.cl))
        request.transportType = .automobile
        do {
            let response = try await MKDirections(request: request).calculate()
            route = response.routes.first
            routeTarget = spot
            routeError = route == nil ? "経路が見つかりません" : nil
            if let r = route { etas[etaKey(from: origin, to: spot)] = DriveETA(seconds: r.expectedTravelTime, meters: r.distance, at: Date()) }
        } catch {
            route = nil; routeTarget = nil
            routeError = "経路を取れません（圏外）"
        }
    }

    func clearRoute() { route = nil; routeTarget = nil; routeError = nil }

    /// Apple のマップで経路案内を始める（ターンバイターンはマップに任せる。F-57）
    static func openInMaps(_ spot: Spot) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: spot.coordinate.cl))
        item.name = spot.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    // MARK: 釣り場の比較（F-30）

    struct CompareRow: Identifiable {
        let spot: Spot
        let maxScore: Int
        let windowStart: Date?
        let windowEnd: Date?
        let conditionCode: String?
        let distanceM: Double?
        var id: UUID { spot.id }
    }

    /// 登録した釣り場ごとに、その日（`dayOffset` 日後）の最高釣れ率と最良の時間帯を出す。釣れ率の高い順
    func compare(dayOffset: Int) async -> [CompareRow] {
        guard let services else { return [] }
        let env = services.environment
        let tz = TimeZone(identifier: "Asia/Tokyo") ?? .current
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let now = Date()
        let start = cal.startOfDay(for: now).addingTimeInterval(Double(dayOffset) * 86_400)
        let end = start.addingTimeInterval(86_400)
        let engine = scoreEngine()
        let spots = ((try? services.store.spots()) ?? []).filter { $0.isRegistered && $0.coordinate.isPlausible }
        var rows: [CompareRow] = []
        for spot in spots.prefix(12) {
            await env.refreshIfNeeded(at: spot.coordinate, now: now)
            let tide = env.tideStation(near: spot.coordinate).map { TideEngine(station: $0) }
            let extremes = tide?.extremes(from: start.addingTimeInterval(-6 * 3600), to: end.addingTimeInterval(6 * 3600)) ?? []
            let builder = env.builder(for: spot.coordinate)
            let inputs = env.inputs(for: spot.coordinate)
            let horizon = env.forecastHorizon(for: spot.coordinate)
            let points = ScoreTimeline.compute(engine: engine, coordinate: spot.coordinate, from: start, to: end, stepMinutes: 15, timeZone: tz) { t in
                var e = builder.build(at: t, coordinate: spot.coordinate, inputs: inputs, tide: tide, extremes: extremes)
                if let h = horizon, t > h { e.isForecast = true }
                return e
            }
            let window = ScoreTimeline.bestWindow(points)
            let noon = start.addingTimeInterval(12 * 3600)
            let beyond = horizon.map { noon > $0 } ?? true
            let cond = beyond ? nil : env.snapshot(at: noon, coordinate: spot.coordinate).conditionCode
            rows.append(CompareRow(spot: spot, maxScore: window?.maxScore ?? (points.map(\.score).max() ?? 0), windowStart: window?.start, windowEnd: window?.end,
                                   conditionCode: cond, distanceM: currentLocation.map { Geo.distanceMeters($0, spot.coordinate) }))
        }
        return rows.sorted { $0.maxScore > $1.maxScore }
    }

    /// 自分データの重み付きエンジン（他の人の魚は学習に入れない。F-54）。ストアの版が同じ間は使い回す
    private func scoreEngine() -> ScoreEngine {
        guard let services else { return ScoreEngine() }
        let personal = cache.value("personalModel", store: services.store) {
            let sessions = (try? services.store.ownSessions()) ?? []
            let spots = (try? services.store.spots()) ?? []
            return PersonalModel.learn(from: sessions.filter { !$0.isActive }, coordinateOf: { s in spots.first { $0.id == s.spotID }?.coordinate })
        }
        return ScoreEngine(personal: personal.total.hours >= 1 ? personal : nil)
    }

    private func setPortCandidates(_ items: [MKMapItem]) {
        guard let services else { return }
        let existing = (try? services.store.spots()) ?? []
        let engine = scoreEngine()
        let now = Date()
        let currentLocation = self.currentLocation
        var out: [Card] = []
        for item in items {
            guard let name = item.name, Self.looksLikePort(name: name, category: item.pointOfInterestCategory) else { continue }
            let c = Coordinate(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
            if existing.contains(where: { Geo.distanceMeters($0.coordinate, c) < 300 }) { continue }
            if out.contains(where: { Geo.distanceMeters($0.spot.coordinate, c) < 300 }) { continue }
            let key = "\(name)@\(Int(c.latitude * 1000)),\(Int(c.longitude * 1000))"
            let id = candidateIDs[key] ?? UUID()
            candidateIDs[key] = id
            let env = services.environment.scoreSnapshot(at: now, coordinate: c)
            let score = engine.score(ScoreInput(at: now, coordinate: c, env: env)).score
            let spot = Spot(id: id, name: name, coordinate: c, isRegistered: false)
            out.append(Card(spot: spot, stats: Analytics.spotStats(sessions: []), score: score,
                            distanceM: currentLocation.map { Geo.distanceMeters($0, c) }, isCandidate: true))
        }
        searchPorts = out
    }

    /// 名前が「〜漁港」「〜港」「〜岸壁」「〜埠頭」「〜防波堤」で終わるものだけを漁港とみなす。
    /// 「〜漁港緑地」「〜港店」「〜港前」のような店・公園・バス停・交差点は除く。マリーナ分類はそのまま通す。
    static func looksLikePort(name: String, category: MKPointOfInterestCategory?) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // 店・施設・交通の名前を除く（マリーナ分類でも名前で判断する。ボート乗り場やスポーツ店が紛れるため）
        let excluded = ["店", "緑地", "公園", "駅", "前", "通", "線", "バス", "停", "入口", "交差点", "会社", "会館", "センター", "市場", "組合", "乗り場", "乗場",
                        "事務所", "倉庫", "工場", "ビル", "ホテル", "旅館", "民宿", "食堂", "レストラン", "カフェ", "居酒屋", "寿司", "鮨", "屋", "亭", "温泉", "橋", "トンネル",
                        "駐車場", "学校", "病院", "郵便局", "神社", "寺", "スポーツ", "ショップ", "釣具", "水産", "株式", "有限", "サービス", "クラブ", "教室", "こちら", "とれたて"]
        if excluded.contains(where: { trimmed.contains($0) }) { return false }
        guard trimmed.count <= 12 else { return false }
        let suffixes = ["漁港", "港", "岸壁", "埠頭", "ふ頭", "防波堤", "波止", "堤防", "桟橋", "築港", "船だまり", "船溜", "船溜り"]
        return suffixes.contains { trimmed.hasSuffix($0) }
    }

    /// 候補の漁港を自分の釣り場として登録する（よく行く漁港）。
    func register(_ card: Card) {
        guard let services else { return }
        var spot = card.spot
        spot.isRegistered = true
        spot.createdAt = .now
        try? services.store.upsert(spot)
        catalogPorts.removeAll { $0.id == card.id }
        searchPorts.removeAll { $0.id == card.id }
        refresh()
    }

    /// 検索結果から未登録の候補を置く（釣行が始まれば登録済みになる）。
    func addCandidate(name: String, coordinate: Coordinate) {
        guard let services else { return }
        let existing = (try? services.store.spots()) ?? []
        if existing.contains(where: { Geo.distanceMeters($0.coordinate, coordinate) < 300 }) { refresh(); return }
        try? services.store.upsert(Spot(name: name, coordinate: coordinate, isRegistered: false))
        refresh()
    }

    func selectForHome(_ spot: Spot) {
        guard spot.coordinate.isPlausible else { return }
        UserDefaults.standard.set(spot.id.uuidString, forKey: "fog.homeSpotID")
    }

    func rename(_ spot: Spot, to name: String) {
        guard let services else { return }
        var s = spot
        s.name = name
        try? services.store.upsert(s)
        refresh()
    }

    func delete(_ spot: Spot) {
        guard let services else { return }
        try? services.store.deleteSpot(id: spot.id)
        refresh()
    }
}
