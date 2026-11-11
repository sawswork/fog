import SwiftUI
import Core

/// 港の図と、その上の情報（F-63）。奥から順に：図 → 風の流れ → 過去の釣果 → 投げる場所の見立て → 自分の位置 → 今日の釣果 → 風の計器。
/// 図は横幅いっぱい（縦 3:4）に敷き、領域からはみ出す上下は切る。位置は図の割合（0〜1）から決める
struct ChartMapView: View {
    let model: ChartViewModel
    /// いま記録した釣果（波紋を出す）
    var newestCatchID: UUID?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let imageHeight = size.width * 4 / 3
            let offsetY = (size.height - imageHeight) / 2
            ZStack(alignment: .topLeading) {
                ChartStyle.bg
                baseImage(width: size.width, height: imageHeight).offset(y: offsetY)
                ChartWindField(fromDeg: model.conditions.windFromDeg, speed: model.conditions.windSpeedMS)
                if let frame = model.frame {
                    pastDots(frame: frame, width: size.width, height: imageHeight, offsetY: offsetY)
                    castLine(frame: frame, width: size.width, height: imageHeight, offsetY: offsetY)
                    zoneLayer(frame: frame, width: size.width, height: imageHeight, offsetY: offsetY)
                    userDot(frame: frame, width: size.width, height: imageHeight, offsetY: offsetY)
                    todayPins(frame: frame, width: size.width, height: imageHeight, offsetY: offsetY)
                }
                VStack(spacing: 0) {
                    LinearGradient(colors: [ChartStyle.bg, ChartStyle.bg.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 44)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [ChartStyle.bg.opacity(0), ChartStyle.bg], startPoint: .top, endPoint: .bottom).frame(height: 120)
                }
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
                // 風向の計器は上のぼかしより手前に置く（丸が全部見える位置）
                windDial.position(x: size.width - 44, y: 46)
            }
            // 図（縦 3:4）は領域より背が高いことがある。上端をそろえて置き、図は offsetY で中央に寄せる。
            // 既定の中央ぞろえだと全体が上へずれて、右上の計器が切れていた（2026-11-11 開発者の指摘）
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
        }
    }

    // MARK: 図

    @ViewBuilder
    private func baseImage(width: CGFloat, height: CGFloat) -> some View {
        if let image = model.image {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: width, height: height).clipped()
                // Apple の地図のときは、海図の色合いに寄せて暗くする
                .overlay(model.isIllustrated ? Color.clear : ChartStyle.bg.opacity(0.35))
        } else {
            ChartStyle.panel.frame(width: width, height: height)
        }
    }

    private func point(_ c: Coordinate, _ frame: PortChart, _ width: CGFloat, _ height: CGFloat, _ offsetY: CGFloat) -> CGPoint {
        let p = frame.point(for: c)
        return CGPoint(x: CGFloat(p.x) * width, y: CGFloat(p.y) * height + offsetY)
    }

    // MARK: 釣果

    private func pastDots(frame: PortChart, width: CGFloat, height: CGFloat, offsetY: CGFloat) -> some View {
        let points = model.past.prefix(300).map { point($0, frame, width, height, offsetY) }
        return Canvas { context, _ in
            for p in points {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4)), with: .color(Color.white.opacity(0.42)))
            }
        }
        .allowsHitTesting(false)
    }

    private func todayPins(frame: PortChart, width: CGFloat, height: CGFloat, offsetY: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(model.today) { pin in
                let p = point(pin.coordinate, frame, width, height, offsetY)
                ZStack {
                    if pin.id == newestCatchID { ChartRipple(color: ChartStyle.white) }
                    Circle().fill(ChartStyle.white).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(ChartStyle.orange, lineWidth: 2))
                }
                .position(p)
                if let cm = pin.lengthCm {
                    Text("\(Int(cm.rounded()))").font(.system(size: 10, weight: .bold)).foregroundStyle(ChartStyle.white)
                        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                        .position(x: p.x + 14, y: p.y)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: 投げる場所の見立て

    private func zoneLayer(frame: PortChart, width: CGFloat, height: CGFloat, offsetY: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(model.zones) { zone in
                let p = CGPoint(x: CGFloat(zone.x) * width, y: CGFloat(zone.y) * height + offsetY)
                ChartZoneMarker(main: zone.rank == 1).position(p)
                zoneLabel(zone).position(x: p.x + (zone.x > 0.6 ? -50 : 50), y: p.y - (zone.rank == 1 ? 30 : 22))
            }
        }
        .allowsHitTesting(false)
    }

    private func zoneLabel(_ zone: CastPredictor.Zone) -> some View {
        let marks = ["①", "②", "③", "④", "⑤"]
        let mark = zone.rank >= 1 && zone.rank <= marks.count ? marks[zone.rank - 1] : "\(zone.rank)"
        return VStack(alignment: .leading, spacing: 1) {
            Text("\(mark) \(zone.percent)%").font(.system(size: zone.rank == 1 ? 14 : 12, weight: .bold)).foregroundStyle(ChartStyle.orange)
            if zone.rank == 1, let d = zone.distanceM, let b = zone.bearingDeg, d < 500 {
                Text("\(CastPredictor.compassName(b)) · \(Int(d.rounded())) m").font(.system(size: 10.5, weight: .medium)).foregroundStyle(ChartStyle.white)
            }
        }
        .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
        .fixedSize()
    }

    /// 自分の位置から 1 番の場所へ、投げる向きの点線
    @ViewBuilder
    private func castLine(frame: PortChart, width: CGFloat, height: CGFloat, offsetY: CGFloat) -> some View {
        if let user = model.user, frame.contains(user), let top = model.zones.first, (top.distanceM ?? 999) < 300 {
            let a = point(user, frame, width, height, offsetY)
            let b = CGPoint(x: CGFloat(top.x) * width, y: CGFloat(top.y) * height + offsetY)
            Path { path in
                path.move(to: a)
                path.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 30))
            }
            .stroke(ChartStyle.orange, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [2, 6]))
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func userDot(frame: PortChart, width: CGFloat, height: CGFloat, offsetY: CGFloat) -> some View {
        if let user = model.user, frame.contains(user) {
            let p = point(user, frame, width, height, offsetY)
            ZStack {
                Circle().fill(RadialGradient(colors: [Color.white.opacity(0.5), Color.white.opacity(0)], center: .center, startRadius: 0, endRadius: 20))
                    .frame(width: 40, height: 40)
                Circle().fill(ChartStyle.white).frame(width: 12, height: 12).overlay(Circle().stroke(ChartStyle.bg, lineWidth: 2.5))
            }
            .position(p)
            .allowsHitTesting(false)
            Text("現在地").font(.system(size: 10, weight: .semibold)).foregroundStyle(ChartStyle.white)
                .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                .position(x: p.x, y: p.y + 20)
                .allowsHitTesting(false)
        }
    }

    // MARK: 風の計器

    private var windDial: some View {
        let from = model.conditions.windFromDeg
        return HStack(spacing: 6) {
            VStack(alignment: .trailing, spacing: 1) {
                Text("風").font(.system(size: 10, weight: .medium)).foregroundStyle(ChartStyle.gray1)
                Text(model.conditions.wind).font(.system(size: 12, weight: .bold)).foregroundStyle(ChartStyle.white)
            }
            .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
            ZStack {
                if let dial = ChartAssets.ui("dial.png") {
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
