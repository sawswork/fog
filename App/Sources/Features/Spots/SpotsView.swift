import SwiftUI
import MapKit
import Core

/// 釣り場（§7）。全画面のモノトーン地図に釣り場を点で置き、下にカードを横並べ。カードを送ると地図が追従する。
struct SpotsView: View {
    @Environment(AppServices.self) private var services
    private var model: SpotsViewModel { services.spotsModel }
    @State private var camera: MapCameraPosition = .automatic
    @State private var selectedID: UUID?
    @State private var detail: SpotsViewModel.Card?
    @State private var searchText = ""
    @State private var showSearch = false
    @State private var showCompare = false
    /// 表示範囲の緯度幅（度）。狭いほど拡大している
    @State private var latitudeSpan: Double = 0.1
    // 地図レイヤー（F-43）
    @State private var layersOn = false
    @State private var layer: MapLayer = .wind
    @State private var hourOffset = 0
    @State private var raster: FieldRaster?
    @State private var particles = ParticleSystem(count: MapLayerSettings.density.count)
    @State private var region: MKCoordinateRegion?
    @State private var showLayerSettings = false
    // 釣果情報のピン（F-44）
    /// 既定で表示（2026-11-05 開発者の指示）。オフにしたら覚える
    @State private var feedPinsOn = UserDefaults.standard.object(forKey: "fog.feedPins.on") as? Bool ?? true
    private var feedPins: [FeedCatchExtractor.Pin] { model.feedPins }
    @State private var feedPin: FeedCatchExtractor.Pin?
    @State private var rasterTask: Task<Void, Never>?
    /// 時刻ごとの色面（同じ層・同じ範囲・同じ版の間だけ有効）。時刻バーを戻しても即座に出る
    @State private var rasterCache: [Int: FieldRaster] = [:]
    @State private var rasterCacheKey = ""
    static let layerHours = 71
    // 地図のメモ（F-52）
    @State private var notes: [Core.Note] = []
    @State private var placingNote = false
    @State private var noteDraft: NoteDraft?
    @State private var selectedNote: Core.Note?
    struct NoteDraft: Identifiable { let id = UUID(); let coordinate: Coordinate }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                map.overlay {
                    if layersOn { MapLayersOverlay(proxy: proxy, raster: raster, particles: particles, animate: layer.vector != nil && MapLayerSettings.particles) }
                }
                // メモを置くモード：地図をタップした場所にメモを書く（F-52）
                .onTapGesture(coordinateSpace: .local) { point in
                    guard placingNote, let c = proxy.convert(point, from: .local) else { return }
                    placingNote = false
                    noteDraft = NoteDraft(coordinate: Coordinate(latitude: c.latitude, longitude: c.longitude))
                }
            }
            .ignoresSafeArea(edges: .top)
            // テーマのキャラクター（転スラ：地図の左上にカレラ）。地図の操作は通さないが、その領域のタップは地図に届く
            .overlay(alignment: .topLeading) {
                GeometryReader { g in
                    ThemeCharacter(name: .charSpots, baseWidth: g.size.width * 0.42)
                        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                        .padding(.top, DS.Spacing.xl)
                }
                .allowsHitTesting(false)
            }
            VStack {
                HStack(alignment: .top) {
                    if layersOn {
                        MapLayersControls(layer: $layer, hourOffset: $hourOffset, start: layerStart, hours: Self.layerHours,
                                          loading: services.gridForecast.loading, error: services.gridForecast.lastError, onSettings: { showLayerSettings = true })
                            .padding(.leading, DS.Spacing.l).padding(.top, DS.Spacing.l)
                    }
                    Spacer()
                    VStack(spacing: DS.Spacing.s) {
                        roundButton("magnifyingglass") { showSearch = true }
                        roundButton("list.number") { showCompare = true }
                        roundButton(layersOn ? "square.3.layers.3d.top.filled" : "square.3.layers.3d") { toggleLayers() }
                        roundButton(feedPinsOn ? "fish.fill" : "fish") { toggleFeedPins() }
                        roundButton(placingNote ? "xmark" : "note.text.badge.plus") { placingNote.toggle() }
                        roundButton("location.fill") { if let c = model.currentLocation { camera = .region(MKCoordinateRegion(center: c.cl, latitudinalMeters: 3000, longitudinalMeters: 3000)) } }
                    }
                    .padding(DS.Spacing.l)
                }
                Spacer()
            }
            cards
            // 経路の帯（F-57）：所要時間と距離、Apple のマップで案内、閉じる
            if let target = model.routeTarget, let r = model.route {
                VStack {
                    HStack(spacing: DS.Spacing.m) {
                        Image(systemName: "car.fill").foregroundStyle(DS.Color.sea)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(target.name).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                            Text(SpotsViewModel.etaText(.init(seconds: r.expectedTravelTime, meters: r.distance, at: Date()))).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        }
                        Spacer()
                        Button { SpotsViewModel.openInMaps(target) } label: {
                            Text("マップで案内").font(DS.Font.caption).foregroundStyle(DS.Color.background)
                                .padding(.horizontal, 10).padding(.vertical, 6).background(DS.Color.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button { model.clearRoute() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.Color.textSecondary).frame(width: 28, height: 28) }
                            .buttonStyle(.plain)
                    }
                    .padding(DS.Spacing.m)
                    .background(DS.Color.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                    .padding(.horizontal, DS.Spacing.l).padding(.top, DS.Spacing.xl)
                    .padding(.trailing, 56)
                    Spacer()
                }
            } else if let e = model.routeError {
                VStack {
                    Text(e).font(DS.Font.caption).foregroundStyle(DS.Color.background)
                        .padding(.horizontal, DS.Spacing.m).padding(.vertical, 6).background(DS.Color.holiday, in: Capsule()).padding(.top, DS.Spacing.xl)
                    Spacer()
                }
                .allowsHitTesting(false)
                .task { try? await Task.sleep(nanoseconds: 2_500_000_000); model.clearRoute() }
            }
            if placingNote {
                VStack {
                    Text("地図をタップしてメモを置く").font(DS.Font.label).foregroundStyle(DS.Color.background)
                        .padding(.horizontal, DS.Spacing.l).padding(.vertical, DS.Spacing.s).background(DS.Color.accent, in: Capsule())
                        .padding(.top, DS.Spacing.xl)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .onChange(of: layer) { _, _ in rebuildRaster() }
        .sheet(isPresented: $showLayerSettings, onDismiss: {
            particles = ParticleSystem(count: MapLayerSettings.density.count)
            if !MapLayerSettings.isEnabled(layer), let first = MapLayerSettings.enabled.first { layer = first }
            rebuildRaster()
        }) { NavigationStack { MapLayerSettingsView() }.preferredColorScheme(ThemeStore.shared.theme.colorScheme).tint(DS.Color.accent) }
        .onChange(of: hourOffset) { _, _ in rebuildRaster(throttle: true) }
        .onChange(of: services.gridForecast.version) { _, _ in rebuildRaster() }
        .onAppear {
            model.attach(services)
            // 地図を開いている間だけ位置を取り続ける（現在地の点・距離・所要時間が動く）。閉じたら止める
            services.location.beginForegroundUpdates()
            Perf.mark("釣り場画面を開いた")
            model.refreshFeedPins(enabled: feedPinsOn)
            if feedPinsOn { Task { await services.feeds.refreshIfNeeded(); await services.party.syncIfNeeded(store: services.store) } }
            if selectedID != nil {
                // 戻ってきたときは前の選択のまま
            } else if let first = model.cards.first(where: { $0.spot.coordinate.isPlausible }) {
                selectedID = first.spot.id
                camera = .region(region(for: first.spot.coordinate))
            } else if let c = model.currentLocation {
                camera = .region(MKCoordinateRegion(center: c.cl, latitudinalMeters: 8000, longitudinalMeters: 8000))
            } else {
                camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 41.77, longitude: 140.73), latitudinalMeters: 20_000, longitudinalMeters: 20_000))
            }
        }
        .onDisappear { services.location.endForegroundUpdates(); Perf.mark("釣り場画面を閉じた") }
        .onReceive(NotificationCenter.default.publisher(for: .fogStoreDidChange)) { _ in model.refresh(); notes = (try? services.store.notes()) ?? []; model.refreshFeedPins(enabled: feedPinsOn) }
        .onChange(of: services.party.revision) { _, _ in model.refreshFeedPins(enabled: feedPinsOn) }
        .task { notes = (try? services.store.notes()) ?? [] }
        .sheet(item: $noteDraft) { draft in
            NoteEditSheet(coordinate: draft.coordinate, existing: nil, placeHint: model.placeName(near: draft.coordinate)).presentationDetents([.medium])
        }
        .sheet(item: $selectedNote) { note in
            NoteEditSheet(coordinate: note.coordinate, existing: note, placeHint: note.placeName ?? model.placeName(near: note.coordinate)).presentationDetents([.medium])
        }
        .onChange(of: selectedID) { _, id in
            if let id, let c = model.allCards.first(where: { $0.spot.id == id }), c.spot.coordinate.isPlausible { withAnimation { camera = .region(region(for: c.spot.coordinate)) } }
        }
        .sheet(item: $detail) { SpotDetailView(card: $0) }
        .sheet(isPresented: $showCompare) { SpotCompareSheet(model: model).presentationDetents([.large]) }
        .sheet(item: $feedPin) { FeedPinSheet(pin: $0).presentationDetents([.medium, .large]) }
        .onChange(of: services.feeds.revision) { _, _ in model.refreshFeedPins(enabled: feedPinsOn) }
        .sheet(isPresented: $showSearch) { SpotSearchSheet { item in
            showSearch = false
            camera = .region(MKCoordinateRegion(center: item.placemark.coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))
            model.addCandidate(name: item.name ?? "釣り場", coordinate: Coordinate(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude))
        } }
    }

    private func region(for c: Coordinate) -> MKCoordinateRegion {
        MKCoordinateRegion(center: c.cl, latitudinalMeters: 4000, longitudinalMeters: 4000)
    }

    /// 拡大しているときは各点にホームと同じ釣れ率の円を出す（緯度幅 0.12° ≈ 13 km 未満）
    private var zoomedIn: Bool { latitudeSpan < 0.12 }

    private var map: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            ForEach(model.allCards.filter { $0.spot.coordinate.isPlausible }) { card in
                Annotation("", coordinate: card.spot.coordinate.cl, anchor: .center) {
                    // 同じ場所の釣果情報は点の上に載せる。overlay で外にはみ出すとタップできないので、
                    // 縦に並べて下に同じ高さの空白を置き、点の中心を座標に合わせる（2026-11-05 実機フィードバック）
                    let badge = feedPin(for: card)
                    let note = note(for: card)
                    VStack(spacing: 2) {
                        // 同じ場所のメモ（F-52）と釣果情報は点の上に縦に積む。下に同じ高さの空白を置いて点の中心を座標に合わせる
                        if let n = note {
                            Button { selectedNote = n } label: { NoteMarker(note: n) }.buttonStyle(.plain)
                        }
                        if let p = badge {
                            Button { feedPin = p } label: { FeedPinMarker(pin: p) }.buttonStyle(.plain)
                        }
                        Button { selectedID = card.spot.id } label: {
                            SpotMarker(card: card, selected: selectedID == card.spot.id, zoomedIn: zoomedIn)
                        }
                        .buttonStyle(.plain)
                        if badge != nil { Color.clear.frame(height: FeedPinMarker.height + 2) }
                        if note != nil { Color.clear.frame(height: NoteMarker.height + 2) }
                    }
                }
            }
            // 現在地（白の点）。地図を開いている間は位置の更新を続けるので、移動するとリアルタイムで動く（2026-11-09）
            UserAnnotation(anchor: .center) { _ in
                Circle().fill(.white).frame(width: 12, height: 12).overlay(Circle().stroke(DS.Color.background, lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
            // 現在地からの車の経路（F-57）
            if let r = model.route {
                MapPolyline(r.polyline).stroke(DS.Color.sea, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            // 地図のメモ（F-52）：黄色い付箋。タップで内容・編集・削除。釣り場の点と同じ場所のものは点の上に積む（上）
            ForEach(standaloneNotes) { note in
                Annotation("", coordinate: note.coordinate.cl, anchor: .bottom) {
                    Button { selectedNote = note } label: { NoteMarker(note: note) }.buttonStyle(.plain)
                }
            }
            // RSS の記事から拾った釣果（F-44）：場所ごとに 1 つ。新しいほど濃い。釣り場の点と同じ場所のものは点の上に載せる（上）
            if feedPinsOn {
                ForEach(standalonePins) { pin in
                    Annotation("", coordinate: pin.coordinate.cl, anchor: .bottom) {
                        Button { feedPin = pin } label: { FeedPinMarker(pin: pin) }.buttonStyle(.plain)
                    }
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            latitudeSpan = context.region.span.latitudeDelta
            region = context.region
            model.searchPorts(in: context.region)
            if layersOn {
                ensureTiles(for: context.region)
                // 読み込み済みの範囲の中なら作り直さない（枠が動かない）。外に出たら作り直す
                if let r = raster, !r.box.contains(region: context.region) { rebuildRaster() } else if raster == nil { rebuildRaster() }
            }
        }
        // モノトーンは地図の色調（ダークの muted）に任せる。saturation/contrast のフィルタは地図全体を毎フレーム描き直させて重かった（2026-11-09）
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControlVisibility(.hidden)
    }

    // MARK: 釣果情報のピン（F-44）

    /// 釣り場の点（登録済み・候補）と同じ場所（80 m 以内）の釣果情報
    private func feedPin(for card: SpotsViewModel.Card) -> FeedCatchExtractor.Pin? {
        guard feedPinsOn else { return nil }
        return feedPins.first { Geo.distanceMeters($0.coordinate, card.spot.coordinate) < 80 }
    }

    /// 釣り場の点が無い場所の釣果情報だけ、単独のピンにする
    /// 釣り場の点と同じ場所（80 m）のメモ。複数あれば新しいもの
    private func note(for card: SpotsViewModel.Card) -> Core.Note? {
        notes.filter { Geo.distanceMeters($0.coordinate, card.spot.coordinate) < 80 }.max { $0.createdAt < $1.createdAt }
    }

    /// 釣り場の点と重ならないメモ
    private var standaloneNotes: [Core.Note] {
        let cards = model.allCards.filter { $0.spot.coordinate.isPlausible }
        return notes.filter { n in !cards.contains { Geo.distanceMeters($0.spot.coordinate, n.coordinate) < 80 } }
    }

    private var standalonePins: [FeedCatchExtractor.Pin] {
        let cards = model.allCards.filter { $0.spot.coordinate.isPlausible }
        return feedPins.filter { p in !cards.contains { Geo.distanceMeters($0.spot.coordinate, p.coordinate) < 80 } }
    }

    private func toggleFeedPins() {
        feedPinsOn.toggle()
        UserDefaults.standard.set(feedPinsOn, forKey: "fog.feedPins.on")
        model.refreshFeedPins(enabled: feedPinsOn)
        guard feedPinsOn else { return }
        Task { await services.feeds.refreshIfNeeded() }
    }

    // MARK: 地図レイヤー（F-43）

    /// 時刻バーの起点：今の時刻を 1 時間に切り下げ
    private var layerStart: Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let c = cal.dateComponents([.year, .month, .day, .hour], from: Date())
        return cal.date(from: c) ?? Date()
    }

    private func toggleLayers() {
        layersOn.toggle()
        guard layersOn else { raster = nil; return }
        MapLayerSettings.usedOnce = true
        if !MapLayerSettings.isEnabled(layer), let first = MapLayerSettings.enabled.first { layer = first }
        if let region {
            ensureTiles(for: region)
        } else if let c = model.currentLocation ?? model.cards.first?.spot.coordinate {
            services.gridForecast.ensure(minLat: c.latitude - 0.2, maxLat: c.latitude + 0.2, minLon: c.longitude - 0.25, maxLon: c.longitude + 0.25)
        }
        rebuildRaster()
    }

    /// 表示範囲＋周り 1 周のタイルを用意する
    private func ensureTiles(for region: MKCoordinateRegion) {
        let half = region.span.latitudeDelta / 2, halfLon = region.span.longitudeDelta / 2
        services.gridForecast.ensure(minLat: region.center.latitude - half, maxLat: region.center.latitude + half,
                                     minLon: region.center.longitude - halfLon, maxLon: region.center.longitude + halfLon)
    }

    /// 読み込み済みタイル全体（表示範囲の周り 1 周を含む）に対して色面と流れの格子を作る。裏で計算して差し替える。
    /// 時刻バーをドラッグ中は 80 ms 待ってから（連続で作らない）。作ったものは時刻ごとに取っておく
    private func rebuildRaster(throttle: Bool = false) {
        guard layersOn, let region, let grid = services.gridForecast.mosaic(marine: layer.isMarine), !grid.isEmpty,
              let lat = grid.latitudeRange, let lon = grid.longitudeRange else { raster = nil; return }
        // 表示範囲の 3 倍までに絞る（遠くまで読み込んでいても画像が巨大にならないように）
        let half = region.span.latitudeDelta * 1.5, halfLon = region.span.longitudeDelta * 1.5
        var box = GeoBox(minLat: max(lat.lowerBound, region.center.latitude - half), maxLat: min(lat.upperBound, region.center.latitude + half),
                         minLon: max(lon.lowerBound, region.center.longitude - halfLon), maxLon: min(lon.upperBound, region.center.longitude + halfLon))
        // 表示が今の色面の中にあるなら、箱はそのまま（時刻だけ変える。キャッシュが効く）
        if let r = raster, r.layer == layer, r.box.contains(region: region) { box = r.box }
        guard box.maxLat > box.minLat, box.maxLon > box.minLon else { raster = nil; return }
        let key = "\(layer.rawValue)|\(services.gridForecast.version)|\(box.minLat),\(box.maxLat),\(box.minLon),\(box.maxLon)|\(MapLayerSettings.opacity)"
        if key != rasterCacheKey { rasterCache = [:]; rasterCacheKey = key }
        if let cached = rasterCache[hourOffset] { raster = cached; return }
        let time = layerStart.addingTimeInterval(Double(hourOffset) * 3600)
        let l = layer, opacity = MapLayerSettings.opacity, hour = hourOffset
        // 画素数は 1° あたり 200（上限 520）。描くときに滑らかに拡大される
        let width = min(520, max(100, Int((box.maxLon - box.minLon) * 200))), height = min(520, max(100, Int((box.maxLat - box.minLat) * 260)))
        rasterTask?.cancel()
        let b = box
        rasterTask = Task.detached(priority: .userInitiated) {
            if throttle { try? await Task.sleep(nanoseconds: 80_000_000) }
            guard !Task.isCancelled else { return }
            let r = FieldRaster.build(grid: grid, layer: l, time: time, box: b, opacity: opacity, width: width, height: height)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                raster = r
                if rasterCache.count > 24 { rasterCache = [:] }
                rasterCache[hour] = r
            }
        }
    }

    private func etaTaskKey(_ card: SpotsViewModel.Card) -> String {
        guard let c = model.currentLocation else { return card.id.uuidString }
        return "\(card.id.uuidString)|\(Int(c.latitude * 200)),\(Int(c.longitude * 200))"
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.Color.textPrimary)
                .frame(width: 44, height: 44).background(DS.Color.panel.opacity(0.95), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 右下の縦のリスト（漁港名・釣れ率・距離か車の時間）と、選んだ漁港の四角い詳細パネル（左）。2026-11-09 開発者の指示でカードの横並びから変更
    private var cards: some View {
        GeometryReader { geo in
            let listWidth: CGFloat = 150
            let panelSide = min(geo.size.width - listWidth - DS.Spacing.l * 3, geo.size.height * 0.36)
            VStack(spacing: DS.Spacing.s) {
                Spacer()
                HStack(alignment: .bottom, spacing: DS.Spacing.l) {
                    Spacer(minLength: 0)
                    if let id = selectedID, let card = model.allCards.first(where: { $0.spot.id == id }) {
                        SpotDetailPanel(card: card, side: panelSide,
                                        feedPoints: feedPinsOn ? feedPins.map(\.coordinate).filter { Geo.distanceMeters($0, card.spot.coordinate) < 1200 } : [],
                                        distanceM: card.distanceM,
                                        eta: model.eta(for: card.spot), routeOn: model.routeTarget?.id == card.spot.id,
                                        onSelectHome: { model.selectForHome(card.spot) },
                                        onRegister: { model.register(card) },
                                        onRoute: { Task { await model.toggleRoute(to: card.spot) } },
                                        onDetail: { detail = card },
                                        onClose: { selectedID = nil })
                            .task(id: etaTaskKey(card)) { await model.requestETA(for: card.spot) }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    spotList(width: listWidth, height: geo.size.height * 0.5)
                }
                .padding(.horizontal, DS.Spacing.l)
                .padding(.bottom, DS.Spacing.m)
            }
            .animation(.easeInOut(duration: 0.2), value: selectedID)
        }
    }

    /// 近い順の漁港の一覧（登録済みが先頭に来るわけではなく、近い順）。行：名前・釣れ率・距離（車の時間が取れていればそれ）
    private func spotList(width: CGFloat, height: CGFloat) -> some View {
        ScrollViewReader { reader in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(model.allCards) { card in
                        SpotListRow(card: card, selected: selectedID == card.spot.id, distanceM: card.distanceM, eta: model.eta(for: card.spot))
                            .id(card.spot.id)
                            .onTapGesture { selectedID = selectedID == card.spot.id ? nil : card.spot.id }
                    }
                    if model.allCards.isEmpty {
                        Text("地図を動かすと近くの漁港が出ます").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).padding(DS.Spacing.s)
                    }
                }
                .padding(6)
            }
            .frame(width: width, height: height)
            .background(DS.Color.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
            .onChange(of: selectedID) { _, id in if let id { withAnimation { reader.scrollTo(id, anchor: .center) } } }
        }
    }
}

/// 一覧の 1 行：漁港名、釣れ率、距離か車の時間。登録済みはテーマ色の点、未登録はグレーの点
struct SpotListRow: View {
    let card: SpotsViewModel.Card
    let selected: Bool
    var distanceM: Double? = nil
    var eta: SpotsViewModel.DriveETA? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 4) {
                    Circle().fill(card.spot.isRegistered ? DS.Color.accent : DS.Color.textTertiary).frame(width: 5, height: 5).padding(.top, 5)
                    // 名前は 2 行まで（「はこだて漁港」のような長い名前が切れないように）
                    Text(card.spot.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary)
                        .lineLimit(2).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
                }
                Text(eta.map { Self.short($0) } ?? (distanceM.map { $0 >= 1000 ? String(format: "%.1f km", $0 / 1000) : "\(Int($0)) m" } ?? "—"))
                    .font(.system(size: 10)).foregroundStyle(DS.Color.textTertiary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 2)
            Text("\(card.score)").font(DS.Font.number(17)).foregroundStyle(card.score >= 70 ? DS.Color.accent : DS.Color.textPrimary)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? DS.Color.surfaceRaised : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    /// 「車25分·18km」を 1 行に収める短い形
    static func short(_ e: SpotsViewModel.DriveETA) -> String {
        let m = Int((e.seconds / 60).rounded())
        let t = m >= 60 ? "\(m / 60)h\(m % 60 == 0 ? "" : "\(m % 60)m")" : "\(m)分"
        return "車\(t)·" + (e.meters >= 10_000 ? String(format: "%.0fkm", e.meters / 1000) : String(format: "%.1fkm", e.meters / 1000))
    }
}

/// 選んだ漁港の四角い詳細：上に航空写真（釣れた位置の点つき）、下に釣れ率・釣行数・最後の釣行・よく釣れる魚、車の時間、ボタン（選択／登録・経路）。パネルをタップで釣り場詳細
struct SpotDetailPanel: View {
    let card: SpotsViewModel.Card
    let side: CGFloat
    var feedPoints: [Coordinate] = []
    var distanceM: Double? = nil
    var eta: SpotsViewModel.DriveETA? = nil
    var routeOn: Bool = false
    let onSelectHome: () -> Void
    var onRegister: () -> Void = {}
    var onRoute: () -> Void = {}
    var onDetail: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        // 写真の高さは枠から逆算する（名前・数字・ボタンの分を引く）。中身が枠を超えて上下にはみ出していた（2026-11-09 実機フィードバック）
        let imageWidth = side - DS.Spacing.m * 2
        let imageHeight = max(60, side - DS.Spacing.m * 2 - 22 - 16 - 30 - 6 * 3)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                if card.spot.coordinate.isPlausible {
                    SpotSnapshotView(coordinate: card.spot.coordinate, catchPoints: card.catchPoints, lossPoints: card.lossPoints, feedPoints: feedPoints,
                                     displaySize: CGSize(width: imageWidth, height: imageHeight))
                }
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(Color.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Text(card.spot.name).font(.system(size: 15, weight: .bold)).foregroundStyle(DS.Color.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                Text("\(card.score)").font(DS.Font.score(24)).foregroundStyle(card.score >= 70 ? DS.Color.accent : DS.Color.textPrimary)
            }
            .frame(height: 22)
            HStack(spacing: DS.Spacing.s) {
                if card.isCandidate {
                    Text("未登録の漁港").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                } else {
                    Text("\(card.stats.sessions)釣行 \(card.stats.catches)尾").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    if let last = card.stats.lastSessionAt { Text(last, format: .dateTime.month().day()).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
                }
                Spacer()
                ForEach(card.stats.topSpecies.prefix(2), id: \.species) { s in
                    Text(s.species).font(.system(size: 10)).foregroundStyle(DS.Color.textTertiary)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button(action: onRoute) {
                    HStack(spacing: 4) {
                        Image(systemName: routeOn ? "car.fill" : "car").font(.system(size: 10, weight: .semibold))
                        Text(eta.map { SpotListRow.short($0) } ?? (distanceM.map { $0 >= 1000 ? String(format: "%.1f km", $0 / 1000) : "\(Int($0)) m" } ?? "—"))
                            .font(DS.Font.caption).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(routeOn ? DS.Color.background : DS.Color.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(routeOn ? DS.Color.sea : DS.Color.surfaceRaised, in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if card.isCandidate {
                    Button(action: onRegister) {
                        Label("登録", systemImage: "plus").font(DS.Font.caption).foregroundStyle(DS.Color.background)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(DS.Color.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: onSelectHome) {
                        Text("ホームに").font(DS.Font.caption).foregroundStyle(DS.Color.textPrimary)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(DS.Color.surfaceRaised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onDetail) {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.Color.textPrimary)
                        .frame(width: 28, height: 28).background(DS.Color.surfaceRaised, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Spacing.m)
        .frame(width: side, height: side, alignment: .top)
        .clipped()
        .background(DS.Color.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onDetail)
    }
}

extension Coordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// 検索（全国の漁港名・地名、F-50）。1 文字打つごとに同梱の港データをよみで絞り込み（かな・ローマ字・漢字）、
/// 少し遅れて MapKit の候補（地名）も足す。Enter で MapKit の全文検索。
struct SpotSearchSheet: View {
    let onPick: (MKMapItem) -> Void
    @State private var text = ""
    @State private var ports: [Core.Port] = []
    @State private var completions: [MKLocalSearchCompletion] = []
    @State private var results: [MKMapItem] = []
    @State private var completer = Completer()
    @State private var debounce: Task<Void, Never>?

    var body: some View {
        VStack(spacing: DS.Spacing.m) {
            TextField("漁港名・地名（かな・ローマ字でも）", text: $text)
                .font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(DS.Spacing.m).background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                .onSubmit { Task { await search() } }
            ScrollView {
                VStack(spacing: DS.Spacing.s) {
                    ForEach(ports) { port in
                        Button { onPick(Self.mapItem(for: port)) } label: {
                            row(port.name, (port.pref.flatMap { PortReadingIndex.prefectures[$0] } ?? "") + (port.kind == .fishing ? " 漁港" : " 港湾"))
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(Array(completions.enumerated()), id: \.offset) { _, c in
                        Button { Task { await pick(c) } } label: { row(c.title, c.subtitle) }.buttonStyle(.plain)
                    }
                    ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                        Button { onPick(item) } label: { row(item.name ?? "", item.placemark.title ?? "") }.buttonStyle(.plain)
                    }
                    if text.isEmpty {
                        Text("例：しかべ、hakodate、森港").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).padding(.top, DS.Spacing.s)
                    }
                }
            }
        }
        .padding(DS.Spacing.l)
        .background(ThemeBackground(name: .bgDetail))
        .onAppear {
            PortReadingIndex.shared.prepare(catalog: PortCatalog.bundled())
            completer.onUpdate = { completions = $0 }
        }
        .onChange(of: text) { _, t in
            ports = PortReadingIndex.shared.search(t)
            results = []
            debounce?.cancel()
            debounce = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                completer.update(query: t)
            }
        }
    }

    private func row(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
            Text(subtitle).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.m).background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
    }

    private static func mapItem(for port: Core.Port) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: port.lat, longitude: port.lon)))
        item.name = port.name
        return item
    }

    private func pick(_ completion: MKLocalSearchCompletion) async {
        let request = MKLocalSearch.Request(completion: completion)
        if let item = (try? await MKLocalSearch(request: request).start())?.mapItems.first { onPick(item) }
    }

    private func search() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 38, longitude: 137), latitudinalMeters: 2_000_000, longitudinalMeters: 2_000_000)
        results = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
    }

    /// MapKit の入力補完（地名）。日本全体を対象にする
    @MainActor
    final class Completer: NSObject, MKLocalSearchCompleterDelegate {
        private let completer = MKLocalSearchCompleter()
        var onUpdate: (([MKLocalSearchCompletion]) -> Void)?
        override init() {
            super.init()
            completer.delegate = self
            completer.resultTypes = [.address, .pointOfInterest]
            completer.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 38, longitude: 137), latitudinalMeters: 2_000_000, longitudinalMeters: 2_000_000)
        }
        func update(query: String) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty { onUpdate?([]); completer.cancel(); return }
            completer.queryFragment = query
        }
        nonisolated func completer(_ completer: MKLocalSearchCompleter, didUpdateResults results: [MKLocalSearchCompletion]) {
            // 港は同梱データで出すので、MapKit からは地名と港以外の候補を少しだけ
            let items = Array(results.prefix(8))
            Task { @MainActor in self.onUpdate?(items) }
        }
        nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
            Task { @MainActor in self.onUpdate?([]) }
        }
    }
}

/// 地図の点。引いているときは釣行数で大きさが変わる点（登録はオレンジ、未登録はグレー）に釣行数の小さな数字、
/// 拡大しているときはホームと同じ釣れ率の円（数字と円弧）。
struct SpotMarker: View {
    let card: SpotsViewModel.Card
    let selected: Bool
    let zoomedIn: Bool

    private var color: Color { card.spot.isRegistered ? DS.Color.accent : DS.Color.textTertiary }

    var body: some View {
        if zoomedIn {
            VStack(spacing: 2) {
                ZStack {
                    Circle().fill(DS.Color.background.opacity(0.85)).frame(width: 44, height: 44)
                    Circle().stroke(DS.Color.faded, lineWidth: 4).frame(width: 38, height: 38)
                    Circle().trim(from: 0, to: CGFloat(max(0, min(100, card.score))) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 38, height: 38)
                    Text("\(card.score)").font(DS.Font.number(15)).foregroundStyle(DS.Color.textPrimary)
                }
                .scaleEffect(selected ? 1.15 : 1)
                Text(card.spot.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(DS.Color.background.opacity(0.7), in: Capsule())
            }
        } else {
            HStack(spacing: 3) {
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
                    .opacity(selected ? 1 : 0.85)
                    .overlay(selected ? Circle().stroke(.white, lineWidth: 2) : nil)
                if card.stats.sessions > 0 {
                    Text("\(card.stats.sessions)").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Color.textSecondary)
                }
            }
        }
    }

    private var dotSize: CGFloat {
        card.isCandidate ? 10 : 14 + CGFloat(min(12, card.stats.sessions)) * 1.6
    }
}

/// 釣り場の比較（F-30）：登録した釣り場を、選んだ日の最高釣れ率の順に並べる。日は矢印で送る（今日から 2 週間）。
/// 行をタップするとホームの釣り場にする
struct SpotCompareSheet: View {
    let model: SpotsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var dayOffset = 0
    @State private var rows: [SpotsViewModel.CompareRow] = []
    @State private var loading = false
    private let tz = TimeZone(identifier: "Asia/Tokyo") ?? .current

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack {
                Button { if dayOffset > 0 { dayOffset -= 1 } } label: { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(dayOffset > 0 ? DS.Color.textSecondary : DS.Color.faded).frame(width: 28, height: 22) }.buttonStyle(.plain)
                Spacer()
                HStack(spacing: 6) {
                    Text(ForecastChart.dayLabel(day, timeZone: tz)).font(DS.Font.number(16)).foregroundStyle(DS.Color.textPrimary)
                    Text(dayOffset == 0 ? "今日" : (dayOffset == 1 ? "明日" : "")).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
                Spacer()
                Button { if dayOffset < 13 { dayOffset += 1 } } label: { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(dayOffset < 13 ? DS.Color.textSecondary : DS.Color.faded).frame(width: 28, height: 22) }.buttonStyle(.plain)
            }
            if rows.isEmpty {
                Text(loading ? "計算中" : "登録した釣り場がありません").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            }
            VStack(spacing: DS.Spacing.s) {
                ForEach(rows) { r in
                    Button { model.selectForHome(r.spot); dismiss() } label: { row(r) }.buttonStyle(.plain)
                }
            }
            Spacer()
            Text("タップでホームの釣り場にする · 予報の先は潮と光だけで計算").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ThemeBackground(name: .bgDetail))
        .task(id: dayOffset) {
            loading = true
            rows = await model.compare(dayOffset: dayOffset)
            loading = false
        }
    }

    private var day: Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return cal.startOfDay(for: Date()).addingTimeInterval(Double(dayOffset) * 86_400)
    }

    private func row(_ r: SpotsViewModel.CompareRow) -> some View {
        HStack(spacing: DS.Spacing.m) {
            Text("\(r.maxScore)").font(DS.Font.score(28)).foregroundStyle(r.maxScore >= 70 ? DS.Color.accent : DS.Color.textPrimary).frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.spot.name).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                HStack(spacing: DS.Spacing.s) {
                    if let s = r.windowStart, let e = r.windowEnd {
                        Text("\(HomeViewModel.clock(s, timeZone: tz))〜\(HomeViewModel.clock(e, timeZone: tz))").font(DS.Font.number(12)).foregroundStyle(DS.Color.sun)
                    }
                    if let d = r.distanceM {
                        Text(d >= 1000 ? String(format: "%.0f km", d / 1000) : "\(Int(d)) m").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                    }
                }
            }
            Spacer()
            Image(systemName: r.conditionCode.map { HomeViewModel.weatherSymbol($0) } ?? "minus").font(.system(size: 16)).foregroundStyle(DS.Color.textSecondary)
        }
        .padding(DS.Spacing.m)
        .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
    }
}

/// 釣果情報のピン：魚のアイコンと件数。直近 7 日は濃く、2 週間を過ぎると薄く
struct FeedPinMarker: View {
    let pin: FeedCatchExtractor.Pin
    /// カプセル 23 + 三角 5 + 間隔 2
    static let height: CGFloat = 30
    private var age: TimeInterval { Date().timeIntervalSince(pin.latestAt ?? .distantPast) }
    private var opacity: Double { age < 7 * 86_400 ? 1 : (age < 14 * 86_400 ? 0.75 : 0.45) }
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: "fish.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.Color.background)
                Text(pin.speciesCounts.first.map { "\($0.0)" } ?? "記事").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Color.background).lineLimit(1).fixedSize()
                if pin.entries.count > 1 { Text("\(pin.entries.count)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(DS.Color.background.opacity(0.7)) }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(DS.Color.sun, in: Capsule())
            Triangle().fill(DS.Color.sun).frame(width: 8, height: 5)
        }
        .opacity(opacity)
    }

    struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.closeSubpath(); return p
        }
    }
}

/// ピンをタップ：その場所の記事を新しい順に。魚種・日付・出典、タップで記事へ
struct FeedPinSheet: View {
    let pin: FeedCatchExtractor.Pin
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(pin.placeName).font(DS.Font.number(20)).foregroundStyle(DS.Color.textPrimary)
                Spacer()
                Text("\(pin.entries.count) 記事").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            }
            if !pin.speciesCounts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(Array(pin.speciesCounts.enumerated()), id: \.offset) { _, sc in
                            Text("\(sc.0) \(sc.1)").font(DS.Font.caption).foregroundStyle(DS.Color.background)
                                .padding(.horizontal, DS.Spacing.s).padding(.vertical, 3).background(DS.Color.sun, in: Capsule())
                        }
                    }
                }
            }
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.s) {
                    ForEach(pin.entries) { e in
                        let content = VStack(alignment: .leading, spacing: 3) {
                            Text(e.title).font(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(2)
                            HStack(spacing: DS.Spacing.s) {
                                if !e.species.isEmpty { Text(e.species.joined(separator: "・")).font(DS.Font.caption).foregroundStyle(DS.Color.sun) }
                                if let d = e.publishedAt { Text(d, format: .dateTime.month().day()).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
                                Text(e.feedTitle).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                            }
                        }
                        .padding(DS.Spacing.m).frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                        if let link = e.link, let url = URL(string: link) { Link(destination: url) { content } } else { content }
                    }
                }
            }
            Text("見出しと要約に出た港名・釣り場名と魚種名から置いています。場所が書かれていない記事は出ません").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ThemeBackground(name: .bgDetail))
    }
}


/// 地図のメモの印（F-52）：黄色い付箋に先頭の文字
struct NoteMarker: View {
    static let height: CGFloat = 27
    let note: Core.Note
    /// 釣果情報と同じく、古いほど薄い（7 日まで 1.0、14 日まで 0.75、それ以降 0.45）
    private var opacity: Double {
        let age = Date().timeIntervalSince(note.createdAt)
        return age < 7 * 86_400 ? 1 : (age < 14 * 86_400 ? 0.75 : 0.45)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: note.source == .voice ? "waveform" : "note.text").font(.system(size: 9, weight: .bold))
                Text(String(note.text.prefix(8))).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(DS.Color.background)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(DS.Color.sun, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Triangle().fill(DS.Color.sun).frame(width: 8, height: 5)
        }
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .opacity(opacity)
    }

    struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.closeSubpath()
            return p
        }
    }
}

/// メモの作成・編集（F-52）
struct NoteEditSheet: View {
    let coordinate: Coordinate
    let existing: Core.Note?
    let placeHint: String?
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var place = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack {
                Text(existing == nil ? "メモを置く" : "メモ").font(DS.Font.number(20)).foregroundStyle(DS.Color.textPrimary)
                Spacer()
                if let e = existing {
                    Text(e.createdAt, format: .dateTime.month().day().hour().minute()).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
            }
            TextField("場所（任意）", text: $place)
                .font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                .padding(DS.Spacing.m).background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
            TextField("店先で聞いた話など", text: $text, axis: .vertical)
                .lineLimit(4...8)
                .font(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                .padding(DS.Spacing.m).background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
            HStack {
                if let e = existing {
                    Button(role: .destructive) { try? services.store.deleteNote(id: e.id); dismiss() } label: {
                        Text("削除").font(DS.Font.label).foregroundStyle(DS.Color.holiday)
                    }
                }
                Spacer()
                Button { save() } label: {
                    Text("保存").font(DS.Font.label).foregroundStyle(DS.Color.background)
                        .padding(.horizontal, DS.Spacing.l).padding(.vertical, DS.Spacing.s).background(DS.Color.accent, in: Capsule())
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Spacer()
        }
        .padding(DS.Spacing.l)
        .background(ThemeBackground(name: .bgDetail))
        .onAppear { text = existing?.text ?? ""; place = existing?.placeName ?? placeHint ?? "" }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var note = existing ?? Core.Note(coordinate: coordinate, text: trimmed)
        note.text = trimmed
        note.placeName = place.isEmpty ? nil : place
        try? services.store.upsert(note)
        dismiss()
    }
}
