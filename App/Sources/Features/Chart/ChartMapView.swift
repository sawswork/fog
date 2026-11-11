import SwiftUI
import Core

/// 港の図と、その上の情報（F-63）。奥から順に：図 → 風の流れ → 過去の釣果 → 投げる場所の見立て → 自分の位置 → 今日の釣果 → 風の計器。
/// 図は横幅いっぱい（縦 3:4）に敷く。ピンチで拡大（1〜5 倍）、ドラッグで移動、ダブルタップで拡大／全体。
/// 印や文字の大きさは変えず、位置だけを拡大に合わせる（`ChartProjector`）
struct ChartMapView: View {
    let model: ChartViewModel
    /// いま記録した釣果（波紋を出す）
    var newestCatchID: UUID?
    /// 枠で囲むテーマ：上のぼかしを入れない（枠の中いっぱいに図を見せる）
    var framed = false

    @State private var scale: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var baseScale: CGFloat = 1
    @State private var basePan: CGSize = .zero
    /// 現在地へ自動で寄せた海図（海図ごとに 1 回だけ）
    @State private var autoZoomed: String?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let project = ChartProjector(size: size, scale: scale, pan: pan)
            ZStack(alignment: .topLeading) {
                ChartStyle.bg
                baseImage(project)
                ChartWindField(fromDeg: model.conditions.windFromDeg, speed: model.conditions.windSpeedMS)
                if let frame = model.frame {
                    pastDots(frame: frame, project)
                    castLine(frame: frame, project)
                    zoneLayer(project)
                    userDot(frame: frame, project)
                    todayPins(frame: frame, project)
                }
                VStack(spacing: 0) {
                    LinearGradient(colors: [ChartStyle.bg.opacity(framed ? 0.35 : 1), ChartStyle.bg.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: framed ? 30 : 44)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [ChartStyle.bg.opacity(0), ChartStyle.bg], startPoint: .top, endPoint: .bottom).frame(height: 120)
                }
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
                // 風向の計器は上のぼかしより手前に置く（丸が全部見える位置）
                windDial.position(x: size.width - 44, y: 46)
                zoomButtons(size: size).position(x: framed ? 30 : 28, y: framed ? 84 : 72)
            }
            // 図（縦 3:4）は領域より背が高いことがある。上端をそろえて置き、図は中央に寄せる。
            // 既定の中央ぞろえだと全体が上へずれて、右上の計器が切れていた（2026-11-11 開発者の指摘）
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(gestures(size))
            .onTapGesture(count: 2) { location in toggleZoom(at: location, size: size) }
            .onAppear { autoZoomIfNeeded(size: size) }
            .onChange(of: model.user) { _, _ in autoZoomIfNeeded(size: size) }
            .onChange(of: model.frame?.id) { _, _ in resetZoom(); autoZoomIfNeeded(size: size) }
        }
    }

    // MARK: 拡大と移動

    private func gestures(_ size: CGSize) -> some Gesture {
        let magnify = MagnifyGesture()
            .onChanged { value in
                let next = min(5, max(1, baseScale * value.magnification))
                // 拡大しても、見ている中心がずれないように移動も同じ割合で伸ばす
                let k = next / max(0.01, baseScale)
                scale = next
                pan = ChartProjector(size: size, scale: next, pan: .zero).clamp(CGSize(width: basePan.width * k, height: basePan.height * k))
            }
            .onEnded { _ in baseScale = scale; basePan = pan }
        let drag = DragGesture(minimumDistance: 6)
            .onChanged { value in
                pan = ChartProjector(size: size, scale: scale, pan: .zero)
                    .clamp(CGSize(width: basePan.width + value.translation.width, height: basePan.height + value.translation.height))
            }
            .onEnded { _ in basePan = pan }
        return drag.simultaneously(with: magnify)
    }

    private func resetZoom() {
        scale = 1; baseScale = 1; pan = .zero; basePan = .zero
    }

    /// その点（拡大前の領域の座標）が中央に来るように拡大する
    private func zoom(to target: CGFloat, centering point: CGPoint, size: CGSize) {
        let wanted = CGSize(width: -(point.x - size.width / 2) * target, height: -(point.y - size.height / 2) * target)
        let clamped = ChartProjector(size: size, scale: target, pan: .zero).clamp(wanted)
        withAnimation(.easeInOut(duration: 0.28)) { scale = target; pan = clamped }
        baseScale = target; basePan = clamped
    }

    /// ダブルタップ：拡大していれば全体へ、全体ならその場所へ 2.5 倍
    private func toggleZoom(at location: CGPoint, size: CGSize) {
        if scale > 1.05 {
            withAnimation(.easeInOut(duration: 0.28)) { scale = 1; pan = .zero }
            baseScale = 1; basePan = .zero
        } else {
            // 画面の位置 → 拡大前の領域の座標
            let before = CGPoint(x: (location.x - size.width / 2 - pan.width) / scale + size.width / 2, y: (location.y - size.height / 2 - pan.height) / scale + size.height / 2)
            zoom(to: 2.5, centering: before, size: size)
        }
    }

    /// 現在地（無ければ 1 番の見立て）が中央に来るように寄せる
    private func centerOnUser(size: CGSize) {
        guard let frame = model.frame else { return }
        let plain = ChartProjector(size: size, scale: 1, pan: .zero)
        if let user = model.user ?? model.userApprox, frame.contains(user) {
            let p = frame.point(for: user)
            zoom(to: max(2.2, scale), centering: plain.point(x: p.x, y: p.y), size: size)
        } else if let top = model.zones.first {
            zoom(to: max(2.2, scale), centering: plain.point(x: top.x, y: top.y), size: size)
        }
    }

    /// 精度の良い現在地が取れたら、その海図で 1 回だけ現在地へ寄せる（全体だと港が小さくて、立ち位置と見立てが重なって見える）
    private func autoZoomIfNeeded(size: CGSize) {
        guard let frame = model.frame, autoZoomed != frame.id, scale <= 1.01, let user = model.user, frame.contains(user), size.width > 10 else { return }
        autoZoomed = frame.id
        centerOnUser(size: size)
    }

    private func zoomButtons(size: CGSize) -> some View {
        VStack(spacing: 8) {
            mapButton("location.fill", label: "現在地へ寄せる") { centerOnUser(size: size) }
            if scale > 1.05 {
                mapButton("arrow.up.left.and.arrow.down.right", label: "全体を見る") {
                    withAnimation(.easeInOut(duration: 0.28)) { scale = 1; pan = .zero }
                    baseScale = 1; basePan = .zero
                }
            }
        }
        .frame(width: 36, height: 80, alignment: .top)
    }

    private func mapButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(ChartStyle.font(13, .bold)).foregroundStyle(ChartStyle.white)
                .frame(width: 34, height: 34)
                .background(ChartStyle.panel.opacity(0.78), in: Circle())
                .overlay(Circle().strokeBorder(ChartStyle.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: 図

    @ViewBuilder
    private func baseImage(_ project: ChartProjector) -> some View {
        let width = project.size.width, height = project.imageHeight
        Group {
            if let image = model.image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: width, height: height).clipped()
                    // Apple の地図のときは、海図の色合いに寄せて暗くする
                    .overlay(model.isIllustrated ? Color.clear : ChartStyle.bg.opacity(0.35))
            } else {
                ChartStyle.panel.frame(width: width, height: height)
            }
        }
        .scaleEffect(project.scale)
        .offset(x: project.pan.width, y: (project.size.height - height) / 2 + project.pan.height)
        .allowsHitTesting(false)
    }

    private func point(_ c: Coordinate, _ frame: PortChart, _ project: ChartProjector) -> CGPoint {
        let p = frame.point(for: c)
        return project.point(x: p.x, y: p.y)
    }

    // MARK: 釣果

    private func pastDots(frame: PortChart, _ project: ChartProjector) -> some View {
        let points = model.past.prefix(300).map { point($0, frame, project) }
        return Canvas { context, _ in
            for p in points {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4)), with: .color(Color.white.opacity(0.42)))
            }
        }
        .allowsHitTesting(false)
    }

    private func todayPins(frame: PortChart, _ project: ChartProjector) -> some View {
        // 同じ場所で釣れた魚は、少しずつずらして並べる（重なって 1 つに見えないように）
        let fan = TrackCleaner.fanOut(model.today.map(\.coordinate), radiusM: 8)
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(model.today.enumerated()), id: \.element.id) { index, pin in
                let base = point(pin.coordinate, frame, project)
                let p = CGPoint(x: base.x + CGFloat(fan[index].index) * 13 - CGFloat(fan[index].count - 1) * 6.5, y: base.y - (fan[index].count > 1 ? 12 : 0))
                ZStack {
                    if pin.id == newestCatchID { ChartRipple(color: ChartStyle.white) }
                    Circle().fill(ChartStyle.white).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(ChartStyle.orange, lineWidth: 2))
                }
                .position(p)
                if let cm = pin.lengthCm {
                    Text("\(Int(cm.rounded()))").font(ChartStyle.font(10, .bold)).foregroundStyle(ChartStyle.white)
                        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                        .position(x: p.x, y: p.y - 12)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: 投げる場所の見立て

    private func zoneLayer(_ project: ChartProjector) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(model.zones) { zone in
                let p = project.point(x: zone.x, y: zone.y)
                ChartZoneMarker(main: zone.rank == 1).position(p)
                // 文字は順位ごとに置き場所を変える（近い見立ての文字が重ならないように）：① 上、② 下、③ 横
                let side: CGFloat = p.x > project.size.width * 0.6 ? -1 : 1
                let offset: CGSize = zone.rank == 1 ? CGSize(width: side * 46, height: -34) : (zone.rank == 2 ? CGSize(width: side * 30, height: 30) : CGSize(width: -side * 40, height: -4))
                zoneLabel(zone).position(x: p.x + offset.width, y: p.y + offset.height)
            }
        }
        .allowsHitTesting(false)
    }

    private func zoneLabel(_ zone: CastPredictor.Zone) -> some View {
        let marks = ["①", "②", "③", "④", "⑤"]
        let mark = zone.rank >= 1 && zone.rank <= marks.count ? marks[zone.rank - 1] : "\(zone.rank)"
        return VStack(alignment: .leading, spacing: 1) {
            Text("\(mark) \(zone.percent)%").font(ChartStyle.font(zone.rank == 1 ? 14 : 12, .bold)).foregroundStyle(ChartStyle.orange)
            if zone.rank == 1, let d = zone.distanceM, let b = zone.bearingDeg, d < 500 {
                Text("\(CastPredictor.compassName(b)) · \(Int(d.rounded())) m").font(ChartStyle.font(10.5, .medium)).foregroundStyle(ChartStyle.white)
            }
        }
        .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
        .fixedSize()
    }

    /// 自分の位置から 1 番の場所へ、投げる向きの点線
    @ViewBuilder
    private func castLine(frame: PortChart, _ project: ChartProjector) -> some View {
        if let user = model.user, frame.contains(user), let top = model.zones.first, (top.distanceM ?? 999) < 300 {
            let a = point(user, frame, project)
            let b = project.point(x: top.x, y: top.y)
            Path { path in
                path.move(to: a)
                path.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 30))
            }
            .stroke(ChartStyle.orange, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [2, 6]))
            .allowsHitTesting(false)
        }
    }

    /// 現在地。精度の良い位置は点（まわりに誤差の丸）。粗い位置は点を出さず、誤差の丸と「おおよそ」だけ
    @ViewBuilder
    private func userDot(frame: PortChart, _ project: ChartProjector) -> some View {
        let pointsPerMeter = project.size.width * project.scale / CGFloat(max(1, frame.widthM))
        if let user = model.user, frame.contains(user) {
            let p = point(user, frame, project)
            let halo = min(160, max(40, CGFloat(model.userAccuracyM) * pointsPerMeter * 2))
            ZStack {
                Circle().fill(RadialGradient(colors: [Color.white.opacity(0.5), Color.white.opacity(0)], center: .center, startRadius: 0, endRadius: halo / 2))
                    .frame(width: halo, height: halo)
                Circle().fill(ChartStyle.white).frame(width: 12, height: 12).overlay(Circle().stroke(ChartStyle.bg, lineWidth: 2.5))
            }
            .position(p)
            .allowsHitTesting(false)
            Text("現在地").font(ChartStyle.font(10, .semibold)).foregroundStyle(ChartStyle.white)
                .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                .position(x: p.x, y: p.y + 20)
                .allowsHitTesting(false)
        } else if let approx = model.userApprox, frame.contains(approx) {
            let p = point(approx, frame, project)
            let d = min(260, max(50, CGFloat(model.userAccuracyM) * pointsPerMeter * 2))
            Circle().fill(Color.white.opacity(0.07)).frame(width: d, height: d)
                .overlay(Circle().stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                .position(p)
                .allowsHitTesting(false)
            Text("現在地（おおよそ ±\(Int(model.userAccuracyM.rounded())) m）").font(ChartStyle.font(10, .semibold)).foregroundStyle(ChartStyle.white.opacity(0.85))
                .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                .position(x: p.x, y: p.y + d / 2 + 10)
                .allowsHitTesting(false)
        }
    }

    // MARK: 風の計器

    private var windDial: some View {
        let from = model.conditions.windFromDeg
        return HStack(spacing: 6) {
            VStack(alignment: .trailing, spacing: 1) {
                Text("風").font(ChartStyle.font(10, .medium)).foregroundStyle(ChartStyle.gray1)
                Text(model.conditions.wind).font(ChartStyle.font(12, .bold)).foregroundStyle(ChartStyle.white)
            }
            .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
            ZStack {
                if let dial = ChartAssets.ui("dial") {
                    Image(uiImage: dial).resizable().scaledToFit()
                } else {
                    Circle().fill(ChartStyle.panel)
                }
                if let from {
                    // 風が吹いていく向きの矢印（図形は東向き＝方位 90°）
                    ChartArrow().fill(ChartStyle.white).frame(width: 30, height: 12).rotationEffect(.degrees(from + 180 - 90))
                }
            }
            .frame(width: 56, height: 56)
        }
        .fixedSize()
        .offset(x: -34)
        .allowsHitTesting(false)
    }
}

/// 図の割合（0〜1）を、拡大・移動を入れた画面の位置に直す。図は横幅いっぱい・縦 3:4 で、領域の中央に置く
struct ChartProjector {
    let size: CGSize
    let scale: CGFloat
    let pan: CGSize

    var imageHeight: CGFloat { size.width * 4 / 3 }

    func point(x: Double, y: Double) -> CGPoint {
        let px = CGFloat(x) * size.width, py = CGFloat(y) * imageHeight + (size.height - imageHeight) / 2
        return CGPoint(x: (px - size.width / 2) * scale + size.width / 2 + pan.width, y: (py - size.height / 2) * scale + size.height / 2 + pan.height)
    }

    /// 移動の限界：図の端が領域の内側へ入らないところまで
    func clamp(_ pan: CGSize) -> CGSize {
        let maxX = max(0, (size.width * scale - size.width) / 2), maxY = max(0, (imageHeight * scale - size.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, pan.width)), height: min(maxY, max(-maxY, pan.height)))
    }
}

/// 右向きの矢印
struct ChartArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let mid = rect.midY, t = rect.height * 0.18
        p.addRoundedRect(in: CGRect(x: rect.minX, y: mid - t / 2, width: rect.width * 0.72, height: t), cornerSize: CGSize(width: t / 2, height: t / 2))
        p.move(to: CGPoint(x: rect.maxX, y: mid))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.34, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.34, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// 投げる場所の印：オレンジのにじみ、輪、ゆっくり広がる波紋
struct ChartZoneMarker: View {
    let main: Bool
    @State private var pulse = false

    var body: some View {
        let r: CGFloat = main ? 30 : 20
        ZStack {
            Circle().fill(RadialGradient(colors: [ChartStyle.orange.opacity(0.55), ChartStyle.orange.opacity(0.18), ChartStyle.orange.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: r * 1.9))
                .frame(width: r * 3.8, height: r * 3.8)
            Circle().stroke(ChartStyle.orange.opacity(0.9), lineWidth: 1.6).frame(width: r * 1.24, height: r * 1.24)
            Circle().stroke(ChartStyle.orange.opacity(pulse ? 0 : 0.7), lineWidth: 1.2).frame(width: r * 1.24, height: r * 1.24)
                .scaleEffect(pulse ? 2.4 : 1)
            Circle().fill(ChartStyle.orange).frame(width: 6, height: 6)
        }
        .onAppear { withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

/// いま記録した釣果の波紋
struct ChartRipple: View {
    let color: Color
    @State private var on = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(on ? 0 : 0.9), lineWidth: 1.4).frame(width: 20, height: 20).scaleEffect(on ? 3.6 : 1)
            Circle().stroke(color.opacity(on ? 0 : 0.6), lineWidth: 1.2).frame(width: 20, height: 20).scaleEffect(on ? 2.4 : 1)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { on = true } }
    }
}

/// 風の流れ：風下へ流れる細い線。速さは風速に合わせる。位置は時刻と番号から決まる（状態を持たない）
struct ChartWindField: View {
    let fromDeg: Double?
    let speed: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            Canvas { context, size in
                guard let from = fromDeg, let speed = speed, speed >= 0.5 else { return }
                let t = timeline.date.timeIntervalSinceReferenceDate
                let to = (from + 180) * .pi / 180
                let dx = CGFloat(sin(to)), dy = CGFloat(-cos(to))
                let velocity = 10 + min(speed, 12) * 7
                let span = max(size.width, size.height) + 80
                for i in 0..<30 {
                    let a = ChartWindField.noise(i, 1), b = ChartWindField.noise(i, 2), phase = ChartWindField.noise(i, 3)
                    let u = CGFloat((t * velocity + Double(phase) * Double(span)).truncatingRemainder(dividingBy: Double(span)))
                    let along = u - span / 2
                    let across = (a - 0.5) * span
                    let head = CGPoint(x: size.width / 2 + dx * along - dy * across, y: size.height / 2 + dy * along + dx * across)
                    let length = 14 + b * 18
                    let tail = CGPoint(x: head.x - dx * length, y: head.y - dy * length)
                    let fade = Double(min(1, u / 60) * min(1, (span - u) / 60))
                    var path = Path()
                    path.move(to: tail)
                    path.addLine(to: head)
                    context.stroke(path, with: .linearGradient(Gradient(colors: [Color.white.opacity(0), Color.white.opacity(0.36 * fade)]), startPoint: tail, endPoint: head),
                                   style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    context.fill(Path(ellipseIn: CGRect(x: head.x - 1.3, y: head.y - 1.3, width: 2.6, height: 2.6)), with: .color(Color.white.opacity(0.5 * fade)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 番号から決まる 0〜1 の値
    static func noise(_ i: Int, _ k: Int) -> CGFloat {
        let x = sin(Double(i * 127 + k * 311) * 12.9898) * 43758.5453
        return CGFloat(x - floor(x))
    }
}

/// 額のような枠：外の線と、四隅の角飾り（テーマの `chart_corner`。左上向きの絵を鏡映しで四隅へ）。
/// 地図とメニューの札に使う
struct ChartFrame: View {
    var radius: CGFloat = 8
    var cornerSize: CGFloat = 46

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(ChartStyle.border, lineWidth: 1)
            if let corner = ChartAssets.ui("corner") {
                GeometryReader { geo in
                    let s = cornerSize, inset: CGFloat = 5
                    ForEach(0..<4, id: \.self) { i in
                        Image(uiImage: corner).resizable().scaledToFit().frame(width: s, height: s)
                            .scaleEffect(x: i % 2 == 0 ? 1 : -1, y: i < 2 ? 1 : -1)
                            .position(x: i % 2 == 0 ? s / 2 + inset : geo.size.width - s / 2 - inset,
                                      y: i < 2 ? s / 2 + inset : geo.size.height - s / 2 - inset)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
