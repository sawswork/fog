import Foundation

/// 潮名（大潮・中潮・小潮・長潮・若潮）。月齢から決める一般的な区分（潮汐表・釣り情報サイトと同じ表）。
///
/// 月齢の整数部 → 潮名
/// - 大潮: 0, 1, 2, 14〜17, 29
/// - 中潮: 3〜6, 12, 13, 18〜21, 27, 28
/// - 小潮: 7〜9, 22〜24
/// - 長潮: 10, 25
/// - 若潮: 11, 26
///
/// 以前は「月齢の整数部 + 1 = 旧暦の日」と見なして旧暦の表を引いていたため 1 日ずれ、
/// 新月の前日（月齢 28.x）が大潮になっていた（2026-11-08 実機フィードバック）。
public enum TideName: String, CaseIterable, Sendable {
    case spring = "大潮", middle = "中潮", neap = "小潮", long = "長潮", young = "若潮"

    /// 月齢（0〜29.53）から潮名を返す。
    public static func from(moonAge: Double) -> TideName {
        let age = moonAge.truncatingRemainder(dividingBy: MoonCalculator.synodicMonth)
        let day = Int(age.rounded(.down))
        switch day {
        case 0...2, 14...17, 29: return .spring
        case 3...6, 12...13, 18...21, 27...28: return .middle
        case 7...9, 22...24: return .neap
        case 10, 25: return .long
        case 11, 26: return .young
        default: return .middle
        }
    }

    /// その日の潮名。1 日の中で変わらないように、その日の正午（現地時刻）の月齢で決める。
    public static func on(_ date: Date, timeZone: TimeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current) -> TideName {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let noon = cal.startOfDay(for: date).addingTimeInterval(12 * 3600)
        return from(moonAge: MoonCalculator.age(at: noon))
    }
}
