import Foundation
import XCTest
@testable import Core

/// L4 受け入れ条件: 位置のシミュレーション（GPX）で開始・終了・ランガンが期待通りになる。通過だけでは開始しない。
final class SessionDetectionTests: XCTestCase {
    let port = Coordinate(latitude: 41.7822, longitude: 140.7192)

    func fixes(_ name: String) throws -> [LocationFix] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "gpx", subdirectory: "Fixtures"))
        let fixes = GPX.parse(try Data(contentsOf: url))
        XCTAssertFalse(fixes.isEmpty)
        return fixes
    }

    /// 港から 300 m 以内を海岸近傍とみなす簡易コンテキスト
    func context(for fix: LocationFix, spots: [Coordinate] = []) -> SessionDetector.Context {
        let shore = [port, Coordinate(latitude: 41.7700, longitude: 140.7400)].contains { Geo.distanceMeters($0, fix.coordinate) < 300 }
        return SessionDetector.Context(registeredSpotID: nil, nearShore: shore)
    }

    func run(_ name: String, settings: DetectionSettings = .default) throws -> [SessionDetector.Event] {
        var detector = SessionDetector(settings: settings)
        var events: [SessionDetector.Event] = []
        for fix in try fixes(name) {
            events += detector.handle(fix, context: context(for: fix))
        }
        return events
    }

    func testSimpleSessionStartsAfterDwellAndEndsWhenDriving() throws {
        let events = try run("gpx_session_simple")
        let starts = events.compactMap { e -> Date? in if case .start(let at, _, _) = e { return at }; return nil }
        let ends = events.compactMap { e -> Date? in if case .end(let at) = e { return at }; return nil }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(ends.count, 1)
        // 開始は到着時刻（10 分後）、終了は走り出した時刻（50 分後）前後
        let t0 = Date(timeIntervalSince1970: 1_792_267_200)
        XCTAssertEqual(starts[0].timeIntervalSince(t0), 600, accuracy: 120)
        XCTAssertEqual(ends[0].timeIntervalSince(t0), 3000, accuracy: 240)
        let tracks = events.filter { if case .track = $0 { return true }; return false }
        XCTAssertGreaterThanOrEqual(tracks.count, 1)
    }

    func testPassingByDoesNotStart() throws {
        let events = try run("gpx_pass_by")
        XCTAssertTrue(events.isEmpty, "\(events)")
    }

    func testShortStopDoesNotStart() throws {
        let events = try run("gpx_short_stop")
        XCTAssertTrue(events.isEmpty, "\(events)")
        // 高感度（5 分）なら開始する
        let high = try run("gpx_short_stop", settings: .forSensitivity(.high))
        XCTAssertTrue(high.contains { if case .start = $0 { return true }; return false })
    }

    func testRunAndGunMergesIntoOneSession() throws {
        let events = try run("gpx_run_and_gun")
        let starts = events.filter { if case .start = $0 { return true }; return false }
        let resumes = events.filter { if case .resume = $0 { return true }; return false }
        let ends = events.filter { if case .end = $0 { return true }; return false }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(resumes.count, 1)
        XCTAssertEqual(ends.count, 2) // A を離れたときと最後
    }

    func testRegisteredSpotStartsWithoutShoreInfo() {
        var detector = SessionDetector(settings: .forSensitivity(.high))
        let spotID = UUID()
        let t0 = Date(timeIntervalSince1970: 1_792_267_200)
        var events: [SessionDetector.Event] = []
        for i in 0..<8 {
            let fix = LocationFix(at: t0.addingTimeInterval(Double(i) * 60), coordinate: port, horizontalAccuracyM: 15, speedMS: 0)
            events += detector.handle(fix, context: .init(registeredSpotID: spotID, nearShore: nil))
        }
        guard case .start(_, _, let id)? = events.first else { return XCTFail("start expected: \(events)") }
        XCTAssertEqual(id, spotID)
    }

    func testBadAccuracyIgnored() {
        var detector = SessionDetector(settings: .forSensitivity(.high))
        let t0 = Date(timeIntervalSince1970: 1_792_267_200)
        for i in 0..<10 {
            let fix = LocationFix(at: t0.addingTimeInterval(Double(i) * 60), coordinate: port, horizontalAccuracyM: 500, speedMS: 0)
            XCTAssertTrue(detector.handle(fix, context: .init(nearShore: true)).isEmpty)
        }
        XCTAssertEqual(detector.state, .idle)
    }

    func testMeshKeyAndCenter() {
        let key = Mesh.key(for: port)
        XCTAssertTrue(key.hasPrefix("30m:"))
        let center = Mesh.center(for: port)
        XCTAssertLessThan(Geo.distanceMeters(center, port), 25)
        // メッシュ中心から数 m 以内は同じキー、1 セル以上離れれば別のキー
        XCTAssertEqual(key, Mesh.key(for: center))
        XCTAssertEqual(key, Mesh.key(for: Coordinate(latitude: center.latitude + 0.00003, longitude: center.longitude + 0.00003)))
        XCTAssertNotEqual(key, Mesh.key(for: Coordinate(latitude: port.latitude + 0.001, longitude: port.longitude)))
    }

    func testSettingsBySensitivity() {
        XCTAssertLessThan(DetectionSettings.forSensitivity(.high).dwellToStart, DetectionSettings.forSensitivity(.medium).dwellToStart)
        XCTAssertLessThan(DetectionSettings.forSensitivity(.medium).dwellToStart, DetectionSettings.forSensitivity(.low).dwellToStart)
    }

    /// F-48: 手動開始は滞在を待たずに釣行中になり、離れると自動で終わる
    func testManualStartEndsAutomaticallyWhenLeaving() {
        var detector = SessionDetector(settings: .default)
        let t0 = Date(timeIntervalSince1970: 1_792_267_200)
        detector.beginManually(at: t0, anchor: port)
        XCTAssertTrue(detector.isActive)
        // その場に 10 分：終了しない
        var events: [SessionDetector.Event] = []
        for i in 1...10 {
            events += detector.handle(LocationFix(at: t0.addingTimeInterval(Double(i) * 60), coordinate: port, horizontalAccuracyM: 15, speedMS: 0), context: context(for: LocationFix(at: t0, coordinate: port, horizontalAccuracyM: 15, speedMS: 0)))
        }
        XCTAssertFalse(events.contains { if case .end = $0 { return true }; return false })
        // 2 km 離れて 1 時間：終了する
        let far = Coordinate(latitude: port.latitude + 0.02, longitude: port.longitude)
        for i in 11...80 {
            events += detector.handle(LocationFix(at: t0.addingTimeInterval(Double(i) * 60), coordinate: far, horizontalAccuracyM: 15, speedMS: 0), context: .init(registeredSpotID: nil, nearShore: false))
        }
        XCTAssertEqual(events.filter { if case .end = $0 { return true }; return false }.count, 1)
    }

    /// F-48: 手動終了のあと同じ場所に居続けても自動では再開しない。離れてから戻れば通常通り始まる
    func testManualEndDoesNotRestartWhileStaying() {
        var detector = SessionDetector(settings: .default)
        let t0 = Date(timeIntervalSince1970: 1_792_267_200)
        detector.beginManually(at: t0, anchor: port)
        detector.endManually(anchor: port)
        XCTAssertFalse(detector.isActive)
        var events: [SessionDetector.Event] = []
        for i in 1...120 {
            events += detector.handle(LocationFix(at: t0.addingTimeInterval(Double(i) * 60), coordinate: port, horizontalAccuracyM: 15, speedMS: 0), context: .init(registeredSpotID: UUID(), nearShore: true))
        }
        XCTAssertTrue(events.isEmpty, "居続けても開始しない")
        // 2 km 離れてから戻り、滞在すると始まる
        let far = Coordinate(latitude: port.latitude + 0.02, longitude: port.longitude)
        _ = detector.handle(LocationFix(at: t0.addingTimeInterval(121 * 60), coordinate: far, horizontalAccuracyM: 15, speedMS: 0), context: .init(registeredSpotID: nil, nearShore: false))
        for i in 122...200 {
            events += detector.handle(LocationFix(at: t0.addingTimeInterval(Double(i) * 60), coordinate: port, horizontalAccuracyM: 15, speedMS: 0), context: .init(registeredSpotID: UUID(), nearShore: true))
        }
        XCTAssertEqual(events.filter { if case .start = $0 { return true }; return false }.count, 1)
    }

    // MARK: 登録した釣り場の境界で見張る方式（2026-11-19）

    /// 見張る釣り場は近い順に 19 個まで。位置が無効な釣り場と重複は除く
    func testGeofencePlannerPicksNearestSpots() {
        let ids = (0..<25).map { _ in UUID() }
        var spots: [(id: UUID, coordinate: Coordinate)] = ids.enumerated().map { i, id in
            (id: id, coordinate: Coordinate(latitude: port.latitude + Double(i) * 0.01, longitude: port.longitude))
        }
        spots.append((id: UUID(), coordinate: Coordinate(latitude: 0, longitude: 0)))   // 位置不明
        spots.append((id: ids[0], coordinate: port))                                   // 重複
        let regions = GeofencePlanner.regions(spots: Array(spots.reversed()), near: port, radiusM: 300)
        XCTAssertEqual(regions.count, 19)
        XCTAssertEqual(regions.first?.id, GeofencePlanner.spotPrefix + ids[0].uuidString)
        XCTAssertEqual(regions.map(\.id), ids.prefix(19).map { GeofencePlanner.spotPrefix + $0.uuidString })
        XCTAssertEqual(regions[3].radiusM, 300)
        XCTAssertEqual(GeofencePlanner.spotID(from: regions[2].id), ids[2])
        XCTAssertNil(GeofencePlanner.spotID(from: GeofencePlanner.sessionID))
        // 位置が分からなければ渡された順
        let unordered = GeofencePlanner.regions(spots: Array(spots.prefix(3).reversed()), near: nil, radiusM: 300)
        XCTAssertEqual(unordered.map(\.id), [ids[2], ids[1], ids[0]].map { GeofencePlanner.spotPrefix + $0.uuidString })
        XCTAssertTrue(GeofencePlanner.regions(spots: spots, near: port, radiusM: 300, limit: 0).isEmpty)
    }

    /// 置いてある境界との差だけを足し引きする（同じものは置き直さない）
    func testGeofenceDiff() {
        let a = GeofencePlanner.Region(id: "fog.spot.a", center: port, radiusM: 300)
        let b = GeofencePlanner.Region(id: "fog.spot.b", center: Coordinate(latitude: port.latitude + 0.05, longitude: port.longitude), radiusM: 300)
        let session = GeofencePlanner.Region(id: GeofencePlanner.sessionID, center: port, radiusM: 300)
        let none = GeofencePlanner.diff(current: [a, b], wanted: [b, a])
        XCTAssertTrue(none.add.isEmpty); XCTAssertTrue(none.remove.isEmpty)
        let started = GeofencePlanner.diff(current: [a, b], wanted: [a, b, session])
        XCTAssertEqual(started.add, [session]); XCTAssertTrue(started.remove.isEmpty)
        // 中心が動いた境界は置き直す。要らなくなった境界は外す
        var moved = session
        moved.center = Coordinate(latitude: port.latitude + 0.001, longitude: port.longitude)
        let d = GeofencePlanner.diff(current: [a, b, session], wanted: [a, moved])
        XCTAssertEqual(d.add, [moved])
        XCTAssertEqual(Set(d.remove), ["fog.spot.b", GeofencePlanner.sessionID])
        XCTAssertEqual(GeofencePlanner.diff(current: [a], wanted: []).remove, ["fog.spot.a"])
    }

    /// 境界を出たら、手動終了後の「開始を止めている」状態と、数えかけの滞在を待機に戻す
    func testLeftPlaceClearsSuppressedAndCandidate() {
        var detector = SessionDetector(settings: .default)
        let t0 = Date(timeIntervalSince1970: 1_792_267_200)
        let here = SessionDetector.Context(registeredSpotID: UUID(), nearShore: true)
        func fix(_ minutes: Double) -> LocationFix { LocationFix(at: t0.addingTimeInterval(minutes * 60), coordinate: port, horizontalAccuracyM: 15, speedMS: 0) }

        // 手動で終えたあと、位置が届かないまま翌日に同じ場所へ：境界を出た知らせで戻っていれば、滞在で始まる
        detector.beginManually(at: t0, anchor: port)
        detector.endManually(anchor: port)
        XCTAssertTrue(detector.isSuppressed)
        detector.leftPlace()
        XCTAssertFalse(detector.isSuppressed)
        var events: [SessionDetector.Event] = []
        for m in stride(from: 1440.0, through: 1455.0, by: 1.0) { events += detector.handle(fix(m), context: here) }
        XCTAssertEqual(events.filter { if case .start = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(detector.activeAnchor, port)

        // 数えかけの滞在（3 分で通り過ぎた）を残さない：残っていると、次に来た瞬間に古い開始時刻で始まってしまう
        var second = SessionDetector(settings: .default)
        _ = second.handle(fix(0), context: here)
        _ = second.handle(fix(3), context: here)
        XCTAssertTrue(second.isCandidate)
        second.leftPlace()
        XCTAssertFalse(second.isCandidate)
        let next = second.handle(fix(600), context: here)
        XCTAssertTrue(next.isEmpty, "着いた瞬間には始まらない")
        var later: [SessionDetector.Event] = []
        for m in stride(from: 601.0, through: 611.0, by: 1.0) { later += second.handle(fix(m), context: here) }
        guard case .start(let at, _, _)? = later.first else { return XCTFail("滞在で始まる") }
        XCTAssertEqual(at, t0.addingTimeInterval(600 * 60))

        // 記録中は変えない
        var active = SessionDetector(settings: .default)
        active.beginManually(at: t0, anchor: port)
        active.leftPlace()
        XCTAssertTrue(active.isActive)
    }
}
