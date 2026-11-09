import Foundation
import XCTest
@testable import Core

final class TapeMeasureTests: XCTestCase {
    /// 横向きのメジャー：10 cm ごとに数字、1 cm = 20 px
    private func marks(pxPerCm: Double = 20, angle: Double = 0, noise: Double = 0) -> [TapeMeasure.Mark] {
        (1...6).map { i in
            let s = Double(i * 10) * pxPerCm
            let n = noise * (i % 2 == 0 ? 1 : -1)
            return TapeMeasure.Mark(value: Double(i * 10), x: 100 + s * cos(angle) - n * sin(angle), y: 400 + s * sin(angle) + n * cos(angle))
        }
    }

    func testScaleFromMarks() throws {
        let s = try XCTUnwrap(TapeMeasure.scale(marks: marks()))
        XCTAssertEqual(s.pxPerCm, 20, accuracy: 0.01)
        XCTAssertEqual(s.axisX, 1, accuracy: 0.001)
        XCTAssertGreaterThan(s.fit, 0.999)
        let tilted = try XCTUnwrap(TapeMeasure.scale(marks: marks(angle: .pi / 6)))
        XCTAssertEqual(tilted.pxPerCm, 20, accuracy: 0.05)
    }

    func testOutlierIsDropped() throws {
        var m = marks()
        m[2].value = 80   // 「30」を「80」と読み違えた
        let s = try XCTUnwrap(TapeMeasure.scale(marks: m))
        XCTAssertEqual(s.pxPerCm, 20, accuracy: 0.2)
        XCTAssertEqual(s.count, 5)
    }

    func testNeedsTwoDistinctValues() {
        XCTAssertNil(TapeMeasure.scale(marks: [TapeMeasure.Mark(value: 10, x: 0, y: 0), TapeMeasure.Mark(value: 10, x: 50, y: 0)]))
        XCTAssertNil(TapeMeasure.scale(marks: []))
    }

    func testFishLengthAlongTape() throws {
        // 35 cm の魚（1 cm = 20 px → 700 px）をメジャーと平行に置く。輪郭は細長い楕円
        var pts: [ImagePoint] = []
        for k in 0..<64 {
            let t = Double(k) / 64 * 2 * .pi
            pts.append(ImagePoint(x: 500 + 350 * cos(t), y: 600 + 80 * sin(t)))
        }
        let e = try XCTUnwrap(TapeMeasure.estimate(marks: marks(), fishPoints: pts))
        XCTAssertEqual(e.lengthCm, 35, accuracy: 0.6)
        XCTAssertGreaterThan(e.confidence, 0.8)
        XCTAssertLessThan(e.errorCm, 3)
        // メジャーに対して 90° の魚でも同じ面なら長さは同じ（確信度は下がる）
        let rotated = pts.map { ImagePoint(x: 500 + ($0.y - 600), y: 600 + ($0.x - 500)) }
        let e2 = try XCTUnwrap(TapeMeasure.estimate(marks: marks(), fishPoints: rotated))
        XCTAssertEqual(e2.lengthCm, 35, accuracy: 0.6)
        XCTAssertLessThan(e2.confidence, e.confidence)
    }

    func testRejectsTinyOrHugeObjects() {
        let dot = (0..<16).map { ImagePoint(x: 300 + 10 * cos(Double($0)), y: 300 + 10 * sin(Double($0))) }
        XCTAssertNil(TapeMeasure.estimate(marks: marks(), fishPoints: dot))
    }
}
