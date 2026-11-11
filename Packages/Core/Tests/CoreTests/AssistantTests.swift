import XCTest
@testable import Core

final class AssistantTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Tokyo")!
    private let here = Coordinate(latitude: 42.03, longitude: 140.82)

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private let species = ["アイナメ": "アイナメ", "アブラコ": "アイナメ", "クロソイ": "クロソイ", "ソイ": "クロソイ", "ホッケ": "ホッケ"]

    // MARK: 声の命令

    func testVoiceCommandsForRecording() {
        XCTAssertEqual(VoiceCommand.parse("ロスト"), .lost(count: 1))
        XCTAssertEqual(VoiceCommand.parse("針ロスト"), .lost(count: 1))
        XCTAssertEqual(VoiceCommand.parse("ロスト 2 回"), .lost(count: 2))
        XCTAssertEqual(VoiceCommand.parse("根掛かりした"), .lost(count: 1))
        XCTAssertEqual(VoiceCommand.parse("針追加"), .hookAdded)
        XCTAssertEqual(VoiceCommand.parse("終了"), .end)
        XCTAssertEqual(VoiceCommand.parse("釣行を終了して"), .end)
        XCTAssertEqual(VoiceCommand.parse("開始"), .start)
        XCTAssertEqual(VoiceCommand.parse("写真"), .camera)
        XCTAssertEqual(VoiceCommand.parse("ベイトに替えた"), .tackle(.bait))
    }

    func testVoiceCommandsForRig() {
        XCTAssertEqual(VoiceCommand.parse("シンカー 14 グラムに替えた"), .rig(hook: nil, sinkerGrams: 14, worm: nil))
        XCTAssertEqual(VoiceCommand.parse("３．５ｇ"), .rig(hook: nil, sinkerGrams: 3.5, worm: nil))
        XCTAssertEqual(VoiceCommand.parse("十四グラム"), .rig(hook: nil, sinkerGrams: 14, worm: nil))
        XCTAssertEqual(VoiceCommand.parse("フック 1/0"), .rig(hook: "1/0", sinkerGrams: nil, worm: nil))
        XCTAssertEqual(VoiceCommand.parse("針を2番に替えた"), .rig(hook: "2", sinkerGrams: nil, worm: nil))
        XCTAssertEqual(VoiceCommand.parse("シンカー14グラム フック1/0"), .rig(hook: "1/0", sinkerGrams: 14, worm: nil))
        let worms = [WormPreset(maker: "エコギア", size: "3インチ", color: "グリパン"), WormPreset(maker: "ガルプ", size: "", color: "赤")]
        XCTAssertEqual(VoiceCommand.parse("ワームをガルプに替えた", worms: worms), .rig(hook: nil, sinkerGrams: nil, worm: "ガルプ 赤"))
    }

    func testQuestionsAndLongTalkAreNotCommands() {
        XCTAssertNil(VoiceCommand.parse("14gと21gでロストが多いのは？"))
        XCTAssertNil(VoiceCommand.parse("明日の鹿部どう？"))
        XCTAssertNil(VoiceCommand.parse("いつ終了すればいい"))
        XCTAssertNil(VoiceCommand.parse("鹿部で先週ホッケが好調らしいと店の人が言っていた。森のほうは今ひとつだとか"))
        XCTAssertNil(VoiceCommand.parse(""))
    }

    // MARK: 振り分け

    func testRouter() {
        XCTAssertEqual(AssistantRouter.route("ロスト", species: species), .command(.lost(count: 1)))
        XCTAssertEqual(AssistantRouter.route("去年の11月、鹿部で何が釣れた？", species: species), .records)
        XCTAssertEqual(AssistantRouter.route("アイナメが一番釣れた潮は？", species: species), .records)
        XCTAssertEqual(AssistantRouter.route("14gと21gでロストが多いのは？", species: species), .records)
        XCTAssertEqual(AssistantRouter.route("今年の記録は", species: species), .records)
        XCTAssertEqual(AssistantRouter.route("30分アタリなし", species: species), .advice)
        XCTAssertEqual(AssistantRouter.route("次どうする？", species: species), .advice)
        XCTAssertEqual(AssistantRouter.route("今週末、朝だけ行ける。どこがいい？", species: species), .plan)
        XCTAssertEqual(AssistantRouter.route("これ持ち帰っていい？", species: species), .fish(""))
        XCTAssertEqual(AssistantRouter.route("アブラコどう食べる？", species: species), .fish("アイナメ"))
        XCTAssertEqual(AssistantRouter.route("今週の道南で釣れているものは？", species: species), .feedDigest)
        XCTAssertEqual(AssistantRouter.route("釣果情報をまとめて", species: species), .feedDigest)
        XCTAssertEqual(AssistantRouter.route("今日のまとめ", species: species), .tripSummary)
        // これまでの流れ：予報の質問と、店先で聞いた話
        XCTAssertEqual(AssistantRouter.route("明日の鹿部どう？", species: species), .other)
        XCTAssertEqual(AssistantRouter.route("鹿部で先週ホッケが好調らしい", species: species), .other)
    }

    // MARK: 自分の記録

    private func sampleSessions(spotA: Spot, spotB: Spot, rig14: UUID, rig21: UUID) -> [Session] {
        func session(_ spot: Spot, _ start: Date, _ items: [(String, Double?, Int, UUID?)], lost: [(Int, UUID?)] = []) -> Session {
            let id = UUID()
            var env = EnvSnapshot(at: start, coordinate: here)
            env.tideRateCmPerHour = -12
            env.tideName = "中潮"
            let catches = items.map { Catch(sessionID: id, at: start.addingTimeInterval(Double($0.2) * 60), coordinate: here, species: $0.0, speciesConfidence: 0.9, lengthCm: $0.1, rigID: $0.3, env: env) }
            let events = lost.map { HookEvent(sessionID: id, at: start.addingTimeInterval(Double($0.0) * 60), coordinate: here, kind: .lost, rigID: $0.1) }
            return Session(id: id, spotID: spot.id, startedAt: start, endedAt: start.addingTimeInterval(3 * 3600), catches: catches, hookEvents: events)
        }
        return [
            session(spotA, date(2025, 11, 8, 15), [("アイナメ", 42, 30, rig14), ("アイナメ", 31, 60, rig14), ("クロソイ", 28, 90, rig21)], lost: [(20, rig21), (40, rig21), (70, rig14)]),
            session(spotA, date(2025, 11, 22, 5), []),
            session(spotB, date(2026, 6, 3, 18), [("クロソイ", 35, 45, rig14)]),
            session(spotA, date(2026, 11, 5, 16), [("アイナメ", 38, 20, rig14), ("ホッケ", 30, 50, rig14)]),
        ]
    }

    func testRecordFilterReadsPeriodSpotAndSpecies() {
        let spotA = Spot(name: "鹿部漁港", coordinate: here), spotB = Spot(name: "森港", coordinate: here)
        let now = date(2026, 11, 11, 13)
        let f = RecordQuery.filter(for: "去年の11月、鹿部で何が釣れた？", spots: [spotA, spotB], species: species, now: now, timeZone: tz)
        XCTAssertEqual(f.from, date(2025, 11, 1))
        XCTAssertEqual(f.to, date(2025, 12, 1))
        XCTAssertEqual(f.spotID, spotA.id)
        XCTAssertNil(f.species)
        XCTAssertEqual(f.label, "去年・11月・鹿部漁港")

        let g = RecordQuery.filter(for: "アブラコが一番釣れた潮は？", spots: [spotA, spotB], species: species, now: now, timeZone: tz)
        XCTAssertNil(g.from); XCTAssertNil(g.spotID)
        XCTAssertEqual(g.species, "アイナメ")

        let h = RecordQuery.filter(for: "先月の釣果は？", spots: [spotA], species: species, now: now, timeZone: tz)
        XCTAssertEqual(h.from, date(2026, 10, 1)); XCTAssertEqual(h.to, date(2026, 11, 1))
        let m = RecordQuery.filter(for: "6月はどうだった", spots: [spotA], species: species, now: now, timeZone: tz)
        XCTAssertEqual(m.month, 6); XCTAssertNil(m.from)
        let w = RecordQuery.filter(for: "今週は何尾？", spots: [spotA], species: species, now: now, timeZone: tz)
        XCTAssertEqual(w.from, date(2026, 11, 9))          // 2026-11-11 は水曜。週は月曜から
    }

    func testRecordFactsCountOnlyMatchingSessions() {
        let spotA = Spot(name: "鹿部漁港", coordinate: here), spotB = Spot(name: "森港", coordinate: here)
        let rig14 = UUID(), rig21 = UUID()
        let sessions = sampleSessions(spotA: spotA, spotB: spotB, rig14: rig14, rig21: rig21)
        let now = date(2026, 11, 11, 13)
        let question = "去年の11月、鹿部で何が釣れた？"
        let f = RecordQuery.filter(for: question, spots: [spotA, spotB], species: species, now: now, timeZone: tz)
        let facts = RecordQuery.facts(question: question, sessions: sessions, spots: [spotA, spotB], rigNames: [rig14: "14g", rig21: "21g"], filter: f, timeZone: tz)
        XCTAssertEqual(facts.catchCount, 3)
        XCTAssertTrue(facts.headline.contains("2 釣行で 3 尾"), facts.headline)
        XCTAssertTrue(facts.headline.contains("ボウズ 1 回"), facts.headline)
        // 「何が」→ 魚種の行が先頭
        XCTAssertEqual(facts.lines.first, "魚種：アイナメ 2 尾（最大 42 cm）、クロソイ 1 尾（最大 28 cm）")
        XCTAssertTrue(facts.lines.contains { $0.hasPrefix("最大：アイナメ 42 cm") })
        XCTAssertTrue(facts.lines.contains("リグ：14g 2 尾・ロスト 1 回、21g 1 尾・ロスト 2 回"), facts.lines.joined(separator: "\n"))
        XCTAssertTrue(facts.lines.contains("ロスト：合計 3 回"))
    }

    func testRecordFactsForSpeciesAndRigQuestions() {
        let spotA = Spot(name: "鹿部漁港", coordinate: here), spotB = Spot(name: "森港", coordinate: here)
        let rig14 = UUID(), rig21 = UUID()
        let sessions = sampleSessions(spotA: spotA, spotB: spotB, rig14: rig14, rig21: rig21)
        let now = date(2026, 11, 11, 13)
        // 魚種で絞る：潮の行が先頭
        var q = "アイナメが一番釣れた潮は？"
        var f = RecordQuery.filter(for: q, spots: [spotA, spotB], species: species, now: now, timeZone: tz)
        var facts = RecordQuery.facts(question: q, sessions: sessions, spots: [spotA, spotB], rigNames: [:], filter: f, timeZone: tz)
        XCTAssertEqual(facts.catchCount, 3)
        XCTAssertTrue(facts.lines.first?.hasPrefix("潮の動き：下げ 3 尾") ?? false, facts.lines.first ?? "")
        // ロストの質問：リグの行が先頭
        q = "14gと21gでロストが多いのは？"
        f = RecordQuery.filter(for: q, spots: [spotA, spotB], species: species, now: now, timeZone: tz)
        facts = RecordQuery.facts(question: q, sessions: sessions, spots: [spotA, spotB], rigNames: [rig14: "14g", rig21: "21g"], filter: f, timeZone: tz)
        XCTAssertTrue(facts.lines.first?.hasPrefix("リグ：") ?? false)
        // 当てはまる記録が無い
        f = RecordQuery.filter(for: "一昨年は？", spots: [spotA], species: species, now: now, timeZone: tz)
        facts = RecordQuery.facts(question: "一昨年は？", sessions: sessions, spots: [spotA], rigNames: [:], filter: f, timeZone: tz)
        XCTAssertEqual(facts.catchCount, 0)
        XCTAssertTrue(facts.headline.contains("記録がありません"))
    }

    func testOtherAnglersFishAreNotCounted() {
        let spot = Spot(name: "鹿部漁港", coordinate: here)
        let id = UUID(), start = date(2026, 11, 1, 15)
        let mine = Catch(sessionID: id, at: start, coordinate: here, species: "アイナメ", speciesConfidence: 0.9, lengthCm: 30)
        let friends = Catch(sessionID: id, at: start, coordinate: here, species: "アイナメ", speciesConfidence: 0.9, lengthCm: 50, angler: "たろう")
        let s = Session(id: id, spotID: spot.id, startedAt: start, endedAt: start.addingTimeInterval(3600), catches: [mine, friends])
        let facts = RecordQuery.facts(question: "最大は？", sessions: [s], spots: [spot], rigNames: [:], filter: RecordFilter(), ownName: "ねも", timeZone: tz)
        XCTAssertEqual(facts.catchCount, 1)
        XCTAssertTrue(facts.lines.first?.contains("30 cm") ?? false)
    }

    // MARK: 次の一手

    private func points(from start: Date, _ scores: [Int]) -> [ScorePoint] {
        scores.enumerated().map { ScorePoint(at: start.addingTimeInterval(Double($0.offset) * 900), score: $0.element, isForecast: true, confidence: .forecast) }
    }

    func testAdvisorPeakAndQuiet() {
        let now = date(2026, 11, 11, 15)
        var input = SessionAdvisor.Input(now: now, sessionStartedAt: now.addingTimeInterval(-50 * 60), scoreNow: 60,
                                         timeline: points(from: now, [60, 62, 66, 72, 80, 84, 80, 70]), zoneCount: 3, timeZone: tz)
        var out = SessionAdvisor.advise(input)
        XCTAssertEqual(SessionAdvisor.quietMinutes(input), 50)
        XCTAssertTrue(out[0].text.hasPrefix("16:15 ごろに山（釣れ率 84）"), out[0].text)
        XCTAssertEqual(out[0].priority, 3)
        XCTAssertTrue(out.contains { $0.text.contains("50 分アタリなし。投げる場所を ② に替える") })
        // いまが山
        input.timeline = points(from: now, [70, 68, 66, 60])
        input.scoreNow = 70
        input.catchTimes = [now.addingTimeInterval(-5 * 60)]
        out = SessionAdvisor.advise(input)
        XCTAssertTrue(out[0].text.hasPrefix("いまが山"))
        XCTAssertFalse(out.contains { $0.text.contains("アタリなし") })
    }

    func testAdvisorLostWindSlackAndRecord() {
        let now = date(2026, 11, 11, 15)
        let input = SessionAdvisor.Input(now: now, sessionStartedAt: now.addingTimeInterval(-90 * 60), catchTimes: [now.addingTimeInterval(-10 * 60)],
                                         lostTimes: [now.addingTimeInterval(-40 * 60), now.addingTimeInterval(-15 * 60), now.addingTimeInterval(-3 * 3600)],
                                         scoreNow: 50, timeline: points(from: now, [50, 50, 49]), tideRateCmPerHour: 1, windSpeedMS: 9, sinkerGrams: 14,
                                         tideNow: "下げ", bestTide: ("下げ", 6, 8), nextTwilight: now.addingTimeInterval(45 * 60), timeZone: tz)
        let out = SessionAdvisor.advise(input)
        XCTAssertEqual(out.count, 3)                                   // 多くても 3 つ
        XCTAssertEqual(out[0].text, "この 1 時間でロスト 2 回。シンカーを 14g から 10g に軽くする")
        XCTAssertTrue(out.allSatisfy { $0.priority >= 2 })
        // 何も無いとき
        let calm = SessionAdvisor.advise(SessionAdvisor.Input(now: now, scoreNow: 45, timeline: points(from: now, [45, 46]), timeZone: tz))
        XCTAssertEqual(calm.count, 1)
        XCTAssertTrue(calm[0].text.hasPrefix("条件は平均的"))
        XCTAssertEqual(SessionAdvisor.text(calm), "1. " + calm[0].text)
    }

    // MARK: 計画

    func testPlanRequestParsing() {
        let wed = date(2026, 11, 11, 13)                       // 水曜
        var r = TripPlanner.parse("今週末、朝だけ行ける。どこがいい？", now: wed, timeZone: tz)
        XCTAssertEqual(r.days, [date(2026, 11, 14), date(2026, 11, 15)])
        XCTAssertEqual(r.fromHour, 4); XCTAssertEqual(r.toHour, 11)
        XCTAssertEqual(r.label, "今週末の朝")
        r = TripPlanner.parse("明日の夕方どこがいい", now: wed, timeZone: tz)
        XCTAssertEqual(r.days, [date(2026, 11, 12)]); XCTAssertEqual(r.fromHour, 15); XCTAssertEqual(r.toHour, 20)
        r = TripPlanner.parse("土曜の5時から9時まで", now: wed, timeZone: tz)
        XCTAssertEqual(r.days, [date(2026, 11, 14)]); XCTAssertEqual(r.fromHour, 5); XCTAssertEqual(r.toHour, 9)
        r = TripPlanner.parse("どこがいい？", now: wed, timeZone: tz)
        XCTAssertEqual(r.days, [date(2026, 11, 11), date(2026, 11, 12)])       // 15 時前は今日と明日
        r = TripPlanner.parse("どこがいい？", now: date(2026, 11, 11, 17), timeZone: tz)
        XCTAssertEqual(r.days, [date(2026, 11, 12)])
        // 土曜に「週末」は今日と明日、日曜は今日だけ
        XCTAssertEqual(TripPlanner.parse("週末", now: date(2026, 11, 14, 8), timeZone: tz).days, [date(2026, 11, 14), date(2026, 11, 15)])
        XCTAssertEqual(TripPlanner.parse("週末", now: date(2026, 11, 15, 8), timeZone: tz).days, [date(2026, 11, 15)])
    }

    func testPlanPicksBestWindowInsideTheSlot() throws {
        let day = date(2026, 11, 14), now = date(2026, 11, 11, 13)
        let request = TripPlanner.parse("土曜の朝", now: now, timeZone: tz)
        // 0 時から 15 分おき。5:00〜6:00 が山（朝の枠の中）、16:00 にもっと高い山（枠の外）
        var scores = [Int](repeating: 40, count: 96)
        for i in 20...24 { scores[i] = 78 }
        scores[22] = 82
        for i in 62...66 { scores[i] = 95 }
        let c = try XCTUnwrap(TripPlanner.best(spotName: "鹿部漁港", dayStart: day, points: points(from: day, scores), request: request, now: now))
        XCTAssertEqual(c.score, 82)
        XCTAssertEqual(c.start, date(2026, 11, 14, 5)); XCTAssertEqual(c.end, date(2026, 11, 14, 6))
        // 過ぎた時刻は見ない
        XCTAssertNil(TripPlanner.best(spotName: "鹿部漁港", dayStart: day, points: points(from: day, scores), request: request, now: date(2026, 11, 14, 12)))

        var far = c; far.spotName = "遠い港"; far.score = 84; far.driveSeconds = 7200
        var near = c; near.driveSeconds = 1800
        var best = c; best.spotName = "いい港"; best.score = 92; best.driveSeconds = 9000
        let ranked = TripPlanner.rank([far, near, best])
        XCTAssertEqual(ranked.map(\.spotName), ["いい港", "鹿部漁港", "遠い港"])     // 3 点以内の差なら近いほう
        let text = TripPlanner.text(request: request, ranked: ranked, timeZone: tz)
        XCTAssertTrue(text.hasPrefix("土曜の朝のおすすめ"), text)
        XCTAssertTrue(text.contains("2. 鹿部漁港 11/14（土） 5:00〜6:00　釣れ率 82"), text)
        XCTAssertTrue(text.contains("車で 30 分 → 4:15 に出発"), text)
        XCTAssertTrue(TripPlanner.text(request: request, ranked: [], timeZone: tz).contains("予報がありません"))
    }

    // MARK: 魚・釣果情報・まとめ

    func testFishFactsNeverInventRules() {
        var e = FishEntry(id: "ainame", name: "アイナメ", aliases: ["アブラコ"], family: "アイナメ科", maxLengthCm: 60, seasonMonths: [10, 11, 12], spawningMonths: [11, 12])
        e.usage = "白身で刺身、煮付け、唐揚げにする。皮目に脂がある。"
        e.maturityLengthCm = 30
        let lines = FishAnswer.facts(e, month: 11, ownCount: 5, ownMaxCm: 42, lengthCm: 24)
        XCTAssertTrue(lines[0].hasPrefix("アイナメ（別名 アブラコ）"))
        XCTAssertTrue(lines.contains("旬：10月・11月・12月（今月は旬）"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("食べ方：白身で刺身") })
        XCTAssertTrue(lines.contains { $0.contains("成熟する大きさは約 30 cm") && $0.contains("今回の 24 cm はまだ小さい") })
        XCTAssertTrue(lines.contains("自分の記録：5 尾、最大 42 cm"))
        XCTAssertEqual(lines.last, "持ち帰りの決まり（サイズ・禁漁期間・地域の規則）は、このアプリのデータにありません")
    }

    func testFeedDigestCountsSpeciesAndPlaces() {
        let now = date(2026, 11, 11, 13)
        func item(_ id: String, _ title: String, daysAgo: Double, place: String? = nil, hint: [String]? = nil) -> FeedItem {
            FeedItem(id: id, feedURL: "u", feedTitle: "道南", title: title, link: nil, summary: nil, publishedAt: now.addingTimeInterval(-daysAgo * 86_400), fetchedAt: now,
                     placeName: place, speciesHint: hint)
        }
        let items = [
            item("1", "函館港でアブラコ好調", daysAgo: 1, place: "函館港"),
            item("2", "鹿部でアイナメとホッケ", daysAgo: 2, place: "鹿部漁港"),
            item("3", "森港 ソイ", daysAgo: 3, place: "森港", hint: ["クロソイ"]),
            item("4", "古い記事 アイナメ", daysAgo: 20, place: "松前港"),
        ]
        let out = FeedDigest.make(items: items, species: species, now: now)
        XCTAssertEqual(out.articleCount, 3)
        XCTAssertEqual(out.lines[0], "この 7 日の釣果情報：3 件")
        XCTAssertEqual(out.lines[1], "・アイナメ 2 件（函館港・鹿部漁港）")
        XCTAssertTrue(out.lines.contains("・クロソイ 1 件（森港）"))
        XCTAssertTrue(out.lines.contains("・ホッケ 1 件（鹿部漁港）"))
        XCTAssertEqual(FeedDigest.make(items: [], species: species, now: now).articleCount, 0)
    }

    func testTripSummaryPerAngler() {
        let start = date(2026, 11, 10, 15, 10), end = date(2026, 11, 10, 18, 40)
        let items = [
            TripSummary.Item(angler: "ねも", species: "アイナメ", lengthCm: 42, at: date(2026, 11, 10, 16, 5)),
            TripSummary.Item(angler: "ねも", species: "アイナメ", lengthCm: 31, at: date(2026, 11, 10, 16, 30)),
            TripSummary.Item(angler: "たろう", species: "クロソイ", lengthCm: 35, at: date(2026, 11, 10, 16, 50)),
            TripSummary.Item(angler: "ねも", species: "クロソイ", lengthCm: nil, at: date(2026, 11, 10, 17, 20)),
        ]
        let text = TripSummary.make(spotName: "鹿部漁港", startedAt: start, endedAt: end, items: items, members: ["はなこ"], lost: 2, tideName: "中潮", timeZone: tz)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "11/10（火）鹿部漁港 15:10〜18:40（3 時間 30 分）")
        XCTAssertEqual(lines[1], "潮：中潮")
        XCTAssertEqual(lines[2], "合計 4 尾")
        XCTAssertEqual(lines[3], "・ねも 3 尾（アイナメ 2、クロソイ 1） 最大 アイナメ 42 cm")
        XCTAssertEqual(lines[4], "・たろう 1 尾（クロソイ 1） 最大 クロソイ 35 cm")
        XCTAssertEqual(lines[5], "・はなこ 0 尾")
        XCTAssertEqual(lines[6], "いちばん釣れた時間：16 時台（3 尾）")
        XCTAssertEqual(lines[7], "ロスト 2 回")
        XCTAssertTrue(TripSummary.make(spotName: "森港", startedAt: start, endedAt: nil, items: [], timeZone: tz).contains("釣果：なし"))
    }
}
