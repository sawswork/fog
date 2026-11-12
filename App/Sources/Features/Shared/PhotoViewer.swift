import SwiftUI
import MapKit
import Photos
import Core

/// 釣果の写真を全画面で見る（F-55）。ピンチで拡大、ドラッグで移動、ダブルタップで切替。
/// 写真本体はフォトライブラリから読み（長辺 2048）、読めない（消した・権限なし）ときはサムネイルを大きく出す。
struct PhotoViewer: View {
    let catchItem: Catch
    /// 仲間の釣果など、ライブラリに写真が無いときのサムネイル
    var fallback: Data?
    /// 仲間の釣果なら、その ID（写真本体を iCloud から取りに行き、「写真に保存」を出す）
    var sharedID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services
    @State private var image: UIImage?
    @State private var loading = true
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var fetchingFull = false
    @State private var saved = false
    @State private var fullLoaded = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else if loading {
                        ProgressView().tint(.white)
                    } else {
                        VStack(spacing: DS.Spacing.s) {
                            Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.white.opacity(0.5))
                            Text("写真を読めません（ライブラリから消えたか、写真の権限がありません）").font(DS.Font.caption).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { v in scale = min(6, max(1, lastScale * v.magnification)) }
                        .onEnded { _ in lastScale = scale; if scale <= 1.01 { withAnimation { offset = .zero; lastOffset = .zero } } }
                        .simultaneously(with: DragGesture()
                            .onChanged { v in if scale > 1 { offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height) } }
                            .onEnded { _ in lastOffset = offset })
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if scale > 1 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5; lastScale = 2.5 }
                    }
                }
            }
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DS.Spacing.s) {
                            Text(catchItem.species.isEmpty ? "魚" : catchItem.species).font(DS.Font.number(20)).foregroundStyle(.white)
                            if let l = catchItem.lengthCm { Text("\(Int(l.rounded()))cm").font(DS.Font.number(20)).foregroundStyle(DS.Color.accent) }
                        }
                        Text(catchItem.at, format: .dateTime.year().month().day().hour().minute()).font(DS.Font.caption).foregroundStyle(.white.opacity(0.7))
                        if let a = catchItem.angler, !a.isEmpty { Text(a).font(DS.Font.caption).foregroundStyle(DS.Color.sun) }
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(Color.white.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(DS.Spacing.l)
                Spacer()
                // 仲間の釣果：写真本体の取得状況と「写真に保存」（この端末のフォトライブラリへ）
                if sharedID != nil {
                    HStack {
                        if fetchingFull {
                            ProgressView().tint(.white)
                            Text("写真を取得中").font(DS.Font.caption).foregroundStyle(.white.opacity(0.8))
                        } else if !fullLoaded {
                            Text("サムネイルを表示中（本体を取れませんでした。圏内でもう一度）").font(DS.Font.caption).foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                        if image != nil {
                            Button { save() } label: {
                                Label(saved ? "保存しました" : "写真に保存", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                                    .font(DS.Font.label).foregroundStyle(saved ? DS.Color.background : .white)
                                    .padding(.horizontal, DS.Spacing.l).padding(.vertical, DS.Spacing.s)
                                    .background(saved ? DS.Color.accent : Color.white.opacity(0.18), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(saved)
                        }
                    }
                    .padding(DS.Spacing.l)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        if let sharedID {
            // 仲間の釣果：まずサムネイル、続けて写真本体を iCloud から（取れたら端末に残る）
            if let data = services.party.cachedPhoto(for: sharedID), let ui = UIImage(data: data) { image = ui; fullLoaded = true; return }
            if let data = fallback ?? services.party.thumbnail(for: sharedID), let ui = UIImage(data: data) { image = ui }
            loading = false
            fetchingFull = true
            if let data = await services.party.fetchPhoto(for: sharedID), let ui = UIImage(data: data) { image = ui; fullLoaded = true }
            fetchingFull = false
            return
        }
        if let id = catchItem.photoLocalIdentifier ?? catchItem.photoLocalIdentifiers.first,
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
           let cg = await PhotoLibraryService().image(for: asset, maxPixel: 2048) {
            image = UIImage(cgImage: cg)
            return
        }
        if let data = fallback ?? services.store.thumbnail(catchID: catchItem.id), let ui = UIImage(data: data) { image = ui }
    }

    /// この端末のフォトライブラリに保存する（仲間の釣果の写真）
    private func save() {
        guard let image else { return }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { return }
            try? await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetChangeRequest.creationRequestForAsset(from: image)
                req.creationDate = catchItem.at
                req.location = CLLocation(latitude: catchItem.coordinate.latitude, longitude: catchItem.coordinate.longitude)
            }
            saved = true
        }
    }
}

/// 釣行の軌跡と釣果の位置を全画面の地図で（F-55）。ピンチ・ドラッグで動かせる。
/// 「位置を直す」で釣果を選んで地図をタップすると、その釣果の位置を置き直せる（F-59。GPS がずれていたときの手直し）
struct SessionMapSheet: View {
    let session: Core.Session
    let spotName: String
    /// 隠している釣果と、立った場所を出すか（釣行詳細の小さい地図と同じ切替）
    @Binding var hidden: Set<UUID>
    @Binding var showStays: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services
    @State private var catches: [Catch] = []
    @State private var editing = false
    @State private var selectedCatchID: UUID?
    @State private var moved = 0

    var body: some View {
        // 軌跡は、飛び値を外して「立った場所」にまとめてから描く（測位が粗いと、線が数百 m 先へ飛んでぐちゃぐちゃになる）
        let cleaned = TrackCleaner.clean(session.track, anchors: catches.map(\.coordinate), end: session.endedAt)
        // 番号は釣れた順（潮位のグラフの凡例と同じ）。隠した釣果は出さない
        let ordered = catches.sorted { $0.at < $1.at }
        let shown = ordered.enumerated().filter { $0.element.coordinate.isPlausible && !hidden.contains($0.element.id) }
        // 同じ場所で釣れた魚は、扇のようにずらして並べる
        let fan = TrackCleaner.fanOut(shown.map(\.element.coordinate), radiusM: 10)
        let lost = session.hookEvents.filter { $0.kind == .lost && $0.coordinate.isPlausible }
        let all = cleaned.stays.map(\.coordinate) + ordered.map(\.coordinate).filter(\.isPlausible)
        ZStack(alignment: .top) {
            MapReader { proxy in
                Map(initialPosition: .region(SessionMapGeometry.region(fitting: all)), interactionModes: [.pan, .zoom, .rotate]) {
                    if showStays, cleaned.path.count >= 2 {
                        MapPolyline(coordinates: cleaned.path.map(\.cl)).stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5]))
                    }
                    ForEach(showStays ? cleaned.stays : []) { stay in
                        Annotation("", coordinate: stay.coordinate.cl) { StayMarker(minutes: stay.minutes, compact: false) }
                    }
                    ForEach(lost, id: \.id) { e in
                        Annotation("", coordinate: e.coordinate.cl) {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                                .frame(width: 16, height: 16).background(Color.black.opacity(0.55), in: Circle())
                        }
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.element.id) { k, item in
                        let c = item.element
                        let picked = selectedCatchID == c.id && editing
                        Annotation(c.species + (c.lengthCm.map { " \(Int($0.rounded()))" } ?? ""), coordinate: c.coordinate.cl) {
                            Text("\(item.offset + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                                .frame(width: 24, height: 24)
                                .background(picked ? DS.Color.sun : DS.Color.accent, in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .scaleEffect(picked ? 1.3 : 1)
                                .offset(SessionMapGeometry.fanOffset(index: fan[k].index, count: fan[k].count))
                        }
                    }
                }
                .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
                .ignoresSafeArea()
                // 位置を直すモード：地図をタップした場所へ、選んだ釣果を動かす
                .onTapGesture(coordinateSpace: .local) { point in
                    guard editing, let id = selectedCatchID, let c = proxy.convert(point, from: .local) else { return }
                    let coordinate = Coordinate(latitude: c.latitude, longitude: c.longitude)
                    services.capture.setCoordinate(catchID: id, coordinate: coordinate)
                    if let i = catches.firstIndex(where: { $0.id == id }) { catches[i].coordinate = coordinate }
                    moved += 1
                }
            }
            VStack(spacing: DS.Spacing.s) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spotName).font(DS.Font.number(18)).foregroundStyle(.white)
                        Text("\(session.catches.count)尾 · 立った場所 \(cleaned.stays.count) か所" + (cleaned.dropped > 0 ? " · 飛んだ位置 \(cleaned.dropped) 点を除外" : ""))
                            .font(DS.Font.caption).foregroundStyle(.white.opacity(0.75))
                        // 凡例
                        HStack(spacing: 10) {
                            HStack(spacing: 4) { Circle().fill(Color.white.opacity(0.3)).overlay(Circle().stroke(.white, lineWidth: 1)).frame(width: 11, height: 11); Text("立った場所（分）") }
                            HStack(spacing: 4) { Circle().fill(DS.Color.accent).frame(width: 11, height: 11); Text("釣果（釣れた順）") }
                            if !lost.isEmpty { HStack(spacing: 3) { Image(systemName: "xmark").font(.system(size: 8, weight: .heavy)); Text("ロスト") } }
                        }
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(DS.Spacing.m).background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(Color.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                // 印の切替：立った場所と、釣果 1 尾ずつ
                if !editing {
                    SessionMapToggles(catches: catches, hidden: $hidden, showStays: $showStays, onDark: true)
                }
                Spacer()
                if !catches.isEmpty { editBar }
            }
            .padding(DS.Spacing.l)
        }
        .onAppear { catches = session.catches; selectedCatchID = session.catches.first?.id; Perf.mark("釣行の地図を開いた") }
    }

    /// 下の帯：「位置を直す」→ 釣果のチップを選んで地図をタップ。「完了」で戻る
    private var editBar: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            if editing {
                Text(moved > 0 ? "動かしました（\(moved) 回）。続けてタップで置き直せます" : "直したい釣果を選んで、地図の正しい場所をタップ")
                    .font(DS.Font.caption).foregroundStyle(.white.opacity(0.85))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.s) {
                        ForEach(catches, id: \.id) { c in
                            Button { selectedCatchID = c.id } label: {
                                Text("\(JPFormat.hm(c.at)) \(c.species.isEmpty ? "魚" : c.species)\(c.lengthCm.map { " \(Int($0.rounded()))" } ?? "")")
                                    .font(DS.Font.caption).foregroundStyle(selectedCatchID == c.id ? DS.Color.background : .white)
                                    .padding(.horizontal, DS.Spacing.m).padding(.vertical, 6)
                                    .background(selectedCatchID == c.id ? DS.Color.sun : Color.white.opacity(0.18), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button { editing.toggle() } label: {
                    Label(editing ? "完了" : "釣れた位置を直す", systemImage: editing ? "checkmark" : "mappin.and.ellipse")
                        .font(DS.Font.label).foregroundStyle(editing ? DS.Color.background : .white)
                        .padding(.horizontal, DS.Spacing.l).padding(.vertical, DS.Spacing.s)
                        .background(editing ? DS.Color.accent : Color.black.opacity(0.55), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Spacing.m)
        .background(Color.black.opacity(editing ? 0.55 : 0), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }
}

/// 立った場所の印：丸の大きさは滞在時間。5 分以上は分数を中に書く
struct StayMarker: View {
    let minutes: Int
    /// 小さい地図用（数字なし・小さめ）
    var compact = false

    var body: some View {
        let d: CGFloat = compact ? 10 + min(14, CGFloat(Double(minutes).squareRoot()) * 1.8) : 18 + min(30, CGFloat(Double(minutes).squareRoot()) * 3.4)
        ZStack {
            Circle().fill(Color.white.opacity(0.24))
            Circle().stroke(Color.white.opacity(0.95), lineWidth: compact ? 1 : 1.5)
            if !compact, minutes >= 5 {
                Text("\(minutes)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).shadow(color: .black.opacity(0.7), radius: 1.5)
            }
        }
        .frame(width: d, height: d)
    }
}

/// 釣行の地図の範囲と、重なる印のずらし方
enum SessionMapGeometry {
    /// 点が全部入る範囲（余白つき。狭すぎないよう 220 m 以上）
    static func region(fitting points: [Coordinate]) -> MKCoordinateRegion {
        let valid = points.filter(\.isPlausible)
        guard let first = valid.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 41.77, longitude: 140.73), latitudinalMeters: 700, longitudinalMeters: 700)
        }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for p in valid {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let northSouth = (maxLat - minLat) * 111_132
        let eastWest = (maxLon - minLon) * 111_320 * cos(center.latitude * .pi / 180)
        let span = max(220, max(northSouth, eastWest) * 1.6)
        return MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span)
    }

    /// 同じ場所の印の k 番目（全 n 個）を、上向きの扇に並べるずれ（pt）。`radius` は扇の半径（省略は印の数で決める）
    static func fanOffset(index k: Int, count n: Int, radius: Double? = nil) -> CGSize {
        guard n > 1 else { return .zero }
        let step = min(40.0, 150.0 / Double(n - 1))
        let angle = (-90.0 + (Double(k) - Double(n - 1) / 2) * step) * .pi / 180
        let r = radius ?? (n > 4 ? 40.0 : 30.0)
        return CGSize(width: cos(angle) * r, height: sin(angle) * r)
    }
}

/// 地図に出す印の切替（釣行詳細の小さい地図と全画面の地図で共通）。「立った場所」と、釣果 1 尾ずつ（番号は釣れた順）。
/// 重なって見づらいとき、見たい魚だけを残せる
struct SessionMapToggles: View {
    let catches: [Catch]
    @Binding var hidden: Set<UUID>
    @Binding var showStays: Bool
    /// 航空写真の上（全画面の地図）に置くとき
    var onDark = false

    var body: some View {
        let ordered = catches.sorted { $0.at < $1.at }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(on: showStays) { showStays.toggle() } label: {
                    Circle().fill(Color.white.opacity(0.3)).overlay(Circle().stroke(.white, lineWidth: 1)).frame(width: 11, height: 11)
                    Text("立った場所")
                }
                if ordered.count >= 2 {
                    chip(on: hidden.isEmpty) { hidden = hidden.isEmpty ? Set(ordered.map(\.id)) : [] } label: { Text(hidden.isEmpty ? "釣果を全部隠す" : "釣果を全部出す") }
                }
                ForEach(Array(ordered.enumerated()), id: \.element.id) { i, c in
                    chip(on: !hidden.contains(c.id)) {
                        if hidden.contains(c.id) { hidden.remove(c.id) } else { hidden.insert(c.id) }
                    } label: {
                        Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 15, height: 15).background(DS.Color.accent, in: Circle())
                        Text((c.species.isEmpty ? "魚" : c.species) + (c.lengthCm.map { " \(Int($0.rounded()))" } ?? ""))
                    }
                }
            }
        }
    }

    private func chip<Label: View>(on: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { label() }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(onDark ? Color.white : DS.Color.textPrimary)
                .padding(.horizontal, 9).frame(height: 28)
                .background(onDark ? Color.black.opacity(0.55) : DS.Color.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? DS.Color.accent : Color.clear, lineWidth: 1.2))
                .opacity(on ? 1 : 0.45)
        }
        .buttonStyle(.plain)
    }
}

