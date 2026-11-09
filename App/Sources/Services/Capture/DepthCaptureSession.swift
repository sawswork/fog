import Foundation
import ARKit
import CoreImage
import os
import Core

/// ARKit の深度付きカメラ（LiDAR）。フレームごとに画像・深度・内部パラメータを渡す。
/// 計測は `FishSegmenter`、保存は `CaptureService` が行う。
///
/// 2026-11-09 処理速度：以前は毎フレーム（60 回/秒）メインスレッドへ Task を投げ、その中でピクセルバッファを握っていた。
/// メインが忙しいと Task が積み上がってバッファが枯渇し、ARKit がフレームを止める（カメラが固まる・開かない）。
/// いまは最新フレームをロック付きの箱に入れ替えるだけにし、解析（6 フレームに 1 回）は ARKit のスレッドで直接呼ぶ。
final class DepthCaptureSession: NSObject, ARSessionDelegate, @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let image: CVPixelBuffer
        let depth: CVPixelBuffer?
        let depthConfidence: CVPixelBuffer?
        let intrinsics: CameraIntrinsics
        let imageSize: (width: Int, height: Int)
        let timestamp: TimeInterval
    }

    let session = ARSession()
    private(set) var isRunning = false
    private let latestLock = NSLock()
    private var latestFrame: Frame?
    private var frameCounter = 0
    /// 解析用：`everyNthFrame` ごとに ARKit のスレッドで呼ばれる（メインではない）。重い処理はここで同期的に行い、結果だけメインへ渡す
    var onFrame: (@Sendable (Frame) -> Void)?
    var everyNthFrame = 6
    private static let log = Logger(subsystem: "fog", category: "depth")

    /// 最新フレーム（シャッター用）
    var latest: Frame? {
        latestLock.lock(); defer { latestLock.unlock() }
        return latestFrame
    }

    static var isSupported: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard !isRunning else { return }
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics = [.smoothedSceneDepth]
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = [.sceneDepth]
        }
        config.isAutoFocusEnabled = true
        config.environmentTexturing = .none
        config.planeDetection = []
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func pause() {
        session.pause()
        isRunning = false
        latestLock.lock(); latestFrame = nil; latestLock.unlock()
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let k = frame.camera.intrinsics
        let size = frame.camera.imageResolution
        let depth = frame.smoothedSceneDepth ?? frame.sceneDepth
        let f = Frame(
            image: frame.capturedImage,
            depth: depth?.depthMap,
            depthConfidence: depth?.confidenceMap,
            intrinsics: CameraIntrinsics(fx: Double(k[0][0]), fy: Double(k[1][1]), cx: Double(k[2][0]), cy: Double(k[2][1])),
            imageSize: (Int(size.width), Int(size.height)),
            timestamp: frame.timestamp
        )
        latestLock.lock()
        latestFrame = f
        frameCounter &+= 1
        let count = frameCounter
        latestLock.unlock()
        if count % max(1, everyNthFrame) == 0 { onFrame?(f) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Self.log.error("AR session failed: \(error.localizedDescription, privacy: .public)")
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Self.log.notice("AR session interrupted")
    }
}

enum DepthSampling {
    /// 画像座標（撮影画像の解像度）に対応する深度（m）。深度マップは 256×192 なので比率で引く。信頼度が低い画素は nil。
    static func depth(at point: ImagePoint, in frame: DepthCaptureSession.Frame) -> Double? {
        guard let map = frame.depth else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let x = min(w - 1, max(0, Int(point.x / Double(frame.imageSize.width) * Double(w))))
        let y = min(h - 1, max(0, Int(point.y / Double(frame.imageSize.height) * Double(h))))
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let value = base.advanced(by: y * rowBytes + x * MemoryLayout<Float32>.size).assumingMemoryBound(to: Float32.self).pointee
        if let conf = frame.depthConfidence {
            CVPixelBufferLockBaseAddress(conf, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(conf, .readOnly) }
            if let cbase = CVPixelBufferGetBaseAddress(conf) {
                let crow = CVPixelBufferGetBytesPerRow(conf)
                let c = cbase.advanced(by: y * crow + x).assumingMemoryBound(to: UInt8.self).pointee
                if c == 0 { return nil } // ARConfidenceLevel.low
            }
        }
        guard value.isFinite, value > 0 else { return nil }
        return Double(value)
    }

    /// 周囲 3×3 の中央値（端の深度は外れやすい）。
    static func robustDepth(at point: ImagePoint, in frame: DepthCaptureSession.Frame, stepPx: Double = 8) -> Double? {
        var values: [Double] = []
        for dy in [-1.0, 0, 1] {
            for dx in [-1.0, 0, 1] {
                if let d = depth(at: ImagePoint(x: point.x + dx * stepPx, y: point.y + dy * stepPx), in: frame) { values.append(d) }
            }
        }
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }
}
