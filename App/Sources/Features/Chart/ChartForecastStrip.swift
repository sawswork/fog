import SwiftUI
import Core

/// これから 9 時間の釣れ率の線（F-63）。いちばん良い時間帯をオレンジにする。なぞるとその時刻を返し、離すと nil（今）に戻す
struct ChartForecastStrip: View {
    let points: [ScorePoint]
    let now: Date
    let horizon: TimeInterval
    let extremes: [TideExtreme]
    @Binding var scrub: Date?

    private static let labelHeight: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = max(10, geo.size.height - Self.labelHeight)
            let best = bestRange()
            ZStack(alignment: .topLeading) {
                areaPath(points, w: w, h: h).fill(LinearGradient(colors: [Color.white.opacity(0.20), Color.white.opacity(0)], startPoint: .top, endPoint: .bottom))
                if let best {
                    areaPath(Array(points[best]), w: w, h: h)
                        .fill(LinearGradient(colors: [ChartStyle.orange.opacity(0.55), ChartStyle.orange.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                linePath(points, w: w, h: h).stroke(ChartStyle.white.opacity(0.75), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                if let best {
                    linePath(Array(points[best]), w: w, h: h).stroke(ChartStyle.orange, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                }
                Rectangle().fill(Color.white.opacity(0.10)).frame(width: w, height: 1).offset(y: h)
                labels(w: w, h: h)
                Circle().fill(ChartStyle.white).frame(width: 9, height: 9).overlay(Circle().stroke(ChartStyle.bg, lineWidth: 2))
                    .position(x: x(now, w), y: y(scoreAt(now), h))
                if let scrub {
                    let sx = x(scrub, w)
                    Rectangle().fill(ChartStyle.orange.opacity(0.7)).frame(width: 1.2, height: h).position(x: sx, y: h / 2)
                    Circle().fill(ChartStyle.orange).frame(width: 14, height: 14).overlay(Circle().stroke(ChartStyle.white, lineWidth: 2.5))
                        .position(x: sx, y: y(scoreAt(scrub), h))
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

    private func x(_ date: Date, _ w: CGFloat) -> CGFloat {
        CGFloat(max(0, min(1, date.timeIntervalSince(now) / horizon))) * w
    }

    private func y(_ score: Int, _ h: CGFloat) -> CGFloat {
        h - CGFloat(max(0, min(1, (Double(score) - 25) / 70))) * (h - 6)
    }

    private func scoreAt(_ date: Date) -> Int {
        points.min { abs($0.at.timeIntervalSince(date)) < abs($1.at.timeIntervalSince(date)) }?.score ?? 0
    }

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

    /// いちばん高い点のまわりで、最高点から 6 点以内が続く範囲
    private func bestRange() -> ClosedRange<Int>? {
        guard points.count >= 3, let top = points.indices.max(by: { points[$0].score < points[$1].score }) else { return nil }
        let floor = points[top].score - 6
        var lo = top, hi = top
        while lo > 0, points[lo - 1].score >= floor { lo -= 1 }
        while hi < points.count - 1, points[hi + 1].score >= floor { hi += 1 }
        return hi > lo ? lo...hi : nil
    }

    /// 下の目盛り：左端に今の時刻、2 時間ごとの時、満潮・干潮
    private func labels(w: CGFloat, h: CGFloat) -> some View {
        let ly = h + Self.labelHeight / 2 + 1
        let tides = extremes.filter { $0.at > now.addingTimeInterval(1800) && $0.at < now.addingTimeInterval(horizon - 900) }
        let tideXs = tides.map { x($0.at, w) }
        // 時の境目は日本時間でも UTC でも同じ（時差が整数時間）
        let firstHour = (now.timeIntervalSince1970 / 3600).rounded(.up) * 3600
        var hours: [(x: CGFloat, text: String)] = []
        var t = firstHour
        while t < now.timeIntervalSince1970 + horizon - 600 {
            let hx = x(Date(timeIntervalSince1970: t), w)
            let hour = (Int(t / 3600) + 9) % 24
            if hour % 2 == 1, hx > 44, tideXs.allSatisfy({ abs($0 - hx) > 22 }) { hours.append((hx, "\(hour)")) }
            t += 3600
        }
        return ZStack(alignment: .topLeading) {
            Color.clear
            Text(JPFormat.hm(now)).font(.system(size: 10, weight: .semibold)).foregroundStyle(ChartStyle.white).fixedSize()
                .position(x: 16, y: ly)
            ForEach(Array(hours.enumerated()), id: \.offset) { _, item in
                Text(item.text).font(.system(size: 10, weight: .medium)).foregroundStyle(ChartStyle.gray2).fixedSize().position(x: item.x, y: ly)
            }
            ForEach(Array(tides.enumerated()), id: \.offset) { _, tide in
                let tx = x(tide.at, w)
                Rectangle().fill(ChartStyle.cyan).frame(width: 1.5, height: 6).position(x: tx, y: h)
                Text(tide.kind == .high ? "満潮" : "干潮").font(.system(size: 9.5, weight: .medium)).foregroundStyle(ChartStyle.cyan).fixedSize()
                    .position(x: tx, y: ly)
            }
        }
        .allowsHitTesting(false)
    }
}
