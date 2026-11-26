import XCTest
@testable import Core

/// 漁港を風の弱い順に並べる（F-68）
final class PortWindTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_795_000_000)
    let hakodate = Coordinate(latitude: 41.78, longitude: 140.72)

    func series(_ speeds: [Double?], direction: [Double?]? = nil, gust: [Double?]? = nil) -> PortWind.Series {
        PortWind.Series(times: speeds.indices.map { t0.addingTimeInterval(Double($0) * 3600) }, speed: speeds,
                        direction: direction ?? speeds.map { _ in 270 }, gust: gust ?? speeds.map { $0.map { $0 * 1.5 } })
    }

    func testSampleInterpolates() {
        let s = series([2, 4, nil, 8], direction: [350, 10, 20, 30])
        XCTAssertEqual(s.sample(at: t0)?.speedMS, 2)
        XCTAssertEqual(s.sample(at: t0.addingTimeInterval(1800))?.speedMS ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(s.sample(at: t0.addingTimeInterval(900))?.gustMS ?? 0, 3.75, accuracy: 1e-9)
        // 風向は近いほうの時刻の値（350° と 10° の間を数字で補間しない）
        XCTAssertEqual(s.sample(at: t0.addingTimeInterval(900))?.directionDeg, 350)
        XCTAssertEqual(s.sample(at: t0.addingTimeInterval(2700))?.directionDeg, 10)
        // 片方が無ければ、あるほうの値
        XCTAssertEqual(s.sample(at: t0.addingTimeInterval(5400))?.speedMS, 4)
        XCTAssertEqual(s.sample(at: t0.addingTimeInterval(9000))?.speedMS, 8)
        // 範囲の外は nil（30 分までは端の値）
        XCTAssertNil(s.sample(at: t0.addingTimeInterval(-7200)))
        XCTAssertNil(s.sample(at: t0.addingTimeInterval(5 * 3600)))
        XCTAssertEqual(s.sample(at: t0.addingTimeInterval(-600))?.speedMS, 2)
        XCTAssertNil(PortWind.Series(times: [], speed: [], direction: [], gust: []).sample(at: t0))
    }

    func testCells() {
        XCTAssertEqual(PortWind.cellKey(for: Coordinate(latitude: 41.816, longitude: 140.654)), "41.80,140.70")
        XCTAssertEqual(PortWind.cellKey(for: Coordinate(latitude: 41.86, longitude: 140.76)), "41.90,140.80")
        let places = [
            PortWind.Place(id: "a", name: "A", coordinate: Coordinate(latitude: 41.816, longitude: 140.654), isSpot: false),
            PortWind.Place(id: "b", name: "B", coordinate: Coordinate(latitude: 41.81, longitude: 140.66), isSpot: false),   // A と同じ升
            PortWind.Place(id: "c", name: "C", coordinate: Coordinate(latitude: 42.10, longitude: 140.57), isSpot: false),
        ]
        let cells = PortWind.cells(for: places)
        XCTAssertEqual(cells.map { $0.key }, ["41.80,140.70", "42.10,140.60"])
        XCTAssertEqual(cells[1].center.longitude, 140.6, accuracy: 1e-9)
        let urls = PortWind.urls(cells: cells, forecastDays: 2)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls[0].keys, cells.map { $0.key })
        let u = urls[0].url.absoluteString
        XCTAssertTrue(u.hasPrefix("https://api.open-meteo.com/v1/forecast?"), u)
        XCTAssertTrue(u.contains("latitude=41.80,42.10"), u)
        XCTAssertTrue(u.contains("longitude=140.70,140.60"), u)
        XCTAssertTrue(u.contains("wind_speed_unit=ms"), u)
        XCTAssertTrue(u.contains("hourly=wind_speed_10m,wind_direction_10m,wind_gusts_10m"), u)
        // 地点が多ければ分ける
        XCTAssertEqual(PortWind.urls(cells: cells, chunk: 1).map { $0.keys }, [["41.80,140.70"], ["42.10,140.60"]])
        XCTAssertTrue(PortWind.urls(cells: []).isEmpty)
    }

    func testPlacesMergeSpotsAndPorts() {
        let spotID = UUID()
        let green = Coordinate(latitude: 41.816, longitude: 140.654)
        let ports = [
            Port(name: "北斗漁港", lat: 41.817, lon: 140.656, kind: .fishing),   // 釣り場から約 200 m：釣り場にまとめる
            Port(name: "函館港", lat: 41.78, lon: 140.72, kind: .harbor),
            Port(name: "函館港", lat: 41.781, lon: 140.721, kind: .fishing),     // 同じ名前は 1 つ
            Port(name: "森港", lat: 42.11, lon: 140.58, kind: .harbor),
            Port(name: "稚内港", lat: 45.41, lon: 141.68, kind: .harbor),        // 範囲の外
        ]
        let places = PortWind.places(spots: [(id: spotID, name: "上磯漁港緑地", coordinate: green)], ports: ports, origin: hakodate, radiusM: 80_000)
        XCTAssertEqual(places.map(\.name), ["函館港", "上磯漁港緑地", "森港"])
        XCTAssertEqual(places.map(\.isSpot), [false, true, false])
        XCTAssertEqual(places[1].id, "spot:" + spotID.uuidString)
        XCTAssertEqual(PortWind.places(spots: [], ports: ports, origin: hakodate, radiusM: 80_000, limit: 1).map(\.name), ["函館港"])
    }

    func testRankWeakestFirst() {
        let a = PortWind.Place(id: "a", name: "函館港", coordinate: hakodate, isSpot: false)
        let b = PortWind.Place(id: "b", name: "森港", coordinate: Coordinate(latitude: 42.11, longitude: 140.58), isSpot: false)
        let c = PortWind.Place(id: "c", name: "鹿部漁港", coordinate: Coordinate(latitude: 42.04, longitude: 140.82), isSpot: false)
        let d = PortWind.Place(id: "d", name: "予報なし", coordinate: Coordinate(latitude: 41.43, longitude: 140.11), isSpot: false)
        let all = [
            PortWind.cellKey(for: a.coordinate): series([6, 2]),
            PortWind.cellKey(for: b.coordinate): series([3, 5]),
            PortWind.cellKey(for: c.coordinate): series([3, 9], gust: [4, 12]),
        ]
        // いま：森 3（瞬間 4.5）と鹿部 3（瞬間 4）→ 瞬間の弱い鹿部が先。函館 6 は最後。予報の無い港は出さない
        let now = PortWind.rank(places: [a, b, c, d], series: all, at: t0, origin: hakodate)
        XCTAssertEqual(now.map(\.place.name), ["鹿部漁港", "森港", "函館港"])
        XCTAssertEqual(now[0].wind.speedMS, 3)
        XCTAssertEqual(now[2].distanceM ?? -1, 0, accuracy: 1)
        // 1 時間後は順番が変わる
        let later = PortWind.rank(places: [a, b, c, d], series: all, at: t0.addingTimeInterval(3600), origin: nil)
        XCTAssertEqual(later.map(\.place.name), ["函館港", "森港", "鹿部漁港"])
        XCTAssertNil(later[0].distanceM)
    }

    func testDecodeKeepsRequestOrder() throws {
        let json = """
        [{"latitude":41.8,"longitude":140.6875,"hourly":{"time":[1795000000,1795003600],"wind_speed_10m":[2.5,3.0],"wind_direction_10m":[200,210],"wind_gusts_10m":[5.0,null]}},
         {"latitude":42.1,"longitude":140.5625,"hourly":{"time":[1795000000,1795003600],"wind_speed_10m":[7.0,6.0],"wind_direction_10m":[300,310],"wind_gusts_10m":[11.0,9.0]}}]
        """
        let out = try PortWind.decode(Data(json.utf8), keys: ["41.80,140.65", "42.10,140.55"])
        XCTAssertEqual(out["41.80,140.65"]?.speed, [2.5, 3.0])
        XCTAssertEqual(out["42.10,140.55"]?.sample(at: t0)?.directionDeg, 300)
        XCTAssertEqual(out["41.80,140.65"]?.gust, [5.0, nil])
        // 地点の数が合わない応答は使わない
        XCTAssertTrue(try PortWind.decode(Data(json.utf8), keys: ["x"]).isEmpty)
    }
}
