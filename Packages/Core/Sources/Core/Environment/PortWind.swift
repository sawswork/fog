import Foundation

/// 漁港を風の弱い順に並べる（F-68）。近くの港の風の予報をまとめて取り、選んだ時刻の風速で並べる。
///
/// 近い港は同じ予報の升に入るので、港の位置を 0.05°（約 5 km）の格子に寄せて、升ごとに 1 回だけ聞く。
/// 予報は気象モデルの値で、港の向きや地形による風裏は入っていない（並びは「その一帯の風の強さ」の目安）。
public enum PortWind {
    /// 予報を聞く升の刻み（度）
    public static let cellDeg = 0.05

    /// 1 つの升の風の予報（1 時間刻み）
    public struct Series: Hashable, Sendable, Codable {
        public var times: [Date]
        /// 風速（m/s）
        public var speed: [Double?]
        /// 風向（度。風が吹いてくる向き。北 0°、時計回り）
        public var direction: [Double?]
        /// 最大瞬間風速（m/s）
        public var gust: [Double?]

        public init(times: [Date], speed: [Double?], direction: [Double?], gust: [Double?]) {
            self.times = times; self.speed = speed; self.direction = direction; self.gust = gust
        }

        /// その時刻の風。風速と瞬間は前後の時刻から直線で補間し、風向は近いほうの時刻の値。範囲の外や値が無ければ nil
        public func sample(at date: Date) -> Sample? {
            guard let first = times.first, let last = times.last, date >= first.addingTimeInterval(-1800), date <= last.addingTimeInterval(1800) else { return nil }
            // date 以下で最後の時刻
            var i = 0
            for (k, t) in times.enumerated() where t <= date { i = k }
            let j = min(i + 1, times.count - 1)
            let span = times[j].timeIntervalSince(times[i])
            let f = span > 0 ? min(1, max(0, date.timeIntervalSince(times[i]) / span)) : 0
            func value(_ a: [Double?]) -> Double? {
                let x = i < a.count ? a[i] : nil, y = j < a.count ? a[j] : nil
                switch (x, y) {
                case let (x?, y?): return x + (y - x) * f
                case let (x?, nil): return x
                case let (nil, y?): return y
                default: return nil
                }
            }
            guard let speed = value(speed) else { return nil }
            let near = f < 0.5 ? i : j
            let dir = (near < direction.count ? direction[near] : nil) ?? (i < direction.count ? direction[i] : nil)
            return Sample(speedMS: speed, directionDeg: dir, gustMS: value(gust))
        }
    }

    public struct Sample: Hashable, Sendable {
        public var speedMS: Double
        public var directionDeg: Double?
        public var gustMS: Double?
        public init(speedMS: Double, directionDeg: Double?, gustMS: Double?) { self.speedMS = speedMS; self.directionDeg = directionDeg; self.gustMS = gustMS }
    }

    /// 並べる場所（港、または登録した釣り場）
    public struct Place: Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var coordinate: Coordinate
        /// 登録した釣り場か
        public var isSpot: Bool
        public init(id: String, name: String, coordinate: Coordinate, isSpot: Bool) { self.id = id; self.name = name; self.coordinate = coordinate; self.isSpot = isSpot }
    }

    public struct Row: Hashable, Sendable, Identifiable {
        public var place: Place
        public var wind: Sample
        public var distanceM: Double?
        public var id: String { place.id }
    }

    /// 升の鍵（「41.80,140.65」）と、その中心
    public static func cellKey(for c: Coordinate) -> String {
        let p = cellCenter(for: c)
        return String(format: "%.2f,%.2f", p.latitude, p.longitude)
    }

    public static func cellCenter(for c: Coordinate) -> Coordinate {
        func snap(_ x: Double) -> Double { ((x / cellDeg).rounded() * cellDeg * 100).rounded() / 100 }
        return Coordinate(latitude: snap(c.latitude), longitude: snap(c.longitude))
    }

    /// 並べる場所：登録した釣り場と、`origin` から `radiusM` 以内の港。釣り場のそば（500 m 以内）の港は釣り場にまとめる。
    /// 近い順に `limit` か所まで
    public static func places(spots: [(id: UUID, name: String, coordinate: Coordinate)], ports: [Port], origin: Coordinate, radiusM: Double, limit: Int = 120) -> [Place] {
        var out: [Place] = []
        for s in spots where s.coordinate.isPlausible && Geo.distanceMeters(s.coordinate, origin) <= radiusM {
            out.append(Place(id: "spot:" + s.id.uuidString, name: s.name, coordinate: s.coordinate, isSpot: true))
        }
        let spotCoordinates = out.map(\.coordinate)
        var seenNames = Set<String>()
        for p in ports where Geo.distanceMeters(p.coordinate, origin) <= radiusM {
            if spotCoordinates.contains(where: { Geo.distanceMeters($0, p.coordinate) <= 500 }) { continue }
            // 同じ名前の港（漁港と港湾の両方に載っているもの）は 1 つに
            guard seenNames.insert(p.name).inserted else { continue }
            out.append(Place(id: "port:" + p.id, name: p.name, coordinate: p.coordinate, isSpot: false))
        }
        return Array(out.sorted { Geo.distanceMeters($0.coordinate, origin) < Geo.distanceMeters($1.coordinate, origin) }.prefix(max(0, limit)))
    }

    /// 予報を聞く升（重複なし。鍵の順）
    public static func cells(for places: [Place]) -> [(key: String, center: Coordinate)] {
        var byKey: [String: Coordinate] = [:]
        for p in places { byKey[cellKey(for: p.coordinate)] = cellCenter(for: p.coordinate) }
        return byKey.sorted { $0.key < $1.key }.map { (key: $0.key, center: $0.value) }
    }

    /// 風の弱い順。同じ風速なら瞬間の弱い順、それも同じなら近い順。予報の無い場所は入れない
    public static func rank(places: [Place], series: [String: Series], at date: Date, origin: Coordinate?) -> [Row] {
        let rows: [Row] = places.compactMap { p in
            guard let wind = series[cellKey(for: p.coordinate)]?.sample(at: date) else { return nil }
            return Row(place: p, wind: wind, distanceM: origin.map { Geo.distanceMeters($0, p.coordinate) })
        }
        return rows.sorted { a, b in
            if abs(a.wind.speedMS - b.wind.speedMS) >= 0.05 { return a.wind.speedMS < b.wind.speedMS }
            let ga = a.wind.gustMS ?? .infinity, gb = b.wind.gustMS ?? .infinity
            if abs(ga - gb) >= 0.05 { return ga < gb }
            return (a.distanceM ?? .infinity, a.place.name) < (b.distanceM ?? .infinity, b.place.name)
        }
    }

    // MARK: 取得（Open-Meteo の予報。地図の風の層と同じ取得元）

    /// 風だけを、升の中心ごとに聞く URL。1 回に `chunk` 地点まで
    public static func urls(cells: [(key: String, center: Coordinate)], forecastDays: Int = 3, chunk: Int = 100) -> [(keys: [String], url: URL)] {
        var out: [(keys: [String], url: URL)] = []
        var start = 0
        while start < cells.count {
            let part = Array(cells[start..<min(start + max(1, chunk), cells.count)])
            var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            comps.queryItems = [
                URLQueryItem(name: "latitude", value: part.map { String(format: "%.2f", $0.center.latitude) }.joined(separator: ",")),
                URLQueryItem(name: "longitude", value: part.map { String(format: "%.2f", $0.center.longitude) }.joined(separator: ",")),
                URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_direction_10m,wind_gusts_10m"),
                URLQueryItem(name: "wind_speed_unit", value: "ms"),
                URLQueryItem(name: "forecast_days", value: String(forecastDays)),
                URLQueryItem(name: "timeformat", value: "unixtime"), URLQueryItem(name: "timezone", value: "UTC"),
            ]
            out.append((keys: part.map { $0.key }, url: comps.url!))
            start += part.count
        }
        return out
    }

    /// 応答を升ごとの予報にする。応答の地点は聞いた順に並んでいる（数が合わなければ空）
    public static func decode(_ data: Data, keys: [String]) throws -> [String: Series] {
        let points = try OpenMeteoGrid.decodePoints(data)
        guard points.count == keys.count else { return [:] }
        var out: [String: Series] = [:]
        for (key, p) in zip(keys, points) {
            out[key] = Series(times: p.times, speed: p.values[.windSpeed] ?? [], direction: p.values[.windDirection] ?? [], gust: p.values[.windGust] ?? [])
        }
        return out
    }
}
