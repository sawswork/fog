import Foundation
import XCTest
@testable import Core

final class ThemeSpecTests: XCTestCase {
    let sample = """
    {
      "label": "森",
      "base": "grimoireDark",
      "colors": {"accent": "#5FD3F3", "scrim": "#00000040", "bogus": "zzz"},
      "fonts": {"text": "serif", "number": "serif"},
      "home": {
        "hidesTabBar": true,
        "layers": [
          {"image": "bg_home", "z": 0},
          {"image": "char_home", "rect": [0.1, 0.2, 0.8, 0.7], "fit": "fit", "z": 50, "opacity": 1.4}
        ],
        "blocks": [
          {"type": "score", "rect": [0.3, 0.1, 0.4, 0.2], "z": 60, "action": "breakdown"},
          {"type": "chart", "rect": {"x": 0.05, "y": 0.35, "w": 0.5, "h": 0.2}, "z": 60},
          {"type": "hologram", "rect": [0, 0, 1, 1]},
          {"type": "nav", "rect": [0, 0.92, 1, 0.08], "z": 100},
          {"type": "text", "rect": [-0.2, 0.5, 1.5, 0.05], "text": "I am sure", "z": 70},
          {"type": "button", "rect": [0.8, 0.0, 0.2, 0.0], "symbol": "gearshape"}
        ]
      }
    }
    """

    func testParsesAndSanitizes() throws {
        let spec = try ThemeSpec.parse(Data(sample.utf8))
        XCTAssertEqual(spec.label, "森")
        XCTAssertEqual(spec.base, "grimoireDark")
        XCTAssertEqual(spec.fonts?.text, "serif")
        let colors = spec.parsedColors
        XCTAssertEqual(colors["accent"]?.b ?? 0, 0xF3 / 255.0, accuracy: 0.001)
        XCTAssertEqual(colors["scrim"]?.a ?? 1, 0x40 / 255.0, accuracy: 0.001)
        XCTAssertNil(colors["bogus"])
        let home = try XCTUnwrap(spec.home)
        XCTAssertTrue(home.hidesTabBar)
        XCTAssertEqual(home.layers.count, 2)
        XCTAssertEqual(home.layers[0].rect, .full)
        XCTAssertEqual(home.layers[1].opacity, 1)          // 1.4 → 1
        // 知らない種類（hologram）と高さ 0 のボタンは落ち、z の順に並ぶ
        XCTAssertEqual(home.blocks.map(\.type), ["score", "chart", "text", "nav"])
        XCTAssertEqual(home.blocks[0].kind, .score)
        XCTAssertEqual(home.blocks[0].action, "breakdown")
        // 長方形は 0〜1 に収まる（x=-0.2, w=1.5 → x=0, w=1）
        XCTAssertEqual(home.blocks[2].rect, LayoutRect(x: 0, y: 0.5, w: 1, h: 0.05))
        XCTAssertEqual(home.blocks[1].rect, LayoutRect(x: 0.05, y: 0.35, w: 0.5, h: 0.2))
    }

    func testMinimalSpecHasDefaults() throws {
        let spec = try ThemeSpec.parse(Data("{}".utf8))
        XCTAssertEqual(spec.version, 1)
        XCTAssertEqual(spec.label, "テーマ")
        XCTAssertNil(spec.home)
        let homeOnly = try ThemeSpec.parse(Data(#"{"home":{"blocks":[{"type":"forecast"}]}}"#.utf8))
        XCTAssertEqual(homeOnly.home?.hidesTabBar, false)
        XCTAssertEqual(homeOnly.home?.blocks.first?.rect, .full)
        XCTAssertEqual(homeOnly.home?.blocks.first?.background, "none")
    }

    func testRectRoundTripsAsArray() throws {
        let r = LayoutRect(x: 0.1, y: 0.2, w: 0.3, h: 0.4)
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[0.1,0.2,0.3,0.4]")
        XCTAssertEqual(try JSONDecoder().decode(LayoutRect.self, from: data), r)
    }

    func testHexColor() {
        XCTAssertNil(HexColor("#12"))
        XCTAssertNil(HexColor("#GGGGGG"))
        let c = HexColor("739E78")!
        XCTAssertEqual(c.r, 0x73 / 255.0, accuracy: 0.001)
        XCTAssertEqual(c.a, 1)
        XCTAssertEqual(HomeLayout.Action(rawValue: "spotSwitch"), .spotSwitch)
    }

    /// 動き（motion）と効果（effect）の層：画像の無い効果の層が通り、画像も効果も無い層は落ち、倍率は範囲に収まる
    func testLayerMotionAndEffect() throws {
        let json = """
        {"home":{"layers":[
          {"image":"bg_home","motion":"drift","speed":0.5,"amount":9},
          {"effect":"fireflies","count":500,"color":"#9BE3B3","z":10},
          {"rect":[0,0,1,1],"z":5},
          {"image":"char_home","motion":"float","speed":0}
        ]}}
        """
        let spec = try ThemeSpec.parse(Data(json.utf8))
        let layers = try XCTUnwrap(spec.home?.layers)
        XCTAssertEqual(layers.count, 3)                   // 画像も効果も無い層は落ちる
        // 並びは z 順（bg 0 → char 0 → fireflies 10）なので名前で引く
        let bg = try XCTUnwrap(layers.first { $0.image == "bg_home" })
        let fire = try XCTUnwrap(layers.first { $0.effect == "fireflies" })
        let char = try XCTUnwrap(layers.first { $0.image == "char_home" })
        XCTAssertEqual(layers.last?.effect, "fireflies")
        XCTAssertEqual(bg.motion, "drift")
        XCTAssertEqual(bg.speed, 0.5)
        XCTAssertEqual(bg.amount, 3)                      // 9 → 3
        XCTAssertEqual(fire.image, "")
        XCTAssertEqual(fire.count, 200)                   // 500 → 200
        XCTAssertEqual(fire.parsedColor?.g ?? 0, 0xE3 / 255.0, accuracy: 0.001)
        XCTAssertEqual(char.speed, 0.1)                   // 0 → 0.1
        XCTAssertNil(char.effect)
        XCTAssertNil(char.parsedColor)
    }

    func testStyleSection() throws {
        let spec = try ThemeSpec.parse(Data(#"{"style":{"chipTilt":-5,"chipPerspective":18,"glass":true,"chipOrnament":"✦","captureSymbol":"moon.fill"}}"#.utf8))
        XCTAssertEqual(spec.style?.chipTilt, -5)
        XCTAssertEqual(spec.style?.chipPerspective, 18)
        XCTAssertEqual(spec.style?.glass, true)
        XCTAssertEqual(spec.style?.chipOrnament, "✦")
        XCTAssertEqual(spec.style?.captureSymbol, "moon.fill")
        XCTAssertNil(try ThemeSpec.parse(Data("{}".utf8)).style)
    }
}
