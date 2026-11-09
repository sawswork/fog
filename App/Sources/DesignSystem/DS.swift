import SwiftUI

/// デザイントークン。docs/02_ui_design.md §1 が正。
/// 値は選択中のテーマ（`ThemeStore.shared.theme`、F-49）から取る。`ThemeStore` は `@Observable` なので切替で再描画される
enum DS {
    @MainActor private static var palette: ThemePalette { ThemeStore.shared.palette }

    enum Color {
        @MainActor static var background: SwiftUI.Color { palette.background }
        @MainActor static var surface: SwiftUI.Color { palette.surface }
        @MainActor static var surfaceRaised: SwiftUI.Color { palette.surfaceRaised }
        /// テーマ色：緑（2026-11-04 実機フィードバックでオレンジ #FF7A1A から変更）。魔導書テーマでは金
        @MainActor static var accent: SwiftUI.Color { palette.accent }
        @MainActor static var secondary: SwiftUI.Color { palette.secondary }
        /// マズメの帯（黄）
        @MainActor static var sun: SwiftUI.Color { palette.sun }
        /// 日の出・日の入（オレンジ）
        @MainActor static var daylight: SwiftUI.Color { palette.daylight }
        @MainActor static var textPrimary: SwiftUI.Color { palette.textPrimary }
        @MainActor static var textSecondary: SwiftUI.Color { palette.textSecondary }
        @MainActor static var textTertiary: SwiftUI.Color { palette.textTertiary }
        /// 予報が届かない先・低確信度
        @MainActor static var faded: SwiftUI.Color { palette.faded }
        /// 潮位の曲線（海の青）
        @MainActor static var sea: SwiftUI.Color { palette.sea }
        /// 月相アイコン（薄い紫）
        @MainActor static var moon: SwiftUI.Color { palette.moon }
        /// 週行の土曜（日付と曜日の文字だけ）
        @MainActor static var saturday: SwiftUI.Color { palette.saturday }
        /// 週行の日曜・祝日（日付と曜日の文字だけ）
        @MainActor static var holiday: SwiftUI.Color { palette.holiday }
        /// グラフのパネル・チップの枠なし面
        @MainActor static var panel: SwiftUI.Color { palette.panel }
    }

    enum Font {
        @MainActor static func score(_ size: CGFloat = 96) -> SwiftUI.Font { .system(size: size, weight: .bold, design: ThemeStore.shared.numberDesign) }
        @MainActor static func number(_ size: CGFloat = 20) -> SwiftUI.Font { .system(size: size, weight: .semibold, design: ThemeStore.shared.numberDesign) }
        @MainActor static var label: SwiftUI.Font { .system(size: 13, weight: .medium, design: ThemeStore.shared.fontDesign) }
        @MainActor static var caption: SwiftUI.Font { .system(size: 11, weight: .regular, design: ThemeStore.shared.fontDesign) }
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 20
        static let chip: CGFloat = 14
    }
}
