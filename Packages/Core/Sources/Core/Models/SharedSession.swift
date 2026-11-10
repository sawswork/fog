import Foundation

/// 仲間と共有する釣行の要約（F-62）。釣果（`SharedCatch`）と同じ公開データベースの同じレコード型に、`payload` の JSON として置く。
/// 釣果が 1 尾も無い釣行（ボウズ）も仲間に見える。釣果そのものは `SharedCatch` を端末と時刻で引き当てる。
public struct SharedSession: Codable, Identifiable, Hashable, Sendable {
    /// 元の `Session.id`
    public var id: UUID
    /// 常に "session"（`SharedCatch` の JSON と見分ける）
    public var kind: String
    /// 端末の持ち主の名前
    public var owner: String
    /// 投稿した端末
    public var device: String
    public var startedAt: Date
    /// nil は記録中
    public var endedAt: Date?
    public var spotName: String
    public var coordinate: Coordinate
    /// この釣行で魚を記録した人（端末の持ち主を含む）
    public var anglers: [String]
    public var catchCount: Int
    public var updatedAt: Date

    public static let kindValue = "session"

    public init(id: UUID, owner: String, device: String, startedAt: Date, endedAt: Date?, spotName: String, coordinate: Coordinate,
                anglers: [String], catchCount: Int, updatedAt: Date) {
        self.id = id; self.kind = Self.kindValue; self.owner = owner; self.device = device; self.startedAt = startedAt; self.endedAt = endedAt
        self.spotName = spotName; self.coordinate = coordinate; self.anglers = anglers; self.catchCount = catchCount; self.updatedAt = updatedAt
    }

    /// 釣行から作る。`angler` が無い釣果は端末の持ち主（`ownName`）の魚
    public static func make(from session: Session, spot: Spot?, ownName: String, device: String, updatedAt: Date = .now) -> SharedSession {
        var names: [String] = [ownName]
        for c in session.catches {
            let n = (c.angler?.isEmpty == false ? c.angler : nil) ?? ownName
            if !names.contains(n) { names.append(n) }
        }
        // 釣り場の位置。無ければ最初の釣果、それも無ければ軌跡の最初
        let coordinate = [spot?.coordinate, session.catches.first?.coordinate, session.track.first?.coordinate]
            .compactMap { $0 }.first { $0.isPlausible } ?? Coordinate(latitude: 0, longitude: 0)
        return SharedSession(id: session.id, owner: ownName, device: device, startedAt: session.startedAt, endedAt: session.endedAt,
                             spotName: spot?.name ?? "", coordinate: coordinate, anglers: names, catchCount: session.catches.count, updatedAt: updatedAt)
    }

    /// 内容の鍵（変わったときだけ送り直す）
    public var contentKey: String {
        "s1|\(owner)|\(startedAt.timeIntervalSince1970)|\(endedAt?.timeIntervalSince1970 ?? -1)|\(spotName)|\(coordinate.latitude),\(coordinate.longitude)|\(catchCount)|\(anglers.joined(separator: ","))"
    }

    /// 公開データベースのレコード名
    public var recordName: String { Self.recordName(for: id) }
    public static let recordPrefix = "session-"
    public static func recordName(for id: UUID) -> String { recordPrefix + id.uuidString }
}
