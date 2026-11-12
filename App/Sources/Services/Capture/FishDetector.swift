import Foundation
import CoreGraphics
import Vision
import Core

/// 写真に魚が写っているかを端末内で見る（F-67）。Vision の画像分類のラベルと、前景の被写体の有無を `FishPresence` に渡す。通信なし。
/// 標準カメラの写真の取り込みと、仲間から届いた釣果のサムネイルに使う。アプリのカメラで撮った写真には使わない（魚を撮る操作なので止めない）
enum FishDetector {
    /// 失敗したとき（ラベルが取れない）は「魚あり」として返す。150〜300 ms 程度
    static func check(_ image: CGImage) async -> FishPresence.Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let classify = VNClassifyImageRequest()
                let mask = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                var labels: [(String, Double)] = []
                var hasSubject: Bool?
                if (try? handler.perform([classify])) != nil {
                    labels = (classify.results ?? []).map { ($0.identifier, Double($0.confidence)) }
                }
                if (try? handler.perform([mask])) != nil {
                    hasSubject = !(mask.results?.first?.allInstances.isEmpty ?? true)
                }
                cont.resume(returning: FishPresence.judge(labels: labels, hasSubject: hasSubject))
            }
        }
    }

    /// 診断の記録に残す 1 行（設定 > 診断）。判定が外れたときに、どのラベルで決めたかが分かるように
    static func note(_ result: FishPresence.Result, source: String) {
        Perf.mark("魚の判定（\(source)）：\(result.hasFish ? "あり" : "なし") \(result.reason.rawValue) \(result.evidence)")
    }
}
