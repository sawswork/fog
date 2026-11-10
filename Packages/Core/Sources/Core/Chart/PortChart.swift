import Foundation

/// 港の海図（F-63）。国土地理院の航空写真と地図をもとに描いた 1 枚の絵（北が上、縦 3:4）と、その絵が地上のどこを写しているか。
/// 絵の中の位置は左上を (0, 0)、右下を (1, 1) とする割合で表す（x は東へ、y は南へ）。
///
/// `water` は水面かどうかの粗い網目（`cols` × `rows`、行ごと・上位ビットから詰めた Base64）。
/// 国土地理院の地図の海の色から作ってあり、投げる場所の予測を水の上だけに置くために使う。水深ではない。
public struct PortChart: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var lat: Double
    public var lon: Double
    /// 絵の横幅・縦の長さ（地上の m）
    public var widthM: Double
    public var heightM: Double
    public var cols: Int
    public var rows: Int
    public var water: String

    public init(id: String, name: String, lat: Double, lon: Double, widthM: Double, heightM: Double, cols: Int, rows: Int, water: String) {
        self.id = id; self.name = name; self.lat = lat; self.lon = lon; self.widthM = widthM; self.heightM = heightM
        self.cols = cols; self.rows = rows; self.water = water
    }

    public var center: Coordinate { Coordinate(latitude: lat, longitude: lon) }

    static let metersPerDegreeLat = 111_132.0
    private var metersPerDegreeLon: Double { 111_320.0 * max(0.1, cos(lat * .pi / 180)) }

    /// 緯度経度 → 絵の中の位置（0〜1 の外なら絵の外）
    public func point(for c: Coordinate) -> (x: Double, y: Double) {
        let x = 0.5 + (c.longitude - lon) * metersPerDegreeLon / widthM
        let y = 0.5 - (c.latitude - lat) * Self.metersPerDegreeLat / heightM
        return (x, y)
    }

    /// 絵の中の位置 → 緯度経度
    public func coordinate(x: Double, y: Double) -> Coordinate {
        Coordinate(latitude: lat + (0.5 - y) * heightM / Self.metersPerDegreeLat,
                   longitude: lon + (x - 0.5) * widthM / metersPerDegreeLon)
    }

    public func contains(_ c: Coordinate) -> Bool {
        let p = point(for: c)
        return p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1
    }

    /// 水面の網目を展開する（読めなければ全部が陸）
    public func waterGrid() -> WaterGrid { WaterGrid(cols: cols, rows: rows, base64: water) }
}

/// 水面かどうかの網目。`cells[row * cols + col]` が true なら水
public struct WaterGrid: Hashable, Sendable {
    public var cols: Int
    public var rows: Int
    public var cells: [Bool]

    public init(cols: Int, rows: Int, cells: [Bool]) {
        self.cols = max(0, cols); self.rows = max(0, rows)
        let n = self.cols * self.rows
        self.cells = cells.count == n ? cells : Array(cells.prefix(n)) + Array(repeating: false, count: max(0, n - cells.count))
    }

    public init(cols: Int, rows: Int, base64: String) {
        let n = max(0, cols) * max(0, rows)
        var out = [Bool](repeating: false, count: n)
        if let data = Data(base64Encoded: base64) {
            for i in 0..<n {
                let byte = i / 8
                guard byte < data.count else { break }
                out[i] = (data[data.startIndex + byte] >> UInt8(7 - i % 8)) & 1 == 1
            }
        }
        self.init(cols: cols, rows: rows, cells: out)
    }

    /// 上位ビットから詰めた Base64（`init(cols:rows:base64:)` の逆）
    public var base64: String {
        var bytes = [UInt8](repeating: 0, count: (cells.count + 7) / 8)
        for (i, w) in cells.enumerated() where w { bytes[i / 8] |= UInt8(1) << UInt8(7 - i % 8) }
        return Data(bytes).base64EncodedString()
    }

    public func isWater(col: Int, row: Int) -> Bool {
        guard col >= 0, row >= 0, col < cols, row < rows else { return false }
        return cells[row * cols + col]
    }

    public var waterFraction: Double { cells.isEmpty ? 0 : Double(cells.filter { $0 }.count) / Double(cells.count) }
}

/// 同梱した港の海図の一覧（`Data/port_charts.json`）。絵そのものはアプリ側の `Charts/<id>.jpg`
public struct PortChartCatalog: Sendable {
    public var charts: [PortChart]
    public init(charts: [PortChart]) { self.charts = charts }

    public static func bundled() -> PortChartCatalog { bundledCache }
    private static let bundledCache: PortChartCatalog = {
        guard let url = Bundle.module.url(forResource: "port_charts", withExtension: "json", subdirectory: "Data"),
              let data = try? Data(contentsOf: url),
              let charts = try? JSONDecoder().decode([PortChart].self, from: data) else { return PortChartCatalog(charts: []) }
        return PortChartCatalog(charts: charts)
    }()

    public var isEmpty: Bool { charts.isEmpty }

    /// その場所を写している海図。複数あれば中心がいちばん近いもの。無ければ nil（アプリは Apple の地図に落とす）
    public func chart(containing c: Coordinate) -> PortChart? {
        guard c.isPlausible else { return nil }
        return charts.filter { $0.contains(c) }.min { Geo.distanceMeters($0.center, c) < Geo.distanceMeters($1.center, c) }
    }
}
