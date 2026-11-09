import Foundation

/// 写真に写ったメジャー（巻き尺・定規）から魚の全長を出す（F-61）。
/// 文字認識で読んだ目盛りの数字（値と画像上の位置）から「1 cm が何ピクセルか」を回帰で求め、魚の主軸の長さを cm に直す。
/// 前提：メジャーと魚が同じ面にあり、ほぼ真上から撮っている（斜めだと短く出る）
public enum TapeMeasure {
    /// 目盛りの数字 1 つ（cm の値と、その文字の中心の画像座標）
    public struct Mark: Hashable, Sendable {
        public var value: Double
        public var x: Double
        public var y: Double
        public init(value: Double, x: Double, y: Double) { self.value = value; self.x = x; self.y = y }
    }

    public struct Scale: Hashable, Sendable {
        /// 1 cm あたりのピクセル
        public var pxPerCm: Double
        /// メジャーの向き（単位ベクトル）
        public var axisX: Double, axisY: Double
        /// 回帰の当てはまり（0〜1）
        public var fit: Double
        /// 使った目盛りの数
        public var count: Int
    }

    public struct Estimate: Hashable, Sendable {
        public var lengthCm: Double
        public var errorCm: Double
        /// 0〜1。目盛りの数・当てはまり・魚とメジャーの向きの差から
        public var confidence: Double
        public var scale: Scale
    }

    /// 目盛りの数字から倍率を求める。値の異なる数字が 2 つ以上要る。読み違いは外れ値として 1 つまで落とす
    public static func scale(marks input: [Mark]) -> Scale? {
        var marks = dedupe(input)
        guard Set(marks.map(\.value)).count >= 2 else { return nil }
        var best = fitScale(marks)
        // 外れ値（読み違い）を 1 つ落として改善するなら採る
        if marks.count >= 4, let b = best, b.fit < 0.995 {
            for i in marks.indices {
                var m = marks; m.remove(at: i)
                if let s = fitScale(m), s.fit > b.fit + 0.002, s.count >= 3 { best = s; marks = m; break }
            }
        }
        guard let s = best, s.fit >= 0.97, s.pxPerCm > 0.5 else { return nil }
        return s
    }

    /// 魚の輪郭点とメジャーの目盛りから全長を出す
    public static func estimate(marks: [Mark], fishPoints: [ImagePoint]) -> Estimate? {
        guard let s = scale(marks: marks), fishPoints.count >= 8,
              let (a, b) = LengthEstimator.principalAxisEndpoints(fishPoints) else { return nil }
        let dx = b.x - a.x, dy = b.y - a.y
        let px = (dx * dx + dy * dy).squareRoot()
        guard px > s.pxPerCm * 3 else { return nil }   // 3 cm 未満は魚ではない
        let lengthCm = px / s.pxPerCm
        // 魚の向きとメジャーの向きのずれ（同じ面なら倍率は向きによらないが、斜め撮影の影響は向きで変わる）
        let cosT = abs(dx * s.axisX + dy * s.axisY) / max(px, 1e-9)
        let angleFactor = 0.5 + 0.5 * cosT
        let confidence = min(1, max(0, (s.fit - 0.97) / 0.03)) * min(1, Double(s.count) / 4) * angleFactor
        let errorCm = max(1.0, lengthCm * (0.04 + (1 - confidence) * 0.08))
        guard lengthCm >= 3, lengthCm <= 300 else { return nil }
        return Estimate(lengthCm: (lengthCm * 10).rounded() / 10, errorCm: (errorCm * 10).rounded() / 10, confidence: confidence, scale: s)
    }

    // MARK: 内部

    /// 同じ値が近くに 2 回読めたら 1 つに（「10」の上下に小さい目盛り文字があるなど）
    static func dedupe(_ marks: [Mark]) -> [Mark] {
        var out: [Mark] = []
        for m in marks {
            if let i = out.firstIndex(where: { $0.value == m.value && hypot($0.x - m.x, $0.y - m.y) < 1 }) { _ = i; continue }
            out.append(m)
        }
        return out
    }

    /// 位置の主軸に沿った座標 s と値 v の回帰 v = a + b s → pxPerCm = 1/|b|
    static func fitScale(_ marks: [Mark]) -> Scale? {
        let n = Double(marks.count)
        guard marks.count >= 2 else { return nil }
        let mx = marks.reduce(0) { $0 + $1.x } / n, my = marks.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for m in marks { let dx = m.x - mx, dy = m.y - my; sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
        // 2×2 共分散の第一主成分
        let tr = sxx + syy, det = sxx * syy - sxy * sxy
        let l1 = tr / 2 + ((tr * tr) / 4 - det).squareRoot()
        var ax: Double, ay: Double
        if abs(sxy) > 1e-9 { ax = l1 - syy; ay = sxy } else if sxx >= syy { ax = 1; ay = 0 } else { ax = 0; ay = 1 }
        let len = (ax * ax + ay * ay).squareRoot(); ax /= len; ay /= len
        let s = marks.map { ($0.x - mx) * ax + ($0.y - my) * ay }
        let v = marks.map(\.value)
        let ms = s.reduce(0, +) / n, mv = v.reduce(0, +) / n
        var sss = 0.0, ssv = 0.0, svv = 0.0
        for i in marks.indices { sss += (s[i] - ms) * (s[i] - ms); ssv += (s[i] - ms) * (v[i] - mv); svv += (v[i] - mv) * (v[i] - mv) }
        guard sss > 1e-9, svv > 1e-9 else { return nil }
        let b = ssv / sss
        guard abs(b) > 1e-9 else { return nil }
        let r2 = (ssv * ssv) / (sss * svv)
        // 向きは値が増える方へ
        if b < 0 { ax = -ax; ay = -ay }
        return Scale(pxPerCm: 1 / abs(b), axisX: ax, axisY: ay, fit: r2, count: marks.count)
    }
}
