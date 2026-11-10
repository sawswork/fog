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

    struct Conditions {
        var tide = "—"
        var wind = "—"
        var wave = "—"
        var temp = "—"
        var windFromDeg: Double?
        var windSpeedMS: Double?
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
        if let rate = env.tideRateCmPerHour {
            let direction = abs(rate) < 2 ? "潮止まり" : (rate > 0 ? "上げ" : "下げ")
            c.tide = env.tideLevelCm.map { "\(direction) \(Int($0.rounded()))cm" } ?? direction
        }
        if let w = env.windSpeedMS {
            c.wind = (env.windDirectionDeg.map { CastPredictor.compassName($0) + " " } ?? "") + "\(Int(w.rounded()))m"
        }
        if let h = env.waveHeightM { c.wave = String(format: "%.1fm", h) }
        if let a = env.airTemperatureC { c.temp = "\(Int(a.rounded()))°" }
        c.windFromDeg = env.windDirectionDeg
        c.windSpeedMS = env.windSpeedMS
        conditions = c
        zones = CastPredictor.predict(.init(chart: frame, user: user, windFromDeg: env.windDirectionDeg, windSpeedMS: env.windSpeedMS,
                                            tideRateCmPerHour: env.tideRateCmPerHour, pastCatches: past, todayCatches: today.map(\.coordinate)))
        advice = makeAdvice()
    }

    private func makeAdvice() -> String {
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
