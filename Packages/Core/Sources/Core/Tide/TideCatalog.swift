import Foundation

/// 同梱の分潮データ（全国の潮位表掲載地点）。
public struct TideCatalog: Codable, Sendable {
    public var year: Int
    public var source: String
    public var stations: [TideStation]

    public init(year: Int, source: String, stations: [TideStation]) {
        self.year = year; self.source = source; self.stations = stations
    }

    /// Core に同梱した harmonics.json を読む。無ければ空。読むのは 1 回だけ
    public static func bundled() -> TideCatalog { bundledCache }
    private static let bundledCache: TideCatalog = {
        guard let url = Bundle.module.url(forResource: "harmonics", withExtension: "json", subdirectory: "Data"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(TideCatalog.self, from: data) else {
            return TideCatalog(year: 0, source: "", stations: [])
        }
        return catalog
    }()

    public static func load(from data: Data) throws -> TideCatalog {
        try JSONDecoder().decode(TideCatalog.self, from: data)
    }

    /// 緯度経度に最も近い地点（分潮を持つ地点のみ）。
    public func nearest(to coordinate: Coordinate) -> TideStation? {
        stations.filter { !$0.constituents.isEmpty }
            .min { Geo.distanceMeters($0.coordinate, coordinate) < Geo.distanceMeters($1.coordinate, coordinate) }
    }

    /// 近い順に n 地点。
    public func nearest(to coordinate: Coordinate, count: Int) -> [TideStation] {
        Array(stations.sorted { Geo.distanceMeters($0.coordinate, coordinate) < Geo.distanceMeters($1.coordinate, coordinate) }.prefix(count))
    }
}

/// 距離計算（ハバーサイン）。釣り場のジオフェンス・最寄り検索でも使う。
public enum Geo {
    public static let earthRadiusM = 6_371_000.0

    public static func distanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let dLat = Angle.rad(b.latitude - a.latitude)
        let dLon = Angle.rad(b.longitude - a.longitude)
        let la1 = Angle.rad(a.latitude), la2 = Angle.rad(b.latitude)
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusM * asin(min(1, sqrt(h)))
    }
}
