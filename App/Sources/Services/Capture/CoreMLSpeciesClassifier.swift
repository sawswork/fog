import Foundation
import CoreML
import Vision
import CoreGraphics
import Core
import os

/// Core ML の魚種判定（F-09）。`App/Resources/Models/FishClassifier.mlmodel`（学習は scripts/train_classifier/）を
/// Vision 経由で実行し、端末内の補正テーブル（F-24）で候補順を直す。モデルが同梱されていなければ仮実装に落とす。
final class CoreMLSpeciesClassifier: SpeciesClassifying, @unchecked Sendable {
    static let correctionKey = "fog.speciesCorrections"
    private let model: VNCoreMLModel?
    private let fallback = PlaceholderSpeciesClassifier()
    private static let log = Logger(subsystem: "fog", category: "classifier")

    init() {
        if let url = Bundle.main.url(forResource: "FishClassifier", withExtension: "mlmodelc"),
           let ml = try? MLModel(contentsOf: url, configuration: MLModelConfiguration()),
           let vn = try? VNCoreMLModel(for: ml) {
            model = vn
        } else {
            model = nil
            Self.log.notice("FishClassifier.mlmodelc not bundled — using placeholder")
        }
    }

    var isModelAvailable: Bool { model != nil }

    /// モデルのバージョン（設定画面「判定」に出す）。設定の一覧の body で毎回モデルを開いていたので 1 回だけ読む
    static let modelVersion: String = {
        guard let url = Bundle.main.url(forResource: "FishClassifier", withExtension: "mlmodelc"),
              let ml = try? MLModel(contentsOf: url) else { return "未同梱" }
        return ml.modelDescription.metadata[.versionString] as? String ?? "1"
    }()

    static func loadCorrections() -> SpeciesCorrectionTable {
        guard let data = UserDefaults.standard.data(forKey: correctionKey),
              let table = try? FogJSON.decode(SpeciesCorrectionTable.self, from: data) else { return SpeciesCorrectionTable() }
        return table
    }

    static func saveCorrections(_ table: SpeciesCorrectionTable) {
        if let data = try? FogJSON.encode(table, pretty: false) { UserDefaults.standard.set(data, forKey: correctionKey) }
    }

    /// 修正を学習する（撮影画面の候補タップ・図鑑の修正から呼ぶ）。
    static func learn(predicted: String, corrected: String) {
        var table = loadCorrections()
        table.record(predicted: predicted, corrected: corrected)
        saveCorrections(table)
    }

    func classify(_ image: CGImage) async -> [SpeciesCandidate] {
        guard let model else { return Self.loadCorrections().rerank(await fallback.classify(image)) }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Self.log.error("classification failed: \(error.localizedDescription, privacy: .public)")
            return await fallback.classify(image)
        }
        let raw = (request.results as? [VNClassificationObservation] ?? []).prefix(5)
            .map { SpeciesCandidate(species: Species.lookup($0.identifier)?.name ?? $0.identifier, confidence: Double($0.confidence)) }
        return Self.loadCorrections().rerank(Array(raw))
    }
}
