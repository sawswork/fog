import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Core

/// テーマ（F-49 / F-58）。`dark` が従来の標準。画像テーマは `App/Resources/Themes/<folder>/` の画像を使い、無ければ色だけで成立する。
///
/// 2026-11-09 から enum ではなく値型。組み込みの 4 つに加えて、フォルダに `theme.json`（`ThemeSpec`）を置いたテーマを起動時に見つけて増やす。
/// `theme.json` は配色・書体の上書きと、ホーム 1 画面の部品の配置（`HomeLayout`）を持つ。画面側のコードはテーマを意識しない。
struct AppTheme: Identifiable, Hashable {
    let id: String
    let label: String
    /// 画像フォルダ名（`Themes/<folder>/`）。空なら画像なし。無いファイルは `fallbackFolder` から探す
    let assetFolder: String
    let fallbackFolder: String?
    /// 明るい地のテーマか。システムの配色（シート・コントロール）もこれに合わせる
    let isLight: Bool
    let palette: ThemePalette
    /// 文字のデザイン。魔導書はセリフ体（New York）
    let fontDesign: Font.Design
    let numberDesign: Font.Design
    /// `theme.json` の内容（組み込みテーマは nil）
    let spec: ThemeSpec?

    var rawValue: String { id }
    var hasAssets: Bool { !assetFolder.isEmpty }
    var colorScheme: ColorScheme { isLight ? .light : .dark }
    /// 海図の 1 画面のテーマか（`"screen": "chart"`。F-63）。選ぶとタブの 5 画面の代わりに `ChartHomeView` を出す
    var isChart: Bool { spec?.isChartScreen == true }
    /// ホーム 1 画面の配置（あればホームは部品を JSON の座標に並べる。F-58）
    var home: HomeLayout? { spec?.home }
    /// 面の輪郭線（`style.borderColor`）。無ければ nil（輪郭なし）
    var outlineColor: Color? { spec?.style?.parsedBorderColor.map { Color(red: $0.r, green: $0.g, blue: $0.b, opacity: $0.a) } }
    var outlineWidth: CGFloat { CGFloat(spec?.style?.resolvedBorderWidth ?? 1.5) }
    /// 撮影ボタンの丸の色（`style.captureFill`）
    var captureFill: Color? { spec?.style?.parsedCaptureFill.map { Color(red: $0.r, green: $0.g, blue: $0.b, opacity: $0.a) } }
    /// 釣れ率の円の後ろの光の色（`style.glowColor`）
    var glowColor: Color? { spec?.style?.parsedGlowColor.map { Color(red: $0.r, green: $0.g, blue: $0.b, opacity: $0.a) } }

    static func == (l: AppTheme, r: AppTheme) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    // MARK: 組み込み

    static let dark = AppTheme(id: "dark", label: "ダーク", assetFolder: "", fallbackFolder: nil, isLight: false, palette: .dark, fontDesign: .default, numberDesign: .rounded, spec: nil)
    static let grimoire = AppTheme(id: "grimoire", label: "フリーレン 白", assetFolder: "grimoire", fallbackFolder: nil, isLight: true, palette: .grimoire, fontDesign: .serif, numberDesign: .serif, spec: nil)
    static let grimoireDark = AppTheme(id: "grimoireDark", label: "フリーレン 黒", assetFolder: "grimoire_dark", fallbackFolder: "grimoire", isLight: false, palette: .grimoireDark, fontDesign: .serif, numberDesign: .serif, spec: nil)
    static let tensura = AppTheme(id: "tensura", label: "転スラ", assetFolder: "tensura", fallbackFolder: nil, isLight: false, palette: .tensura, fontDesign: .default, numberDesign: .rounded, spec: nil)
    static let builtIns: [AppTheme] = [.dark, .grimoire, .grimoireDark, .tensura]

    /// 組み込み＋フォルダのテーマ（起動時に 1 回探す）
    @MainActor static var all: [AppTheme] {
        if let cached = allCache { return cached }
        let found = discovered()
        // 組み込みと同じ id の theme.json はそれを上書きとして使う
        var list: [AppTheme] = builtIns.map { b in found.first { $0.id == b.id } ?? b }
        list += found.filter { f in !builtIns.contains { $0.id == f.id } }
        allCache = list
        return list
    }
    @MainActor private static var allCache: [AppTheme]?

    @MainActor static func find(id: String) -> AppTheme? { all.first { $0.id == id } }

    /// `Themes/*/theme.json` を探す（フォルダ参照の置かれ方の違いに備えて 2 階層まで）
    @MainActor private static func discovered() -> [AppTheme] {
        guard let root = Bundle.main.resourceURL else { return [] }
        let fm = FileManager.default
        var dirs: [URL] = []
        for base in [root.appendingPathComponent("Themes"), root] {
            guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for url in items where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if fm.fileExists(atPath: url.appendingPathComponent("theme.json").path) { dirs.append(url) }
            }
        }
        var seen = Set<String>()
        return dirs.compactMap { dir -> AppTheme? in
            let folder = dir.lastPathComponent
            guard seen.insert(folder).inserted, let data = try? Data(contentsOf: dir.appendingPathComponent("theme.json")),
                  let spec = try? ThemeSpec.parse(data) else { return nil }
            return AppTheme(folder: folder, spec: spec)
        }
    }

    /// `theme.json` から作る。土台（base）の配色・書体に、colors / fonts / light を重ねる
    init(folder: String, spec: ThemeSpec) {
        let baseID = spec.base ?? (Self.builtIns.first { $0.assetFolder == folder }?.id ?? "dark")
        let base = Self.builtIns.first { $0.id == baseID } ?? .dark
        id = Self.builtIns.contains { $0.assetFolder == folder } ? base.id : folder
        label = spec.label
        assetFolder = folder
        fallbackFolder = spec.fallbackFolder ?? (base.assetFolder == folder ? base.fallbackFolder : (base.assetFolder.isEmpty ? nil : base.assetFolder))
        isLight = spec.light ?? base.isLight
        palette = base.palette.applying(spec.parsedColors)
        fontDesign = Self.design(spec.fonts?.text) ?? base.fontDesign
        numberDesign = Self.design(spec.fonts?.number) ?? base.numberDesign
        self.spec = spec
    }

    private init(id: String, label: String, assetFolder: String, fallbackFolder: String?, isLight: Bool, palette: ThemePalette, fontDesign: Font.Design, numberDesign: Font.Design, spec: ThemeSpec?) {
        self.id = id; self.label = label; self.assetFolder = assetFolder; self.fallbackFolder = fallbackFolder; self.isLight = isLight
        self.palette = palette; self.fontDesign = fontDesign; self.numberDesign = numberDesign; self.spec = spec
    }

    private static func design(_ s: String?) -> Font.Design? {
        switch s {
        case "serif": return .serif
        case "rounded": return .rounded
        case "monospaced": return .monospaced
        case "default": return .default
        default: return nil
        }
    }
}

struct ThemePalette {
    var background: Color
    var surface: Color
    var surfaceRaised: Color
    var accent: Color
    var secondary: Color
    var sun: Color
    var daylight: Color
    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color
    var faded: Color
    var sea: Color
    var moon: Color
    var saturday: Color
    var holiday: Color
    var panel: Color
    /// 背景画像の上に敷く幕（文字の読みやすさのため）。`.clear` で無し
    var scrim: Color

    /// `theme.json` の colors で上書きする（キーは ThemeSpec の説明のとおり）
    func applying(_ colors: [String: HexColor]) -> ThemePalette {
        guard !colors.isEmpty else { return self }
        func c(_ key: String, _ current: Color) -> Color {
            guard let h = colors[key] else { return current }
            return Color(red: h.r, green: h.g, blue: h.b, opacity: h.a)
        }
        var p = self
        p.background = c("background", p.background); p.surface = c("surface", p.surface); p.surfaceRaised = c("surfaceRaised", p.surfaceRaised)
        p.accent = c("accent", p.accent); p.secondary = c("secondary", p.secondary); p.sun = c("sun", p.sun); p.daylight = c("daylight", p.daylight)
        p.textPrimary = c("textPrimary", p.textPrimary); p.textSecondary = c("textSecondary", p.textSecondary); p.textTertiary = c("textTertiary", p.textTertiary)
        p.faded = c("faded", p.faded); p.sea = c("sea", p.sea); p.moon = c("moon", p.moon); p.saturday = c("saturday", p.saturday); p.holiday = c("holiday", p.holiday)
        p.panel = c("panel", p.panel); p.scrim = c("scrim", p.scrim)
        return p
    }

    static let dark = ThemePalette(
        background: Color(red: 0.043, green: 0.043, blue: 0.047),   // #0B0B0C
        surface: Color(red: 0.11, green: 0.11, blue: 0.12),
        surfaceRaised: Color(red: 0.16, green: 0.16, blue: 0.17),
        accent: Color(red: 0.45, green: 0.62, blue: 0.47),          // #739E78
        secondary: Color(red: 0.45, green: 0.62, blue: 0.47),
        sun: Color(red: 0.96, green: 0.77, blue: 0.26),             // #F5C542
        daylight: Color(red: 1.0, green: 0.478, blue: 0.102),       // #FF7A1A
        textPrimary: .white,
        textSecondary: .white.opacity(0.7),
        textTertiary: .white.opacity(0.4),
        faded: .white.opacity(0.25),
        sea: Color(red: 0.30, green: 0.62, blue: 0.95),
        moon: Color(red: 0.56, green: 0.52, blue: 0.85),
        saturday: Color(red: 0.36, green: 0.64, blue: 1.0),         // #5CA3FF
        holiday: Color(red: 1.0, green: 0.36, blue: 0.36),          // #FF5C5C
        panel: Color(red: 0.11, green: 0.11, blue: 0.12),
        scrim: .clear
    )

    /// フリーレン：白を基調にした淡い画風（霞んだ白・薄い藤色のグレー）。テーマ色は緑のまま。面は半透明の白で背景画像を透かす
    static let grimoire = ThemePalette(
        background: Color(red: 0.96, green: 0.96, blue: 0.97),      // #F5F5F7
        surface: Color.white.opacity(0.78),
        surfaceRaised: Color(red: 0.88, green: 0.88, blue: 0.91),
        accent: Color(red: 0.45, green: 0.62, blue: 0.47),          // #739E78（ダークと同じ緑）
        secondary: Color(red: 0.38, green: 0.56, blue: 0.42),       // 少し深い緑 #618F6B
        sun: Color(red: 0.85, green: 0.64, blue: 0.0),              // #D9A400（白地で読める黄）
        daylight: Color(red: 0.91, green: 0.42, blue: 0.06),        // #E86A10
        textPrimary: Color(red: 0.17, green: 0.17, blue: 0.20),     // 墨 #2B2B33
        textSecondary: Color(red: 0.17, green: 0.17, blue: 0.20).opacity(0.66),
        textTertiary: Color(red: 0.17, green: 0.17, blue: 0.20).opacity(0.42),
        faded: Color(red: 0.17, green: 0.17, blue: 0.20).opacity(0.18),
        sea: Color(red: 0.23, green: 0.50, blue: 0.84),             // #3A7FD6
        moon: Color(red: 0.48, green: 0.40, blue: 0.79),            // #7A66C9
        saturday: Color(red: 0.18, green: 0.50, blue: 0.88),
        holiday: Color(red: 0.88, green: 0.28, blue: 0.28),
        panel: Color.white.opacity(0.72),
        scrim: Color.white.opacity(0.30)
    )

    /// フリーレン 黒：漆黒に緑のテーマ色、クリームの文字、セリフ体。画像は夜の情景（無いものは白版から借りる）
    static let grimoireDark = ThemePalette(
        background: Color(red: 0.043, green: 0.043, blue: 0.047),   // #0B0B0C
        surface: Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.88),
        surfaceRaised: Color(red: 0.17, green: 0.17, blue: 0.19),
        accent: Color(red: 0.45, green: 0.62, blue: 0.47),          // #739E78
        secondary: Color(red: 0.45, green: 0.62, blue: 0.47),
        sun: Color(red: 0.96, green: 0.77, blue: 0.26),
        daylight: Color(red: 1.0, green: 0.478, blue: 0.102),
        textPrimary: Color(red: 0.95, green: 0.91, blue: 0.80),     // クリーム #F3E9CC
        textSecondary: Color(red: 0.95, green: 0.91, blue: 0.80).opacity(0.72),
        textTertiary: Color(red: 0.95, green: 0.91, blue: 0.80).opacity(0.45),
        faded: Color(red: 0.95, green: 0.91, blue: 0.80).opacity(0.25),
        sea: Color(red: 0.30, green: 0.62, blue: 0.95),
        moon: Color(red: 0.62, green: 0.56, blue: 0.90),
        saturday: Color(red: 0.36, green: 0.64, blue: 1.0),
        holiday: Color(red: 1.0, green: 0.36, blue: 0.36),
        panel: Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.82),
        scrim: Color.black.opacity(0.30)
    )

    /// 転スラ：漆黒にリムルの水色。面は半透明の黒で背景画像（各キャラの色の亀裂）を透かす
    static let tensura = ThemePalette(
        background: Color(red: 0.04, green: 0.04, blue: 0.05),      // #0A0A0C
        surface: Color(red: 0.08, green: 0.08, blue: 0.10).opacity(0.90),
        surfaceRaised: Color(red: 0.16, green: 0.16, blue: 0.19),
        accent: Color(red: 0.37, green: 0.83, blue: 0.95),          // リムルの水色 #5FD3F3
        secondary: Color(red: 0.37, green: 0.83, blue: 0.95),
        sun: Color(red: 0.96, green: 0.77, blue: 0.26),
        daylight: Color(red: 1.0, green: 0.478, blue: 0.102),
        textPrimary: .white,
        textSecondary: .white.opacity(0.72),
        textTertiary: .white.opacity(0.45),
        faded: .white.opacity(0.25),
        sea: Color(red: 0.30, green: 0.62, blue: 0.95),
        moon: Color(red: 0.62, green: 0.56, blue: 0.90),
        saturday: Color(red: 0.36, green: 0.64, blue: 1.0),
        holiday: Color(red: 1.0, green: 0.36, blue: 0.36),
        panel: Color(red: 0.08, green: 0.08, blue: 0.10).opacity(0.82),
        scrim: Color.black.opacity(0.25)
    )
}

/// 選択中のテーマ。`@Observable` なので、`DS.Color.*` を読む全ビューが切替で再描画される
@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()
    static let key = "fog.theme"

    var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Self.key)
            ThemeAssets.clear()
            palette = theme.palette; fontDesign = theme.fontDesign; numberDesign = theme.numberDesign
            ChartStyle.skin = ChartSkinValues(theme: theme)
        }
    }
    /// `DS.Color` / `DS.Font` が毎回読む値。観測の対象から外して（切替は `RootTabView` の `.id(theme)` で全画面を作り直す）、
    /// 1 フレームに何千回も `theme` 全体（ThemeSpec を含む）を複製しないようにする（2026-11-09 処理速度）
    @ObservationIgnored private(set) var palette: ThemePalette
    @ObservationIgnored private(set) var fontDesign: Font.Design
    @ObservationIgnored private(set) var numberDesign: Font.Design

    private init() {
        let t = AppTheme.find(id: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .dark
        theme = t
        palette = t.palette; fontDesign = t.fontDesign; numberDesign = t.numberDesign
        ChartStyle.skin = ChartSkinValues(theme: t)
    }
}

/// テーマ画像の読み込み。`Themes/<theme>/<name>.(png|jpg|jpeg)` をバンドルから探す。無ければ nil
@MainActor
enum ThemeAssets {
    /// 画面ごとの画像名（開発者が用意するファイル名）
    enum Name: String, CaseIterable {
        case bgHome = "bg_home"
        case bgLog = "bg_log"
        case bgGuide = "bg_guide"
        case bgSpots = "bg_spots"
        case bgSheet = "bg_sheet"
        case tabbar = "tabbar"
        case tabHome = "tab_home"
        case tabLog = "tab_log"
        case tabCamera = "tab_camera"
        case tabGuide = "tab_guide"
        case tabSpots = "tab_spots"
        case ringHome = "ring_home"
        case charHome = "char_home"
        case charLog = "char_log"
        case charGuide = "char_guide"
        case charSpots = "char_spots"
        case bgDetail = "bg_detail"

        /// キャラクターの切り抜き（位置とサイズを設定で微調整できる）
        var isCharacter: Bool { self == .charHome || self == .charLog || self == .charGuide || self == .charSpots }

        var note: String {
            switch self {
            case .bgHome: return "ホームの背景（縦 9:16）"
            case .bgLog: return "記録の背景（縦 9:16）"
            case .bgGuide: return "図鑑の背景（縦 9:16）"
            case .bgSpots: return "釣り場の一覧シートの背景（縦 9:16）"
            case .bgSheet: return "設定・各シートの背景（縦 9:16）"
            case .tabbar: return "タブバーの帯（横 3:1）"
            case .tabHome: return "タブ：ホーム（正方形・マゼンタ背景）"
            case .tabLog: return "タブ：記録（正方形・マゼンタ背景）"
            case .tabCamera: return "タブ：撮影（正方形・マゼンタ背景）"
            case .tabGuide: return "タブ：図鑑（正方形・マゼンタ背景）"
            case .tabSpots: return "タブ：釣り場（正方形・マゼンタ背景）"
            case .ringHome: return "ホームの釣れ率の飾り枠（正方形・マゼンタ背景・中央は空ける）"
            case .charHome: return "ホーム：釣れ率の円を両手で囲むキャラクター（横 16:9・円は高さの 44%）"
            case .charLog: return "記録：右上のキャラクター（縦 3:4・マゼンタ背景）"
            case .charGuide: return "図鑑：右上のキャラクター（縦 3:4・マゼンタ背景）"
            case .charSpots: return "釣り場：地図の左上のキャラクター（縦 3:4・マゼンタ背景）"
            case .bgDetail: return "釣行詳細・各シートの背景（縦 9:16）"
            }
        }
    }

    /// 読み込んだ画像と、重ね方（背景の色から自動で決める）
    struct Loaded {
        enum Blend { case opaque, screen, keyed }
        let image: UIImage
        let blend: Blend
    }

    private static var cache: [String: Loaded?] = [:]

    static func clear() { cache.removeAll(); circleCache.removeAll() }

    static func image(_ name: Name) -> UIImage? { load(name)?.image }
    static func has(_ name: Name) -> Bool { load(name) != nil }
    static func has(_ name: Name, theme: AppTheme) -> Bool { load(name, theme: theme) != nil }

    /// ファイルがあるかだけ（画像を読み込まない。設定 > テーマ の一覧用。読み込みと透明化は 1 枚数百 ms かかる）
    static func exists(_ name: Name, theme: AppTheme) -> Bool {
        guard theme.hasAssets else { return false }
        let dirs = [directory(for: theme), theme.fallbackFolder.flatMap { directory(named: $0) }].compactMap { $0 }
        for dir in dirs {
            for ext in ["png", "jpg", "jpeg", "PNG", "JPG"] where FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(name.rawValue).\(ext)").path) { return true }
        }
        return false
    }
    static func image(_ name: Name, theme: AppTheme) -> UIImage? { load(name, theme: theme)?.image }

    static func load(_ name: Name) -> Loaded? { load(name, theme: ThemeStore.shared.theme) }
    static func load(_ name: Name, theme: AppTheme) -> Loaded? { load(named: name.rawValue, theme: theme) }

    /// 任意のファイル名で読む（`theme.json` の layers / button が使う。F-58）
    static func load(named raw: String) -> Loaded? { load(named: raw, theme: ThemeStore.shared.theme) }

    static func load(named raw: String, theme: AppTheme) -> Loaded? {
        guard theme.hasAssets, !raw.isEmpty, !raw.contains("/"), !raw.contains("..") else { return nil }
        let key = "\(theme.rawValue)/\(raw)"
        if let cached = cache[key] { return cached }
        var found: Loaded?
        let dirs = [directory(for: theme), theme.fallbackFolder.flatMap { directory(named: $0) }].compactMap { $0 }
        search: for dir in dirs {
            for ext in ["png", "jpg", "jpeg", "PNG", "JPG"] {
                let url = dir.appendingPathComponent("\(raw).\(ext)")
                if FileManager.default.fileExists(atPath: url.path), let image = UIImage(contentsOfFile: url.path) {
                    found = Perf.measure("テーマ画像の読み込み \(raw)") { prepare(image) }
                    break search
                }
            }
        }
        cache[key] = found
        return found
    }

    /// テーマの画像フォルダ。フォルダ参照の置かれ方の違いに備えて、バンドル直下の `Themes/<theme>`、`<theme>`、
    /// そしてバンドル内を 2 階層まで探して `<theme>` という名前のフォルダを使う
    static func directory(for theme: AppTheme) -> URL? { directory(named: theme.assetFolder) }

    static func directory(named folder: String) -> URL? {
        guard !folder.isEmpty, let root = Bundle.main.resourceURL else { return nil }
        let fm = FileManager.default
        var candidates = [root.appendingPathComponent("Themes/\(folder)"), root.appendingPathComponent(folder)]
        if let sub = Bundle.main.url(forResource: folder, withExtension: nil, subdirectory: "Themes") { candidates.append(sub) }
        for c in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c.path, isDirectory: &isDir), isDir.boolValue { return c }
        }
        // 2 階層まで探す
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in e {
                if e.level > 2 { e.skipDescendants(); continue }
                if url.lastPathComponent == folder, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return url }
            }
        }
        return nil
    }

    /// 設定 > テーマ の診断用：フォルダの場所とファイル数
    static func diagnostics(for theme: AppTheme) -> String {
        guard let dir = directory(for: theme) else {
            let top = (try? FileManager.default.contentsOfDirectory(atPath: Bundle.main.resourceURL?.path ?? "")) ?? []
            return "画像フォルダが見つかりません（バンドル直下: \(top.prefix(12).joined(separator: ", "))）"
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let rel = dir.path.replacingOccurrences(of: Bundle.main.resourceURL?.path ?? "", with: "")
        return "フォルダ \(rel)：\(files.count) ファイル"
    }

    /// 四隅の色で背景を判定する。マゼンタ（#FF00FF 付近）なら透過に抜き、黒なら screen で重ね、それ以外はそのまま
    private static func prepare(_ image: UIImage) -> Loaded {
        guard let corner = cornerColor(image) else { return Loaded(image: image, blend: .opaque) }
        // すでに透過 PNG（四隅が透明）ならそのまま重ねる
        if corner.a < 0.1 { return Loaded(image: image, blend: .keyed) }
        if corner.r > 0.6 && corner.g < 0.45 && corner.b > 0.45 && corner.r - corner.g > 0.3 {
            if let keyed = chromaKeyed(image) { return Loaded(image: keyed, blend: .keyed) }
            return Loaded(image: image, blend: .opaque)
        }
        if corner.r < 0.12 && corner.g < 0.12 && corner.b < 0.12 {
            // 黒背景：明るさを不透明度に変換して透過画像にする（screen 合成はボタンの中など別レイヤーでは効かないため使わない）
            if let keyed = luminanceKeyed(image) { return Loaded(image: keyed, blend: .keyed) }
            return Loaded(image: image, blend: .screen)
        }
        return Loaded(image: image, blend: .opaque)
    }

    /// 明るさ（最大チャンネル）をそのまま不透明度にする。黒は透明、鮮やかな色と白は不透明
    private static func luminanceKeyed(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let size = 32
        var cube = [Float](repeating: 0, count: size * size * size * 4)
        var i = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let rf = Float(r) / Float(size - 1), gf = Float(g) / Float(size - 1), bf = Float(b) / Float(size - 1)
                    let alpha = max(rf, gf, bf)
                    // 乗算済みアルファ：色はそのまま（最大チャンネル＝alpha なので色 ≤ alpha を満たす）
                    cube[i] = rf; cube[i + 1] = gf; cube[i + 2] = bf; cube[i + 3] = alpha
                    i += 4
                }
            }
        }
        return applyCube(cube, size: size, to: cg, like: image)
    }

    private static func applyCube(_ cube: [Float], size: Int, to cg: CGImage, like image: UIImage) -> UIImage? {
        let filter = CIFilter.colorCube()
        filter.cubeDimension = Float(size)
        filter.cubeData = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        filter.inputImage = CIImage(cgImage: cg)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: nil)
        guard let out = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
    }

    /// 縁に沿った 8 点（角から 4% 内側）の平均色と不透明度（0〜1）。生成画像の角の滲みに引きずられないようにする
    private static func cornerColor(_ image: UIImage) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w > 16, h > 16 else { return nil }
        let ix = max(2, w / 25), iy = max(2, h / 25)
        var sum = (r: 0.0, g: 0.0, b: 0.0, a: 0.0)
        var count = 0.0
        for (x, y) in [(ix, iy), (w - 1 - ix, iy), (ix, h - 1 - iy), (w - 1 - ix, h - 1 - iy), (w / 2, iy), (w / 2, h - 1 - iy), (ix, h / 2), (w - 1 - ix, h / 2)] {
            var px = [UInt8](repeating: 0, count: 4)
            guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.draw(cg, in: CGRect(x: -x, y: -(h - 1 - y), width: w, height: h))
            let a = Double(px[3]) / 255
            // 乗算済みなので色は不透明度で割って戻す
            let d = max(a, 0.001)
            sum.r += Double(px[0]) / 255 / d; sum.g += Double(px[1]) / 255 / d; sum.b += Double(px[2]) / 255 / d; sum.a += a
            count += 1
        }
        guard count > 0 else { return nil }
        return (sum.r / count, sum.g / count, sum.b / count, sum.a / count)
    }

    /// マゼンタ系（色相 285〜335°、彩度 0.45 以上、明度 0.35 以上）を透明にする色立方体フィルタ
    private static func chromaKeyed(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let size = 32
        var cube = [Float](repeating: 0, count: size * size * size * 4)
        var i = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let rf = Float(r) / Float(size - 1), gf = Float(g) / Float(size - 1), bf = Float(b) / Float(size - 1)
                    let (h, sat, val) = hsv(rf, gf, bf)
                    let isKey = sat >= 0.45 && val >= 0.35 && h >= 285 && h <= 335
                    // 境界は少しだけ半透明にして縁のマゼンタのにじみを減らす
                    let edge = sat >= 0.3 && val >= 0.3 && h >= 275 && h <= 345
                    let alpha: Float = isKey ? 0 : (edge ? 0.5 : 1)
                    cube[i] = rf * alpha; cube[i + 1] = gf * alpha; cube[i + 2] = bf * alpha; cube[i + 3] = alpha
                    i += 4
                }
            }
        }
        return applyCube(cube, size: size, to: cg, like: image)
    }

    private static func hsv(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        var h: Float = 0
        if d > 0 {
            if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
            if h < 0 { h += 360 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    // MARK: ホームの円の位置（画像ごとの JSON）

    /// 画像の中で「釣れ率の円」が占める位置と大きさ（画像の幅・高さに対する割合）。`<name>.json` に `{"cx":0.5,"cy":0.6,"d":0.4}` で置く
    struct CircleSpec: Decodable {
        var cx: Double = 0.5
        var cy: Double = 0.5
        var d: Double = 0.44
    }

    private static var circleCache: [String: CircleSpec] = [:]

    static func circle(_ name: Name) -> CircleSpec {
        let theme = ThemeStore.shared.theme
        let key = "\(theme.rawValue)/\(name.rawValue)"
        if let c = circleCache[key] { return c }
        var spec = CircleSpec()
        for dir in [directory(for: theme), theme.fallbackFolder.flatMap { directory(named: $0) }].compactMap({ $0 }) {
            let url = dir.appendingPathComponent("\(name.rawValue).json")
            if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(CircleSpec.self, from: data) { spec = decoded; break }
        }
        circleCache[key] = spec
        return spec
    }

    // MARK: キャラクターの位置の微調整（設定 > テーマ）

    static func scale(_ name: Name) -> Double {
        let v = UserDefaults.standard.double(forKey: "fog.theme.\(name.rawValue).scale")
        return v == 0 ? 1 : v
    }
    static func offset(_ name: Name) -> CGSize {
        CGSize(width: UserDefaults.standard.double(forKey: "fog.theme.\(name.rawValue).dx"),
               height: UserDefaults.standard.double(forKey: "fog.theme.\(name.rawValue).dy"))
    }
    static func setScale(_ name: Name, _ v: Double) { UserDefaults.standard.set(v, forKey: "fog.theme.\(name.rawValue).scale") }
    static func setOffset(_ name: Name, _ v: CGSize) {
        UserDefaults.standard.set(v.width, forKey: "fog.theme.\(name.rawValue).dx")
        UserDefaults.standard.set(v.height, forKey: "fog.theme.\(name.rawValue).dy")
    }
}

/// 画面の背景：テーマ画像があれば全面に敷き（はみ出しは切る）、暗幕を重ねる。無ければテーマの背景色
struct ThemeBackground: View {
    let name: ThemeAssets.Name

    var body: some View {
        let theme = ThemeStore.shared.theme
        ZStack {
            theme.palette.background
            if let image = ThemeAssets.image(name, theme: theme) {
                GeometryReader { geo in
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                }
                theme.palette.scrim
            }
        }
        .ignoresSafeArea()
    }
}

/// テーマの `style.borderColor` があるときだけ、面の輪郭線を描く（F-58）。無いテーマでは何も描かない（標準は枠線なし）
struct ThemeOutline: View {
    var cornerRadius: CGFloat
    var body: some View {
        let theme = ThemeStore.shared.theme
        if let color = theme.outlineColor {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(color, lineWidth: theme.outlineWidth)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// 面の上にテーマの輪郭線を重ねる。丸い面（Capsule）は大きな半径（999）を渡す
    func themeOutline(_ cornerRadius: CGFloat) -> some View { overlay { ThemeOutline(cornerRadius: cornerRadius) } }
}

/// 黒背景で描かれた飾り画像（タブのアイコン・飾り枠）を、黒を透かして重ねる
struct ThemeOrnament: View {
    let name: ThemeAssets.Name
    var body: some View {
        if let loaded = ThemeAssets.load(name) {
            Image(uiImage: loaded.image).resizable().aspectRatio(contentMode: .fit)
                .blendMode(loaded.blend == .screen ? .screen : .normal)
        }
    }
}

/// キャラクターの切り抜き（F-49）。`baseWidth` を基準に、設定の倍率と位置ずらしを掛けて置く。
/// 画面の内容より後ろに置く（`.background(alignment:)` で使う）
struct ThemeCharacter: View {
    let name: ThemeAssets.Name
    let baseWidth: CGFloat
    /// 設定画面で調整中の値を即時に反映するための tick
    var revision: Int = ThemeLayoutTuning.shared.revision

    var body: some View {
        if let loaded = ThemeAssets.load(name) {
            let scale = ThemeAssets.scale(name)
            let offset = ThemeAssets.offset(name)
            Image(uiImage: loaded.image).resizable().aspectRatio(contentMode: .fit)
                .blendMode(loaded.blend == .screen ? .screen : .normal)
                .frame(width: baseWidth * scale)
                .offset(offset)
                .allowsHitTesting(false)
        }
    }
}

/// 設定で倍率・位置を動かしたときに、置いてある画面を再描画させるための観測点
@MainActor
@Observable
final class ThemeLayoutTuning {
    static let shared = ThemeLayoutTuning()
    var revision = 0
}
