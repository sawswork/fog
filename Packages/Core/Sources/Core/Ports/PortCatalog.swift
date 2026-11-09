import Foundation

/// 港の一覧（国土数値情報の漁港 C09・港湾 C02）。釣り場地図の「未登録の漁港」の元データ。通信なし。
public struct Port: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case fishing, harbor }
    public var name: String
    public var lat: Double
    public var lon: Double
    public var kind: Kind
    public var pref: String?

    public var id: String { "\(name)@\(lat),\(lon)" }
    public var coordinate: Coordinate { Coordinate(latitude: lat, longitude: lon) }

    public init(name: String, lat: Double, lon: Double, kind: Kind, pref: String? = nil) {
        self.name = name; self.lat = lat; self.lon = lon; self.kind = kind; self.pref = pref
    }
}

public struct PortCatalog: Sendable {
    public let ports: [Port]

    public init(ports: [Port]) { self.ports = ports }

    /// Core に同梱した ports.json を読む。無ければ空（CI の port-data が埋める）。読むのは 1 回だけ（約 4,000 件の JSON）
    public static func bundled() -> PortCatalog { bundledCache }
    private static let bundledCache: PortCatalog = {
        guard let url = Bundle.module.url(forResource: "ports", withExtension: "json", subdirectory: "Data"),
              let data = try? Data(contentsOf: url),
              let ports = try? JSONDecoder().decode([Port].self, from: data) else { return PortCatalog(ports: []) }
        return PortCatalog(ports: ports)
    }()

    public var isEmpty: Bool { ports.isEmpty }

    /// 緯度経度の範囲に入る港。中心に近い順に `limit` 件。
    public func ports(latitude: ClosedRange<Double>, longitude: ClosedRange<Double>, limit: Int = 80) -> [Port] {
        let cLat = (latitude.lowerBound + latitude.upperBound) / 2
        let cLon = (longitude.lowerBound + longitude.upperBound) / 2
        let center = Coordinate(latitude: cLat, longitude: cLon)
        return ports.filter { latitude.contains($0.lat) && longitude.contains($0.lon) }
            .sorted { Geo.distanceMeters($0.coordinate, center) < Geo.distanceMeters($1.coordinate, center) }
            .prefix(limit).map { $0 }
    }

    public func nearest(to c: Coordinate, within meters: Double) -> Port? {
        ports.min { Geo.distanceMeters($0.coordinate, c) < Geo.distanceMeters($1.coordinate, c) }
            .flatMap { Geo.distanceMeters($0.coordinate, c) <= meters ? $0 : nil }
    }
}
