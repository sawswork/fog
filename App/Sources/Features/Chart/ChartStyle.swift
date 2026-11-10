import SwiftUI
import UIKit
import Core

/// 新しい 1 画面「海図」（F-63）の色と素材。テーマには従わない（どのテーマを選んでいても同じ見た目）。
/// 強調のオレンジは「押すところ」「釣れる時間」「投げる場所」だけに使う
enum ChartStyle {
    static let bg = Color(red: 0.024, green: 0.039, blue: 0.059)
    static let white = Color(red: 0.953, green: 0.965, blue: 0.973)
    static let gray1 = Color(red: 0.64, green: 0.68, blue: 0.72)
    static let gray2 = Color(red: 0.42, green: 0.47, blue: 0.51)
    static let orange = Color(red: 1.0, green: 0.478, blue: 0.102)
    static let cyan = Color(red: 0.39, green: 0.84, blue: 0.90)
    static let panel = Color(red: 0.055, green: 0.082, blue: 0.11)
    /// 設定の鍵：true（既定）で海図の 1 画面、false でこれまでのタブとテーマ
    static let modeKey = "fog.ui.chart"
}

/// 海図の画面の画像。`ChartUI/`（ボタン・計器・待機の背景）と `Charts/`（港の海図）はフォルダ参照で同梱する
@MainActor
enum ChartAssets {
    private static var cache: [String: UIImage] = [:]

    static func ui(_ file: String) -> UIImage? { load(file, directory: "ChartUI") }
    static func chart(id: String) -> UIImage? { load(id + ".jpg", directory: "Charts") }

    private static func load(_ file: String, directory: String) -> UIImage? {
        let key = directory + "/" + file
        if let cached = cache[key] { return cached }
        let name = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: directory)
                ?? Bundle.main.url(forResource: name, withExtension: ext),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache[key] = image
        return image
    }
}
