import XCTest
@testable import Core

final class PartyTripsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private let otaru = Coordinate(latitude: 43.20, longitude: 141.00)
    private let yoichi = Coordinate(latitude: 43.20, longitude: 140.78)

    private func leg(_ device: String, owner: String, start: TimeInterval, end: TimeInterval?, at: Coordinate? = nil, spot: String = "小樽港",
                     anglers: [String]? = nil, count: Int = 0, id: UUID = UUID()) -> PartyTrip.Leg {
        PartyTrip.Leg(sessionID: id, device: device, owner: owner, startedAt: t0.addingTimeInterval(start * 3600),
                      endedAt: end.map { t0.addingTimeInterval($0 * 3600) }, spotName: spot, coordinate: at ?? otaru,
                      anglers: anglers ?? [owner], catchCount: count)
    }

    func testSameTimeAndPlaceIsTogether() {
        let mine = leg("A", owner: "けん", start: 0, end: 3)
        let friend = leg("B", owner: "たろう", start: 1, end: 4, count: 2)
        let r = PartyTrips.resolve(own: [mine], others: [friend], ownName: "けん", now: t0.addingTimeInterval(86400))
        XCTAssertEqual(r.companions[mine.sessionID], ["たろう"])
        XCTAssertEqual(r.companionLegs[mine.sessionID]?.count, 1)
        XCTAssertTrue(r.friendTrips.isEmpty)
    }

    func testDifferentPlaceOrTimeIsFriendTrip() {
        let mine = leg("A", owner: "けん", start: 0, end: 3)
        let far = leg("B", owner: "たろう", start: 1, end: 4, at: yoichi, spot: "余市", count: 3)
        let later = leg("B", owner: "たろう", start: 10, end: 12, count: 1)
        let r = PartyTrips.resolve(own: [mine], others: [far, later], ownName: "けん", now: t0.addingTimeInterval(86400))
        XCTAssertNil(r.companions[mine.sessionID])
        XCTAssertEqual(r.friendTrips.count, 2)
        XCTAssertEqual(r.friendTrips.first?.startedAt, later.startedAt)   // 新しい順
        XCTAssertEqual(r.friendTrips.last?.spotName, "余市")
        XCTAssertEqual(r.friendTrips.last?.members, ["たろう"])
        XCTAssertEqual(r.friendTrips.last?.catchCount, 3)
    }

    func testSlackOfThirtyMinutes() {
        let mine = leg("A", owner: "けん", start: 0, end: 2)
        let justAfter = leg("B", owner: "たろう", start: 2.4, end: 4)
        let tooLate = leg("B", owner: "たろう", start: 2.6, end: 4)
        let now = t0.addingTimeInterval(86400)
        XCTAssertTrue(PartyTrips.together(mine, justAfter, now: now))
        XCTAssertFalse(PartyTrips.together(mine, tooLate, now: now))
        XCTAssertFalse(PartyTrips.together(mine, leg("A", owner: "けん", start: 1, end: 2), now: now))   // 同じ端末
    }

    func testFriendsTogetherAreOneTrip() {
        let a = leg("B", owner: "たろう", start: 0, end: 5, count: 2)
        let b1 = leg("C", owner: "はな", start: 0.5, end: 2, anglers: ["はな", "ゆう"], count: 1)
        let b2 = leg("C", owner: "はな", start: 3, end: 4.5, count: 4)
        let r = PartyTrips.resolve(own: [], others: [b2, a, b1], ownName: "けん", now: t0.addingTimeInterval(86400))
        XCTAssertEqual(r.friendTrips.count, 1)
        let trip = r.friendTrips[0]
        XCTAssertEqual(trip.legs.count, 3)
        XCTAssertEqual(trip.members, ["たろう", "はな", "ゆう"])
        XCTAssertEqual(trip.catchCount, 7)
        XCTAssertEqual(trip.startedAt, a.startedAt)
        XCTAssertEqual(trip.endedAt, a.endedAt)
        XCTAssertEqual(trip.id, a.sessionID)
    }

    func testAnglersRecordedOnMyDeviceAreCompanions() {
        let mine = leg("A", owner: "けん", start: 0, end: 3, anglers: ["けん", "たろう"])
        let r = PartyTrips.resolve(own: [mine], others: [], ownName: "けん", now: t0.addingTimeInterval(86400))
        XCTAssertEqual(r.companions[mine.sessionID], ["たろう"])
    }

    func testUnnamedOwnerAndMissingCoordinate() {
        let none = Coordinate(latitude: 0, longitude: 0)
        let mine = leg("A", owner: "自分", start: 0, end: 3, at: none)
        let friend = leg("B", owner: "自分", start: 1, end: 2, at: none)
        let other = leg("B", owner: "自分", start: 1, end: 2, at: none, spot: "余市")
        let now = t0.addingTimeInterval(86400)
        XCTAssertTrue(PartyTrips.together(mine, friend, now: now))    // 位置が無ければ釣り場名
        XCTAssertFalse(PartyTrips.together(mine, other, now: now))
        let r = PartyTrips.resolve(own: [mine], others: [friend], ownName: "自分", now: now)
        XCTAssertEqual(r.companions[mine.sessionID], ["仲間"])
    }

    func testActiveLegUsesNow() {
        let mine = leg("A", owner: "けん", start: 0, end: nil)
        let friend = leg("B", owner: "たろう", start: 2, end: nil)
        XCTAssertTrue(PartyTrips.together(mine, friend, now: t0.addingTimeInterval(3 * 3600)))
        XCTAssertFalse(PartyTrips.together(mine, friend, now: t0.addingTimeInterval(1 * 3600)))   // 仲間はまだ始めていない
        let r = PartyTrips.resolve(own: [], others: [friend], ownName: "けん", now: t0.addingTimeInterval(3 * 3600))
        XCTAssertEqual(r.friendTrips.first?.isActive, true)
        XCTAssertNil(r.friendTrips.first?.duration)
    }

    func testCatchesOfLegs() {
        let l = leg("B", owner: "たろう", start: 0, end: 2)
        func c(_ device: String, _ h: Double) -> SharedCatch {
            SharedCatch(id: UUID(), angler: "たろう", device: device, species: "アイナメ", lengthCm: 30, at: t0.addingTimeInterval(h * 3600),
                        coordinate: otaru, spotName: "小樽港", updatedAt: t0)
        }
        let inside = c("B", 1), edge = c("B", 2.1), outside = c("B", 3), otherDevice = c("C", 1)
        let got = PartyTrips.catches(in: [l], from: [outside, edge, inside, otherDevice], now: t0.addingTimeInterval(86400))
        XCTAssertEqual(got.map(\.id), [inside.id, edge.id])
    }

    func testSharedSessionPayload() throws {
        let spot = Spot(name: "小樽港", coordinate: otaru)
        let own = Catch(id: UUID(), sessionID: UUID(), at: t0, coordinate: otaru, species: "アイナメ", speciesConfidence: 1, lengthCm: 30)
        let friend = Catch(id: UUID(), sessionID: UUID(), at: t0, coordinate: otaru, species: "ソイ", speciesConfidence: 1, lengthCm: 25, angler: "たろう")
        let session = Session(spotID: spot.id, startedAt: t0, endedAt: t0.addingTimeInterval(7200), catches: [own, friend])
        let shared = SharedSession.make(from: session, spot: spot, ownName: "けん", device: "A", updatedAt: t0)
        XCTAssertEqual(shared.anglers, ["けん", "たろう"])
        XCTAssertEqual(shared.catchCount, 2)
        XCTAssertEqual(shared.recordName, "session-" + session.id.uuidString)
        let data = try FogJSON.encode(shared, pretty: false)
        XCTAssertEqual(try FogJSON.decode(SharedSession.self, from: data), shared)
        // 釣果の JSON と取り違えない（古い版は釣行のレコードを読み飛ばす）
        XCTAssertNil(try? FogJSON.decode(SharedCatch.self, from: data))
        let catchData = try FogJSON.encode(SharedCatch.make(from: own, ownName: "けん", device: "A", spotName: "小樽港", updatedAt: t0), pretty: false)
        XCTAssertNil(try? FogJSON.decode(SharedSession.self, from: catchData))
        var changed = shared; changed.catchCount = 3
        XCTAssertNotEqual(changed.contentKey, shared.contentKey)
    }
}
