import XCTest
@testable import Core

final class FeedCatchTests: XCTestCase {
    let hakodate = Coordinate(latitude: 41.78, longitude: 140.72)
    let shikabe = Coordinate(latitude: 42.02, longitude: 140.81)

    func item(_ id: String, _ title: String, _ summary: String?, daysAgo: Double = 0) -> FeedItem {
        FeedItem(id: id, feedURL: "f", feedTitle: "店", title: title, link: "https://x/\(id)", summary: summary, publishedAt: Date(timeIntervalSince1970: 1_762_300_800 - daysAgo * 86_400), fetchedAt: .now)
    }

    func testPlacesPreferNearAndSpots() {
        let ports = [Port(name: "大浦漁港", lat: 41.8, lon: 140.7, kind: .fishing), Port(name: "大浦漁港", lat: 35.0, lon: 135.0, kind: .fishing),
                     Port(name: "函館港", lat: 41.78, lon: 140.72, kind: .harbor), Port(name: "港", lat: 40, lon: 140, kind: .harbor)]
        let places = FeedCatchExtractor.places(spots: [(name: "函館港", coordinate: Coordinate(latitude: 41.79, longitude: 140.73)), (name: "釣り場", coordinate: hakodate)], ports: ports, near: hakodate)
        XCTAssertEqual(places.count, 2) // 「港」は短すぎ、「釣り場」は除外、同名の港は 1 つ
        let oura = places.first { $0.name == "大浦漁港" }!
        XCTAssertEqual(oura.coordinate.latitude, 41.8, accuracy: 1e-9)
        let hk = places.first { $0.name == "函館港" }!
        XCTAssertEqual(hk.coordinate.latitude, 41.79, accuracy: 1e-9) // 登録釣り場が優先
    }

    func testExtractPlaceAndSpecies() {
        let places = [FeedCatchExtractor.Place(name: "鹿部漁港", coordinate: shikabe), FeedCatchExtractor.Place(name: "函館港", coordinate: hakodate)]
        let words = FeedCatchExtractor.speciesWords(Species.initialCatalog)
        let a = FeedCatchExtractor.extract(item("a", "函館港でアブラコ好調", "朝マズメにアブラコとクロソイ。鹿部漁港ではホッケ。"), places: places, speciesWords: words)
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(Set(a.map(\.placeName)), ["函館港", "鹿部漁港"])
        XCTAssertEqual(a[0].species, ["アブラコ", "クロソイ", "ホッケ"])
        // 場所が無ければ空
        XCTAssertTrue(FeedCatchExtractor.extract(item("b", "ソイの入荷", nil), places: places, speciesWords: words).isEmpty)
        // 魚種が無くても場所があれば 1 件
        let c = FeedCatchExtractor.extract(item("c", "函館港の様子", "静かでした"), places: places, speciesWords: words)
        XCTAssertEqual(c.count, 1); XCTAssertTrue(c[0].species.isEmpty)
    }

    func testPins() {
        let places = [FeedCatchExtractor.Place(name: "函館港", coordinate: hakodate)]
        let words = FeedCatchExtractor.speciesWords(Species.initialCatalog)
        let items = [item("1", "函館港 アブラコ", nil, daysAgo: 3), item("2", "函館港 アブラコとソイ", nil, daysAgo: 1), item("3", "函館港 ヒラメ", nil, daysAgo: 10)]
        let pins = FeedCatchExtractor.pins(items.flatMap { FeedCatchExtractor.extract($0, places: places, speciesWords: words) })
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins[0].entries.map(\.itemID), ["2", "1", "3"])
        XCTAssertEqual(pins[0].speciesCounts.map(\.0), ["アブラコ", "ソイ", "ヒラメ"])
        XCTAssertEqual(pins[0].speciesCounts[0].1, 2)
        XCTAssertEqual(pins[0].latestAt, items[1].publishedAt)
    }

    func testFeedCoordinateIsUsedWhenNoPortInText() {
        let places = [FeedCatchExtractor.Place(name: "函館港", coordinate: hakodate)]
        let words = FeedCatchExtractor.speciesWords(Species.initialCatalog)
        var i = item("f", "登別〜室蘭方面 漁港ランガン", "良型のカジカ")
        i.placeName = "室蘭"; i.coordinate = Coordinate(latitude: 42.315, longitude: 140.974); i.speciesHint = ["カジカ", "クロソイ"]
        let out = FeedCatchExtractor.extract(i, places: places, speciesWords: words)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].placeName, "室蘭")
        XCTAssertEqual(out[0].coordinate.latitude, 42.315, accuracy: 1e-9)
        XCTAssertEqual(out[0].species, ["カジカ", "クロソイ"])
        // 文中に港名があればそちらを優先（配信側の場所は使わない）
        var j = item("g", "函館港でアブラコ", nil)
        j.placeName = "室蘭"; j.coordinate = Coordinate(latitude: 42.315, longitude: 140.974)
        XCTAssertEqual(FeedCatchExtractor.extract(j, places: places, speciesWords: words).map(\.placeName), ["函館港"])
    }

    func testFacilityAliasInsidePort() {
        let ports = [Port(name: "函館港 北ふ頭", lat: 41.80, lon: 140.73, kind: .harbor), Port(name: "函館港", lat: 41.78, lon: 140.72, kind: .harbor),
                     Port(name: "函館港 西ふ頭", lat: 41.77, lon: 140.71, kind: .harbor), Port(name: "室蘭港 中央ふ頭", lat: 42.32, lon: 140.97, kind: .harbor)]
        let places = FeedCatchExtractor.places(spots: [], ports: ports, near: hakodate)
        XCTAssertNotNil(places.first { $0.name == "北ふ頭" })
        XCTAssertEqual(places.first { $0.name == "北ふ頭" }?.coordinate.latitude ?? 0, 41.80, accuracy: 1e-9)
        let words = FeedCatchExtractor.speciesWords(Species.initialCatalog)
        let out = FeedCatchExtractor.extract(item("h", "北ふ頭でサバ", nil), places: places, speciesWords: words)
        XCTAssertEqual(out.map(\.placeName), ["北ふ頭"])
        XCTAssertEqual(out[0].species, ["サバ"].filter { words.contains($0) })
    }

    /// 仲間の釣果の場所は、近くに自分の登録釣り場があればその名前と位置にする（300 m 以内でいちばん近いもの）
    func testLocalPlacePrefersOwnSpot() {
        let green = Coordinate(latitude: 41.8160, longitude: 140.6540)
        let spots: [(name: String, coordinate: Coordinate)] = [(name: "上磯漁港緑地", coordinate: green), (name: "函館港", coordinate: hakodate)]
        // 約 170 m 東
        let caught = Coordinate(latitude: 41.8160, longitude: 140.6560)
        let p = FeedCatchExtractor.localPlace(for: caught, fallbackName: "北斗漁港", spots: spots)
        XCTAssertEqual(p.name, "上磯漁港緑地")
        XCTAssertEqual(p.coordinate.longitude, 140.6540, accuracy: 1e-9)
        // 離れていれば相手の付けた名前と釣果の位置のまま
        let far = Coordinate(latitude: 41.8300, longitude: 140.6540)
        let q = FeedCatchExtractor.localPlace(for: far, fallbackName: "北斗漁港", spots: spots)
        XCTAssertEqual(q.name, "北斗漁港")
        XCTAssertEqual(q.coordinate.latitude, 41.8300, accuracy: 1e-9)
        XCTAssertEqual(FeedCatchExtractor.localPlace(for: far, fallbackName: "", spots: []).name, "釣り場")

        // ピンは自分の釣り場の名前でまとまる（自分の釣果と仲間の釣果が同じピンに入る）
        let at = Date(timeIntervalSince1970: 1_794_000_000)
        let friend = SharedCatch(id: UUID(), angler: "のぶ", device: "d2", species: "クロソイ", lengthCm: nil, at: at, coordinate: caught, spotName: "北斗漁港", updatedAt: at)
        let mine = SharedCatch(id: UUID(), angler: "自分", device: "d1", species: "アイナメ", lengthCm: 45, at: at.addingTimeInterval(600), coordinate: green, spotName: "上磯漁港緑地", updatedAt: at)
        let pins = FeedCatchExtractor.pins([
            friend.feedCatch(place: p),
            mine.feedCatch(sourceTitle: "自分の釣果", place: FeedCatchExtractor.localPlace(for: green, fallbackName: "上磯漁港緑地", spots: spots), idPrefix: "own:"),
        ])
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins[0].placeName, "上磯漁港緑地")
        XCTAssertEqual(pins[0].entries.map(\.feedTitle), ["自分の釣果", "仲間の釣果"])
        XCTAssertEqual(pins[0].entries[0].title, "アイナメ 45cm（自分）")
        XCTAssertTrue(pins[0].entries[0].itemID.hasPrefix("own:"))
        // 何も渡さなければ今までどおり
        XCTAssertEqual(friend.feedCatch().placeName, "北斗漁港")
    }
}
