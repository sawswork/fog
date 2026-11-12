import Foundation
import XCTest
@testable import Core

/// L8 受け入れ条件: Core の集計に固定データでのスナップショットテスト。Foundation Models が使えない場合でもテンプレート文で成立。
final class AnalyticsL8Tests: XCTestCase {
    let hakodate = Coordinate(latitude: 41.7822, longitude: 140.7192)
    let jst = TimeZone(identifier: "Asia/Tokyo")!
    let spotA = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    let spotB = UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!

    func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = jst
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
    }

    func env(at: Date, rate: Double, wind: Double = 2, sst: Double = 14, tideName: String = "中潮", trend: Double = -1.5) -> EnvSnapshot {
        var e = EnvSnapshot(at: at, coordinate: hakodate)
        e.tideRateCmPerHour = rate; e.windSpeedMS = wind; e.seaSurfaceTempC = sst; e.tideName = tideName; e.pressureTrend3hHPa = trend
        e.airTemperatureC = 10
        return e
    }

    /// 固定データ：A で 3 釣行（2 回釣れて 1 回ボウズ）、B で 1 釣行。
    func fixture() -> [Session] {
        let s1Start = date(2026, 10, 10, 5)
        var s1 = Session(id: UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!, spotID: spotA, startedAt: s1Start, endedAt: s1Start.addingTimeInterval(3 * 3600))
        s1.snapshots = [env(at: s1Start, rate: 10), env(at: s1Start.addingTimeInterval(1800), rate: 9), env(at: s1Start.addingTimeInterval(3600), rate: 7, wind: 3)]
        s1.catches = [
            Catch(id: UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!, sessionID: s1.id, at: s1Start.addingTimeInterval(1200), coordinate: hakodate, species: "アイナメ", speciesConfidence: 0.9, lengthCm: 32, lengthErrorCm: 1.5, env: env(at: s1Start.addingTimeInterval(1200), rate: 10)),
            Catch(id: UUID(uuidString: "C0000000-0000-4000-8000-000000000002")!, sessionID: s1.id, at: s1Start.addingTimeInterval(2400), coordinate: Coordinate(latitude: 41.7822, longitude: 140.7193), species: "クロソイ", speciesConfidence: 0.8, lengthCm: 25, lengthErrorCm: 1.5, env: env(at: s1Start.addingTimeInterval(2400), rate: 9)),
        ]
        s1.hookEvents = [HookEvent(sessionID: s1.id, at: s1Start.addingTimeInterval(3000), coordinate: Coordinate(latitude: 41.7830, longitude: 140.7200), kind: .lost)]
        s1.rigID = UUID(uuidString: "F0000000-0000-4000-8000-000000000002")

        let s2Start = date(2026, 10, 17, 12)
        var s2 = Session(id: UUID(uuidString: "B0000000-0000-4000-8000-000000000002")!, spotID: spotA, startedAt: s2Start, endedAt: s2Start.addingTimeInterval(2 * 3600))
        s2.snapshots = [env(at: s2Start, rate: 1, wind: 9, tideName: "小潮", trend: 2)]

        let s3Start = date(2026, 10, 24, 5)
        var s3 = Session(id: UUID(uuidString: "B0000000-0000-4000-8000-000000000003")!, spotID: spotA, startedAt: s3Start, endedAt: s3Start.addingTimeInterval(3 * 3600))
        s3.snapshots = [env(at: s3Start, rate: 12, sst: 13), env(at: s3Start.addingTimeInterval(3600), rate: 8, sst: 13)]
        s3.catches = [
            Catch(id: UUID(uuidString: "C0000000-0000-4000-8000-000000000003")!, sessionID: s3.id, at: s3Start.addingTimeInterval(900), coordinate: hakodate, species: "アイナメ", speciesConfidence: 0.95, lengthCm: 41, lengthErrorCm: 1.5, env: env(at: s3Start.addingTimeInterval(900), rate: 12, sst: 13)),
        ]

        let s4Start = date(2026, 11, 1, 16)
        var s4 = Session(id: UUID(uuidString: "B0000000-0000-4000-8000-000000000004")!, spotID: spotB, startedAt: s4Start, endedAt: s4Start.addingTimeInterval(2 * 3600))
        s4.snapshots = [env(at: s4Start, rate: -9, sst: 12)]
        s4.catches = [
            Catch(id: UUID(uuidString: "C0000000-0000-4000-8000-000000000004")!, sessionID: s4.id, at: s4Start.addingTimeInterval(3000), coordinate: Coordinate(latitude: 41.77, longitude: 140.74), species: "アイナメ", speciesConfidence: 0.9, lengthCm: 36, lengthErrorCm: 1.5, env: env(at: s4Start.addingTimeInterval(3000), rate: -9, sst: 12)),
        ]
        return [s1, s2, s3, s4]
    }

    func testSpotStatsSnapshot() {
        let sessions = fixture()
        let a = Analytics.spotStats(sessions: sessions.filter { $0.spotID == spotA })
        XCTAssertEqual(a.sessions, 3)
        XCTAssertEqual(a.catches, 3)
        XCTAssertEqual(a.hours, 8, accuracy: 0.001)
        XCTAssertEqual(a.catchesPerHour, 0.375, accuracy: 0.001)
        XCTAssertEqual(a.blankRate, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(a.hookLosses, 1)
        XCTAssertEqual(a.hookLossPerHour, 0.125, accuracy: 0.001)
        XCTAssertEqual(a.catchHeatmap.values.reduce(0, +), 3)
        XCTAssertEqual(a.hookLossHeatmap.count, 1)
        XCTAssertEqual(a.topSpecies.first?.species, "アイナメ")
        XCTAssertEqual(a.topSpecies.first?.count, 2)
        XCTAssertEqual(a.lastSessionAt, date(2026, 10, 24, 5))
        let all = Analytics.statsBySpot(sessions: sessions)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[spotB]?.catches, 1)
    }

    func testSpeciesStatsAndConditions() {
        let stats = Analytics.speciesStats(sessions: fixture(), timeZone: jst)
        XCTAssertEqual(stats.map(\.species), ["アイナメ", "クロソイ"])
        let ainame = stats[0]
        XCTAssertEqual(ainame.count, 3)
        XCTAssertEqual(ainame.maxLengthCm, 41)
        XCTAssertEqual(ainame.firstCaughtAt, date(2026, 10, 10, 5, 20))
        XCTAssertEqual(ainame.lastCaughtAt, date(2026, 11, 1, 16, 50))
        XCTAssertEqual(ainame.bySpot[spotA], 2)
        XCTAssertEqual(ainame.bySpot[spotB], 1)
        XCTAssertEqual(ainame.topSpots.first?.0, spotA)
        XCTAssertEqual(ainame.sizeHistogram[30], 1)
        XCTAssertEqual(ainame.sizeHistogram[40], 1)
        XCTAssertEqual(ainame.sizeHistogram[35], 1)
        XCTAssertEqual(ainame.maxLengthHistory.map(\.1), [32, 41])
        XCTAssertEqual(ainame.conditions.total, 3)
        XCTAssertEqual(ainame.conditions.byTide["上げ"], 2)
        XCTAssertEqual(ainame.conditions.byTide["下げ"], 1)
        XCTAssertEqual(ainame.conditions.byMonth[10], 2)
        XCTAssertEqual(ainame.conditions.bySeaTemp[12], 2)   // 13, 12 → 12〜14 のバケット
        XCTAssertEqual(ainame.conditions.bySeaTemp[14], 1)
        XCTAssertEqual(ainame.conditions.byPressureTrend["下降"], 3)
        XCTAssertEqual(ainame.conditions.top(ainame.conditions.byTide), "上げ")
    }

    func testHourMonthAndRigStats() {
        let sessions = fixture()
        let cells = Analytics.hourMonthStats(catches: sessions.flatMap(\.catches), timeZone: jst)
        XCTAssertEqual(cells.count, 2)   // 10月5時（3 尾）, 11月16時（1 尾）
        let oct5 = cells.first { $0.month == 10 && $0.hour == 5 }
        XCTAssertEqual(oct5?.catches, 3)
        XCTAssertEqual(oct5!.averageLengthCm!, (32.0 + 25 + 41) / 3, accuracy: 0.001)
        XCTAssertEqual(Analytics.catchesByHour(catches: sessions.flatMap(\.catches), timeZone: jst)[5], 3)
        let months = Analytics.catchesByMonth(catches: sessions.flatMap(\.catches), timeZone: jst)
        XCTAssertEqual(months.map { $0.count }, [3, 1])
        let rigs = Analytics.rigStats(sessions: sessions)
        XCTAssertEqual(rigs.first { $0.rigID == UUID(uuidString: "F0000000-0000-4000-8000-000000000002") }?.catches, 2)
        XCTAssertEqual(rigs.first { $0.rigID == UUID(uuidString: "F0000000-0000-4000-8000-000000000002") }?.hookLosses, 1)
    }

    func testComparison() {
        let sessions = fixture()
        let c = Analytics.comparison(current: sessions[2], previous: sessions[1])!
        XCTAssertEqual(c.catchesDelta, 1)
        XCTAssertEqual(c.hoursDelta, 1, accuracy: 0.001)
        XCTAssertEqual(c.windDeltaMS!, -7, accuracy: 0.001)
        XCTAssertEqual(c.tideNamePrevious, "小潮")
        XCTAssertNil(Analytics.comparison(current: sessions[0], previous: nil))
    }

    func testRecordJudgementConsidersErrorRange() {
        let sessions = fixture()
        let existing = sessions.flatMap { s in s.catches.map { ($0, s.spotID) } }
        // 初魚種
        let hokke = Catch(sessionID: sessions[0].id, at: .now, coordinate: hakodate, species: "ホッケ", speciesConfidence: 0.9, lengthCm: 30, lengthErrorCm: 1)
        let j1 = Analytics.judge(new: hokke, newSpotID: spotA, existing: existing)
        XCTAssertTrue(j1.isFirstSpecies); XCTAssertFalse(j1.isPersonalBest)
        // 41±1.5 の既存最大に対し 42±1.5 → 下限 40.5 は上限 42.5 を超えない → 記録ではない
        let close = Catch(sessionID: sessions[0].id, at: .now, coordinate: hakodate, species: "アイナメ", speciesConfidence: 0.9, lengthCm: 42, lengthErrorCm: 1.5)
        XCTAssertFalse(Analytics.judge(new: close, newSpotID: spotA, existing: existing).isPersonalBest)
        // 45±1.5 → 下限 43.5 > 42.5 → 自己記録・釣り場記録
        let big = Catch(sessionID: sessions[0].id, at: .now, coordinate: hakodate, species: "アイナメ", speciesConfidence: 0.9, lengthCm: 45, lengthErrorCm: 1.5)
        let j3 = Analytics.judge(new: big, newSpotID: spotA, existing: existing)
        XCTAssertTrue(j3.isPersonalBest); XCTAssertTrue(j3.isSpotRecord); XCTAssertEqual(j3.previousBestCm, 41)
        // B の釣り場記録（B の既存最大 36）：38±1.5 → 下限 36.5 ≤ 37.5 → 釣り場記録ではない、40 → 記録
        let atB = Catch(sessionID: sessions[3].id, at: .now, coordinate: hakodate, species: "アイナメ", speciesConfidence: 0.9, lengthCm: 40, lengthErrorCm: 1.5)
        let j4 = Analytics.judge(new: atB, newSpotID: spotB, existing: existing)
        XCTAssertTrue(j4.isSpotRecord); XCTAssertFalse(j4.isPersonalBest)
    }

    func testGuideEntries() {
        let entries = Guide.entries(sessions: fixture(), now: date(2026, 11, 3, 12), timeZone: jst)
        XCTAssertEqual(entries.count, 2)
        let ainame = entries.first { $0.species == "アイナメ" }!
        XCTAssertEqual(ainame.count, 3)
        XCTAssertEqual(ainame.maxLengthCm, 41)
        XCTAssertEqual(ainame.bestCatchID, UUID(uuidString: "C0000000-0000-4000-8000-000000000003"))
        XCTAssertEqual(ainame.topSpots.first?.spotID, spotA)
        XCTAssertFalse(ainame.recentlyUpdated)   // 最後の記録更新は 10/24、今は 11/3
        let soi = entries.first { $0.species == "クロソイ" }!
        XCTAssertFalse(soi.recentlyUpdated)
        XCTAssertEqual(Guide.sorted(entries, by: .maxLength).first?.species, "アイナメ")
        XCTAssertEqual(Guide.sorted(entries, by: .recent).first?.species, "アイナメ")
        // 1 週間以内の初釣果は点が付く
        let recent = Guide.entries(sessions: fixture(), now: date(2026, 11, 2, 12), timeZone: jst)
        XCTAssertTrue(recent.first { $0.species == "アイナメ" }!.recentlyUpdated == false)
        let fresh = Guide.entries(sessions: [fixture()[3]], now: date(2026, 11, 2, 12), timeZone: jst)
        XCTAssertTrue(fresh[0].recentlyUpdated)
    }

    /// 図鑑に仲間の魚を足す（F-66）：同じ魚種は 1 つにまとめて釣った人ごとに数え、自分の数字は変えない
    func testGuideMergesFriendCatches() {
        let now = date(2026, 11, 3, 12)
        let own = Guide.entries(sessions: fixture(), now: now, timeZone: jst)
        func f(_ n: Int, _ species: String, _ angler: String, _ cm: Double?, day: Int, local: Bool = false) -> GuideFriendCatch {
            GuideFriendCatch(id: UUID(uuidString: "D0000000-0000-4000-8000-00000000000\(n)")!, species: species, angler: angler, lengthCm: cm,
                             at: date(2026, 11, day, 9), isLocal: local)
        }
        let friends = [
            f(1, "アイナメ", "ねも", 45, day: 1), f(2, "アイナメ", "ねも", nil, day: 2), f(3, "アイナメ", "たろ", 30, day: 2, local: true),
            f(4, "ホッケ", "ねも", 33, day: 2), f(5, "ホッケ", "ねも", 36, day: 1),
            f(6, "", "ねも", 20, day: 2),             // 魚種名なしは入れない
            f(1, "アイナメ", "ねも", 45, day: 1),      // 同じ ID は 1 つに数える
            f(7, "クロソイ", "自分", 28, day: 2),      // 仲間が撮った自分の魚は自分の行へ
        ]
        let merged = Guide.merged(own: own, friends: friends, ownName: "自分", now: now)
        XCTAssertEqual(merged.count, 3)

        let ainame = merged.first { $0.species == "アイナメ" }!
        XCTAssertEqual(ainame.count, 3)             // 自分の数字はそのまま
        XCTAssertEqual(ainame.maxLengthCm, 41)
        XCTAssertFalse(ainame.isFriendOnly)
        XCTAssertEqual(ainame.anglers.map(\.name), ["自分", "ねも", "たろ"])
        XCTAssertEqual(ainame.anglers.map(\.count), [3, 2, 1])
        XCTAssertEqual(ainame.anglers.map(\.isOwn), [true, false, false])
        XCTAssertEqual(ainame.anglers[1].maxLengthCm, 45)
        XCTAssertEqual(ainame.friendCatches.count, 3)
        XCTAssertEqual(ainame.friendBest?.lengthCm, 45)
        XCTAssertEqual(ainame.totalCount, 6)
        XCTAssertEqual(ainame.latestAt, date(2026, 11, 2, 9))

        let hokke = merged.first { $0.species == "ホッケ" }!
        XCTAssertTrue(hokke.isFriendOnly)
        XCTAssertEqual(hokke.anglers.map(\.name), ["ねも"])
        XCTAssertEqual(hokke.anglers[0].count, 2)
        XCTAssertEqual(hokke.anglers[0].maxLengthCm, 36)
        XCTAssertEqual(hokke.bestCatchID, UUID(uuidString: "D0000000-0000-4000-8000-000000000005"))
        XCTAssertEqual(hokke.shownMaxLengthCm, 36)
        XCTAssertNil(hokke.maxLengthCm)
        XCTAssertTrue(hokke.recentlyUpdated)        // 初めて見たのが 1 週間以内

        let soi = merged.first { $0.species == "クロソイ" }!
        XCTAssertEqual(soi.count, 1)
        XCTAssertEqual(soi.anglers.count, 1)
        XCTAssertTrue(soi.anglers[0].isOwn)
        XCTAssertEqual(soi.anglers[0].count, 2)
        XCTAssertTrue(soi.friends.isEmpty)

        // 並び：最大サイズは自分の記録、無ければ仲間の記録で比べる
        XCTAssertEqual(Guide.sorted(merged, by: .maxLength).map(\.species).first, "アイナメ")
        XCTAssertEqual(Guide.sorted(merged, by: .count).map(\.species), ["アイナメ", "クロソイ", "ホッケ"])
        // 仲間がいなければ、自分の 1 行だけ
        let alone = Guide.merged(own: own, friends: [], ownName: "自分", now: now)
        XCTAssertEqual(alone.count, 2)
        XCTAssertEqual(alone.first { $0.species == "アイナメ" }!.anglers.map(\.name), ["自分"])
    }

    func testReportTemplateWorksWithoutFoundationModels() {
        let sessions = fixture()
        let before = sessions[0].catches.map { ($0, spotA) } + sessions[1].catches.map { ($0, spotA) }
        let facts = ReportFacts.make(session: sessions[2], spotName: "函館港", previous: sessions[1], allCatchesBefore: before, timeZone: jst)
        XCTAssertEqual(facts.catches, 1)
        XCTAssertEqual(facts.records, ["アイナメ 自己記録 41cm"])
        XCTAssertEqual(facts.comparison?.catchesDelta, 1)
        let summary = ReportTemplate.summary(facts)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(summary.contains("アイナメ"), summary)
        let body = ReportTemplate.body(facts, timeZone: jst)
        XCTAssertTrue(body.contains("函館港 5:00〜8:00"), body)
        XCTAssertTrue(body.contains("自己記録"), body)
        XCTAssertTrue(body.contains("前回比"), body)
        XCTAssertTrue(body.contains("次回"), body)
        // ボウズ
        let blank = ReportFacts.make(session: sessions[1], spotName: "函館港", previous: sessions[0], allCatchesBefore: [], timeZone: jst)
        XCTAssertEqual(ReportTemplate.summary(blank), "ボウズ（2時間）")
        XCTAssertTrue(ReportTemplate.body(blank, timeZone: jst).contains("風が 5 m/s 以下"))
    }

    /// レポート：ほかの人の魚は尾数には入るが、初物・自己記録には入れない。釣った人ごとの尾数を書く（釣った人を後から直したら、作り直しで変わる）
    func testReportSeparatesOtherAnglers() {
        let spot = UUID(), id = UUID()
        let here = Coordinate(latitude: 41.8, longitude: 140.6)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let mine = Catch(sessionID: id, at: start.addingTimeInterval(600), coordinate: here, species: "クロソイ", speciesConfidence: 0.9, lengthCm: 26)
        let friend = Catch(sessionID: id, at: start.addingTimeInterval(1200), coordinate: here, species: "クロソイ", speciesConfidence: 0.9, lengthCm: 33, angler: "のぶ")
        let session = Session(id: id, spotID: spot, startedAt: start, endedAt: start.addingTimeInterval(3600), catches: [mine, friend])
        let facts = ReportFacts.make(session: session, spotName: "上磯", previous: nil, allCatchesBefore: [], ownName: "ねも")
        XCTAssertEqual(facts.catches, 2)
        XCTAssertEqual(facts.byAngler.map(\.name), ["ねも", "のぶ"])
        XCTAssertEqual(facts.records, ["初 クロソイ"])                        // のぶの 33 cm は自己記録にしない
        let body = ReportTemplate.body(facts)
        XCTAssertTrue(body.contains("釣った人：ねも 1尾、のぶ 1尾。"), body)
        // 全部自分なら「釣った人」の行は出さない
        let solo = ReportFacts.make(session: Session(id: id, spotID: spot, startedAt: start, endedAt: start.addingTimeInterval(3600), catches: [mine]),
                                    spotName: "上磯", previous: nil, allCatchesBefore: [], ownName: "ねも")
        XCTAssertTrue(solo.byAngler.isEmpty)
        XCTAssertFalse(ReportTemplate.body(solo).contains("釣った人"))
    }
}
