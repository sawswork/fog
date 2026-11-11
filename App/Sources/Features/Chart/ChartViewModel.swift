import SwiftUI
import MapKit
import Core

/// 海図の 1 画面（F-63）の状態。釣れ率・予報はホームの計算（`HomeViewModel`）をそのまま使い、
/// ここでは「港の図」「投げる場所の見立て」「釣れた地点」「なぞった時刻の条件」を組み立てる
@MainActor
@Observable
final class ChartViewModel {
    struct CatchPin: Identifiable, Hashable {
        let id: UUID
        let coordinate: Coordinate
        let lengthCm: Double?
        let species: String
        let at: Date
    }

    /// 潮の動き（マークで出す）
    enum TideState { case rising, falling, slack }

    struct Conditions {
        /// 潮位（"47cm"）。上げ・下げは `tideState` のマークで出す
        var tide = "—"
        var tideState: TideState?
        /// 風速（"2m"）。向きは `windFromDeg` のマークで出す
        var wind = "—"
        var wave = "—"
        var temp = "—"
        /// 降水確率（"30%"）と天気の印（SF Symbols）
        var rain = "—"
        var weatherSymbol: String?
        var windFromDeg: Double?
        var windSpeedMS: Double?
        /// 読み上げ用（"西南西"）
        var windName: String?
    }

    /// マズメの帯（朝：市民薄明の始まり〜日の出 30 分後、夕：日の入 30 分前〜市民薄明の終わり。ホームのグラフと同じ定義）
    struct TwilightBand: Hashable {
        let start: Date
        let end: Date
    }

    /// 潮位の線の 1 点
    struct TideSample: Hashable {
        let at: Date
        let cm: Double
    }

    struct Peak {
        let at: Date
        let score: Int
    }

    /// 図の範囲（同梱の海図、無ければ釣り場を中心にした 800 m の枠）
    private(set) var frame: PortChart?
    /// 同梱の海図か（false は Apple の地図）
    private(set) var isIllustrated = false
    private(set) var image: UIImage?
    private(set) var zones: [CastPredictor.Zone] = []
    private(set) var today: [CatchPin] = []
    private(set) var past: [Coordinate] = []
    private(set) var user: Coordinate?
    private(set) var conditions = Conditions()
    /// 今から 9 時間の釣れ率
    private(set) var points: [ScorePoint] = []
    private(set) var peak: Peak?
    /// 今から 9 時間の潮位（10 分おき）と、線の縦の範囲
    private(set) var tide: [TideSample] = []
    private(set) var tideRange: ClosedRange<Double> = 0...200
    /// 今から 9 時間にかかるマズメ
    private(set) var twilight: [TwilightBand] = []
    private(set) var scoreNow = 0
    private(set) var advice = ""
    private(set) var lostCount = 0
    private(set) var now = Date()
    /// グラフをなぞっている時刻（nil は今）
    var scrub: Date? {
        didSet { if scrub != oldValue { recomputeForTime() } }
    }

    static let horizon: TimeInterval = 9 * 3600

    @ObservationIgnored private weak var services: AppServices?
    @ObservationIgnored private var coordinate = SampleData.hakodate
    @ObservationIgnored private var snapshotKey = ""
    @ObservationIgnored private var tideKey = ""

    /// 表示中の時刻の釣れ率
    var shownScore: Int {
        guard let t = scrub else { return scoreNow }
        return points.min { abs($0.at.timeIntervalSince(t)) < abs($1.at.timeIntervalSince(t)) }?.score ?? scoreNow
    }

    /// ホームの再計算のあとに呼ぶ
    func update(services: AppServices) {
        self.services = services
        let home = services.homeModel
        now = home.now
        coordinate = home.coordinate
        user = services.location.lastFix?.coordinate
        scoreNow = home.score?.score ?? 0
        let start = now.addingTimeInterval(-900), end = now.addingTimeInterval(Self.horizon)
        points = home.timeline.filter { $0.at >= start && $0.at <= end }
        if let best = points.max(by: { $0.score < $1.score }), best.score >= scoreNow + 3, best.at > now.addingTimeInterval(600) {
            peak = Peak(at: best.at, score: best.score)
        } else {
            peak = nil
        }

        updateTide(services: services)
        twilight = Self.twilightBands(from: now, to: end, coordinate: coordinate)

        // 図：その釣り場（か現在地）を写している海図。無ければ Apple の地図
        let catalog = PortChartCatalog.bundled()
        let target = catalog.chart(containing: coordinate) ?? user.flatMap { catalog.chart(containing: $0) }
        let newFrame: PortChart
        if let chart = target, let art = ChartAssets.chart(id: chart.id) {
            newFrame = chart
            if frame?.id != chart.id || !isIllustrated { image = art }
            isIllustrated = true
        } else {
            newFrame = Self.plainFrame(center: coordinate)
            if frame?.id != newFrame.id || isIllustrated {
                image = nil
                loadSnapshot(for: newFrame)
            }
            isIllustrated = false
        }
        frame = newFrame

        // 釣果：記録中の釣行の分は「今日」、ほかは「過去」
        let sessions = (try? services.store.sessions()) ?? []
        let live = home.liveSession
        var todayPins: [CatchPin] = []
        var pastPoints: [Coordinate] = []
        for s in sessions {
            let isLive = live.map { $0.id == s.id } ?? false
            for c in s.catches where c.coordinate.isPlausible && newFrame.contains(c.coordinate) {
                if isLive {
                    todayPins.append(CatchPin(id: c.id, coordinate: c.coordinate, lengthCm: c.lengthCm, species: c.species, at: c.at))
                } else {
                    pastPoints.append(c.coordinate)
                }
            }
        }
        today = todayPins.sorted { $0.at < $1.at }
        past = pastPoints
        lostCount = live?.hookEvents.filter { $0.kind == .lost }.count ?? 0
        recomputeForTime()
    }

    /// 表示中の時刻（今か、なぞっている時刻）の条件と、投げる場所の見立て
    private func recomputeForTime() {
        guard let services, let frame else { return }
        let t = scrub ?? now
        let env = services.environment.scoreSnapshot(at: t, coordinate: coordinate)
        var c = Conditions()
        if let level = env.tideLevelCm { c.tide = "\(Int(level.rounded()))cm" }
        if let rate = env.tideRateCmPerHour { c.tideState = abs(rate) < 2 ? .slack : (rate > 0 ? .rising : .falling) }
        if let w = env.windSpeedMS { c.wind = "\(Int(w.rounded()))m" }
        if let h = env.waveHeightM { c.wave = String(format: "%.1fm", h) }
        if let a = env.airTemperatureC { c.temp = "\(Int(a.rounded()))°" }
        if let chance = env.precipitationChance { c.rain = "\(Int((chance * 100).rounded()))%" }
        if env.conditionCode != nil || env.precipitationChance != nil {
            c.weatherSymbol = Self.weatherSymbol(env.conditionCode, at: t, sunrise: env.sunriseAt, sunset: env.sunsetAt)
        }
        c.windFromDeg = env.windDirectionDeg
        c.windSpeedMS = env.windSpeedMS
        c.windName = env.windDirectionDeg.map { CastPredictor.compassName($0) }
        conditions = c
        zones = CastPredictor.predict(.init(chart: frame, user: user, windFromDeg: env.windDirectionDeg, windSpeedMS: env.windSpeedMS,
                                            tideRateCmPerHour: env.tideRateCmPerHour, pastCatches: past, todayCatches: today.map(\.coordinate)))
        advice = makeAdvice()
    }

    /// 天気の印。晴れ・晴れ時々曇りは、夜（日の入〜日の出）なら月にする
    static func weatherSymbol(_ code: String?, at date: Date, sunrise: Date?, sunset: Date?) -> String {
        var night = false
        if let sunrise, let sunset { night = date < sunrise || date > sunset }
        switch code ?? "" {
        case "clear", "mostlyClear": return night ? "moon.stars.fill" : "sun.max.fill"
        case "partlyCloudy": return night ? "cloud.moon.fill" : "cloud.sun.fill"
        default: return HomeViewModel.weatherSymbol(code)
        }
    }

    /// その時間にかかるマズメの帯。日をまたぐので、前日・当日・翌日の太陽の時刻から拾う
    static func twilightBands(from start: Date, to end: Date, coordinate: Coordinate) -> [TwilightBand] {
        guard coordinate.isPlausible else { return [] }
        let zone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        var out: [TwilightBand] = []
        for offset in [-1.0, 0.0, 1.0] {
            let sun = SunCalculator.times(on: start.addingTimeInterval(offset * 86_400), at: coordinate, timeZone: zone)
            if let dawn = sun.civilDawn, let rise = sun.sunrise { out.append(TwilightBand(start: dawn, end: rise.addingTimeInterval(30 * 60))) }
            if let set = sun.sunset, let dusk = sun.civilDusk { out.append(TwilightBand(start: set.addingTimeInterval(-30 * 60), end: dusk)) }
        }
        var seen = Set<TwilightBand>()
        return out.filter { $0.end > start && $0.start < end && $0.end > $0.start && seen.insert($0).inserted }.sorted { $0.start < $1.start }
    }

    /// 今から 9 時間の潮位。5 分ごとに作り直す（調和推算を 55 回。軽い）
    private func updateTide(services: AppServices) {
        let key = String(format: "%.3f,%.3f,%d", coordinate.latitude, coordinate.longitude, Int(now.timeIntervalSince1970 / 300))
        guard key != tideKey else { return }
        tideKey = key
        guard let station = services.environment.tideStation(near: coordinate) else { tide = []; return }
        let engine = TideEngine(station: station)
        let start = now
        let samples = stride(from: 0.0, through: Self.horizon, by: 600).map { offset -> TideSample in
            let t = start.addingTimeInterval(offset)
            return TideSample(at: t, cm: engine.level(at: t))
        }
        tide = samples
        // 縦の範囲：この 9 時間の上下を中心に、1 か月の幅の半分より狭くはしない（小潮の日は線が低く平らに見える＝潮の高さが伝わる）
        let lo = samples.map(\.cm).min() ?? 0, hi = samples.map(\.cm).max() ?? 200
        let month = services.homeModel.tideRangeCm
        let span = max((hi - lo) * 1.15, (month.upperBound - month.lowerBound) * 0.5, 20)
        let mid = (hi + lo) / 2
        tideRange = (mid - span / 2)...(mid + span / 2)
    }

    private func makeAdvice() -> String {
        // 釣行中は「次の一手」（F-65）を先に：山が近い・アタリが無い・ロストが続く・風が強い、など優先度の高い提案があればそれを出す
        if scrub == nil, let services, services.homeModel.isRecording,
           let top = SessionAdvisor.advise(AssistantActions.advisorInput(services: services, home: services.homeModel, now: now)).first, top.priority >= 2 {
            return top.text
        }
        guard let top = zones.first else {
            return isIllustrated ? "釣果が増えると、投げる場所の見立てが出ます" : "この場所の釣果が増えると、投げる場所の見立てが出ます"
        }
        var text = "① は" + (top.reasons.isEmpty ? "届く範囲でいちばん条件が良い所" : top.reasons.prefix(2).joined(separator: "・"))
        if scrub == nil, let p = peak { text += "。\(JPFormat.hm(p.at)) ごろが山" }
        return text
    }

    // MARK: 海図の無い港：Apple の地図

    private static let allWater = WaterGrid(cols: 60, rows: 80, cells: [Bool](repeating: true, count: 4800)).base64

    /// 釣り場を中心にした 800 m × 1,067 m の枠（北が上）。水面の網目は「全部が水」（釣果だけで見立てる）
    static func plainFrame(center: Coordinate) -> PortChart {
        let id = String(format: "plain:%.4f,%.4f", center.latitude, center.longitude)
        return PortChart(id: id, name: "", lat: center.latitude, lon: center.longitude, widthM: 800, heightM: 800 * 4 / 3, cols: 60, rows: 80, water: allWater)
    }

    private func loadSnapshot(for frame: PortChart) {
        let key = frame.id
        snapshotKey = key
        guard frame.center.isPlausible else { return }
        Task { [weak self] in
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: frame.lat, longitude: frame.lon),
                                                latitudinalMeters: frame.heightM, longitudinalMeters: frame.widthM)
            options.size = CGSize(width: 600, height: 800)
            let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            config.pointOfInterestFilter = .excludingAll
            options.preferredConfiguration = config
            options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
            let snapshot = try? await MKMapSnapshotter(options: options).start()
            guard let self, self.snapshotKey == key, let snapshot else { return }
            self.image = snapshot.image
        }
    }
}
