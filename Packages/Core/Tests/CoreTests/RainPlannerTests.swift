import XCTest
@testable import Core

/// 雨が降り出す前の通知（F-69）
final class RainPlannerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    func t(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    /// `wet` の分（今からの分）だけ雨。ほかは乾いている。60 分ぶん
    func minutes(wet: ClosedRange<Int>..., intensity: Double = 0.8, kind: RainPlanner.Kind = .rain) -> [RainPlanner.Minute] {
        (0..<60).map { m in
            let isWet = wet.contains { $0.contains(m) }
            return RainPlanner.Minute(at: t(Double(m)), chance: isWet ? 0.8 : 0.1, intensityMMH: isWet ? intensity : 0, kind: kind)
        }
    }

    func alert(_ d: RainPlanner.Decision) -> RainPlanner.Alert? {
        if case .notify(let a) = d { return a }
        return nil
    }

    func testNotifiesNowWhenRainIsNear() {
        let d = RainPlanner.decide(now: now, minutes: minutes(wet: 18...59), hours: [], previous: nil)
        let a = alert(d)
        XCTAssertEqual(a?.onset, t(18))
        XCTAssertEqual(a?.fireAt, now)                    // 30 分より近いので、すぐ知らせる
        XCTAssertEqual(a?.minutesAhead, 18)
        XCTAssertEqual(a?.title, "まもなく雨")
        XCTAssertEqual(a?.body(), "約 20 分後に雨が降りそうです（弱い雨）")   // 10 分以上は 5 分刻み
        XCTAssertEqual(a?.coarse, false)
    }

    func testSchedulesThirtyMinutesBefore() {
        let a = alert(RainPlanner.decide(now: now, minutes: minutes(wet: 50...59, intensity: 4), hours: [], previous: nil))
        XCTAssertEqual(a?.onset, t(50))
        XCTAssertEqual(a?.fireAt, t(20))
        XCTAssertEqual(a?.body(), "約 30 分後に雨が降りそうです（雨）")
        // 雪は雪と言う。7 分後は丸めない
        let snow = alert(RainPlanner.decide(now: now, minutes: minutes(wet: 7...40, intensity: 3.5, kind: .snow), hours: [], previous: nil))
        XCTAssertEqual(snow?.title, "まもなく雪")
        XCTAssertEqual(snow?.body(), "約 7 分後に雪が降りそうです（強い雪）")
        let soon = alert(RainPlanner.decide(now: now, minutes: minutes(wet: 4...30, intensity: 12), hours: [], previous: nil))
        XCTAssertEqual(soon?.body(), "約 4 分後に雨が降りそうです（強い雨）")
    }

    func testIgnoresBlipsAndCurrentRain() {
        // 2 分だけの反応は拾わない
        XCTAssertEqual(RainPlanner.decide(now: now, minutes: minutes(wet: 20...21), hours: [], previous: nil), .nothing)
        // 2 分の反応のあと、本降りが 40 分後から
        XCTAssertEqual(alert(RainPlanner.decide(now: now, minutes: minutes(wet: 20...21, 40...59), hours: [], previous: nil))?.onset, t(40))
        // いま降っている：知らせない
        XCTAssertEqual(RainPlanner.decide(now: now, minutes: minutes(wet: 0...30), hours: [], previous: nil), .nothing)
        // 確率が低い・強さが足りない分は雨に数えない
        let weak = (0..<60).map { RainPlanner.Minute(at: t(Double($0)), chance: 0.4, intensityMMH: 2) }
        XCTAssertEqual(RainPlanner.decide(now: now, minutes: weak, hours: [], previous: nil), .nothing)
        XCTAssertEqual(RainPlanner.decide(now: now, minutes: [], hours: [], previous: nil), .nothing)
    }

    func testDoesNotRepeatAndCancels() {
        let first = alert(RainPlanner.decide(now: now, minutes: minutes(wet: 18...59), hours: [], previous: nil))!
        // 10 分後に見直し：降り出しが 5 分ずれただけ。もう知らせたので何もしない
        let later = t(10)
        let shifted = (0..<60).map { m -> RainPlanner.Minute in
            let wet = m >= 13
            return RainPlanner.Minute(at: later.addingTimeInterval(Double(m) * 60), chance: wet ? 0.9 : 0, intensityMMH: wet ? 1 : 0)
        }
        XCTAssertEqual(RainPlanner.decide(now: later, minutes: shifted, hours: [], previous: first), .nothing)
        // 予約しただけ（まだ鳴っていない）の通知：雨が早まったら置き換える、ほぼ同じなら置き換えない、消えたら取り消す
        let scheduled = alert(RainPlanner.decide(now: now, minutes: minutes(wet: 50...59), hours: [], previous: nil))!
        XCTAssertEqual(scheduled.fireAt, t(20))
        let earlier = alert(RainPlanner.decide(now: t(5), minutes: minutes(wet: 25...59), hours: [], previous: scheduled))
        XCTAssertEqual(earlier?.onset, t(25))
        XCTAssertEqual(earlier?.fireAt, t(5))
        XCTAssertEqual(RainPlanner.decide(now: t(5), minutes: minutes(wet: 52...59), hours: [], previous: scheduled), .nothing)
        XCTAssertEqual(RainPlanner.decide(now: t(5), minutes: minutes(wet: 70...80), hours: [], previous: scheduled), .cancel)
        // 鳴ったあとで雨が消えても、取り消すものは無い
        XCTAssertEqual(RainPlanner.decide(now: t(25), minutes: [], hours: [], previous: scheduled), .nothing)
        // 別の雨（2 時間後）は、あらためて知らせる
        let far = t(120)
        let next = (0..<60).map { m -> RainPlanner.Minute in
            RainPlanner.Minute(at: far.addingTimeInterval(Double(m) * 60), chance: m >= 10 ? 0.9 : 0, intensityMMH: m >= 10 ? 1 : 0)
        }
        XCTAssertEqual(alert(RainPlanner.decide(now: far, minutes: next, hours: [], previous: first))?.onset, far.addingTimeInterval(600))
    }

    func testFallsBackToHourlyForecast() {
        let jst = TimeZone(identifier: "Asia/Tokyo")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = jst
        // 13:20
        let base = cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 13, minute: 20))!
        let h13 = cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 13))!
        func hour(_ offset: Int, chance: Double, mm: Double, kind: RainPlanner.Kind = .rain) -> RainPlanner.Hour {
            RainPlanner.Hour(at: h13.addingTimeInterval(Double(offset) * 3600), chance: chance, amountMM: mm, kind: kind)
        }
        // 分単位の予報が無い地域：14 時から雪（40 分後）→ 30 分前の 13:30 に知らせる
        let d = RainPlanner.decide(now: base, minutes: [], hours: [hour(0, chance: 0.1, mm: 0), hour(1, chance: 0.7, mm: 1.2, kind: .snow), hour(2, chance: 0.9, mm: 3)], previous: nil)
        guard case .notify(let a) = d else { return XCTFail("知らせる") }
        XCTAssertTrue(a.coarse)
        XCTAssertEqual(a.onset, h13.addingTimeInterval(3600))
        XCTAssertEqual(a.fireAt, base.addingTimeInterval(600))
        XCTAssertEqual(a.body(timeZone: jst), "14 時ごろから雪の予報です（約 30 分後）")
        // いまの 1 時間がすでに雨の予報なら、降り出しは分からないので知らせない
        XCTAssertEqual(RainPlanner.decide(now: base, minutes: [], hours: [hour(0, chance: 0.8, mm: 2), hour(1, chance: 0.8, mm: 2)], previous: nil), .nothing)
        // 2 時間より先は知らせない。確率や量が小さい時間は数えない
        XCTAssertEqual(RainPlanner.decide(now: base, minutes: [], hours: [hour(0, chance: 0, mm: 0), hour(1, chance: 0.3, mm: 2), hour(2, chance: 0.9, mm: 0.1), hour(4, chance: 0.9, mm: 3)], previous: nil), .nothing)
        // 分単位の予報（60 分先まで乾いている）の先を、1 時間ごとの予報で見る
        let dry = (0..<60).map { RainPlanner.Minute(at: base.addingTimeInterval(Double($0) * 60), chance: 0, intensityMMH: 0) }
        let beyond = RainPlanner.decide(now: base, minutes: dry, hours: [hour(0, chance: 0, mm: 0), hour(1, chance: 0.9, mm: 2), hour(2, chance: 0.9, mm: 2)], previous: nil)
        guard case .notify(let b) = beyond else { return XCTFail("知らせる") }
        XCTAssertEqual(b.onset, h13.addingTimeInterval(2 * 3600))   // 14 時台は分単位の予報が乾いている。15 時から
        XCTAssertEqual(b.fireAt, h13.addingTimeInterval(2 * 3600 - 1800))
    }
}
