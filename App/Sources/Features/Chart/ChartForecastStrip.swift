import SwiftUI
import Core

/// これから 9 時間のグラフ（F-63）。1 つの枠に、釣れ率の線（白。いちばん良い時間帯はオレンジ）と潮位の線（水色）を重ねる。
/// 満潮・干潮は、潮位の線の山と谷に時刻だけを出す。マズメの時間帯は背景に色を付ける。下の時刻は 3 時間おき。なぞるとその時刻を返し、離すと nil（今）に戻す
struct ChartForecastStrip: View {
    let points: [ScorePoint]
    let tide: [ChartViewModel.TideSample]
    let tideRange: ClosedRange<Double>
    let now: Date
    let horizon: TimeInterval
    let extremes: [TideExtreme]
    /// マズメの帯（背景に色を付ける）
    var twilight: [ChartViewModel.TwilightBand] = []
    @Binding var scrub: Date?

    private static let labelHeight: CGFloat = 16
    /// 枠の上に空けておく高さ（満潮の時刻の文字が入る）
    private static let tideHeadroom: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = max(20, geo.size.height - Self.labelHeight)
            let hasTide = tide.count >= 2
            let best = bestRange()
            ZStack(alignment: .topLeading) {
                twilightBands(w: w, plot: h)
                hourGrid(w: w, plot: h)
                areaPath(points, w: w, h: h).fill(LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0)], startPoint: .top, endPoint: .bottom))
                if let best {
                    areaPath(Array(points[best]), w: w, h: h)
                        .fill(LinearGradient(colors: [ChartStyle.orange.opacity(0.55), ChartStyle.orange.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                linePath(points, w: w, h: h).stroke(ChartStyle.white.opacity(0.75), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                if let best {
                    linePath(Array(points[best]), w: w, h: h).stroke(ChartStyle.orange, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                }
                if hasTide {
                    // 潮位は同じ枠に水色の線で重ねる（面は塗らない。釣れ率の面と混ざらないように）
                    tidePath(w: w, top: 0, bottom: h)
                        .stroke(ChartStyle.cyan, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    tideTimes(w: w, top: 0, bottom: h)
                    Circle().fill(ChartStyle.cyan).frame(width: 7, height: 7).overlay(Circle().stroke(ChartStyle.bg, lineWidth: 1.5))
                        .position(x: x(now, w), y: tideY(tideAt(now), top: 0, bottom: h))
                }
                Rectangle().fill(Color.white.opacity(0.10)).frame(width: w, height: 1).offset(y: h)
                timeLabels(w: w, plot: h)
                Circle().fill(ChartStyle.white).frame(width: 9, height: 9).overlay(Circle().stroke(ChartStyle.bg, lineWidth: 2))
                    .position(x: x(now, w), y: y(scoreAt(now), h))
                if let scrub {
                    let sx = x(scrub, w)
                    Rectangle().fill(ChartStyle.orange.opacity(0.7)).frame(width: 1.2, height: h).position(x: sx, y: h / 2)
                    if hasTide {
                        Circle().fill(ChartStyle.cyan).frame(width: 10, height: 10).overlay(Circle().stroke(ChartStyle.white, lineWidth: 2))
                            .position(x: sx, y: tideY(tideAt(scrub), top: 0, bottom: h))
                    }
                    Circle().fill(ChartStyle.orange).frame(width: 14, height: 14).overlay(Circle().stroke(ChartStyle.white, lineWidth: 2.5))
                        .position(x: sx, y: y(scoreAt(scrub), h))
                    // なぞっている時刻と、その時刻の釣れ率（線のいちばん上。端では枠の内側へ寄せる）
                    HStack(spacing: 5) {
                        Text(JPFormat.hm(scrub)).font(ChartStyle.font(11, .bold)).monospacedDigit()
                        Text("\(scoreAt(scrub))").font(ChartStyle.number(12, .bold)).monospacedDigit()
                    }
                    .foregroundStyle(ChartStyle.onAccent)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(ChartStyle.orange, in: Capsule())
                    .fixedSize()
                    .position(x: min(max(sx, 36), w - 36), y: 10)
                }
            }
            .frame(width: w, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let f = Double(max(0, min(1, value.location.x / max(1, w))))
                        scrub = now.addingTimeInterval(f * horizon)
                    }
                    .onEnded { _ in scrub = nil }
            )
        }
    }

    // MARK: 位置

    private func x(_ date: Date, _ w: CGFloat) -> CGFloat {
        CGFloat(max(0, min(1, date.timeIntervalSince(now) / horizon))) * w
    }

    private func y(_ score: Int, _ h: CGFloat) -> CGFloat {
        h - CGFloat(max(0, min(1, (Double(score) - 25) / 70))) * (h - 6)
    }

    private func scoreAt(_ date: Date) -> Int {
        points.min { abs($0.at.timeIntervalSince(date)) < abs($1.at.timeIntervalSince(date)) }?.score ?? 0
    }

    private func tideAt(_ date: Date) -> Double {
        tide.min { abs($0.at.timeIntervalSince(date)) < abs($1.at.timeIntervalSince(date)) }?.cm ?? tideRange.lowerBound
    }

    /// 潮位 → 縦の位置。上は時刻の文字のために空け、いちばん低い所でも下の線から 4 pt 上
    private func tideY(_ cm: Double, top: CGFloat, bottom: CGFloat) -> CGFloat {
        let span = max(1, tideRange.upperBound - tideRange.lowerBound)
        let f = CGFloat(max(0, min(1, (cm - tideRange.lowerBound) / span)))
        let usable = max(4, bottom - top - Self.tideHeadroom - 4)
        return bottom - 4 - f * usable
    }

    // MARK: 線

    private func linePath(_ list: [ScorePoint], w: CGFloat, h: CGFloat) -> Path {
        var path = Path()
        for (i, p) in list.enumerated() {
            let q = CGPoint(x: x(p.at, w), y: y(p.score, h))
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        return path
    }

    private func areaPath(_ list: [ScorePoint], w: CGFloat, h: CGFloat) -> Path {
        var path = linePath(list, w: w, h: h)
        guard let first = list.first, let last = list.last else { return path }
        path.addLine(to: CGPoint(x: x(last.at, w), y: h))
        path.addLine(to: CGPoint(x: x(first.at, w), y: h))
        path.closeSubpath()
        return path
    }

    private func tidePath(w: CGFloat, top: CGFloat, bottom: CGFloat) -> Path {
        var path = Path()
        for (i, sample) in tide.enumerated() {
            let q = CGPoint(x: x(sample.at, w), y: tideY(sample.cm, top: top, bottom: bottom))
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        return path
    }

    /// いちばん高い点のまわりで、最高点から 6 点以内が続く範囲
    private func bestRange() -> ClosedRange<Int>? {
        guard points.count >= 3, let top = points.indices.max(by: { points[$0].score < points[$1].score }) else { return nil }
        let floor = points[top].score - 6
        var lo = top, hi = top
        while lo > 0, points[lo - 1].score >= floor { lo -= 1 }
        while hi < points.count - 1, points[hi + 1].score >= floor { hi += 1 }
        return hi > lo ? lo...hi : nil
    }

    // MARK: 目盛り

    /// 3 時間おきの時刻（日本時間の 0・3・6…時）。時の境目は日本時間でも UTC でも同じ（時差が整数時間）
    private func hourMarks(w: CGFloat) -> [(x: CGFloat, hour: Int)] {
        var out: [(x: CGFloat, hour: Int)] = []
        var t = (now.timeIntervalSince1970 / 3600).rounded(.up) * 3600
        while t <= now.timeIntervalSince1970 + horizon {
            let hour = (Int(t / 3600) + 9) % 24
            if hour % 3 == 0 { out.append((x(Date(timeIntervalSince1970: t), w), hour)) }
            t += 3600
        }
        return out
    }

    /// マズメの時間帯：枠の背景に色（上が濃く、下へ薄く）と、上の端に細い線。文字は出さない
    private func twilightBands(w: CGFloat, plot: CGFloat) -> some View {
        let end = now.addingTimeInterval(horizon)
        let spans: [(x: CGFloat, width: CGFloat)] = twilight.compactMap { band -> (x: CGFloat, width: CGFloat)? in
            let a = max(band.start, now), b = min(band.end, end)
            guard b > a else { return nil }
            let x0 = x(a, w), x1 = x(b, w)
            return x1 - x0 >= 1 ? (x0, x1 - x0) : nil
        }
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                Rectangle()
                    .fill(LinearGradient(colors: [ChartStyle.twilight.opacity(0.34), ChartStyle.twilight.opacity(0.10)], startPoint: .top, endPoint: .bottom))
                    .frame(width: span.width, height: plot)
                    .overlay(alignment: .top) { Rectangle().fill(ChartStyle.twilight.opacity(0.9)).frame(height: 1.5) }
                    .offset(x: span.x)
            }
        }
        .frame(width: w, height: plot, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// 3 時間おきの薄い縦線
    private func hourGrid(w: CGFloat, plot: CGFloat) -> some View {
        let xs = hourMarks(w: w).map { $0.x }
        return Canvas { context, _ in
            for hx in xs {
                var path = Path()
                path.move(to: CGPoint(x: hx, y: 0))
                path.addLine(to: CGPoint(x: hx, y: plot))
                context.stroke(path, with: .color(Color.white.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .allowsHitTesting(false)
    }

    /// 下の時刻：左端に今、あとは 3 時間おき
    private func timeLabels(w: CGFloat, plot: CGFloat) -> some View {
        let ly = plot + Self.labelHeight / 2 + 1
        // 今の時刻の文字に重なるものと、右端で切れるものは出さない
        let marks = hourMarks(w: w).filter { $0.x > 46 && $0.x < w - 10 }
        return ZStack(alignment: .topLeading) {
            Color.clear
            Text(JPFormat.hm(now)).font(ChartStyle.font(10, .semibold)).foregroundStyle(ChartStyle.white).fixedSize()
                .position(x: 16, y: ly)
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                Text("\(mark.hour)時").font(ChartStyle.font(10, .medium)).foregroundStyle(ChartStyle.gray1).fixedSize().position(x: mark.x, y: ly)
            }
        }
        .allowsHitTesting(false)
    }

    /// 満潮・干潮：潮位の線の山と谷に点と時刻だけ（「満潮」「干潮」の文字と高さは出さない。2026-11-11 開発者の指示）
    private func tideTimes(w: CGFloat, top: CGFloat, bottom: CGFloat) -> some View {
        let shown = extremes.filter { $0.at > now.addingTimeInterval(1500) && $0.at < now.addingTimeInterval(horizon - 600) }
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(shown.enumerated()), id: \.offset) { _, extreme in
                let tx = x(extreme.at, w)
                let ty = tideY(extreme.levelCm, top: top, bottom: bottom)
                Circle().fill(ChartStyle.cyan).frame(width: 5, height: 5).position(x: tx, y: ty)
                Text(JPFormat.hm(extreme.at))
                    .font(ChartStyle.font(10, .semibold)).monospacedDigit().foregroundStyle(ChartStyle.cyan).fixedSize()
                    .shadow(color: ChartStyle.bg.opacity(0.95), radius: 2)
                    .position(x: min(max(tx, 18), w - 18), y: max(top + 5, ty - 9))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - マーク

/// 潮の動きのマーク：上げは上向きの矢印、下げは下向きの矢印、潮止まりは波 2 本。どれも下に水面の波線
struct ChartTideMark: View {
    let state: ChartViewModel.TideState?

    var body: some View {
        let color = state == .slack || state == nil ? ChartStyle.gray1 : ChartStyle.cyan
        Canvas { context, size in
            let w = size.width, h = size.height
            let stroke = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
            func wave(_ wy: CGFloat) -> Path {
                var p = Path()
                let amp = h * 0.11
                p.move(to: CGPoint(x: 0.5, y: wy))
                p.addCurve(to: CGPoint(x: w / 2, y: wy), control1: CGPoint(x: w * 0.18, y: wy - amp * 2), control2: CGPoint(x: w * 0.32, y: wy + amp * 2))
                p.addCurve(to: CGPoint(x: w - 0.5, y: wy), control1: CGPoint(x: w * 0.68, y: wy - amp * 2), control2: CGPoint(x: w * 0.82, y: wy + amp * 2))
                return p
            }
            context.stroke(wave(h * 0.86), with: .color(color), style: stroke)
            guard let state else { return }
            let mid = w / 2, head = w * 0.30
            var arrow = Path()
            switch state {
            case .rising:
                arrow.move(to: CGPoint(x: mid, y: h * 0.62)); arrow.addLine(to: CGPoint(x: mid, y: h * 0.07))
                arrow.move(to: CGPoint(x: mid - head, y: h * 0.07 + head)); arrow.addLine(to: CGPoint(x: mid, y: h * 0.07)); arrow.addLine(to: CGPoint(x: mid + head, y: h * 0.07 + head))
            case .falling:
                arrow.move(to: CGPoint(x: mid, y: h * 0.05)); arrow.addLine(to: CGPoint(x: mid, y: h * 0.60))
                arrow.move(to: CGPoint(x: mid - head, y: h * 0.60 - head)); arrow.addLine(to: CGPoint(x: mid, y: h * 0.60)); arrow.addLine(to: CGPoint(x: mid + head, y: h * 0.60 - head))
            case .slack:
                arrow = wave(h * 0.42)
            }
            context.stroke(arrow, with: .color(color), style: stroke)
        }
        .frame(width: 13, height: 16)
        .accessibilityHidden(true)
    }
}

/// 風向のマーク。上が北。矢印は風が吹いていく向き（南南西の風なら、南南西から北北東へ向く）。上の小さな印が北
struct ChartWindMark: View {
    /// 風が吹いてくる方角（度）
    let fromDeg: Double?

    var body: some View {
        ZStack {
            Circle().stroke(ChartStyle.gray2.opacity(0.9), lineWidth: 1)
            // 北の印
            Capsule().fill(ChartStyle.gray1).frame(width: 1.6, height: 3.6).offset(y: -9)
            if let fromDeg {
                ChartNeedle().fill(ChartStyle.white).frame(width: 8, height: 12).rotationEffect(.degrees(fromDeg + 180))
            } else {
                Circle().fill(ChartStyle.gray2).frame(width: 3, height: 3)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

/// 上向きの矢じり（方位磁針の針の形）
struct ChartNeedle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.70))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
