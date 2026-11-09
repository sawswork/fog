import Foundation
import Vision
import CoreGraphics
import Core

/// 標準カメラの写真から、写っているメジャーを手がかりに全長を出す（F-61）。
/// 文字認識でメジャーの数字を読み（位置と値）、前景の切り抜きで魚の輪郭を取り、Core の `TapeMeasure` に渡す。通信なし。
enum TapeSizeEstimator {
    /// 読めなければ nil（従来どおり未計測）。採用は確信度 0.35 以上
    static func estimate(_ image: CGImage) async -> LengthMeasurement? {
        await Task.detached(priority: .userInitiated) { () -> LengthMeasurement? in
            let w = Double(image.width), h = Double(image.height)
            // 1) メジャーの数字
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = false
            text.recognitionLanguages = ["en-US"]
            text.minimumTextHeight = 0.008
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            guard (try? handler.perform([text])) != nil else { return nil }
            var marks: [TapeMeasure.Mark] = []
            for o in text.results ?? [] {
                guard let c = o.topCandidates(1).first, c.confidence > 0.3 else { continue }
                guard let value = parseCm(c.string) else { continue }
                let b = o.boundingBox   // 左下原点・正規化
                marks.append(TapeMeasure.Mark(value: value, x: b.midX * w, y: (1 - b.midY) * h))
            }
            guard marks.count >= 2 else { return nil }
            // 2) 魚の輪郭（前景の切り抜き。いちばん大きく、細長すぎないもの）
            let mask = VNGenerateForegroundInstanceMaskRequest()
            guard (try? handler.perform([mask])) != nil, let obs = mask.results?.first else { return nil }
            var bestPoints: [ImagePoint] = []
            for inst in obs.allInstances {
                guard let m = try? obs.generateScaledMaskForImage(forInstances: [inst], from: handler) else { continue }
                let pts = FishSegmenter().contourPoints(mask: m, targetWidth: image.width, targetHeight: image.height)
                guard pts.count >= 8, let (a, b) = LengthEstimator.principalAxisEndpoints(pts) else { continue }
                let len = hypot(b.x - a.x, b.y - a.y)
                // 主軸に直交する幅（細長さ）。メジャー自体は幅が極端に狭い
                let ux = (b.x - a.x) / max(len, 1e-9), uy = (b.y - a.y) / max(len, 1e-9)
                var minP = Double.infinity, maxP = -Double.infinity
                for p in pts { let d = -(p.x - a.x) * uy + (p.y - a.y) * ux; minP = min(minP, d); maxP = max(maxP, d) }
                let width = maxP - minP
                if width > 0, len / width > 9 { continue }     // メジャー（細長い帯）は除外
                if pts.count > bestPoints.count { bestPoints = pts }
            }
            guard let est = TapeMeasure.estimate(marks: marks, fishPoints: bestPoints), est.confidence >= 0.35 else { return nil }
            return LengthMeasurement(lengthCm: est.lengthCm, errorCm: est.errorCm, distanceM: 0)
        }.value
    }

    /// 「10」「10cm」「10 cm」「１０」を cm の値に。0〜300 の整数だけ
    static func parseCm(_ s: String) -> Double? {
        var t = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        t = t.lowercased().replacingOccurrences(of: " ", with: "")
        if t.hasSuffix("cm") { t.removeLast(2) }
        guard !t.isEmpty, t.count <= 3, t.allSatisfy(\.isNumber), let v = Double(t), v >= 0, v <= 300 else { return nil }
        return v
    }
}
