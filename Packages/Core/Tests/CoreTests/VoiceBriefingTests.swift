import XCTest
@testable import Core

/// 釣行中の音声の知らせ（F-70）
final class VoiceBriefingTests: XCTestCase {
    let jst = TimeZone(identifier: "Asia/Tokyo")!
    func at(_ h: Int, _ m: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = jst
        return cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: h, minute: m))!
    }

    func testFullBriefing() {
        let input = VoiceBriefing.Input(now: at(9, 30), spotName: "森港", score: 62, tideLevelCm: 58.4, tideRateCmPerHour: 12, tideName: "若潮",
                                        nextHighTideAt: at(12, 28), nextLowTideAt: at(19, 25), weatherLater: "雪",
                                        precipitationChanceLater: 0.8, temperatureLaterC: 2.2, windLaterMS: 3.1, windDirectionLaterDeg: 270)
        XCTAssertEqual(VoiceBriefing.text(input, timeZone: jst),
                       "9時30分。森港。釣れ率は62。若潮の上げ潮、潮位58センチ。次の満潮は12時28分。30分後は雪、降水確率80パーセント、気温2度、西の風3メートル。")
    }

    func testTideDirectionAndNextExtreme() {
        // 下げ潮で、次は干潮。正時は「分」を言わない。過ぎた満潮は言わない
        let falling = VoiceBriefing.Input(now: at(15, 0), spotName: "鹿部漁港", score: 40, tideLevelCm: 71, tideRateCmPerHour: -9, tideName: "大潮",
                                          nextHighTideAt: at(12, 28), nextLowTideAt: at(19, 0))
        XCTAssertEqual(VoiceBriefing.text(falling, timeZone: jst), "15時。鹿部漁港。釣れ率は40。大潮の下げ潮、潮位71センチ。次の干潮は19時。")
        XCTAssertEqual(VoiceBriefing.tideWord(rateCmPerHour: 1.5), "潮止まり")
        XCTAssertEqual(VoiceBriefing.tideWord(rateCmPerHour: -3), "下げ潮")
        let slack = VoiceBriefing.Input(now: at(6, 16), spotName: "", tideLevelCm: 30, tideRateCmPerHour: 0.4, nextHighTideAt: at(12, 28))
        XCTAssertEqual(VoiceBriefing.text(slack, timeZone: jst), "6時16分。潮止まり、潮位30センチ。次の満潮は12時28分。")
    }

    func testOmitsUnknownsAndReadsNegativeTemperature() {
        // 分からない項目は言わない
        XCTAssertEqual(VoiceBriefing.text(VoiceBriefing.Input(now: at(0, 5), spotName: "釣り場"), timeZone: jst), "0時5分。釣り場。")
        // 氷点下は「マイナス」。風が 1 メートル未満は「弱い」。向きが無ければ速さだけ
        let cold = VoiceBriefing.Input(now: at(21, 0), spotName: "八雲漁港", score: 130, laterMinutes: 30, weatherLater: "晴れ",
                                       temperatureLaterC: -3.6, windLaterMS: 0.4)
        XCTAssertEqual(VoiceBriefing.text(cold, timeZone: jst), "21時。八雲漁港。釣れ率は100。30分後は晴れ、気温マイナス4度、風は弱い。")
        let wind = VoiceBriefing.Input(now: at(21, 0), spotName: "八雲漁港", laterMinutes: 60, precipitationChanceLater: 0.04, windLaterMS: 6.6)
        XCTAssertEqual(VoiceBriefing.text(wind, timeZone: jst), "21時。八雲漁港。60分後は降水確率4パーセント、風7メートル。")
    }

    /// 読むのは 0 分と 30 分ちょうど
    func testNextSlotIsOnTheHalfHour() {
        XCTAssertEqual(VoiceBriefing.nextSlot(after: at(9, 13)), at(9, 30))
        XCTAssertEqual(VoiceBriefing.nextSlot(after: at(9, 30)), at(10, 0))                              // ちょうどの時刻なら、その次
        XCTAssertEqual(VoiceBriefing.nextSlot(after: at(9, 30).addingTimeInterval(0.3)), at(10, 0))      // 読んだ直後に予約し直しても同じ回にならない
        XCTAssertEqual(VoiceBriefing.nextSlot(after: at(23, 59)), at(23, 59).addingTimeInterval(60))     // 日付をまたぐ
        XCTAssertEqual(VoiceBriefing.nextSlot(after: at(9, 29).addingTimeInterval(59)), at(9, 30))
    }
}

