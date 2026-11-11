import XCTest
@testable import Core

final class TrackCleanerTests: XCTestCase {
    private let base = Coordinate(latitude: 41.8170, longitude: 140.6480)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// base から東へ dx m、北へ dy m
    private func at(_ dx: Double, _ dy: Double) -> Coordinate {
        Coordinate(latitude: base.latitude + dy / 111_132, longitude: base.longitude + dx / (111_320 * cos(base.latitude * .pi / 180)))
    }

    private func sample(_ minute: Double, _ dx: Double, _ dy: Double) -> TrackSample {
        TrackSample(at: start.addingTimeInterval(minute * 60), coordinate: at(dx, dy))
    }

    func testSpikesAreDroppedAndNearbyPointsMerge() {
        // 堤防の先で 30 分 → 飛び値（700 m 北東）→ 同じ場所 → 80 m 移動して 20 分 → 飛び値 → 元の場所へ戻って 10 分
        let track = [
            sample(0, 0, 0), sample(10, 6, -4), sample(20, -5, 3),
            sample(25, 520, 480),                       // 飛び値：遠すぎる
            sample(30, 4, 2),
            sample(31, 150, 90),                        // 飛び値：行って戻る
            sample(32, 2, -3),
            sample(40, 80, 10), sample(50, 84, 14),
            sample(60, 3, 1),
        ]
        let out = TrackCleaner.clean(track, anchors: [at(1, 1)], end: start.addingTimeInterval(70 * 60))
        XCTAssertEqual(out.dropped, 2)
        XCTAssertEqual(out.stays.count, 2)
        // 1 つめ：0〜40 分（40 分）＋戻ってきた 60〜70 分（10 分）。2 つめ：40〜60 分
        XCTAssertEqual(out.stays[0].minutes, 50)
        XCTAssertEqual(out.stays[1].minutes, 20)
        XCTAssertLessThan(Geo.distanceMeters(out.stays[0].coordinate, base), 8)
        XCTAssertLessThan(Geo.distanceMeters(out.stays[1].coordinate, at(82, 12)), 8)
        // 線は、訪れた順（1 → 2 → 1）
        XCTAssertEqual(out.path.count, 3)
        XCTAssertEqual(out.path[0], out.stays[0].coordinate)
        XCTAssertEqual(out.path[1], out.stays[1].coordinate)
        XCTAssertEqual(out.path[2], out.stays[0].coordinate)
    }

    func testEmptyAndSinglePoint() {
        XCTAssertTrue(TrackCleaner.clean([]).stays.isEmpty)
        let one = TrackCleaner.clean([sample(0, 0, 0)], end: start.addingTimeInterval(45 * 60))
        XCTAssertEqual(one.stays.count, 1)
        XCTAssertEqual(one.stays[0].minutes, 30)          // 間が空いたら 30 分まで
        XCTAssertEqual(one.path.count, 1)
        // 緯度経度 0（位置なし）の点は使わない
        let none = TrackCleaner.clean([TrackSample(at: start, coordinate: Coordinate(latitude: 0, longitude: 0))])
        XCTAssertTrue(none.stays.isEmpty)
    }

    func testFanOutGroupsOverlappingPoints() {
        let groups = TrackCleaner.fanOut([at(0, 0), at(3, 2), at(60, 0), at(-2, 1), at(61, 3)])
        XCTAssertEqual(groups.map(\.index), [0, 1, 0, 2, 1])
        XCTAssertEqual(groups.map(\.count), [3, 3, 2, 3, 2])
    }

    func testChartChoiceIsStable() {
        let water = WaterGrid(cols: 6, rows: 8, cells: [Bool](repeating: true, count: 48)).base64
        let a = PortChart(id: "a", name: "A", lat: base.latitude, lon: base.longitude, widthM: 800, heightM: 1067, cols: 6, rows: 8, water: water)
        let far = at(900, 0)
        let b = PortChart(id: "b", name: "B", lat: far.latitude, lon: far.longitude, widthM: 800, heightM: 1067, cols: 6, rows: 8, water: water)
        let catalog = PortChartCatalog(charts: [a, b])
        // 釣り場と釣果は A、揺れた現在地だけが B の中 → 多く写している A
        XCTAssertEqual(catalog.chart(for: [at(300, 0), at(250, 20), at(700, 0)])?.id, "a")
        // いま B を出していて、候補の 1 つでも B の中なら替えない
        XCTAssertEqual(catalog.chart(for: [at(300, 0), at(250, 20), at(700, 0)], keeping: "b")?.id, "b")
        // どの海図にも入らない
        XCTAssertNil(catalog.chart(for: [at(5000, 5000)]))
        XCTAssertNil(catalog.chart(for: []))
    }
}
