import XCTest
@testable import Core

final class PortChartTests: XCTestCase {
    /// 60×80 の網目。下 10 行が陸、左から 20 列目に縦の防波堤（上 20 行目から下まで）
    private func grid() -> WaterGrid {
        var cells = [Bool](repeating: true, count: 60 * 80)
        for r in 0..<80 { for c in 0..<60 {
            if r >= 70 { cells[r * 60 + c] = false }
            if c == 20 && r >= 20 { cells[r * 60 + c] = false }
        } }
        return WaterGrid(cols: 60, rows: 80, cells: cells)
    }
    private func chart() -> PortChart {
        PortChart(id: "t", name: "テスト漁港", lat: 42.0, lon: 140.8, widthM: 800, heightM: 800 * 4 / 3, cols: 60, rows: 80, water: grid().base64)
    }

    func testWaterGridRoundTrip() {
        let g = grid()
        let back = WaterGrid(cols: 60, rows: 80, base64: g.base64)
        XCTAssertEqual(back, g)
        XCTAssertTrue(back.isWater(col: 5, row: 5))
        XCTAssertFalse(back.isWater(col: 20, row: 40))
        XCTAssertFalse(back.isWater(col: 5, row: 75))
        XCTAssertFalse(back.isWater(col: -1, row: 0))
        XCTAssertEqual(WaterGrid(cols: 4, rows: 2, base64: "not base64").cells, [Bool](repeating: false, count: 8))
    }

    func testPointAndCoordinateRoundTrip() {
        let c = chart()
        let center = c.point(for: c.center)
        XCTAssertEqual(center.x, 0.5, accuracy: 1e-9); XCTAssertEqual(center.y, 0.5, accuracy: 1e-9)
        let ne = c.coordinate(x: 0.9, y: 0.1)
        XCTAssertGreaterThan(ne.latitude, c.lat); XCTAssertGreaterThan(ne.longitude, c.lon)
        let p = c.point(for: ne)
        XCTAssertEqual(p.x, 0.9, accuracy: 1e-6); XCTAssertEqual(p.y, 0.1, accuracy: 1e-6)
        // 絵の横幅は地上の 800 m
        let w = Geo.distanceMeters(c.coordinate(x: 0, y: 0.5), c.coordinate(x: 1, y: 0.5))
        XCTAssertEqual(w, 800, accuracy: 8)
        XCTAssertTrue(c.contains(ne))
        XCTAssertFalse(c.contains(c.coordinate(x: 1.2, y: 0.5)))
    }

    func testCatalogPicksContainingChart() {
        let a = chart()
        var b = chart(); b.id = "b"; b.lat = 42.5
        let catalog = PortChartCatalog(charts: [a, b])
        XCTAssertEqual(catalog.chart(containing: a.coordinate(x: 0.3, y: 0.3))?.id, "t")
        XCTAssertEqual(catalog.chart(containing: b.center)?.id, "b")
        XCTAssertNil(catalog.chart(containing: Coordinate(latitude: 43.5, longitude: 141.5)))
        XCTAssertNil(catalog.chart(containing: Coordinate(latitude: 0, longitude: 0)))
    }

    func testBundledChartsAreValid() {
        // 同梱の海図（無い版では空）。あるなら、網目の大きさと水面の割合がまともであること
        for c in PortChartCatalog.bundled().charts {
            XCTAssertEqual(c.waterGrid().cells.count, c.cols * c.rows, c.name)
            XCTAssertGreaterThan(c.waterGrid().waterFraction, 0.03, c.name)
            XCTAssertGreaterThan(c.widthM, 100, c.name)
            XCTAssertEqual(c.heightM / c.widthM, 4.0 / 3.0, accuracy: 0.02, c.name)
        }
    }

    func testZonesAreOnWaterNearStructureAndWithinReach() {
        let c = chart()
        // 防波堤の上（20 列目・30 行目）に立つ
        let user = c.coordinate(x: 20.5 / 60, y: 30.5 / 80)
        let zones = CastPredictor.predict(.init(chart: c, user: user))
        XCTAssertFalse(zones.isEmpty)
        XCTAssertLessThanOrEqual(zones.count, 3)
        let g = c.waterGrid()
        for z in zones {
            XCTAssertTrue(g.isWater(col: Int(z.x * 60), row: Int(z.y * 80)), "水の上")
            XCTAssertLessThanOrEqual(z.distanceM ?? 999, 75, "届く範囲")
            XCTAssertTrue((30...90).contains(z.percent))
            XCTAssertNotNil(z.bearingDeg)
        }
        XCTAssertEqual(zones.map(\.rank), Array(1...zones.count))
        XCTAssertEqual(zones.map(\.percent), zones.map(\.percent).sorted(by: >), "期待度は高い順")
        // 候補どうしは 30 m 以上離れる
        for (i, a) in zones.enumerated() { for b in zones.dropFirst(i + 1) {
            XCTAssertGreaterThanOrEqual(Geo.distanceMeters(a.coordinate, b.coordinate), 28)
        } }
        // 同じ入力なら同じ結果
        XCTAssertEqual(CastPredictor.predict(.init(chart: c, user: user)), zones)
    }

    func testCatchesPullTheTopZone() {
        let c = chart()
        let user = c.coordinate(x: 20.5 / 60, y: 30.5 / 80)
        // 防波堤の右（東）側 40 m に釣果が固まっている
        let spot = c.coordinate(x: 23.5 / 60, y: 30.5 / 80)
        let catches = Array(repeating: spot, count: 6)
        let zones = CastPredictor.predict(.init(chart: c, user: user, pastCatches: catches))
        XCTAssertLessThan(Geo.distanceMeters(zones[0].coordinate, spot), 25)
        XCTAssertTrue(zones[0].reasons.contains("過去に釣れた場所"))
        let without = CastPredictor.predict(.init(chart: c, user: user))
        XCTAssertGreaterThan(zones[0].percent, without[0].percent - 1)
        // 今日の釣果は過去の釣果より強く効く
        let other = c.coordinate(x: 17.5 / 60, y: 30.5 / 80)
        let pulled = CastPredictor.predict(.init(chart: c, user: user, pastCatches: [spot, spot], todayCatches: [other, other]))
        XCTAssertLessThan(Geo.distanceMeters(pulled[0].coordinate, other), 25)
    }

    func testWindSideAndBearing() {
        let c = chart()
        let user = c.coordinate(x: 20.5 / 60, y: 30.5 / 80)
        // 西風 4 m/s：風は東へ吹く。防波堤の西側の水面が「風が当たる面」
        let west = CastPredictor.predict(.init(chart: c, user: user, windFromDeg: 270, windSpeedMS: 4))
        XCTAssertLessThan(west[0].x, 20.0 / 60, "西側")
        XCTAssertGreaterThan(west[0].bearingDeg ?? 0, 180, "現在地から見て西側")
        // 西の強風 10 m/s：風裏（東側）
        let strong = CastPredictor.predict(.init(chart: c, user: user, windFromDeg: 270, windSpeedMS: 10))
        XCTAssertGreaterThan(strong[0].x, 21.0 / 60, "東側")
        XCTAssertTrue(strong[0].reasons.contains("風裏"))
        XCTAssertEqual(CastPredictor.compassName(0), "北")
        XCTAssertEqual(CastPredictor.compassName(90), "東")
        XCTAssertEqual(CastPredictor.compassName(225), "南西")
        XCTAssertEqual(CastPredictor.compassName(359), "北")
    }

    func testNoUserFallsBackToShoreAndEmptyCases() {
        let c = chart()
        let zones = CastPredictor.predict(.init(chart: c))
        XCTAssertFalse(zones.isEmpty)
        XCTAssertNil(zones[0].distanceM)
        // 現在地が図の外：岸の近くから選ぶ。距離は出る
        let outside = CastPredictor.predict(.init(chart: c, user: Coordinate(latitude: 42.2, longitude: 140.8)))
        XCTAssertFalse(outside.isEmpty)
        XCTAssertGreaterThan(outside[0].distanceM ?? 0, 10_000)
        // 全部が陸なら何も出ない
        let land = PortChart(id: "l", name: "陸", lat: 42, lon: 140.8, widthM: 800, heightM: 1067, cols: 60, rows: 80,
                             water: WaterGrid(cols: 60, rows: 80, cells: [Bool](repeating: false, count: 4800)).base64)
        XCTAssertTrue(CastPredictor.predict(.init(chart: land)).isEmpty)
    }
}
