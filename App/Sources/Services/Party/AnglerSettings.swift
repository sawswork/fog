import Foundation
import UIKit

/// 釣り人（F-54）。自分の名前と、いっしょに釣りをする人の名前。撮影時に「誰の魚か」を選ぶ候補になる。
/// 値は App Group の UserDefaults（ウィジェットの撮影ボタンからも同じ候補を見られるように）
enum AnglerSettings {
    static let ownNameKey = "fog.angler.own"
    static let membersKey = "fog.angler.members"
    static let deviceIDKey = "fog.angler.deviceID"
    static let defaultOwnName = "自分"

    /// 自分の名前（未設定なら「自分」）
    static var ownName: String {
        get { FogShared.defaults.string(forKey: ownNameKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultOwnName }
        set { FogShared.defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: ownNameKey) }
    }

    /// 自分以外の釣り人（順番は登録順）
    static var members: [String] {
        get { FogShared.defaults.stringArray(forKey: membersKey) ?? [] }
        set { FogShared.defaults.set(newValue, forKey: membersKey) }
    }

    /// 撮影画面の候補：自分が先頭
    static var candidates: [String] { [ownName] + members.filter { $0 != ownName } }

    static func add(member: String) {
        let name = member.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ownName, !members.contains(name) else { return }
        members.append(name)
    }

    static func remove(member: String) { members.removeAll { $0 == member } }

    /// 釣果の表示名。nil（自分）は自分の名前
    static func displayName(for angler: String?) -> String {
        guard let angler, !angler.isEmpty else { return ownName }
        return angler
    }

    /// この端末の識別子（共有した釣果のうち自分の投稿を見分ける。個人情報は含まない）
    static var deviceID: String {
        if let id = FogShared.defaults.string(forKey: deviceIDKey), !id.isEmpty { return id }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        FogShared.defaults.set(id, forKey: deviceIDKey)
        return id
    }
}
