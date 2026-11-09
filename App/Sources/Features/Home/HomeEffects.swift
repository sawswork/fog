import SwiftUI
import Core

// MARK: 画像の層の動き（theme.json の layers[].motion）

/// 画像をゆっくり動かす。Core Animation の繰り返しアニメーションだけで動かすので、毎フレームの再描画は無い（固まりの原因にならない）。
/// 「視差を減らす」が有効なら動かさない
struct HomeLayerMotion: ViewModifier {
    let kind: String
    let speed: Double
    let amount: Double
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let s = max(0.1, speed), a = amount
        Group {
            switch kind {
            case "float":
                // 上下にふわり＋かすかな呼吸（キャラクター向け）
                content.offset(y: on ? -7 * a : 5 * a).scaleEffect(on ? 1 + 0.012 * a : 1, anchor: .bottom)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 3.4 / s).repeatForever(autoreverses: true), value: on)
            case "breathe":
                content.scaleEffect(on ? 1 + 0.025 * a : 1, anchor: .bottom)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 3.0 / s).repeatForever(autoreverses: true), value: on)
            case "sway":
                content.rotationEffect(.degrees(on ? 1.6 * a : -1.6 * a), anchor: .bottom)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 4.0 / s).repeatForever(autoreverses: true), value: on)
            case "spin":
                // 1 周 60 秒（speed で変わる）。魔法陣向け
                content.rotationEffect(.degrees(on ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 60 / s).repeatForever(autoreverses: false), value: on)
            case "drift":
                // 背景がゆっくり寄って戻る（Ken Burns）。はみ出しは画面の外なので見えない
                content.scaleEffect(on ? 1 + 0.06 * a : 1.0).offset(x: on ? -4 * a : 4 * a, y: on ? 3 * a : -3 * a)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 26 / s).repeatForever(autoreverses: true), value: on)
            case "pulse":
                content.opacity(on ? 1 : max(0, 1 - 0.35 * a))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 2.6 / s).repeatForever(autoreverses: true), value: on)
            default:
                content
            }
        }
        .onAppear { on = true }
    }
}

// MARK: 効果の層（theme.json の layers[].effect）

/// 光の粒・舞う葉・きらめき・泡を Canvas で描く。30 fps、画面が前面でないときと「視差を減らす」では止める。
/// 粒の位置は番号から決まる擬似乱数なので、毎フレームの状態を持たない（計算は数十個の三角関数だけ）
struct HomeEffectField: View {
    let kind: String
    let count: Int?
    let color: Color
    let speed: Double
    let amount: Double
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var n: Int {
        if let count { return count }
        switch kind {
        case "leaves": return 10
        case "sparkles": return 16
        case "bubbles": return 18
        default: return 36
        }
    }

    var body: some View {
        let paused = scenePhase != .active || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { tl in
            Canvas(rendersAsynchronously: true) { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate * max(0.1, speed)
                switch kind {
                case "leaves": drawLeaves(ctx, size, t)
                case "sparkles": drawSparkles(ctx, size, t)
                case "bubbles": drawBubbles(ctx, size, t)
                default: drawFireflies(ctx, size, t)
                }
            }
        }
    }

    /// 番号 i と項目 k から 0〜1 の決まった値（同じ粒は毎フレーム同じ性質）
    private func r(_ i: Int, _ k: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: i &* 7_919 &+ k &* 104_729 &+ 1)
        x ^= x >> 12; x ^= x << 25; x ^= x >> 27
        x = x &* 2_685_821_657_736_338_717
        return Double(x >> 11) / Double(1 << 53)
    }

    private func drawFireflies(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        for i in 0..<n {
            let bx = r(i, 1) * size.width, by = r(i, 2) * size.height
            let ax = (10 + 30 * r(i, 3)) * amount, ay = (8 + 24 * r(i, 4)) * amount
            let w1 = 0.15 + 0.25 * r(i, 5), w2 = 0.12 + 0.2 * r(i, 6), ph = r(i, 7) * 6.283
            let x = bx + sin(t * w1 + ph) * ax, y = by + cos(t * w2 + ph * 1.7) * ay
            let br = 0.25 + 0.75 * (0.5 + 0.5 * sin(t * (0.6 + 0.9 * r(i, 8)) + ph))
            let rad = (1.2 + 1.8 * r(i, 9)) * max(0.3, amount)
            glow(ctx, at: CGPoint(x: x, y: y), radius: rad, brightness: br)
        }
    }

    private func glow(_ ctx: GraphicsContext, at p: CGPoint, radius rad: Double, brightness br: Double) {
        let outer = Path(ellipseIn: CGRect(x: p.x - rad * 4, y: p.y - rad * 4, width: rad * 8, height: rad * 8))
        ctx.fill(outer, with: .color(color.opacity(0.10 * br)))
        let mid = Path(ellipseIn: CGRect(x: p.x - rad * 2, y: p.y - rad * 2, width: rad * 4, height: rad * 4))
        ctx.fill(mid, with: .color(color.opacity(0.30 * br)))
        let core = Path(ellipseIn: CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2))
        ctx.fill(core, with: .color(Color.white.opacity(0.85 * br)))
    }

    private func drawLeaves(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        for i in 0..<n {
            let period = 16 + 10 * r(i, 1)                       // 1 枚が上から下まで 16〜26 秒
            let prog = ((t / period) + r(i, 2)).truncatingRemainder(dividingBy: 1)
            let y = prog * (size.height + 60) - 30
            let x = r(i, 3) * size.width + sin(t * (0.5 + 0.4 * r(i, 4)) + r(i, 5) * 6.283) * (14 + 16 * r(i, 6)) * amount
            let len = (7 + 6 * r(i, 7)) * max(0.3, amount), wid = len * 0.45
            let angle = t * (0.8 + 0.8 * r(i, 8)) + r(i, 9) * 6.283
            var c = ctx
            c.translateBy(x: x, y: y)
            c.rotate(by: .radians(angle))
            // 葉の形：細長い楕円を 2 つ重ねる
            let leaf = Path(ellipseIn: CGRect(x: -len / 2, y: -wid / 2, width: len, height: wid))
            c.fill(leaf, with: .color(color.opacity(0.55)))
            let vein = Path(ellipseIn: CGRect(x: -len * 0.3, y: -wid * 0.18, width: len * 0.6, height: wid * 0.36))
            c.fill(vein, with: .color(Color.white.opacity(0.22)))
        }
    }

    private func drawSparkles(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        for i in 0..<n {
            let x = r(i, 1) * size.width, y = r(i, 2) * size.height
            let s = sin(t * (0.7 + 1.2 * r(i, 3)) + r(i, 4) * 6.283)
            guard s > 0 else { continue }
            let br = s * s * s
            let len = (3 + 5 * r(i, 5)) * max(0.3, amount) * (0.6 + 0.4 * br)
            var star = Path()
            star.move(to: CGPoint(x: x - len, y: y)); star.addLine(to: CGPoint(x: x + len, y: y))
            star.move(to: CGPoint(x: x, y: y - len)); star.addLine(to: CGPoint(x: x, y: y + len))
            ctx.stroke(star, with: .color(color.opacity(0.9 * br)), lineWidth: 1)
            let core = Path(ellipseIn: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4))
            ctx.fill(core, with: .color(Color.white.opacity(br)))
        }
    }

    private func drawBubbles(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        for i in 0..<n {
            let period = 10 + 10 * r(i, 1)
            let prog = ((t / period) + r(i, 2)).truncatingRemainder(dividingBy: 1)
            let y = size.height + 20 - prog * (size.height + 40)
            let x = r(i, 3) * size.width + sin(t * (0.6 + 0.5 * r(i, 4)) + r(i, 5) * 6.283) * 10 * amount
            let rad = (2 + 5 * r(i, 6)) * max(0.3, amount)
            let ring = Path(ellipseIn: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2))
            ctx.stroke(ring, with: .color(color.opacity(0.5)), lineWidth: 1)
            let hi = Path(ellipseIn: CGRect(x: x - rad * 0.45, y: y - rad * 0.6, width: rad * 0.5, height: rad * 0.35))
            ctx.fill(hi, with: .color(Color.white.opacity(0.5)))
        }
    }
}
