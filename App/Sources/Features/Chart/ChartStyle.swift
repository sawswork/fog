import SwiftUI
import UIKit
import Core

/// 海図の 1 画面（F-63）の見た目ひとそろい。標準は濃紺にオレンジ。テーマの `theme.json` の `chart` で色・書体・配置を着せ替える
struct ChartSkinValues {
    var bg = Color(red: 0.024, green: 0.039, blue: 0.059)
    var text = Color(red: 0.953, green: 0.965, blue: 0.973)
    var sub = Color(red: 0.64, green: 0.68, blue: 0.72)
    var dim = Color(red: 0.42, green: 0.47, blue: 0.51)
    /// 強調（押すところ・釣れる時間・投げる場所）
    var accent = Color(red: 1.0, green: 0.478, blue: 0.102)
    /// 潮
    var tide = Color(red: 0.39, green: 0.84, blue: 0.90)
    var panel = Color(red: 0.055, green: 0.082, blue: 0.11)
    /// 面の輪郭線。nil は標準（薄い白）
    var border: Color?
    /// 強調色の面に載せる文字
    var onAccent = Color(red: 0.024, green: 0.039, blue: 0.059)
    var design: Font.Design = .default
    var numberDesign: Font.Design = .default
    var idleNumberSize: CGFloat = 124
    var idleFaceGap: CGFloat?
    var idleTopScrim: Double = 0
    var idleBottomScrim: Double = 1
    /// 待機中の背景全体を暗くする濃さ（標準の海図は 0.25。着せ替えは絵をそのまま見せる）
    var idleDim: Double = 0.25
    var idleEffects: [String] = []
    var mapFrame = false
    /// ボタンのまわりの光の強さ（0〜1）
    var glow: Double = 1
    var menuPanel = false
    /// 素材を探すテーマのフォルダ（無ければ標準の `ChartUI/`）
    var folder: URL?

    static let standard = ChartSkinValues()

    @MainActor
    init(theme: AppTheme) {
        self.init()
        folder = theme.isChart ? ThemeAssets.directory(for: theme) : nil
        guard let skin = theme.spec?.chart else { return }
        let colors = skin.parsedColors
        func color(_ key: String, _ current: Color) -> Color {
            guard let h = colors[key] else { return current }
            return Color(red: h.r, green: h.g, blue: h.b, opacity: h.a)
        }
        bg = color("background", bg); text = color("text", text); sub = color("sub", sub); dim = color("dim", dim)
        accent = color("accent", accent); tide = color("tide", tide); panel = color("panel", panel)
        onAccent = color("onAccent", bg)
        if colors["border"] != nil { border = color("border", .white) }
        design = Self.design(skin.font) ?? .default
        numberDesign = Self.design(skin.numberFont) ?? design
        idleNumberSize = CGFloat(skin.resolvedIdleNumberSize)
        idleFaceGap = skin.resolvedIdleFaceGap.map { CGFloat($0) }
        idleTopScrim = skin.resolvedIdleTopScrim
        idleBottomScrim = skin.resolvedIdleBottomScrim
        idleEffects = skin.idleEffects ?? []
        idleDim = 0.06
        mapFrame = skin.mapFrame == true
        menuPanel = skin.usesMenuPanel
        glow = skin.resolvedGlow
    }

    private init() {}

    private static func design(_ name: String?) -> Font.Design? {
        switch name {
        case "serif": return .serif
        case "rounded": return .rounded
        case "monospaced": return .monospaced
        case "default": return .default
        default: return nil
        }
    }
}

/// 海図の画面が読む色と書体。テーマの切替のたびに `ThemeStore` が `skin` を入れ替える（画面は `.id(theme)` で作り直される）
enum ChartStyle {
    static var skin = ChartSkinValues.standard

    static var bg: Color { skin.bg }
    static var white: Color { skin.text }
    static var gray1: Color { skin.sub }
    static var gray2: Color { skin.dim }
    static var orange: Color { skin.accent }
    static var cyan: Color { skin.tide }
    static var panel: Color { skin.panel }
    /// 面の輪郭線（テーマが決めていなければ薄い白）
    static var border: Color { skin.border ?? Color.white.opacity(0.13) }
    static var onAccent: Color { skin.onAccent }

    /// 文字。12 pt より小さい字は、テーマが明朝（serif）でも標準の書体のまま（細い明朝は小さいと読みにくい）
    static func font(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: size < 12 && skin.design == .serif ? .default : skin.design)
    }
    static func number(_ size: CGFloat, _ weight: Font.Weight) -> Font { .system(size: size, weight: weight, design: skin.numberDesign) }
}

/// 海図の画面の画像。テーマのフォルダの `chart_<名前>` を先に探し、無ければ標準の `ChartUI/<名前>`。港の海図は `Charts/`
@MainActor
enum ChartAssets {
    private static var cache: [String: UIImage] = [:]
    private static var missing = Set<String>()

    /// 例：`ui("bg_idle")` `ui("orb_start")` `ui("menu_log")`
    static func ui(_ name: String) -> UIImage? {
        let base = (name as NSString).deletingPathExtension
        if let folder = ChartStyle.skin.folder {
            let key = folder.path + "/chart_" + base
            if let cached = cache[key] { return cached }
            if !missing.contains(key) {
                for ext in ["png", "jpg", "jpeg"] {
                    let url = folder.appendingPathComponent("chart_\(base).\(ext)")
                    if let image = UIImage(contentsOfFile: url.path) { cache[key] = image; return image }
                }
                missing.insert(key)
            }
        }
        for ext in ["png", "jpg"] {
            if let image = load("\(base).\(ext)", directory: "ChartUI") { return image }
        }
        return nil
    }

    static func chart(id: String) -> UIImage? { load(id + ".jpg", directory: "Charts") }

    private static func load(_ file: String, directory: String) -> UIImage? {
        let key = directory + "/" + file
        if let cached = cache[key] { return cached }
        if missing.contains(key) { return nil }
        let name = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: directory)
                ?? Bundle.main.url(forResource: name, withExtension: ext),
              let image = UIImage(contentsOfFile: url.path) else { missing.insert(key); return nil }
        cache[key] = image
        return image
    }
}
