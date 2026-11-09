import Foundation
import SwiftUI
import Core

/// ホーム画面の状態（§3）。今の釣れ率・内訳・魚種別、4 チップ、イベント列、先の推移と潮位曲線を保存データと端末計算から作る。
@MainActor
@Observable
final class HomeViewModel {
    struct Chip: Identifiable {
        enum Kind: String { case tide, light, wind, weather }
        enum Tone { case good, normal, bad }
        let kind: Kind
        var symbol: String
        /// 大きく出す値（時刻・風速・気温）
        var value: String
        /// 値の意味（満潮・朝マズメ・北西・晴れ）
        var label: String
        var tone: Tone
        var id: String { kind.rawValue }
        var text: String { label.isEmpty ? value : "\(label) \(value)" }
    }

    struct TidePoint: Identifiable, Sendable {
        let at: Date
        let levelCm: Double
        var id: Date { at }
    }

    private(set) var spot: Spot?
    private(set) var coordinate: Coordinate = SampleData.hakodate
    private(set) var now: Date = .now
    private(set) var score: ScoreResult?
    private(set) var speciesScores: [(species: String, score: Int)] = []
    private(set) var chips: [Chip] = []
    private(set) var events: [ScoreEvent] = []
    private(set) var timeline: [ScorePoint] = []
    private(set) var tideCurve: [TidePoint] = []
    private(set) var tideExtremes: [TideExtreme] = []
    private(set) var sunTimesByDay: [SunTimes] = []
    private(set) var forecastHorizon: Date?
    private(set) var isRecording = false
    private(set) var moonAge: Double = 0
    private(set) var rangeStart: Date = .now
    private(set) var rangeEnd: Date = .now
    var scrollTarget: Date?
    /// グラフに出している日（0 = 今日、-1 = 昨日、+n = n 日後）
    var dayOffset: Int = 0 {
        didSet {
            // 表示していない日・週の計算（1 日 約 50 ms）はメインでせず、裏で用意してから切り替える（日送りの固まりの修正。2026-11-09）
            dayTask?.cancel()
            let target = dayOffset
            if dayCache[target] != nil, neededOffsets().allSatisfy({ dayCache[$0] != nil }) { updateDay(); updateWeekOutlook(); return }
            dayTask = Task { [weak self] in
                guard let self else { return }
                await self.ensureDays(self.neededOffsets())
                guard !Task.isCancelled, self.dayOffset == target else { return }
                self.updateDay(); self.updateWeekOutlook()
            }
        }
    }
    private var dayTask: Task<Void, Never>?
    private(set) var dayStart: Date = .now
    private(set) var dayEnd: Date = .now
    private(set) var dayTimeline: [ScorePoint] = []
    private(set) var dayTide: [TidePoint] = []
    private(set) var dayExtremes: [TideExtreme] = []
    /// その日の 0,3,…,21 時の環境（詳細表）
    private(set) var dayDetail: [EnvSnapshot] = []
    private(set) var seaSurfaceTempC: Double?
    private(set) var nextFetchAt: Date?
    /// 今の潮位（cm）と変化率（cm/時、正で上げ）
    private(set) var nowTideLevelCm: Double?
    private(set) var nowTideRateCmPerHour: Double?
    /// 表示中の日の日の出入・月の出入
    private(set) var daySun: SunTimes?
    private(set) var dayMoon: MoonTimes?
    /// 週間の見通し（今日から 7 日）：その日の最高釣れ率と昼の天気
    struct DayOutlook: Identifiable {
        let offset: Int
        let dayStart: Date
        /// 推移の範囲外（データなし）なら nil
        let maxScore: Int?
        let conditionCode: String?
        /// 曜日。1=日 … 7=土
        let weekday: Int
        /// 祝日（振替休日・国民の休日を含む）
        let isHoliday: Bool
        var id: Int { offset }
        var available: Bool { maxScore != nil }
    }
    private(set) var weekOutlook: [DayOutlook] = []
    /// 釣果情報（F-27）の 1 行
    private(set) var feedHeadline: FeedItem?
    /// 記録中の釣行（F-38 ライブ画面）
    private(set) var liveSession: Core.Session?
    private(set) var liveNextTide: TideExtreme?
    private(set) var liveNextTwilight: (label: String, at: Date)?

    private var services: AppServices?
    /// 釣り場詳細に埋め込むとき：この釣り場に固定し、ウィジェット・通知の書き出しはしない（F-51）
    var fixedSpotID: UUID?
    /// ストアに無い釣り場（未登録の漁港）に固定するとき。`fixedSpotID` と組で使う
    var fixedSpot: Spot?
    var isEmbedded = false
    private let cache = AnalysisCache()
    private var timelineKey = ""
    private var dayCache: [Int: DayData] = [:]
    private var calc: DayCalculator?
    /// 右軸の目盛りに使う潮位の範囲（1 か月）
    private(set) var tideRangeCm: ClosedRange<Double> = 0...200

    struct DayData: Sendable { let timeline: [ScorePoint]; let tide: [TidePoint]; let extremes: [TideExtreme] }

    /// 1 日分の推移・潮位曲線・満干を計算する（純粋な計算。約 50 ms）
    struct DayCalculator: Sendable {
        let engine: ScoreEngine
        let builder: EnvSnapshotBuilder
        let inputs: EnvSnapshotBuilder.Inputs
        let tide: TideEngine?
        let coordinate: Coordinate
        let timeZone: TimeZone
        let horizon: Date?

        func compute(from start: Date) -> DayData {
            let end = start.addingTimeInterval(86_400)
            let extremes = tide?.extremes(from: start.addingTimeInterval(-6 * 3600), to: end.addingTimeInterval(6 * 3600)) ?? []
            let timeline = ScoreTimeline.compute(engine: engine, coordinate: coordinate, from: start, to: end, stepMinutes: 15, timeZone: timeZone) { t in
                var e = builder.build(at: t, coordinate: coordinate, inputs: inputs, tide: tide, extremes: extremes)
                if let h = horizon, t > h { e.isForecast = true }
                return e
            }
            let curve = stride(from: 0, through: 86_400, by: 600).compactMap { offset -> TidePoint? in
                let t = start.addingTimeInterval(offset)
                return tide.map { TidePoint(at: t, levelCm: $0.level(at: t)) }
            }
            return DayData(timeline: timeline, tide: curve, extremes: extremes.filter { $0.at >= start && $0.at <= end })
        }
    }

    private var refreshingNetwork = false
    private var lastWidgetKey = ""
    private var lastWidgetPublishAt: Date = .distantPast
    private var lastNotifyKey = ""
    private var lastNotifyScheduleAt: Date = .distantPast

    /// 画面に要る日：表示中の日、その週（月〜日）、ウィジェットの今日〜明後日
    private func neededOffsets() -> [Int] {
        let range = dayOffsetRange
        let shown = min(max(dayOffset, range.lowerBound), range.upperBound)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today.addingTimeInterval(Double(shown) * 86_400))
        let monday = shown - (weekday + 5) % 7
        return Array(Set([shown, 0, 1, 2] + Array(monday...(monday + 6)))).filter { range.contains($0) }.sorted()
    }

    /// 足りない日を裏で計算してキャッシュに入れる
    private func ensureDays(_ offsets: [Int]) async {
        guard let calc else { return }
        let missing = offsets.filter { dayCache[$0] == nil }
        guard !missing.isEmpty else { return }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        let key = timelineKey
        let computed: [(Int, DayData)] = await Task.detached(priority: .userInitiated) {
            missing.map { ($0, calc.compute(from: today.addingTimeInterval(Double($0) * 86_400))) }
        }.value
        // 計算中に場所や予報が変わっていたら捨てる
        guard key == timelineKey else { return }
        for (o, d) in computed { dayCache[o] = d }
    }

    /// オフセット日のデータ（キャッシュ）
    private func dayData(_ offset: Int) -> DayData {
        if let d = dayCache[offset] { return d }
        guard let calc else { return DayData(timeline: [], tide: [], extremes: []) }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let start = cal.startOfDay(for: now).addingTimeInterval(Double(offset) * 86_400)
        let d = calc.compute(from: start)
        dayCache[offset] = d
        return d
    }
    let timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current

    func attach(_ services: AppServices) {
        self.services = services
    }

    /// ワンタップの開始・終了（F-48）。開始できなかった（位置が決められない）ときは false
    @discardableResult
    func toggleSession() async -> Bool {
        guard let services else { return false }
        let ok: Bool
        if isRecording {
            await services.detection.endManually()
            ok = true
        } else {
            ok = await services.detection.startManually()
        }
        await refresh()
        return ok
    }

    /// 全部を計算し直す（起動時・30 秒ごと・釣り場切替・ストア変更時）。
    func refresh(now: Date = .now) async {
        guard let services else { return }
        await Perf.measure("ホームの再計算") { await refreshBody(services: services, now: now) }
    }

    private func refreshBody(services: AppServices, now: Date) async {
        self.now = now
        let store = services.store
        let env = services.environment
        let sessions = (try? store.sessions()) ?? []
        // 位置の無い釣行（室内の試し撮りなど）は、ホームの釣り場選びと「記録中」の対象にしない
        let allSpots = (try? store.spots()) ?? []
        let active = sessions.first { s in s.isActive && (allSpots.first { $0.id == s.spotID }?.coordinate.isPlausible ?? false) }
        isRecording = active != nil
        liveSession = active

        // 釣り場：記録中の釣行 → 選択中 → 現在地に最も近い登録釣り場 → 直近の釣行の釣り場
        // 位置が無い（0, 0）釣り場はホームの対象にしない
        let spots = ((try? store.spots()) ?? []).filter { $0.coordinate.isPlausible }
        let selectedRaw = UserDefaults.standard.string(forKey: "fog.homeSpotID")
        let useCurrentLocation = selectedRaw == Self.currentLocationKey
        let selectedID = selectedRaw.flatMap(UUID.init(uuidString:))
        let location = services.location.lastFix?.coordinate
        if let active, let s = spots.first(where: { $0.id == active.spotID }) {
            spot = s
        } else if active != nil || useCurrentLocation {
            spot = nil
        } else if let selectedID, let s = spots.first(where: { $0.id == selectedID }) {
            spot = s
        } else if let location, let nearest = spots.filter(\.isRegistered).min(by: { Geo.distanceMeters($0.coordinate, location) < Geo.distanceMeters($1.coordinate, location) }) {
            spot = nearest
        } else if let last = sessions.first, let s = spots.first(where: { $0.id == last.spotID }) {
            spot = s
        }
        if let fixedSpotID, let s = spots.first(where: { $0.id == fixedSpotID }) ?? fixedSpot {
            spot = s
            isRecording = false
            liveSession = nil
        }
        let candidate = (fixedSpotID != nil ? spot?.coordinate : nil) ?? active?.track.last?.coordinate ?? spot?.coordinate ?? location ?? SampleData.hakodate
        coordinate = candidate.isPlausible ? candidate : (location ?? SampleData.hakodate)

        // 自分データの重み（削除が即時反映されるよう revision で捨てる）。他の人の魚（F-54）は学習に入れない
        let ownSessions = (try? store.ownSessions()) ?? sessions
        let personal = cache.value("personalModel", store: store) {
            Perf.measure("ホーム: 自分の傾向の学習") { PersonalModel.learn(from: ownSessions.filter { !$0.isActive }, coordinateOf: { s in spots.first { $0.id == s.spotID }?.coordinate }, timeZone: timeZone) }
        }
        let engine = ScoreEngine(personal: personal.total.hours >= 1 ? personal : nil)
        // 通信を待たずに手元のキャッシュで先に描く。取れたら（予報の時刻が変わったら）もう一度計算する
        let fetchedBefore = env.cache.entry(for: coordinate)?.weatherFetchedAt
        let target = coordinate
        if !refreshingNetwork {
            refreshingNetwork = true
            Task { [weak self] in
                await env.refreshIfNeeded(at: target, now: now)
                guard let self else { return }
                self.refreshingNetwork = false
                if env.cache.entry(for: target)?.weatherFetchedAt != fetchedBefore { await self.refresh() }
            }
        }
        let current = Perf.measure("ホーム: 現在値") { env.snapshot(at: now, coordinate: coordinate) }
        score = engine.score(ScoreInput(at: now, coordinate: coordinate, env: current, timeZone: timeZone))
        moonAge = current.moonAge ?? MoonCalculator.age(at: now)

        // 魚種別（自分が釣った魚種の上位 3）
        let topSpecies = Analytics.speciesStats(sessions: ownSessions, timeZone: timeZone).prefix(3).map(\.species)
        speciesScores = topSpecies.map { name in
            (species: name, score: engine.score(ScoreInput(at: now, coordinate: coordinate, env: current, species: name, timeZone: timeZone)).score)
        }

        chips = makeChips(current, fetchFailed: env.lastError != nil)

        // 推移：前日の 0 時から 31 日先まで（潮・天文は無期限、天気は約 10 日先まで。その先は線を薄く）。
        // 1 日分ずつ必要になったときに計算してキャッシュする（31 日分を一度に計算すると 1.5 秒かかる）。
        // 場所・予報・保存データ・日付が変わったらキャッシュを捨てる
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let start = cal.startOfDay(for: now).addingTimeInterval(-86_400)
        forecastHorizon = env.forecastHorizon(for: coordinate)
        let end = start.addingTimeInterval(32 * 86_400)
        let entry = env.cache.entry(for: coordinate)
        // 立ち位置・気圧ログの追記（minor）では捨てない：分析に影響する変更の版だけを鍵にする
        let key = [String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude), "\(entry?.weatherFetchedAt?.timeIntervalSince1970 ?? 0)",
                   "\(entry?.marineFetchedAt?.timeIntervalSince1970 ?? 0)", "\(store.analysisRevision)", "\(start.timeIntervalSince1970)"].joined(separator: "|")
        let station = env.tideStation(near: coordinate)
        let tide = station.map { TideEngine(station: $0) }
        let inputs = env.inputs(for: coordinate)
        if key != timelineKey {
            timelineKey = key
            rangeStart = start; rangeEnd = end
            dayCache = [:]
            calc = DayCalculator(engine: engine, builder: env.builder(for: coordinate), inputs: inputs, tide: tide, coordinate: coordinate, timeZone: timeZone, horizon: forecastHorizon)
            // 右軸の目盛り用：1 か月の潮位の範囲（1 時間おき）
            if let tide {
                Perf.measure("ホーム: 潮位の範囲") {
                    let levels = stride(from: 0, to: end.timeIntervalSince(start), by: 3600).map { tide.level(at: start.addingTimeInterval($0)) }
                    if let lo = levels.min(), let hi = levels.max(), hi > lo { tideRangeCm = lo...hi }
                }
            }
        }
        // 表示に要る日（表示中の日・週行・ウィジェットの 3 日）を裏で先に計算してから画面を更新する（メインスレッドを止めない）
        await Perf.measure("ホーム: 日の計算") { await ensureDays(neededOffsets()) }
        Perf.measure("ホーム: 日と週の表示") {
            updateDay()
            updateWeekOutlook()
        }
        let todayData = dayData(0)
        tideExtremes = Perf.measure("ホーム: 次の満干") { tide?.extremes(from: now, to: now.addingTimeInterval(3 * 86_400)) ?? [] }
        timeline = todayData.timeline + dayData(1).timeline + dayData(2).timeline
        sunTimesByDay = daySun.map { [$0] } ?? []
        seaSurfaceTempC = current.seaSurfaceTempC
        nowTideLevelCm = current.tideLevelCm
        nowTideRateCmPerHour = current.tideRateCmPerHour
        nextFetchAt = env.gate.nextAllowed("weather:" + ForecastCache.key(for: coordinate))
        let wind = inputs.weather.compactMap { s in s.windSpeedMS.map { (s.at, $0) } }
        events = ScoreEvents.upcoming(from: now, count: 3, coordinate: coordinate, timeZone: timeZone, tideExtremes: tideExtremes, wind: wind)

        // ウィジェット（15 分更新）とピーク通知（§8）
        // ウィジェットの書き出しは 10 分に 1 回（釣り場・記録中・予報・タックルが変わったときはすぐ）。毎 30 秒の再計算では書かない
        guard !isEmbedded else { return }
        let widgetKey = "\(spot?.id.uuidString ?? "current")|\(isRecording)|\(key)|\(services.capture.currentTackle?.rawValue ?? "")"
        if widgetKey != lastWidgetKey || now.timeIntervalSince(lastWidgetPublishAt) > 600 {
            lastWidgetKey = widgetKey; lastWidgetPublishAt = now
            Perf.measure("ホーム: ウィジェット") {
                let widgetEvents = ScoreEvents.upcoming(from: now, count: 16, coordinate: coordinate, timeZone: timeZone, tideExtremes: tideExtremes, wind: wind)
                WidgetSync.publish(spotName: spot?.name ?? "現在地", timeline: timeline, tide: tide, events: widgetEvents, isRecording: isRecording, tackle: services.capture.currentTackle,
                                   envAt: { env.weatherSnapshot(at: $0, coordinate: coordinate) })
            }
        }
        // 通知の予約もウィジェットと同じく 10 分に 1 回（30 秒ごとに予約し直していた）
        if now.timeIntervalSince(lastNotifyScheduleAt) > 600 || widgetKey != lastNotifyKey {
            lastNotifyScheduleAt = now; lastNotifyKey = widgetKey
            Perf.measure("ホーム: 通知の予約") {
                PeakNotifier.schedule(points: timeline, spot: spot, now: now, timeZone: timeZone)
                // 明日のベストタイム（F-28）：明日 1 日分から
                let tomorrow = dayData(1)
                DailyBriefNotifier.schedule(points: tomorrow.timeline, extremes: tomorrow.extremes, spot: spot, coordinate: coordinate,
                                            airTemperatureAt: { env.weatherSnapshot(at: $0, coordinate: coordinate).airTemperatureC }, now: now, timeZone: timeZone)
                // 安全通知（F-36）：釣行中だけ予約し直す（帰る時間の設定変更を反映するため）
                if isRecording { SafetyNotifier.schedule(at: now, coordinate: coordinate, environment: env, timeZone: timeZone) }
            }
        }
        // 地図レイヤー（F-43）：使ったことがあれば、この釣り場の周りのタイルを先に用意しておく（開いたときに最初からある）
        if MapLayerSettings.usedOnce {
            services.gridForecast.ensure(minLat: coordinate.latitude - 0.1, maxLat: coordinate.latitude + 0.1,
                                         minLon: coordinate.longitude - 0.12, maxLon: coordinate.longitude + 0.12, now: now)
        }
        // ライブ画面（F-38）：次の満干と次のマズメ
        liveNextTide = tideExtremes.first { $0.at > now }
        liveNextTwilight = Self.nextTwilight(now: now, coordinate: coordinate, timeZone: timeZone)
        // 釣果情報（F-27）：取得は裏で、1 行は手元の記事から
        let keywords = feedKeywords(sessions: sessions, spots: allSpots)
        feedHeadline = Perf.measure("ホーム: 釣果情報の 1 行") { services.feeds.headline(keywords: keywords) }
        let feeds = services.feeds
        Task { [weak self] in
            await feeds.refreshIfNeeded(now: now)
            self?.feedHeadline = feeds.headline(keywords: keywords)
        }
    }

    /// 記事の関連付けに使う語：釣った魚種・登録釣り場の名前
    func feedKeywords(sessions: [Core.Session]? = nil, spots: [Spot]? = nil) -> [String] {
        let sessions = sessions ?? ((try? services?.store.sessions()) ?? [])
        let spots = spots ?? ((try? services?.store.spots()) ?? [])
        let species = Set(sessions.flatMap(\.catches).map(\.species)).filter { !$0.isEmpty }
        let names = spots.filter(\.isRegistered).map(\.name).filter { $0.count >= 2 && $0 != "釣り場" }
        return Array(species) + names
    }

    /// 次のマズメ（朝マズメは市民薄明の始まり、夕マズメは日の入 30 分前）
    static func nextTwilight(now: Date, coordinate: Coordinate, timeZone: TimeZone) -> (label: String, at: Date)? {
        let sun = SunCalculator.times(on: now, at: coordinate, timeZone: timeZone)
        let tomorrow = SunCalculator.times(on: now.addingTimeInterval(86_400), at: coordinate, timeZone: timeZone)
        let candidates: [(String, Date)] = [sun.civilDawn.map { ("朝マズメ", $0) }, sun.sunset.map { ("夕マズメ", $0.addingTimeInterval(-30 * 60)) }, tomorrow.civilDawn.map { ("朝マズメ", $0) }]
            .compactMap { $0 }.filter { $0.1 > now }
        return candidates.min { $0.1 < $1.1 }.map { (label: $0.0, at: $0.1) }
    }

    // MARK: 年間カレンダー（F-33）

    /// 今月から 12 か月分の「日ごとの最高釣れ率」。1 時間刻みで裏で計算し、月ごとに `progress` に渡す。
    /// 予報の先は天気なし（潮・光・月の要素だけ）になるので、潮回りの良し悪しが主に出る
    func yearHeat(species: String? = nil, progress: @escaping @MainActor ([Date: Int]) -> Void) -> Task<Void, Never>? {
        guard let calc else { return nil }
        let tz = timeZone
        let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c }()
        let comps = cal.dateComponents([.year, .month], from: now)
        guard let monthStart = cal.date(from: comps) else { return nil }
        return Task.detached(priority: .userInitiated) {
            var acc: [Date: Int] = [:]
            for m in 0..<12 {
                guard !Task.isCancelled, let start = cal.date(byAdding: .month, value: m, to: monthStart),
                      let end = cal.date(byAdding: .month, value: 1, to: start) else { return }
                let points = ScoreTimeline.compute(engine: calc.engine, coordinate: calc.coordinate, from: start, to: end.addingTimeInterval(-1), stepMinutes: 60, species: species, timeZone: tz) { t in
                    var e = calc.builder.build(at: t, coordinate: calc.coordinate, inputs: calc.inputs, tide: calc.tide, extremes: [])
                    if let h = calc.horizon, t > h { e.isForecast = true }
                    return e
                }
                acc.merge(ScoreTimeline.dailyMax(points, timeZone: tz)) { max($0, $1) }
                let snapshot = acc
                await progress(snapshot)
            }
        }
    }

    /// チップ詳細の「再取得」：1 時間の間隔制限を無視して気象・海況を取りに行く。
    func forceRefreshEnvironment() async {
        guard let services else { return }
        await services.environment.refreshIfNeeded(at: coordinate, now: .now, force: true)
        await refresh()
    }

    /// 日単位の範囲。前日から推移の終わりまでの間に収める
    var dayOffsetRange: ClosedRange<Int> {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        let first = Int((rangeStart.timeIntervalSince(today) / 86_400).rounded(.down))
        let last = Int((rangeEnd.timeIntervalSince(today) / 86_400).rounded(.down)) - 1
        return min(first, 0)...max(last, 0)
    }

    private func updateDay() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        let offset = min(max(dayOffset, dayOffsetRange.lowerBound), dayOffsetRange.upperBound)
        dayStart = today.addingTimeInterval(Double(offset) * 86_400)
        dayEnd = dayStart.addingTimeInterval(86_400)
        let data = dayData(offset)
        dayTimeline = data.timeline
        dayTide = data.tide
        dayExtremes = data.extremes
        if let services {
            dayDetail = stride(from: 0, to: 24, by: 3).map { h in services.environment.weatherSnapshot(at: dayStart.addingTimeInterval(Double(h) * 3600), coordinate: coordinate) }
        }
        let noon = dayStart.addingTimeInterval(12 * 3600)
        daySun = SunCalculator.times(on: noon, at: coordinate, timeZone: timeZone)
        dayMoon = MoonCalculator.times(on: noon, at: coordinate, timeZone: timeZone)
    }

    /// 週間の見通し：表示中の日を含む月曜〜日曜の 7 日（週の並びは固定）。各日の最高釣れ率と昼 12 時の天気。
    /// 推移の範囲外の日は日付だけ出す（釣れ率・天気なし、タップ不可）
    private func updateWeekOutlook() {
        let range = dayOffsetRange
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        let shown = today.addingTimeInterval(Double(min(max(dayOffset, range.lowerBound), range.upperBound)) * 86_400)
        let shownWeekday = cal.component(.weekday, from: shown) // 1=日 … 7=土
        let monday = dayOffset - (shownWeekday + 5) % 7
        var out: [DayOutlook] = []
        for offset in monday...(monday + 6) {
            let start = today.addingTimeInterval(Double(offset) * 86_400)
            let ymd = cal.dateComponents([.year, .month, .day, .weekday], from: start)
            let holiday = JapaneseHolidays.isHoliday(year: ymd.year ?? 0, month: ymd.month ?? 0, day: ymd.day ?? 0)
            guard range.contains(offset), let best = dayData(offset).timeline.map(\.score).max() else {
                out.append(DayOutlook(offset: offset, dayStart: start, maxScore: nil, conditionCode: nil, weekday: ymd.weekday ?? 0, isHoliday: holiday))
                continue
            }
            let noon = start.addingTimeInterval(12 * 3600)
            let cond = services.map { $0.environment.weatherSnapshot(at: noon, coordinate: coordinate).conditionCode } ?? nil
            let beyond = forecastHorizon.map { noon > $0 } ?? true
            out.append(DayOutlook(offset: offset, dayStart: start, maxScore: best, conditionCode: beyond ? nil : cond, weekday: ymd.weekday ?? 0, isHoliday: holiday))
        }
        weekOutlook = out
    }

    /// イベント列のタップ：その時刻の日へ
    func show(date: Date) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        dayOffset = Int((cal.startOfDay(for: date).timeIntervalSince(today) / 86_400).rounded())
    }

    static let currentLocationKey = "current"

    func select(spot: Spot) {
        UserDefaults.standard.set(spot.id.uuidString, forKey: "fog.homeSpotID")
        Task { await refresh() }
    }

    /// 「現在地」を選ぶ：登録釣り場があっても今いる場所の情報を出す
    func selectCurrentLocation() {
        UserDefaults.standard.set(Self.currentLocationKey, forKey: "fog.homeSpotID")
        Task { await refresh() }
    }

    /// 同梱の港データから漁港を選んで釣り場に登録し、ホームの釣り場にする
    func select(port: Core.Port) {
        guard let services else { return }
        let existing = (try? services.store.spots()) ?? []
        if let same = existing.first(where: { Geo.distanceMeters($0.coordinate, port.coordinate) < 300 }) {
            var s = same; s.isRegistered = true
            try? services.store.upsert(s)
            select(spot: s)
            return
        }
        let spot = Spot(name: port.name, coordinate: port.coordinate, isRegistered: true)
        try? services.store.upsert(spot)
        select(spot: spot)
    }

    var availableSpots: [Spot] { ((try? services?.store.spots()) ?? []).filter { $0.isRegistered && $0.coordinate.isPlausible } }

    var isUsingCurrentLocation: Bool { UserDefaults.standard.string(forKey: "fog.homeSpotID") == Self.currentLocationKey }

    var currentLocation: Coordinate? { services?.location.lastFix?.coordinate }

    private static let portCatalog = PortCatalog.bundled()

    /// 近い順の漁港（検索語があれば全国から名前で絞る）
    func ports(matching query: String, limit: Int = 30) -> [Core.Port] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = Self.portCatalog.ports
        let origin = currentLocation ?? coordinate
        // 文字があるときは、よみ（かな・ローマ字）でも当たる索引を使う（F-50）。索引がまだ無ければ名前の部分一致
        let filtered: [Core.Port]
        if q.isEmpty { filtered = base }
        else if !PortReadingIndex.shared.entries.isEmpty { filtered = PortReadingIndex.shared.search(q, limit: 200) }
        else { filtered = base.filter { $0.name.contains(q) } }
        return filtered.sorted { Geo.distanceMeters($0.coordinate, origin) < Geo.distanceMeters($1.coordinate, origin) }.prefix(limit).map { $0 }
    }

    /// 4 チップ：値は「次の出来事の時刻」か「今の数値」。残り時間は出さない（時刻と紛らわしいため）。
    private func makeChips(_ env: EnvSnapshot, fetchFailed: Bool) -> [Chip] {
        var out: [Chip] = []
        // 潮：矢印（上げ／下げ／止まり）、次の満干の時刻、潮名
        let rate = env.tideRateCmPerHour ?? 0
        let next = [env.nextHighTideAt.map { ("満潮", $0) }, env.nextLowTideAt.map { ("干潮", $0) }].compactMap { $0 }.min { $0.1 < $1.1 }
        let tideLabel = [next?.0, env.tideName].compactMap { $0 }.joined(separator: " · ")
        out.append(Chip(kind: .tide, symbol: abs(rate) < 2 ? "minus" : (rate > 0 ? "arrow.up" : "arrow.down"),
                        value: next.map { Self.clock($0.1) } ?? "—", label: tideLabel.isEmpty ? "潮" : tideLabel,
                        tone: abs(rate) < 2 ? .bad : (abs(rate) >= 6 ? .good : .normal)))
        // 光：マズメ中はその名前、そうでなければ次のマズメの時刻
        let sun = SunCalculator.times(on: now, at: coordinate, timeZone: timeZone)
        let tomorrow = SunCalculator.times(on: now.addingTimeInterval(86_400), at: coordinate, timeZone: timeZone)
        let candidates: [(String, Date)] = [sun.civilDawn.map { ("朝マズメ", $0) }, sun.sunset.map { ("夕マズメ", $0.addingTimeInterval(-30 * 60)) }, tomorrow.civilDawn.map { ("朝マズメ", $0) }]
            .compactMap { $0 }.filter { $0.1 > now }
        let nextTwilight = candidates.min { $0.1 < $1.1 }
        let inMorning: Bool = { guard let dawn = sun.civilDawn, let sunrise = sun.sunrise else { return false }; return now >= dawn && now <= sunrise.addingTimeInterval(30 * 60) }()
        let inEvening: Bool = { guard let sunset = sun.sunset, let dusk = sun.civilDusk else { return false }; return now >= sunset.addingTimeInterval(-30 * 60) && now <= dusk }()
        if inMorning || inEvening {
            out.append(Chip(kind: .light, symbol: "sun.horizon.fill", value: inMorning ? "朝マズメ" : "夕マズメ", label: "いま", tone: .good))
        } else {
            let minutesTo = nextTwilight.map { $0.1.timeIntervalSince(now) / 60 } ?? 999
            out.append(Chip(kind: .light, symbol: minutesTo < 90 ? "sun.horizon" : "sun.max", value: nextTwilight.map { Self.clock($0.1) } ?? "—",
                            label: nextTwilight?.0 ?? "マズメ", tone: minutesTo < 90 ? .good : .normal))
        }
        // 風：風速と風向（吹いてくる方角）
        if let w = env.windSpeedMS {
            out.append(Chip(kind: .wind, symbol: "location.north.fill", value: "\(Int(w.rounded())) m/s",
                            label: env.windDirectionDeg.map { Self.compass($0) + "の風" } ?? "風", tone: w > 8 ? .bad : (w <= 3 ? .good : .normal)))
        } else {
            out.append(Chip(kind: .wind, symbol: "wind", value: "—", label: fetchFailed ? "風 取得できず" : "風 取得中", tone: .normal))
        }
        // 天気：気温と天気の名前
        let temp = env.airTemperatureC.map { "\(Int($0.rounded()))°" } ?? "—"
        out.append(Chip(kind: .weather, symbol: Self.weatherSymbol(env.conditionCode), value: temp,
                        label: env.airTemperatureC == nil ? (fetchFailed ? "天気 取得できず" : "天気 取得中") : Self.weatherName(env.conditionCode, precipitation: env.precipitationMM),
                        tone: (env.precipitationMM ?? 0) > 1 ? .bad : .normal))
        return out
    }

    static func clock(_ date: Date, timeZone: TimeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        return "\(c.hour ?? 0):" + String(format: "%02d", c.minute ?? 0)
    }

    /// 風向（度、吹いてくる方角）→ 8 方位
    static func compass(_ deg: Double) -> String {
        let names = ["北", "北東", "東", "南東", "南", "南西", "西", "北西"]
        let i = Int(((deg + 22.5).truncatingRemainder(dividingBy: 360)) / 45) % 8
        return names[max(0, i)]
    }

    static func weatherName(_ code: String?, precipitation: Double?) -> String {
        switch code ?? "" {
        case "clear", "mostlyClear": return "晴れ"
        case "partlyCloudy": return "晴れ時々曇り"
        case "cloudy", "mostlyCloudy": return "曇り"
        case "rain", "drizzle", "heavyRain": return "雨"
        case "snow", "flurries", "heavySnow": return "雪"
        case "foggy", "haze": return "霧"
        case "windy", "breezy": return "強風"
        default: return (precipitation ?? 0) > 0.5 ? "雨" : "曇り"
        }
    }

    static func weatherSymbol(_ code: String?) -> String {
        switch code ?? "" {
        case "clear", "mostlyClear": return "sun.max.fill"
        case "partlyCloudy": return "cloud.sun.fill"
        case "cloudy", "mostlyCloudy": return "cloud.fill"
        case "rain", "drizzle", "heavyRain": return "cloud.rain.fill"
        case "snow", "flurries", "heavySnow": return "cloud.snow.fill"
        case "foggy", "haze": return "cloud.fog.fill"
        case "windy", "breezy": return "wind"
        default: return "cloud.fill"
        }
    }

    static func hm(_ interval: TimeInterval) -> String {
        let m = max(0, Int(interval / 60))
        return "\(m / 60):\(String(format: "%02d", m % 60))"
    }

    var windDirectionDeg: Double? { services?.environment.snapshot(at: now, coordinate: coordinate).windDirectionDeg }
}
