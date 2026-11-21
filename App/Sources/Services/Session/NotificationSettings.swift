import Foundation

/// 通知の種類ごとのオンオフ（§8）。既定はすべてオン。
enum NotificationSettings {
    enum Kind: String, CaseIterable, Identifiable {
        case sessionStart, sessionEnd, record, peak, dailyBrief, safety, rain, snag, inventory
        var id: String { rawValue }

        var title: String {
            switch self {
            case .sessionStart: return "釣行開始"
            case .sessionEnd: return "釣行終了"
            case .record: return "記録更新"
            case .peak: return "釣れ率ピーク"
            case .dailyBrief: return "明日のベストタイム"
            case .safety: return "安全"
            case .rain: return "雨の前"
            case .snag: return "根掛かり注意"
            case .inventory: return "在庫"
            }
        }

        var detail: String {
            switch self {
            case .sessionStart: return "記録を始めたとき。誤検出なら通知から停止"
            case .sessionEnd: return "レポートの要約と尾数"
            case .record: return "初魚種・自己記録（アプリを閉じているときだけ）"
            case .peak: return "今日のピークが 80 以上のとき、1 時間前に 1 回"
            case .dailyBrief: return "毎晩 20 時に、明日の最良の時間帯を 1 通（ホームの釣り場）"
            case .safety: return "釣行中：日の入り 30 分前・満潮 1 時間前・帰る時間"
            case .rain: return "釣行中：雨や雪が降り出す 30 分ほど前に「約 ◯ 分後に雨」"
            case .snag: return "釣行中：過去に針を失った場所に入ったとき"
            case .inventory: return "針ロストで在庫がしきい値を下回ったとき"
            }
        }

        fileprivate var key: String { "fog.notify.\(rawValue)" }
    }

    static func isEnabled(_ kind: Kind) -> Bool {
        UserDefaults.standard.object(forKey: kind.key) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, for kind: Kind) {
        UserDefaults.standard.set(enabled, forKey: kind.key)
    }

    // MARK: 明日のベストタイム（F-28）の条件

    private static let briefWeekendOnlyKey = "fog.notify.brief.weekendOnly"
    private static let briefRegisteredOnlyKey = "fog.notify.brief.registeredOnly"

    /// 週末（土日祝）の前夜だけ送る
    static var briefWeekendOnly: Bool {
        get { UserDefaults.standard.bool(forKey: briefWeekendOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: briefWeekendOnlyKey) }
    }

    /// 登録した釣り場を見ているときだけ送る（現在地のときは送らない）。既定オン
    static var briefRegisteredOnly: Bool {
        get { UserDefaults.standard.object(forKey: briefRegisteredOnlyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: briefRegisteredOnlyKey) }
    }

    // MARK: 安全通知（F-36）の帰る時間

    private static let homeTimeKey = "fog.notify.safety.homeTimeMinutes"

    /// 帰る時間（0 時からの分）。未設定は nil
    static var homeTimeMinutes: Int? {
        get { UserDefaults.standard.object(forKey: homeTimeKey) as? Int }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: homeTimeKey) } else { UserDefaults.standard.removeObject(forKey: homeTimeKey) }
        }
    }
}
