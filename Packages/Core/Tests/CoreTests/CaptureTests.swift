import Foundation
import XCTest
@testable import Core

/// L5: 深度からの実寸換算と同一個体まとめ（純粋ロジック）。精度 ±2 cm の実機確認は開発者。
final class CaptureTests: XCTestCase {
    // iPhone 16 Pro 広角の内部パラメータ相当（1920×1440）
    let k = CameraIntrinsics(fx: 1400, fy: 1400, cx: 960, cy: 720)

    func testThirtyCentimeterRulerAtHalfMeter() throws {
        // 0.5 m の距離で 30 cm は 1400 × 0.3 / 0.5 = 840 px
        let m = try XCTUnwrap(LengthEstimator.measure(a: ImagePoint(x: 540, y: 720), b: ImagePoint(x: 1380, y: 720), depthA: 0.5, depthB: 0.5, intrinsics: k))
        XCTAssertEqual(m.lengthCm, 30, accuracy: 0.01)
        XCTAssertLessThan(m.errorCm, 2)
        XCTAssertEqual(m.distanceM, 0.5, accuracy: 0.001)
    }

    func testTiltedFishUsesDepthDifference() throws {
        // 片端が 5 cm 奥：画像上は短く見えるが 3 次元では長い
        let flat = try XCTUnwrap(LengthEstimator.measure(a: ImagePoint(x: 540, y: 720), b: ImagePoint(x: 1380, y: 720), depthA: 0.5, depthB: 0.5, intrinsics: k))
        let tilted = try XCTUnwrap(LengthEstimator.measure(a: ImagePoint(x: 540, y: 720), b: ImagePoint(x: 1380, y: 720), depthA: 0.5, depthB: 0.55, intrinsics: k))
        XCTAssertGreaterThan(tilted.lengthCm, flat.lengthCm)
        XCTAssertGreaterThan(tilted.errorCm, flat.errorCm)
    }

    func testInvalidDepthReturnsNil() {
        XCTAssertNil(LengthEstimator.measure(a: ImagePoint(x: 0, y: 0), b: ImagePoint(x: 10, y: 0), depthA: 0, depthB: 0.5, intrinsics: k))
    }

    func testFrameStatus() {
        XCTAssertEqual(LengthEstimator.frameStatus(distanceM: nil), .searching)
        XCTAssertEqual(LengthEstimator.frameStatus(distanceM: 0.2), .tooClose)
        XCTAssertEqual(LengthEstimator.frameStatus(distanceM: 1.2), .tooFar)
        XCTAssertEqual(LengthEstimator.frameStatus(distanceM: 0.5), .ok)
    }

    func testPrincipalAxisFindsLongEnds() throws {
        // 横長の楕円の輪郭
        var pts: [ImagePoint] = []
        for i in 0..<72 {
            let t = Double(i) / 72 * 2 * .pi
            pts.append(ImagePoint(x: 960 + 400 * cos(t), y: 720 + 80 * sin(t)))
        }
        let (a, b) = try XCTUnwrap(LengthEstimator.principalAxisEndpoints(pts))
        XCTAssertEqual(abs(a.x - b.x), 800, accuracy: 2)
        XCTAssertLessThan(abs(a.y - b.y), 10)
    }

    // MARK: 同一個体

    func makeCatch(at offset: TimeInterval, species: String, conf: Double, length: Double?, error: Double? = 1.5, photo: String) -> Catch {
        Catch(sessionID: SampleData.sessionID, at: SampleData.caughtAt.addingTimeInterval(offset), coordinate: SampleData.hakodate,
              species: species, speciesConfidence: conf, lengthCm: length, lengthErrorCm: error, photoLocalIdentifier: photo)
    }

    func testThreeShotsBecomeOneCatch() {
        let first = makeCatch(at: 0, species: "アイナメ", conf: 0.8, length: 38, photo: "p1")
        let second = makeCatch(at: 20, species: "アイナメ", conf: 0.9, length: 37, error: 1.0, photo: "p2")
        XCTAssertNotNil(CatchMerger.findSameIndividual(for: second, in: [first]))
        let merged = CatchMerger.merge(base: first, new: second)
        XCTAssertEqual(merged.id, first.id)
        XCTAssertEqual(merged.lengthCm, 37)          // 推定幅の小さい方
        XCTAssertEqual(merged.speciesConfidence, 0.9)
        XCTAssertEqual(merged.photoLocalIdentifier, "p2") // ベストショット
        XCTAssertEqual(Set(merged.photoLocalIdentifiers), ["p1", "p2"])
        let third = makeCatch(at: 45, species: "アイナメ", conf: 0.7, length: 39, error: 2.0, photo: "p3")
        XCTAssertNotNil(CatchMerger.findSameIndividual(for: third, in: [merged]))
        let all = CatchMerger.merge(base: merged, new: third)
        XCTAssertEqual(all.photoLocalIdentifiers.count, 3)
        XCTAssertEqual(all.lengthCm, 37)
    }

    func testDifferentFishIsNotMerged() {
        let first = makeCatch(at: 0, species: "アイナメ", conf: 0.9, length: 38, photo: "p1")
        let other = makeCatch(at: 30, species: "クロソイ", conf: 0.9, length: 25, photo: "p2")
        XCTAssertNil(CatchMerger.findSameIndividual(for: other, in: [first]))
        let later = makeCatch(at: 10 * 60, species: "アイナメ", conf: 0.9, length: 38, photo: "p3")
        XCTAssertNil(CatchMerger.findSameIndividual(for: later, in: [first]))
        let muchBigger = makeCatch(at: 30, species: "アイナメ", conf: 0.9, length: 50, photo: "p4")
        XCTAssertNil(CatchMerger.findSameIndividual(for: muchBigger, in: [first]))
    }

    func testUnmeasuredPhotoMergesAndKeepsMeasurement() {
        let measured = makeCatch(at: 0, species: "アイナメ", conf: 0.9, length: 38, photo: "p1")
        let imported = makeCatch(at: 60, species: "アイナメ", conf: 0.6, length: nil, error: nil, photo: "lib1")
        XCTAssertNotNil(CatchMerger.findSameIndividual(for: imported, in: [measured]))
        let merged = CatchMerger.merge(base: measured, new: imported)
        XCTAssertEqual(merged.lengthCm, 38)
        XCTAssertEqual(merged.photoLocalIdentifier, "p1")
        XCTAssertTrue(merged.photoLocalIdentifiers.contains("lib1"))
    }

    func testCorrectedSpeciesIsKept() {
        var base = makeCatch(at: 0, species: "クジメ", conf: 0.5, length: 30, photo: "p1")
        base.speciesCorrected = true
        let new = makeCatch(at: 10, species: "アイナメ", conf: 0.95, length: 30, photo: "p2")
        XCTAssertEqual(CatchMerger.merge(base: base, new: new).species, "クジメ")
    }

    /// 魚が写っているかの判定（F-67）：魚のラベルが無く、魚以外だとはっきり分かるときだけ「写っていない」
    func testFishPresence() {
        // 魚のラベルがあれば魚（人や景色が一緒でも）
        let held = FishPresence.judge(labels: [("people", 0.9), ("adult", 0.8), ("fish", 0.35), ("outdoor", 0.9)], hasSubject: true)
        XCTAssertTrue(held.hasFish); XCTAssertEqual(held.reason, .fishLabel)
        XCTAssertTrue(FishPresence.judge(labels: [("sky", 0.9), ("seafood", 0.12)], hasSubject: false).hasFish)
        // 夜の海の景色：被写体が無く、空と海
        let night = FishPresence.judge(labels: [("sky", 0.92), ("night_sky", 0.7), ("ocean", 0.8), ("outdoor", 0.95), ("fish", 0.01)], hasSubject: false)
        XCTAssertFalse(night.hasFish); XCTAssertEqual(night.reason, .scenery)
        XCTAssertEqual(night.evidence, "sky 0.92")
        // 岸壁に立つ人：人が写っていて魚のラベルが無い。"fishing" は魚に数えない
        let person = FishPresence.judge(labels: [("people", 0.85), ("fishing", 0.6), ("harbor", 0.5)], hasSubject: true)
        XCTAssertFalse(person.hasFish); XCTAssertEqual(person.reason, .people)
        // 画面の写し
        XCTAssertEqual(FishPresence.judge(labels: [("screenshot", 0.9)], hasSubject: nil).reason, .other)
        // 迷ったら残す：被写体があって魚のラベルも人も無い（暗い魚など）、ラベルが取れない、景色でも被写体がある・分からない
        XCTAssertTrue(FishPresence.judge(labels: [("outdoor", 0.9), ("rock", 0.4), ("night", 0.5)], hasSubject: true).hasFish)
        XCTAssertEqual(FishPresence.judge(labels: [], hasSubject: nil).reason, .unsure)
        XCTAssertTrue(FishPresence.judge(labels: [("ocean", 0.9)], hasSubject: nil).hasFish)
        XCTAssertTrue(FishPresence.judge(labels: [("ocean", 0.9)], hasSubject: true).hasFish)
        // 弱いラベルは根拠にしない
        XCTAssertTrue(FishPresence.judge(labels: [("people", 0.3), ("sky", 0.2)], hasSubject: false).hasFish)
        // "starfish" "fishing_rod" は魚に数えない、"fish_market" は語が合うので魚
        XCTAssertEqual(FishPresence.judge(labels: [("starfish", 0.9), ("fishing_rod", 0.9), ("people", 0.9)], hasSubject: true).reason, .people)
        XCTAssertTrue(FishPresence.judge(labels: [("fish_market", 0.5), ("people", 0.9)], hasSubject: true).hasFish)
    }
}
