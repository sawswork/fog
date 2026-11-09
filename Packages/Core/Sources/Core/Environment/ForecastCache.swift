import Foundation

/// 釣り場ごとの予報キャッシュ（圏外でも §2 の項目を組み立てるため）。
/// 位置は 0.01°（約 1 km）に丸めたキーで持つ。保存は App 側（JSON ファイル）。
public struct ForecastCache: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var coordinate: Coordinate
        public var weatherFetchedAt: Date?
        public var weather: [WeatherSample]
        public var marineFetchedAt: Date?
        /// 実際に値が返った海上格子点（漁港内の座標は陸扱いになるため）
        public var marineGrid: Coordinate?
        public var marine: [MarineSample]

        public init(coordinate: Coordinate) {
            self.coordinate = coordinate; weather = []; marine = []
        }
    }

    public var entries: [String: Entry]

    public init() { entries = [:] }

    public static func key(for coordinate: Coordinate) -> String {
        String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
    }

    public func entry(for coordinate: Coordinate) -> Entry? { entries[Self.key(for: coordinate)] }

    public mutating func update(_ coordinate: Coordinate, _ body: (inout Entry) -> Void) {
        let k = Self.key(for: coordinate)
        var e = entries[k] ?? Entry(coordinate: coordinate)
        body(&e)
        entries[k] = e
    }

    /// 予報を差し替える。同じ時刻の実況（isForecast == false）は残す。
    public mutating func mergeWeather(_ coordinate: Coordinate, samples: [WeatherSample], fetchedAt: Date) {
        update(coordinate) { e in
            var byHour: [Date: WeatherSample] = [:]
            for s in e.weather where !s.isForecast { byHour[s.at] = s }
            for s in samples {
                if let existing = byHour[s.at], !existing.isForecast, s.isForecast { continue }
                byHour[s.at] = s
            }
            // 古いデータは落とす（過去 48 時間より前）
            let cutoff = fetchedAt.addingTimeInterval(-48 * 3600)
            e.weather = byHour.values.filter { $0.at >= cutoff }.sorted { $0.at < $1.at }
            e.weatherFetchedAt = fetchedAt
        }
    }

    public mutating func mergeMarine(_ coordinate: Coordinate, grid: Coordinate, samples: [MarineSample], fetchedAt: Date) {
        update(coordinate) { e in
            var byHour: [Date: MarineSample] = [:]
            for s in e.marine { byHour[s.at] = s }
            for s in samples { byHour[s.at] = s }
            let cutoff = fetchedAt.addingTimeInterval(-48 * 3600)
            e.marine = byHour.values.filter { $0.at >= cutoff }.sorted { $0.at < $1.at }
            e.marineGrid = grid
            e.marineFetchedAt = fetchedAt
        }
    }

    /// 古い釣り場の予報を落とす（取得から maxAge 以上たったもの。残りも新しい順に maxEntries 件まで）。
    /// 地図で見た港ごとに 1 件たまり、保存・読み込みが遅くなるため
    public mutating func prune(now: Date, maxAge: TimeInterval = 14 * 86_400, maxEntries: Int = 24) {
        func fetchedAt(_ e: Entry) -> Date { max(e.weatherFetchedAt ?? .distantPast, e.marineFetchedAt ?? .distantPast) }
        let cutoff = now.addingTimeInterval(-maxAge)
        entries = entries.filter { fetchedAt($0.value) >= cutoff }
        if entries.count > maxEntries {
            let keep = entries.sorted { fetchedAt($0.value) > fetchedAt($1.value) }.prefix(maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    /// 予報が届いている最後の時刻（ホームのグラフで線を薄くする境界）。
    public func weatherHorizon(for coordinate: Coordinate) -> Date? { entry(for: coordinate)?.weather.last?.at }
    public func marineHorizon(for coordinate: Coordinate) -> Date? { entry(for: coordinate)?.marine.last?.at }
}
