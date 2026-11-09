import Foundation
import SwiftUI
import AVFoundation
import ARKit
import Core

/// 撮影画面の状態。ARKit のフレームを間引いて輪郭・全長をライブ計算し、シャッターで釣果にする。
@MainActor
@Observable
final class CaptureViewModel {
    let depth = DepthCaptureSession()
    private let analyzer = FrameAnalyzer()
    private var capture: CaptureService?
    private var store: FogStore?
    private var location: LocationService?
    private var usingLocation = false

    private(set) var status: FrameStatus = .searching
    private(set) var liveLengthCm: Double?
    private(set) var liveMeasurement: LengthMeasurement?
    private(set) var endpoints: (CGPoint, CGPoint)?
    private(set) var result: CaptureService.Outcome?
    private(set) var isSaving = false
    private(set) var spotName: String = ""
    private(set) var torchOn = false
    var tackle: TackleKind = .spinning
    var rig: Rig?
    var rigs: [Rig] = []
    /// 釣った人（F-54）。候補は 設定 > 釣り人
    var angler: String = AnglerSettings.ownName
    var anglerCandidates: [String] = AnglerSettings.candidates
    private var lastResultAt: Date?
    /// LiDAR が無い端末（iPhone 17 など）はサイズ未計測で記録する（F-12）
    var measuresLength: Bool { DepthCaptureSession.isSupported }

    func attach(services: AppServices) {
        store = services.store
        location = services.location
        // 撮影位置を付けるため、画面を開いている間だけ位置を取る（閉じたら止める）
        if !usingLocation { services.location.beginForegroundUpdates(); usingLocation = true }
        if capture == nil { capture = services.capture }
        tackle = services.capture.currentTackle ?? ((try? services.store.sessions())?.first?.tackle) ?? .spinning
        rigs = (try? services.store.rigs()) ?? []
        rig = rigs.first { $0.id == services.capture.currentRigID } ?? rigs.first
        spotName = services.detection.activeSpotName ?? ""
        anglerCandidates = AnglerSettings.candidates
        angler = services.capture.currentAngler ?? AnglerSettings.ownName
    }

    func start() {
        Perf.mark("撮影画面を開いた")
        // 解析は ARKit のスレッドで（6 フレームに 1 回）。結果だけメインへ
        depth.onFrame = { [weak self, analyzer] frame in
            guard let r = analyzer.analyze(frame) else { return }
            Task { @MainActor [weak self] in self?.apply(r, frame: frame) }
        }
        depth.start()
    }

    func stop() {
        Perf.mark("撮影画面を閉じた")
        depth.pause()
        depth.onFrame = nil
        if usingLocation { location?.endForegroundUpdates(); usingLocation = false }
    }

    private func apply(_ r: FishSegmenter.Result, frame: DepthCaptureSession.Frame) {
        status = r.status
        liveMeasurement = r.measurement
        liveLengthCm = r.status == .ok ? r.measurement?.lengthCm : nil
        if let (a, b) = r.endpoints {
            // 縦向き表示：撮影画像は横向きなので (x, y) → (height − y, x) に回す
            let w = Double(frame.imageSize.width), h = Double(frame.imageSize.height)
            endpoints = (CGPoint(x: (h - a.y) / h, y: a.x / w), CGPoint(x: (h - b.y) / h, y: b.x / w))
        } else {
            endpoints = nil
        }
    }

    /// シャッター。保存まで 2 秒以内（写真保存を待たずに結果を返す設計は CaptureService 側）。
    func shutter() async {
        guard !isSaving, let capture, let frame = depth.latest else { return }
        isSaving = true
        defer { isSaving = false }
        guard let (jpeg, image) = CaptureImageConverter.jpegAndImage(from: frame.image) else { return }
        let measurement = (status == .ok && measuresLength) ? liveMeasurement : nil
        capture.currentTackle = tackle
        capture.currentRigID = rig?.id
        let coordinate = depthCoordinate()
        result = await capture.record(jpeg: jpeg, image: image, measurement: measurement, coordinate: coordinate)
        // 釣った人は釣行ができてから覚える（撮影で釣行が始まることがある）
        capture.currentAngler = angler == AnglerSettings.ownName ? nil : angler
        if let saved = result?.catchRecord, saved.angler != (angler == AnglerSettings.ownName ? nil : angler) {
            capture.setAngler(catchID: saved.id, angler: angler)
            result?.catchRecord.angler = angler == AnglerSettings.ownName ? nil : angler
        }
        lastResultAt = .now
    }

    /// 撮影位置：記録中の釣行の最後の立ち位置 → 端末の最新の位置（撮影画面を開いたときに取り始める）
    private func depthCoordinate() -> Coordinate? {
        if let c = location?.lastFix?.coordinate, c.isPlausible, let at = location?.lastFix?.at, Date.now.timeIntervalSince(at) < 10 * 60 { return c }
        if let store, let active = try? store.activeSession(), let c = active.track.last?.coordinate, c.isPlausible { return c }
        if let c = location?.lastFix?.coordinate, c.isPlausible { return c }
        return nil
    }

    func dismissResult() { result = nil }

    /// 夜のライト（LiDAR は暗くても測れるが、輪郭検出には光が要る）。
    func toggleTorch() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = torchOn ? .off : .on
            device.unlockForConfiguration()
            torchOn.toggle()
        } catch {}
    }

    func choose(species: String) {
        guard let result, let capture else { return }
        capture.setSpecies(catchID: result.catchRecord.id, species: species, corrected: false)
        var updated = result
        updated.catchRecord.species = species
        self.result = updated
    }

    func toggleTackle() {
        tackle = tackle == .spinning ? .bait : .spinning
        capture?.currentTackle = tackle
    }

    func selectRig(_ r: Rig) {
        rig = r
        capture?.currentRigID = r.id
    }

    func select(angler name: String) {
        angler = name
        capture?.currentAngler = name == AnglerSettings.ownName ? nil : name
    }
}

/// ARKit のスレッドで輪郭・全長を計算する（同時に 1 つだけ。解析中に来たフレームは捨てる）
final class FrameAnalyzer: @unchecked Sendable {
    private let segmenter = FishSegmenter()
    private let lock = NSLock()
    private var busy = false

    func analyze(_ frame: DepthCaptureSession.Frame) -> FishSegmenter.Result? {
        lock.lock()
        if busy { lock.unlock(); return nil }
        busy = true
        lock.unlock()
        defer { lock.lock(); busy = false; lock.unlock() }
        return segmenter.analyze(frame)
    }
}
