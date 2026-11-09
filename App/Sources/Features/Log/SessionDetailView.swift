import SwiftUI
import MapKit
import Charts
import Core

/// 釣行詳細：時系列に釣果と条件の推移、立ち位置の軌跡、レポート。
struct SessionDetailView: View {
    let session: Core.Session
    let spotName: String
    @Environment(AppServices.self) private var services
    @State private var deleting: Catch?
    @State private var removedIDs: Set<UUID> = []
    /// 答え合わせ（F-29）：釣行の時間範囲の釣れ率の推移と評価
    @State private var reviewPoints: [ScorePoint] = []
    @State private var review: SessionReview.Result?
    /// 推算した潮位曲線と満干（スナップショットの 30 分刻みより滑らかで、満干の時刻が分かる）
    @State private var tideCurve: [(at: Date, levelCm: Double)] = []
    @State private var tideExtremes: [TideExtreme] = []
    @State private var showMap = false
    @State private var viewing: Catch?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                header
                if let r = session.report {
                    panel("レポート") {
                        Text(r.summary).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                        Text(r.body).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                panel("釣果 \(session.catches.count)尾 · タップで写真、長押しで削除") { catches }
                panel("答え合わせ · 釣れ率の推移と釣れた瞬間（白い点）") { reviewChart }
                panel("潮位と釣れた時刻") { timeline }
                if session.pressureLog?.count ?? 0 >= 2 { panel("現場の気圧（端末の気圧計）") { pressure } }
                panel("立ち位置と釣れた場所 · タップで全画面") { track }
            }
            .padding(DS.Spacing.l)
        }
        .background(ThemeBackground(name: .bgDetail))
        .task { computeReview() }
        .fullScreenCover(isPresented: $showMap) { SessionMapSheet(session: session, spotName: spotName) }
        .fullScreenCover(item: $viewing) { c in PhotoViewer(catchItem: c) }
    }

    /// 釣り場名、日付と時間帯、数字（尾数・最大・時間・針ロスト）
    private var header: some View {
        let end = session.endedAt ?? Date()
        let maxLen = session.catches.compactMap(\.lengthCm).max()
        let losses = session.hookEvents.filter { $0.kind == .lost }.count
        return VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(spotName).font(DS.Font.number(24)).foregroundStyle(DS.Color.textPrimary)
            Text("\(JPFormat.ymdw(session.startedAt)) \(JPFormat.hm(session.startedAt))〜\(session.endedAt == nil ? "記録中" : JPFormat.hm(end)) · \(JPFormat.duration(end.timeIntervalSince(session.startedAt)))")
                .font(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
            HStack(spacing: DS.Spacing.s) {
                stat("尾数", session.isBlank ? "ボウズ" : "\(session.catches.count)", unit: session.isBlank ? "" : "尾", highlight: !session.isBlank)
                stat("最大", maxLen.map { "\(Int($0.rounded()))" } ?? "—", unit: "cm")
                stat("魚種", "\(Set(session.catches.map(\.species).filter { !$0.isEmpty }).count)", unit: "種")
                stat("針ロスト", "\(losses)", unit: "回")
            }
        }
    }

    private func stat(_ label: String, _ value: String, unit: String = "", highlight: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(label).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(DS.Font.number(20)).foregroundStyle(highlight ? DS.Color.accent : DS.Color.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
                if !unit.isEmpty { Text(unit).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.s)
        .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
    }

    /// 見出し付きの区画（枠線なし、面で区切る）
    private func panel<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(title).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            content()
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    /// 答え合わせ（F-29）：釣れ率の推移（緑）に釣れた瞬間の点を重ね、当たっていたかを 1 行で
    private var reviewChart: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if let r = review {
                Text(r.verdict).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
            }
            if reviewPoints.isEmpty {
                Text("推移を計算中").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            } else {
                Chart {
                    RectangleMark(xStart: .value("s", session.startedAt), xEnd: .value("e", session.endedAt ?? Date()), yStart: .value("y0", 0), yEnd: .value("y1", 100))
                        .foregroundStyle(DS.Color.textPrimary.opacity(0.05))
                    ForEach(reviewPoints, id: \.at) { p in
                        LineMark(x: .value("時刻", p.at), y: .value("釣れ率", p.score)).foregroundStyle(DS.Color.accent).interpolationMethod(.monotone)
                    }
                    if let r = review {
                        ForEach(Array(r.catchScores.enumerated()), id: \.offset) { _, c in
                            PointMark(x: .value("釣果", c.0), y: .value("釣れ率", c.1)).foregroundStyle(DS.Color.textPrimary).symbolSize(40)
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) { _ in AxisValueLabel().font(.system(size: 9)).foregroundStyle(DS.Color.accent) } }
                .chartXAxis { AxisMarks(values: .stride(by: .hour)) { _ in AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary) } }
                .frame(height: 110)
                if let r = review {
                    Text("釣行中の平均 \(Int(r.meanScore.rounded()))" + (r.meanScoreAtCatch.map { " · 釣れた時 \(Int($0.rounded()))" } ?? "") + (r.hitRate.map { " · 60 以上で釣れた割合 \(Int(($0 * 100).rounded()))%" } ?? ""))
                        .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
            }
        }
    }

    /// 釣行の時間範囲の推移を計算する（`SessionReviewer`）
    private func computeReview() {
        guard let out = SessionReviewer.review(session, services: services) else { return }
        reviewPoints = out.points
        review = out.result
        tideCurve = out.tide
        tideExtremes = out.extremes
    }

    /// 現場の気圧（F-35）：釣行中に端末の気圧計で 5 分ごとに記録した値
    private var pressure: some View {
        Group {
            if let log = session.pressureLog, log.count >= 2, let first = log.first, let last = log.last {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Spacer()
                        let trend = PressureTrend.threeHourChange(log, now: last.at)
                        Text(String(format: "%.0f → %.0f hPa", first.pressureHPa, last.pressureHPa) + (trend.map { String(format: "（3h %+.1f）", $0) } ?? ""))
                            .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    }
                    Chart(log, id: \.at) { p in
                        LineMark(x: .value("時刻", p.at), y: .value("hPa", p.pressureHPa)).foregroundStyle(Color.white.opacity(0.8))
                    }
                    .chartYScale(domain: (log.map(\.pressureHPa).min()! - 1)...(log.map(\.pressureHPa).max()! + 1))
                    .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel().font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary) } }
                    .chartXAxis { AxisMarks(values: .stride(by: .hour)) { _ in AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary) } }
                    .frame(height: 70)
                }
            }
        }
    }

    /// 条件の推移：推算した潮位（海の青）に満干の時刻、釣れた時刻（テーマ色の線）。推算が無ければスナップショットの潮位
    private var timeline: some View {
        let catches = session.catches.sorted { $0.at < $1.at }
        let levels = (tideCurve.isEmpty ? session.snapshots.compactMap { s in s.tideLevelCm.map { (at: s.at, levelCm: $0) } } : tideCurve)
        let lo = (levels.map(\.levelCm).min() ?? 0) - 10, hi = (levels.map(\.levelCm).max() ?? 100) + 10
        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Text(session.snapshots.first?.tideName ?? "").font(DS.Font.caption).foregroundStyle(DS.Color.sea)
                Spacer()
                ForEach(tideExtremes, id: \.at) { e in
                    Text("\(e.kind == .high ? "満" : "干") \(HomeViewModel.clock(e.at)) \(Int(e.levelCm.rounded()))cm").font(DS.Font.caption).foregroundStyle(DS.Color.sea)
                }
            }
            Chart {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("時刻", p.at), yStart: .value("底", lo), yEnd: .value("潮位", p.levelCm), series: .value("系列", "潮位面"))
                        .foregroundStyle(LinearGradient(colors: [DS.Color.sea.opacity(0.3), DS.Color.sea.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("時刻", p.at), y: .value("潮位", p.levelCm), series: .value("系列", "潮位")).foregroundStyle(DS.Color.sea).interpolationMethod(.catmullRom)
                }
                RectangleMark(xStart: .value("s", session.startedAt), xEnd: .value("e", session.endedAt ?? Date()), yStart: .value("y0", lo), yEnd: .value("y1", hi))
                    .foregroundStyle(DS.Color.textPrimary.opacity(0.05))
                ForEach(Array(catches.enumerated()), id: \.element.id) { i, c in
                    RuleMark(x: .value("釣果", c.at)).foregroundStyle(DS.Color.accent).lineStyle(StrokeStyle(lineWidth: 2))
                        // 近い時刻の釣果は上下に振り分けて重ねない
                        .annotation(position: i % 2 == 0 ? .top : .bottom, alignment: .center) {
                            Text(c.species + (c.lengthCm.map { " \(Int($0.rounded()))" } ?? "")).font(DS.Font.caption).foregroundStyle(DS.Color.accent)
                        }
                }
            }
            .chartYScale(domain: lo...hi)
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisValueLabel().font(.system(size: 9)).foregroundStyle(DS.Color.sea) } }
            .chartXAxis { AxisMarks(values: .stride(by: .hour)) { _ in AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary) } }
            .frame(height: 120)
        }
    }

    /// 立ち位置の軌跡（モノトーン地図）
    private var track: some View {
        let coords = session.track.map { CLLocationCoordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        return Group {
            if coords.count >= 1 {
                Map(initialPosition: .region(MKCoordinateRegion(center: coords[coords.count / 2], latitudinalMeters: 600, longitudinalMeters: 600)), interactionModes: []) {
                    if coords.count >= 2 { MapPolyline(coordinates: coords).stroke(DS.Color.accent, lineWidth: 3) }
                    ForEach(session.catches, id: \.id) { c in
                        Annotation(c.species, coordinate: CLLocationCoordinate2D(latitude: c.coordinate.latitude, longitude: c.coordinate.longitude)) {
                            Circle().fill(DS.Color.accent).frame(width: 10, height: 10)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .saturation(0)
                // タップで全画面の地図（ピンチで拡大。F-55）
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.Color.textPrimary)
                        .padding(8).background(DS.Color.background.opacity(0.7), in: Circle()).padding(DS.Spacing.s)
                }
                .contentShape(Rectangle())
                .onTapGesture { showMap = true }
            }
        }
    }

    /// 釣果の一覧。長押しで削除（記録だけ／写真も）。
    private var catches: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            ForEach(session.catches.filter { !removedIDs.contains($0.id) }, id: \.id) { c in
                HStack(spacing: DS.Spacing.m) {
                    Group {
                        if let data = services.store.thumbnail(catchID: c.id), let ui = UIImage(data: data) {
                            Image(uiImage: ui).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
                        } else {
                            RoundedRectangle(cornerRadius: DS.Radius.chip).fill(DS.Color.surface).frame(width: 56, height: 56)
                        }
                    }
                    // 写真をタップで全画面（F-55）
                    .onTapGesture { viewing = c }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DS.Spacing.s) {
                            Text(JPFormat.hm(c.at)).font(DS.Font.number(14)).foregroundStyle(DS.Color.textSecondary)
                            Text(c.species.isEmpty ? "魚種なし" : c.species).font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.Color.textPrimary)
                            // 釣った人（F-54）：自分以外のときだけ
                            if let a = c.angler, !a.isEmpty {
                                Text(a).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Color.background)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(DS.Color.sun, in: Capsule())
                            }
                        }
                        HStack(spacing: DS.Spacing.s) {
                            Text(c.lengthCm.map { "\(Int($0.rounded()))cm" } ?? "未計測").font(DS.Font.number(16)).foregroundStyle(c.lengthCm == nil ? DS.Color.textTertiary : DS.Color.accent)
                            if let e = c.env {
                                Text([e.tideName, e.tideRateCmPerHour.map { abs($0) < 2 ? "潮止まり" : ($0 > 0 ? "上げ" : "下げ") }, e.tideLevelCm.map { "潮位\(Int($0.rounded()))cm" }, e.windSpeedMS.map { "風\(Int($0.rounded()))m/s" }, e.airTemperatureC.map { "\(Int($0.rounded()))°" }].compactMap { $0 }.joined(separator: " · "))
                                    .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).lineLimit(1).minimumScaleFactor(0.8)
                            }
                        }
                        // タックル・リグ（後からも設定できる：図鑑の写真を長押し）
                        HStack(spacing: DS.Spacing.s) {
                            if let t = c.tackle { Text(t == .spinning ? "スピニング" : "ベイト").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary) }
                            if let r = c.rigID.flatMap({ id in rigs.first { $0.id == id } }) { Text(r.displayName).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary) }
                        }
                        // 写真から推定した足場・時間帯・天気（F-31）
                        if let tags = c.sceneTags, !tags.isEmpty {
                            Text(tags.joined(separator: " · ")).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onLongPressGesture { deleting = c }
            }
            if session.catches.isEmpty { Text("釣果なし").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
        }
        .catchDeleteDialog(item: $deleting) { removedIDs.insert($0.id) }
    }

    private var rigs: [Rig] { (try? services.store.rigs()) ?? [] }
}

/// 分析の全画面：魚種別の切替、水温・風・気圧傾向との相関、タックル・リグ別。
struct AnalysisDetailView: View {
    let kind: LogView.AnalysisKind
    let sessions: [Core.Session]
    let spots: [UUID: Spot]
    @State private var species: String = ""

    private var allCatches: [Catch] { sessions.flatMap(\.catches) }
    private var speciesList: [String] { Array(Set(allCatches.map(\.species))).sorted() }
    private var catches: [Catch] { species.isEmpty ? allCatches : allCatches.filter { $0.species == species } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.s) {
                        chip("全部", selected: species.isEmpty) { species = "" }
                        ForEach(speciesList, id: \.self) { s in chip(s, selected: species == s) { species = s } }
                    }
                }
                switch kind {
                case .hour:
                    let cells = Analytics.catchesByHour(catches: catches)
                    bars("時間帯別", (0..<24).map { ("\($0)", Double(cells[$0] ?? 0)) }, labelsEvery: 6)
                    let months = Analytics.catchesByMonth(catches: catches)
                    bars("月別", months.map { ("\($0.month)月", Double($0.count)) }, labelsEvery: 1)
                case .tide:
                    let d = Analytics.conditionDistribution(of: catches)
                    bars("上げ・下げ", ["上げ", "下げ", "潮止まり"].map { ($0, Double(d.byTide[$0] ?? 0)) }, labelsEvery: 1)
                    bars("潮名", ["大潮", "中潮", "小潮", "長潮", "若潮"].map { ($0, Double(d.byTideName[$0] ?? 0)) }, labelsEvery: 1)
                    bars("水温", d.bySeaTemp.keys.sorted().map { ("\($0)℃", Double(d.bySeaTemp[$0] ?? 0)) }, labelsEvery: 1)
                    bars("風", ["微風", "そよ風", "強風"].map { ($0, Double(d.byWind[$0] ?? 0)) }, labelsEvery: 1)
                    bars("気圧傾向", ["下降", "安定", "上昇"].map { ($0, Double(d.byPressureTrend[$0] ?? 0)) }, labelsEvery: 1)
                case .spot:
                    let stats = Analytics.statsBySpot(sessions: sessions)
                    bars("釣行 1 時間あたり尾数", stats.map { (spots[$0.key]?.name ?? "釣り場", $0.value.catchesPerHour) }.sorted { $0.1 > $1.1 }, labelsEvery: 1)
                    bars("ボウズ率", stats.map { (spots[$0.key]?.name ?? "釣り場", $0.value.blankRate * 100) }.sorted { $0.1 < $1.1 }, labelsEvery: 1)
                    let rigs = Analytics.rigStats(sessions: sessions)
                    bars("リグ別 釣果", rigs.map { ($0.rigID?.uuidString.prefix(4).description ?? "未設定", Double($0.catches)) }, labelsEvery: 1)
                    bars("リグ別 ロスト", rigs.map { ($0.rigID?.uuidString.prefix(4).description ?? "未設定", Double($0.hookLosses)) }, labelsEvery: 1)
                case .map:
                    CatchMapView(catches: catches, spots: spots)
                }
            }
            .padding(DS.Spacing.l)
        }
        .background(ThemeBackground(name: .bgDetail))
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(DS.Font.label).foregroundStyle(selected ? DS.Color.background : DS.Color.textPrimary)
                .padding(.horizontal, DS.Spacing.m).padding(.vertical, DS.Spacing.xs)
                .background(selected ? DS.Color.accent : DS.Color.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func bars(_ title: String, _ data: [(String, Double)], labelsEvery: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(title).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            Chart(Array(data.enumerated()), id: \.offset) { i, item in
                BarMark(x: .value("x", item.0), y: .value("y", item.1)).foregroundStyle(DS.Color.accent)
            }
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks { v in if v.index % labelsEvery == 0 { AxisValueLabel().font(.system(size: 9)).foregroundStyle(DS.Color.textTertiary) } } }
            .frame(height: 100)
        }
    }
}

/// 釣果の地図（F-32）：全釣り場の釣果を 30 m メッシュで集計し、尾数の多い場所ほど濃い円で示す。魚種の絞り込みは上のチップ。
struct CatchMapView: View {
    let catches: [Catch]
    let spots: [UUID: Spot]

    private struct Cell: Identifiable { let key: String; let center: Coordinate; let count: Int; var id: String { key } }

    private var cells: [Cell] {
        var counts: [String: (Coordinate, Int)] = [:]
        for c in catches where c.coordinate.isPlausible {
            let key = Mesh.key(for: c.coordinate)
            let v = counts[key] ?? (Mesh.center(for: c.coordinate), 0)
            counts[key] = (v.0, v.1 + 1)
        }
        return counts.map { Cell(key: $0.key, center: $0.value.0, count: $0.value.1) }
    }

    private var region: MKCoordinateRegion {
        let coords = catches.map(\.coordinate).filter(\.isPlausible)
        guard let minLat = coords.map(\.latitude).min(), let maxLat = coords.map(\.latitude).max(),
              let minLon = coords.map(\.longitude).min(), let maxLon = coords.map(\.longitude).max() else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 41.77, longitude: 140.73), latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.01, (maxLat - minLat) * 1.4), longitudeDelta: max(0.01, (maxLon - minLon) * 1.4))
        return MKCoordinateRegion(center: center, span: span)
    }

    var body: some View {
        let list = cells
        let maxCount = max(1, list.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("\(catches.count) 尾 · \(list.count) か所").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            Map(initialPosition: .region(region), interactionModes: [.pan, .zoom]) {
                ForEach(list) { cell in
                    MapCircle(center: cell.center.cl, radius: 25)
                        .foregroundStyle(DS.Color.accent.opacity(0.25 + 0.65 * Double(cell.count) / Double(maxCount)))
                }
                ForEach(Array(spots.values).filter { $0.isRegistered && $0.coordinate.isPlausible }) { spot in
                    Annotation(spot.name, coordinate: spot.coordinate.cl) {
                        Circle().fill(Color.white).frame(width: 6, height: 6)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .saturation(0)
            .frame(height: 460)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
    }
}
