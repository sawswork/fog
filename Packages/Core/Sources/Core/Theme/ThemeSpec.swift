import Foundation

/// テーマ定義（`App/Resources/Themes/<folder>/theme.json`）。配色・書体と、ホーム画面の「部品の配置」を JSON で持つ（F-58）。
///
/// 画面側のコードはテーマを意識しない。新しいテーマは **フォルダに画像と theme.json を置くだけ** で増やせ、
/// ホームは `home.blocks` に書いた部品（釣れ率・グラフ・週・釣果・地図・ボタン…）を `rect`（画面に対する割合）の位置に並べる。
/// 画像は `home.layers` で何枚でも重ねられる（z の順）。タブバーは `home.hidesTabBar` で消せる（部品の `nav` や `button` で画面を行き来する）。
///
/// 書き方は `docs/07_theme_spec.md`。Core にあるのは読み込みと検証だけ（Linux のテストで確かめる）。
public struct ThemeSpec: Codable, Hashable, Sendable {
    public var version: Int
    /// 表示名（設定 > テーマ）
    public var label: String
    /// 配色・書体の土台：dark / grimoire / grimoireDark / tensura。省略は dark
    public var base: String?
    /// この フォルダに無い画像を借りるフォルダ
    public var fallbackFolder: String?
    /// 明るい地か（システムの配色も合わせる）。省略は土台に従う
    public var light: Bool?
    public var fonts: Fonts?
    /// 配色の上書き。キーは background / surface / surfaceRaised / accent / secondary / sun / daylight / textPrimary / textSecondary / textTertiary / faded / sea / moon / saturday / holiday / panel / scrim。値は "#RRGGBB" か "#RRGGBBAA"
    public var colors: [String: String]?
    public var home: HomeLayout?
    public var style: Style?

    public init(version: Int = 1, label: String, base: String? = nil, fallbackFolder: String? = nil, light: Bool? = nil, fonts: Fonts? = nil,
                colors: [String: String]? = nil, home: HomeLayout? = nil) {
        self.version = version; self.label = label; self.base = base; self.fallbackFolder = fallbackFolder; self.light = light
        self.fonts = fonts; self.colors = colors; self.home = home
    }

    /// 標準レイアウトの部品の見た目（チップの傾き・ガラス・飾り・撮影ボタンの印）
    public struct Style: Codable, Hashable, Sendable {
        /// チップを時計回りに傾ける角度（度。負で反時計回り）
        public var chipTilt: Double?
        /// チップを縦軸まわりに回す角度（度。奥行きのある見え方）
        public var chipPerspective: Double?
        /// チップと予報のカードをガラス（すりガラス＋薄い白い枠）にする
        public var glass: Bool?
        /// ガラスの上に重ねる面の濃さ（0〜1。小さいほど背景が透ける。省略は 0.35）
        public var glassOpacity: Double?
        /// チップの角に置く飾りの文字（例 "✦"）
        public var chipOrnament: String?
        /// 撮影ボタンの SF Symbols 名（例 "moon.fill"）。省略は camera.fill
        public var captureSymbol: String?
        public init(chipTilt: Double? = nil, chipPerspective: Double? = nil, glass: Bool? = nil, glassOpacity: Double? = nil, chipOrnament: String? = nil, captureSymbol: String? = nil) {
            self.chipTilt = chipTilt; self.chipPerspective = chipPerspective; self.glass = glass; self.glassOpacity = glassOpacity; self.chipOrnament = chipOrnament; self.captureSymbol = captureSymbol
        }
    }

    public struct Fonts: Codable, Hashable, Sendable {
        /// default / serif / rounded / monospaced
        public var text: String?
        public var number: String?
        public init(text: String? = nil, number: String? = nil) { self.text = text; self.number = number }
    }

    enum CodingKeys: String, CodingKey { case version, label, base, fallbackFolder, light, fonts, colors, home, style }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "テーマ"
        base = try c.decodeIfPresent(String.self, forKey: .base)
        fallbackFolder = try c.decodeIfPresent(String.self, forKey: .fallbackFolder)
        light = try c.decodeIfPresent(Bool.self, forKey: .light)
        fonts = try c.decodeIfPresent(Fonts.self, forKey: .fonts)
        colors = try c.decodeIfPresent([String: String].self, forKey: .colors)
        home = try c.decodeIfPresent(HomeLayout.self, forKey: .home)
        style = try c.decodeIfPresent(Style.self, forKey: .style)
    }

    public static func parse(_ data: Data) throws -> ThemeSpec {
        var spec = try JSONDecoder().decode(ThemeSpec.self, from: data)
        spec.home = spec.home?.sanitized()
        return spec
    }

    /// 配色の色を (r, g, b, a) に。読めないキーは無視
    public var parsedColors: [String: HexColor] {
        var out: [String: HexColor] = [:]
        for (k, v) in colors ?? [:] { if let c = HexColor(v) { out[k] = c } }
        return out
    }
}

/// "#RRGGBB" / "#RRGGBBAA" / "RRGGBB"
public struct HexColor: Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255; a = 1
        } else {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255; b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        }
    }
}

/// ホーム 1 画面の配置。座標はすべて画面の幅・高さに対する割合（0〜1。安全領域を含む全画面が基準）
public struct HomeLayout: Codable, Hashable, Sendable {
    /// タブバーを消す（画面の行き来は `nav` か `button` の部品で）
    public var hidesTabBar: Bool
    /// 背景・キャラクターなどの画像（z の小さい順に下から重ねる）
    public var layers: [Layer]
    /// 部品
    public var blocks: [Block]
    /// 背景画像の上に敷く幕の濃さ（0〜1。省略は土台の既定）
    public var scrim: Double?

    public init(hidesTabBar: Bool = false, layers: [Layer] = [], blocks: [Block] = [], scrim: Double? = nil) {
        self.hidesTabBar = hidesTabBar; self.layers = layers; self.blocks = blocks; self.scrim = scrim
    }

    enum CodingKeys: String, CodingKey { case hidesTabBar, layers, blocks, scrim }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hidesTabBar = try c.decodeIfPresent(Bool.self, forKey: .hidesTabBar) ?? false
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
        blocks = try c.decodeIfPresent([Block].self, forKey: .blocks) ?? []
        scrim = try c.decodeIfPresent(Double.self, forKey: .scrim)
    }

    /// 範囲外の座標を 0〜1 に収め、知らない種類の部品を落とし、z の順に並べる
    public func sanitized() -> HomeLayout {
        var out = self
        out.layers = layers.filter { !$0.image.isEmpty || $0.effect != nil }
            .map { var l = $0; l.rect = l.rect.clamped(); l.opacity = min(1, max(0, l.opacity))
                   l.speed = min(5, max(0.1, l.speed)); l.amount = min(3, max(0, l.amount)); l.count = l.count.map { min(200, max(0, $0)) }; return l }
            .sorted { $0.z < $1.z }
        out.blocks = blocks.filter { $0.kind != nil && $0.rect.w > 0 && $0.rect.h > 0 }
            .map { var b = $0; b.rect = b.rect.clamped(); b.opacity = min(1, max(0, b.opacity)); return b }
            .sorted { $0.z < $1.z }
        if let s = scrim { out.scrim = min(1, max(0, s)) }
        return out
    }

    /// 画像の 1 枚
    public struct Layer: Codable, Hashable, Sendable {
        /// テーマフォルダの画像名（拡張子なし）。`effect` の層では空
        public var image: String
        public var rect: LayoutRect
        /// fill（はみ出しを切って埋める）/ fit（全体が入るように）
        public var fit: String
        public var z: Int
        public var opacity: Double
        /// auto（背景色から自動：マゼンタ抜き・黒抜き）/ normal（そのまま）
        public var blend: String
        /// 画像の動き：float（上下にふわり）/ breathe（呼吸）/ sway（左右に揺れる）/ spin（ゆっくり回る）/ drift（背景がゆっくり寄る）/ pulse（明滅）。省略は動かない
        public var motion: String?
        /// 動き・効果の速さの倍率（1 が既定、0.1〜5）
        public var speed: Double
        /// 動き・効果の大きさの倍率（1 が既定、0〜3）
        public var amount: Double
        /// 画像の代わりに描く効果：fireflies（光の粒）/ leaves（舞う葉）/ sparkles（きらめき）/ bubbles（泡）
        public var effect: String?
        /// 効果の粒の数（省略は効果ごとの既定）
        public var count: Int?
        /// 効果の色 `#RRGGBB`（省略はアクセント色）
        public var color: String?
        public init(image: String = "", rect: LayoutRect = .full, fit: String = "fill", z: Int = 0, opacity: Double = 1, blend: String = "auto",
                    motion: String? = nil, speed: Double = 1, amount: Double = 1, effect: String? = nil, count: Int? = nil, color: String? = nil) {
            self.image = image; self.rect = rect; self.fit = fit; self.z = z; self.opacity = opacity; self.blend = blend
            self.motion = motion; self.speed = speed; self.amount = amount; self.effect = effect; self.count = count; self.color = color
        }
        enum CodingKeys: String, CodingKey { case image, rect, fit, z, opacity, blend, motion, speed, amount, effect, count, color }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
            rect = try c.decodeIfPresent(LayoutRect.self, forKey: .rect) ?? .full
            fit = try c.decodeIfPresent(String.self, forKey: .fit) ?? "fill"
            z = try c.decodeIfPresent(Int.self, forKey: .z) ?? 0
            opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
            blend = try c.decodeIfPresent(String.self, forKey: .blend) ?? "auto"
            motion = try c.decodeIfPresent(String.self, forKey: .motion)
            speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
            amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 1
            effect = try c.decodeIfPresent(String.self, forKey: .effect)
            count = try c.decodeIfPresent(Int.self, forKey: .count)
            color = try c.decodeIfPresent(String.self, forKey: .color)
        }
        /// 効果の色（読めなければ nil → アクセント色）
        public var parsedColor: HexColor? { color.flatMap(HexColor.init) }
    }

    /// 部品の 1 つ
    public struct Block: Codable, Hashable, Sendable {
        /// 種類（文字列のまま持ち、知らないものは `kind` が nil になって無視される）
        public var type: String
        public var rect: LayoutRect
        public var z: Int
        public var opacity: Double
        /// タップしたときの動き（画面の切替やシート）。省略は部品ごとの既定
        public var action: String?
        /// 部品の後ろの面：none（既定。画像テーマは自前の泡を描く）/ panel（半透明の面）
        public var background: String
        /// 内側の余白（pt）
        public var padding: Double
        /// `button` の画像名（テーマフォルダ）か `symbol`（SF Symbols）、`text` の文字
        public var image: String?
        public var symbol: String?
        public var text: String?
        /// 部品ごとの見た目の指定（例：score の "ring" / "plain"、text の "caption"）
        public var style: String?

        public var kind: Kind? { Kind(rawValue: type) }

        public enum Kind: String, CaseIterable, Sendable {
            case header        // 釣り場名・時刻・開始/終了・相談・月・歯車
            case score         // 釣れ率の円（記録中はライブ画面）
            case chips         // 今の 4 チップ
            case feedLine      // 釣果情報の 1 行
            case forecast      // 日付・グラフ・表・週・水温の全部（タブ版と同じ）
            case chart         // 日付とグラフだけ
            case table         // 3 時間ごとの表だけ
            case week          // 週の見通しだけ
            case recentCatches // 直近の釣果の写真（タップでログ）
            case miniMap       // 周りの釣り場の小さな地図（タップで釣り場）
            case nav           // 5 つの画面のボタン（タブバーの代わり）
            case button        // 1 つのボタン（image か symbol、action）
            case text          // 文字（text）
            case date          // 今日の日付
            case spacer        // 何も描かない（将来のために予約）
        }

        public init(type: String, rect: LayoutRect, z: Int = 10, opacity: Double = 1, action: String? = nil, background: String = "none",
                    padding: Double = 0, image: String? = nil, symbol: String? = nil, text: String? = nil, style: String? = nil) {
            self.type = type; self.rect = rect; self.z = z; self.opacity = opacity; self.action = action; self.background = background
            self.padding = padding; self.image = image; self.symbol = symbol; self.text = text; self.style = style
        }

        enum CodingKeys: String, CodingKey { case type, rect, z, opacity, action, background, padding, image, symbol, text, style }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            rect = try c.decodeIfPresent(LayoutRect.self, forKey: .rect) ?? .full
            z = try c.decodeIfPresent(Int.self, forKey: .z) ?? 10
            opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
            action = try c.decodeIfPresent(String.self, forKey: .action)
            background = try c.decodeIfPresent(String.self, forKey: .background) ?? "none"
            padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? 0
            image = try c.decodeIfPresent(String.self, forKey: .image)
            symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
            text = try c.decodeIfPresent(String.self, forKey: .text)
            style = try c.decodeIfPresent(String.self, forKey: .style)
        }
    }

    /// タップの動き
    public enum Action: String, CaseIterable, Sendable {
        case home, log, capture, guide, spots, settings, breakdown, feed, assistant, spotSwitch, moon, year, toggleSession, none
    }
}

/// 画面に対する割合の長方形。JSON では `[x, y, w, h]` の配列か `{"x":..,"y":..,"w":..,"h":..}`
public struct LayoutRect: Codable, Hashable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public static let full = LayoutRect(x: 0, y: 0, w: 1, h: 1)

    public func clamped() -> LayoutRect {
        let x = min(1, max(0, x)), y = min(1, max(0, y))
        return LayoutRect(x: x, y: y, w: min(1 - x, max(0, w)), h: min(1 - y, max(0, h)))
    }

    enum CodingKeys: String, CodingKey { case x, y, w, h }

    public init(from decoder: Decoder) throws {
        if var arr = try? decoder.unkeyedContainer() {
            let x = try arr.decode(Double.self), y = try arr.decode(Double.self), w = try arr.decode(Double.self), h = try arr.decode(Double.self)
            self.init(x: x, y: y, w: w, h: h)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y), w: try c.decode(Double.self, forKey: .w), h: try c.decode(Double.self, forKey: .h))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(w); try c.encode(h)
    }
}
