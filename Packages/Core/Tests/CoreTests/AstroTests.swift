import Foundation
import XCTest
@testable import Core

/// L2 受け入れ条件: 日の出入り・月齢が国立天文台の暦と 1 分・0.1 以内。
/// 東京の値は国立天文台「こよみの計算」（東京 35°41′N 139°46′E）。
final class AstroTests: XCTestCase {
    let jst = TimeZone(identifier: "Asia/Tokyo")!
    let tokyo = Coordinate(latitude: 35.6895, longitude: 139.7692)
    let hakodate = Coordinate(latitude: 41.7687, longitude: 140.7288)

    func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0, zone: TimeZone? = nil) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone ?? jst
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
    }

    func assertMinute(_ actual: Date?, _ expected: Date, tolerance: TimeInterval = 90, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("nil", file: file, line: line) }
        XCTAssertEqual(actual.timeIntervalSince(expected), 0, accuracy: tolerance,
                       "expected \(expected) got \(actual)", file: file, line: line)
    }

    func testTokyoNewYear2024() {
        let t = SunCalculator.times(on: date(2024, 1, 1), at: tokyo, timeZone: jst)
        assertMinute(t.sunrise, date(2024, 1, 1, 6, 51))
        assertMinute(t.sunset, date(2024, 1, 1, 16, 39))
    }

    func testTokyoSolstice2024() {
        let t = SunCalculator.times(on: date(2024, 6, 21), at: tokyo, timeZone: jst)
        assertMinute(t.sunrise, date(2024, 6, 21, 4, 25))
        assertMinute(t.sunset, date(2024, 6, 21, 19, 0))
    }

    func testTokyoAutumn2026() {
        // 国立天文台 2026-10-18 東京: 日の出 5:50, 日の入 17:03
        let t = SunCalculator.times(on: date(2026, 10, 18), at: tokyo, timeZone: jst)
        assertMinute(t.sunrise, date(2026, 10, 18, 5, 50))
        assertMinute(t.sunset, date(2026, 10, 18, 17, 3))
    }

    func testHakodateNewYear2024() {
        // 国立天文台 函館（41°46′N 140°44′E）2024-01-01: 日の出 7:04, 日の入 16:16
        let t = SunCalculator.times(on: date(2024, 1, 1), at: hakodate, timeZone: jst)
        assertMinute(t.sunrise, date(2024, 1, 1, 7, 4))
        assertMinute(t.sunset, date(2024, 1, 1, 16, 16))
    }

    func testTwilightBracketsSunrise() {
        let t = SunCalculator.times(on: date(2026, 10, 18), at: hakodate, timeZone: jst)
        XCTAssertLessThan(t.civilDawn!, t.sunrise!)
        XCTAssertLessThan(t.sunset!, t.civilDusk!)
        // マズメは 30 分前後
        XCTAssertEqual(t.sunrise!.timeIntervalSince(t.civilDawn!), 28 * 60, accuracy: 6 * 60)
    }

    func testNewMoonJanuary2024() {
        // 朔 2024-01-11 11:57 UTC
        let newMoon = MoonCalculator.lastNewMoon(before: date(2024, 1, 20))
        let expected = date(2024, 1, 11, 11, 57, zone: TimeZone(identifier: "UTC"))
        XCTAssertEqual(newMoon.timeIntervalSince(expected), 0, accuracy: 15 * 60)
    }

    func testFullMoonJanuary2024() {
        // 望 2024-01-25 17:54 UTC → 黄経差 180°
        let e = MoonCalculator.elongation(at: date(2024, 1, 25, 17, 54, zone: TimeZone(identifier: "UTC")))
        XCTAssertEqual(e, 180, accuracy: 0.3)
    }

    func testMoonAgeMatchesNAODefinition() {
        // 国立天文台の月齢（正午）= 直前の朔からの日数。2024-01-25 正午 JST → 13.6
        let age = MoonCalculator.age(at: date(2024, 1, 25, 12, 0))
        XCTAssertEqual(age, 13.63, accuracy: 0.1)
        // 2024-01-11 朔直後はほぼ 0
        XCTAssertLessThan(MoonCalculator.age(at: date(2024, 1, 11, 21, 30)), 0.1)
    }

    func testMoonTimesExist() {
        let t = MoonCalculator.times(on: date(2024, 1, 25), at: tokyo, timeZone: jst)
        XCTAssertNotNil(t.moonrise)
        XCTAssertNotNil(t.moonset)
        // 満月の日は夕方に昇り朝に沈む
        var cal = Calendar(identifier: .gregorian); cal.timeZone = jst
        XCTAssertGreaterThan(cal.component(.hour, from: t.moonrise!), 14)
        XCTAssertLessThan(cal.component(.hour, from: t.moonset!), 10)
    }

    func testTideNameFromMoonAge() {
        XCTAssertEqual(TideName.from(moonAge: 0.5), .spring)
        XCTAssertEqual(TideName.from(moonAge: 2.9), .spring)
        XCTAssertEqual(TideName.from(moonAge: 3.1), .middle)
        XCTAssertEqual(TideName.from(moonAge: 7.5), .neap)
        // 月齢 10 が長潮、11 が若潮、12〜13 は中潮、14〜17 は大潮
        XCTAssertEqual(TideName.from(moonAge: 10.4), .long)
        XCTAssertEqual(TideName.from(moonAge: 11.2), .young)
        XCTAssertEqual(TideName.from(moonAge: 12.5), .middle)
        XCTAssertEqual(TideName.from(moonAge: 14.2), .spring)
        XCTAssertEqual(TideName.from(moonAge: 17.9), .spring)
        XCTAssertEqual(TideName.from(moonAge: 18.1), .middle)
        XCTAssertEqual(TideName.from(moonAge: 25.5), .long)
        XCTAssertEqual(TideName.from(moonAge: 26.5), .young)
        // 新月の前日（月齢 28.x）は中潮、新月の日（29.x / 0.x）から大潮
        XCTAssertEqual(TideName.from(moonAge: 28.4), .middle)
        XCTAssertEqual(TideName.from(moonAge: 29.3), .spring)
    }

    /// 2026-11-09 16:02 JST が新月。前日の 11/8 は中潮、11/9〜11/11 は大潮（実機フィードバック：11/8 の釣果が「大潮」と記録されていた）
    func testTideNameAroundNovember2026NewMoon() {
        let jst = TimeZone(identifier: "Asia/Tokyo")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = jst
        func day(_ d: Int, hour: Int = 16) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: hour))! }
        XCTAssertEqual(TideName.on(day(8), timeZone: jst), .middle)
        // 同じ日なら朝でも夜でも同じ潮名
        XCTAssertEqual(TideName.on(day(8, hour: 5), timeZone: jst), .middle)
        XCTAssertEqual(TideName.on(day(8, hour: 23), timeZone: jst), .middle)
        XCTAssertEqual(TideName.on(day(9), timeZone: jst), .spring)
        // 11/12 の正午は月齢 2.8（整数部 2）なのでまだ大潮、11/13（3.8）から中潮
        XCTAssertEqual(TideName.on(day(12), timeZone: jst), .spring)
        XCTAssertEqual(TideName.on(day(13), timeZone: jst), .middle)
        // 11/24 が満月 → 11/23〜11/26 が大潮
        XCTAssertEqual(TideName.on(day(24), timeZone: jst), .spring)
        XCTAssertEqual(TideName.on(day(19), timeZone: jst), .neap)
    }
}
