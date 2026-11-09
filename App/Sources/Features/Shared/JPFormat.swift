import Foundation

/// 端末の言語が英語でも日本語の日付表記にする（「Nov 8」ではなく「11/8(日)」。2026-11-09 実機フィードバック：図鑑・ログが読みにくい）
enum JPFormat {
    static let tz = TimeZone(identifier: "Asia/Tokyo") ?? .current
    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = tz
        f.dateFormat = pattern
        return f
    }
    private static let mdF = formatter("M/d")
    private static let mdwF = formatter("M/d(E)")
    private static let ymdwF = formatter("yyyy/M/d(E)")
    private static let hmF = formatter("H:mm")
    private static let mdhmF = formatter("M/d H:mm")

    /// 11/8
    static func md(_ d: Date) -> String { mdF.string(from: d) }
    /// 11/8(日)
    static func mdw(_ d: Date) -> String { mdwF.string(from: d) }
    /// 2026/11/8(日)
    static func ymdw(_ d: Date) -> String { ymdwF.string(from: d) }
    /// 15:29
    static func hm(_ d: Date) -> String { hmF.string(from: d) }
    /// 11/8 15:29
    static func mdhm(_ d: Date) -> String { mdhmF.string(from: d) }
    /// 1時間44分
    static func duration(_ seconds: TimeInterval) -> String {
        let m = max(0, Int(seconds / 60))
        return m >= 60 ? "\(m / 60)時間\(m % 60 == 0 ? "" : "\(m % 60)分")" : "\(m)分"
    }
}
