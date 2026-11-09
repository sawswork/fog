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

    func testBundledCatalogDecodes() {
        // 同梱の fish.json が必ず読める（1 件でも読めないと全体が空になり、図鑑に何も出なくなった 2026-11-09 の再発防止）
        let c = FishCatalog.bundled()
        XCTAssertGreaterThan(c.entries.count, 1000)
        XCTAssertGreaterThan(c.namedCount, 500)
        XCTAssertNotNil(c.entry(forSpecies: "アイナメ"))
        for e in c.entries.prefix(5) { XCTAssertFalse(e.name.isEmpty) }
    }

    func testMinimalEntryDecodes() throws {
        // 別名・分類・出典のキーが無くても読める
        let json = #"{"entries":[{"id":"x","name":"テスト"},{"id":"y","name":"ふたつめ","sources":[{"name":"FishBase"}],"depthMaxM":50,"spawningMonths":[4,5]}]}"#
        let c = try JSONDecoder().decode(FishCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(c.entries.count, 2)
        XCTAssertEqual(c.entries[0].aliases, [])
        XCTAssertEqual(c.entries[0].sources.count, 0)
        XCTAssertEqual(c.entries[1].depthMaxM, 50)
        XCTAssertEqual(c.entries[1].sources.first?.name, "FishBase")
        XCTAssertEqual(c.filtered(query: "ふたつめ").map(\.id), ["y"])
    }

    func testAdviceFromData() {
        var e = FishEntry(id: "ainame", name: "アイナメ", groups: ["根魚"], maxLengthCm: 57, seasonMonths: [11, 12, 1, 2, 3], spawningMonths: [10, 11, 12], waters: ["Marine"],
                          distributionJa: "北海道から九州の沿岸。朝鮮半島にも。", ecology: "昼行性で、岩礁帯やテトラポッド、防波堤などの陰につき、小魚や甲殻類、多毛類などを捕食する。")
        e.depthMinM = 4; e.depthMaxM = 155; e.commonLengthCm = 30
        let out = FishAdvice.make(e, month: 12, ownCount: 2, ownMaxCm: 41)
        XCTAssertTrue(out.advice.first?.contains("11〜3月") == true, out.advice.first ?? "")
        XCTAssertTrue(out.advice.first?.contains("旬") == true)
        XCTAssertTrue(out.places.contains("堤防・漁港"))
        XCTAssertTrue(out.places.contains("岩礁帯・根周り"))
        XCTAssertTrue(out.places.contains("水深 4〜155 m"))
        XCTAssertTrue(out.advice.contains { $0.contains("ルアー") || $0.contains("エビ") || $0.contains("イソメ") })
        XCTAssertTrue(out.advice.contains { $0.contains("57 cm") && $0.contains("30 cm") && $0.contains("41 cm") })
        XCTAssertEqual(out.distribution, "北海道から九州の沿岸")
        XCTAssertEqual(FishAdvice.monthList([12, 1, 2]), "12〜2月")
        XCTAssertEqual(FishAdvice.monthList([3, 5, 6]), "3月・5〜6月")
    }

    func testByteIndexSearchMatchesStringSearch() {
        var entries: [FishEntry] = []
        for i in 0..<3000 { entries.append(FishEntry(id: "s\(i)", name: "テスト\(i)", scientificName: "Genus species\(i)", distributionJa: i % 7 == 0 ? "北海道南部" : "九州")) }
        let c = FishCatalog(entries: entries)
        let t0 = Date()
        let hits = c.filtered(query: "北海道")
        XCTAssertEqual(hits.count, 3000 / 7 + 1)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
        let expected = (0..<3000).filter { "genus species\($0)".contains("species12") && $0 % 7 == 0 }.count
        XCTAssertEqual(c.filtered(query: "species12 北海道").count, expected)   // 語は AND、学名も対象
    }
}
