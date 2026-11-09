import Foundation
import XCTest
@testable import Core

final class FishCatalogTests: XCTestCase {
    private func sample() -> FishCatalog {
        FishCatalog(entries: [
            FishEntry(id: "ainame", name: "アイナメ", aliases: ["アブラコ", "アブラメ"], groups: ["根魚", "北の魚"], scientificName: "Hexagrammos otakii", family: "アイナメ科",
                      summary: "日本〜朝鮮半島沿岸の岩礁域に生息する底生魚", maxLengthCm: 57, seasonMonths: [11, 12, 1, 2, 3], spawningMonths: [10, 11, 12], waters: ["Marine"],
                      distributionJa: "北海道から九州", ecology: "昼行性で岩礁帯やテトラポッドの陰につく"),
            FishEntry(id: "kurosoi", name: "クロソイ", aliases: ["ソイ"], groups: ["根魚"], scientificName: "Sebastes schlegelii", family: "メバル科",
                      summary: "北海道から九州の沿岸", maxLengthCm: 60, seasonMonths: [12, 1, 2], spawningMonths: [4, 5, 6], waters: ["Marine"], distributionJa: "北海道から九州"),
            FishEntry(id: "yamame", name: "ヤマメ", groups: ["渓流", "淡水"], scientificName: "Oncorhynchus masou", family: "サケ科",
                      summary: "渓流の女王", maxLengthCm: 40, seasonMonths: [3, 4, 5, 6, 7, 8, 9], waters: ["Freshwater"], distributionJa: "神奈川県以北の太平洋側"),
        ])
    }

    func testNormalizeAbsorbsKanaAndWidth() {
        XCTAssertEqual(FishSearch.normalize("あいなめ"), "アイナメ")
        XCTAssertEqual(FishSearch.normalize("ＡＩＮＡＭＥ"), "ainame")
        XCTAssertEqual(FishSearch.normalize("ｱｲﾅﾒ"), "アイナメ")   // 半角カナも全角に
        XCTAssertEqual(FishSearch.normalize("アイナメ"), "アイナメ")   // カタカナは半角にしない
        XCTAssertEqual(FishSearch.normalize("北海道　根魚"), "北海道 根魚")
    }

    func testSearchByNameAliasPlaceAndTrait() {
        let c = sample()
        XCTAssertEqual(c.filtered(query: "あいなめ").map(\.id), ["ainame"])
        XCTAssertEqual(c.filtered(query: "アブラコ").map(\.id), ["ainame"])
        XCTAssertEqual(c.filtered(query: "hexagrammos").map(\.id), ["ainame"])
        XCTAssertEqual(Set(c.filtered(query: "北海道").map(\.id)), ["ainame", "kurosoi"])   // 分布で
        XCTAssertEqual(c.filtered(query: "テトラ").map(\.id), ["ainame"])                      // 生態で
        XCTAssertEqual(c.filtered(query: "渓流").map(\.id), ["yamame"])                        // 分類で
        XCTAssertEqual(Set(c.filtered(query: "北海道 根魚").map(\.id)), ["ainame", "kurosoi"]) // 語は AND
        XCTAssertTrue(c.filtered(query: "マグロ").isEmpty)
    }

    func testRankingPrefersNameMatch() {
        let c = sample()
        // 「ソイ」は クロソイ の名前にも含まれ、別名にも一致。アイナメには含まれない
        XCTAssertEqual(c.filtered(query: "ソイ").map(\.id), ["kurosoi"])
        // 「北海道」は 2 種の分布に出る。名前に無いので元の順
        XCTAssertEqual(c.filtered(query: "北海道").map(\.id), ["ainame", "kurosoi"])
    }

    func testFilters() {
        let c = sample()
        XCTAssertEqual(c.filtered(group: "根魚").count, 2)
        XCTAssertEqual(c.filtered(month: 5).map(\.id).sorted(), ["kurosoi", "yamame"])   // 旬か産卵期に 5 月
        XCTAssertEqual(c.filtered(waters: "淡水").map(\.id), ["yamame"])
        XCTAssertEqual(c.filtered(caughtOnly: ["ainame"]).map(\.id), ["ainame"])
        XCTAssertEqual(c.groups.first, "根魚")
        XCTAssertEqual(c.filtered(family: "サケ科").map(\.id), ["yamame"])
        XCTAssertEqual(c.families.count, 3)
        XCTAssertEqual(c.namedCount, 3)
        // 和名の無い種（学名だけ）は namedOnly で外れる
        var c2 = c
        c2.entries.append(FishEntry(id: "fb1", name: "Sebastes sp.", scientificName: "Sebastes sp."))
        XCTAssertEqual(c2.filtered(namedOnly: true).count, 3)
        XCTAssertEqual(c2.filtered(query: "sebastes").count, 2)        // 作り置きの索引が entries の変更に追従する
    }

    func testSpeciesNameLinksToEntry() {
        let c = sample()
        XCTAssertEqual(c.entry(forSpecies: "アブラコ")?.id, "ainame")
        XCTAssertEqual(c.entry(forSpecies: "アイナメ")?.id, "ainame")
        XCTAssertNil(c.entry(forSpecies: "マダイ"))
        XCTAssertEqual(c.entries[0].watersJa, ["海水"])
    }

    func testBundledCatalogDecodesIfPresent() {
        // 同梱データが無いときは空で動く（CI の port-data と同じ考え）
        let c = FishCatalog.bundled()
        for e in c.entries.prefix(5) { XCTAssertFalse(e.name.isEmpty) }
    }
}
