import XCTest
@testable import Core

final class RigPartsTests: XCTestCase {
    func testStandardHasSizesAndWeightsButNoWorms() {
        let parts = RigParts.standard
        XCTAssertTrue(parts.hooks.contains("1/0"))
        XCTAssertEqual(parts.sinkers, parts.sinkers.sorted())
        XCTAssertTrue(parts.worms.isEmpty)
    }

    func testHookIsNormalizedAndNotDuplicated() {
        var parts = RigParts()
        XCTAssertTrue(parts.addHook("＃１／０"))
        XCTAssertEqual(parts.hooks, ["1/0"])
        XCTAssertFalse(parts.addHook(" #1/0 "))          // 同じもの
        XCTAssertFalse(parts.addHook("   "))             // 空
        XCTAssertTrue(parts.addHook("2番"))
        XCTAssertEqual(parts.hooks, ["1/0", "2"])
        parts.removeHook("1/0")
        XCTAssertEqual(parts.hooks, ["2"])
    }

    func testSinkerParsingAndSorting() {
        XCTAssertEqual(RigParts.parseGrams("14"), 14)
        XCTAssertEqual(RigParts.parseGrams("14g"), 14)
        XCTAssertEqual(RigParts.parseGrams("３．５ｇ"), 3.5)
        XCTAssertEqual(RigParts.parseGrams("3,5"), 3.5)
        XCTAssertEqual(RigParts.parseGrams("7 グラム"), 7)
        XCTAssertNil(RigParts.parseGrams("重い"))
        XCTAssertNil(RigParts.parseGrams("0"))
        XCTAssertNil(RigParts.parseGrams("9999"))
        XCTAssertEqual(RigParts.gramsText(14), "14")
        XCTAssertEqual(RigParts.gramsText(3.5), "3.5")

        var parts = RigParts()
        XCTAssertTrue(parts.addSinker("14"))
        XCTAssertTrue(parts.addSinker("5g"))
        XCTAssertFalse(parts.addSinker("14.0"))          // 同じ重さ
        XCTAssertFalse(parts.addSinker("abc"))
        XCTAssertEqual(parts.sinkers, [5, 14])           // 軽い順
        parts.removeSinker(5)
        XCTAssertEqual(parts.sinkers, [14])
    }

    func testWormLabelAndDuplicates() throws {
        var parts = RigParts()
        let worm = try XCTUnwrap(parts.addWorm(maker: " エコギア ", size: "3インチ", color: "グリパン"))
        XCTAssertEqual(worm.label, "エコギア 3インチ グリパン")
        XCTAssertNil(parts.addWorm(maker: "エコギア", size: "3インチ", color: "グリパン"))   // 同じ内容
        XCTAssertNil(parts.addWorm(maker: "", size: " ", color: ""))                        // 全部空
        let partial = try XCTUnwrap(parts.addWorm(maker: "ガルプ", size: "", color: "赤"))    // 空の項目は飛ばす
        XCTAssertEqual(partial.label, "ガルプ 赤")
        parts.removeWorm(id: worm.id)
        XCTAssertEqual(parts.worms.map(\.label), ["ガルプ 赤"])
    }

    func testCodableRoundTrip() throws {
        var parts = RigParts.standard
        parts.addWorm(maker: "エコギア", size: "3インチ", color: "グリパン")
        let again = try JSONDecoder().decode(RigParts.self, from: JSONEncoder().encode(parts))
        XCTAssertEqual(again, parts)
    }

    func testResolveReusesSameCombination() throws {
        let old = Rig(sinkerGrams: 14, hookSize: "1/0", worm: "エコギア 3インチ グリパン", sortOrder: 3)
        let named = Rig(name: "定番", sinkerGrams: 14, hookSize: "1/0", worm: "エコギア 3インチ グリパン", sortOrder: 4)
        // 同じ組み合わせはもうあるものを使う（名前なしを優先）
        let hit = try XCTUnwrap(Rig.resolve(hook: "1/0", sinkerGrams: 14, worm: "エコギア 3インチ グリパン", in: [named, old]))
        XCTAssertFalse(hit.isNew)
        XCTAssertEqual(hit.rig.id, old.id)
        // 違う組み合わせは新しく作り、並びは最後
        let made = try XCTUnwrap(Rig.resolve(hook: "2", sinkerGrams: 7, worm: nil, in: [named, old]))
        XCTAssertTrue(made.isNew)
        XCTAssertEqual(made.rig.sortOrder, 5)
        XCTAssertEqual(made.rig.hookSize, "2")
        XCTAssertEqual(made.rig.sinkerGrams, 7)
        // 何も選んでいなければリグなし
        XCTAssertNil(Rig.resolve(hook: nil, sinkerGrams: nil, worm: nil, in: [old]))
        XCTAssertNil(Rig.resolve(hook: "", sinkerGrams: 0, worm: "", in: []))
    }

    func testDisplayNameOfPartCombinations() {
        XCTAssertEqual(Rig(sinkerGrams: 14, hookSize: "1/0", worm: "エコギア 3インチ グリパン").displayName, "14g エコギア 3インチ グリパン")
        XCTAssertEqual(Rig(sinkerGrams: 0, hookSize: "1/0", worm: "エコギア 3インチ").displayName, "エコギア 3インチ")   // シンカーなし
        XCTAssertEqual(Rig(sinkerGrams: 0, hookSize: "1/0", worm: "").displayName, "#1/0")                              // フックだけ
        XCTAssertEqual(Rig(sinkerGrams: 3.5, hookSize: "", worm: "").displayName, "3.5g")
        XCTAssertTrue(Rig(sinkerGrams: 0, hookSize: "", worm: "").isEmpty)
    }
}
