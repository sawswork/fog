import Foundation

/// 自動開始・終了の見張り（F-01 の作り直し、2026-11-19）。
///
/// 以前は「どこでも滞在を見張り、海のそばかを調べる」方式で、釣り場でない場所で始まったり、常に位置を取って電池を使ったりした。
/// いまは **登録した釣り場のまわりの境界（ジオフェンス）だけ** を OS に見張らせる。境界の出入りは OS が基地局と Wi-Fi で見ていて、
/// アプリは境界を越えたときだけ起こされる。釣り場の外ではアプリは位置を取らない。
///
/// OS が 1 つのアプリに許す境界は 20 個まで。釣り場 19 個（近い順）＋記録中の釣行 1 個に割り当てる。
public enum GeofencePlanner {
    public struct Region: Hashable, Sendable {
        public var id: String
        public var center: Coordinate
        public var radiusM: Double
        public init(id: String, center: Coordinate, radiusM: Double) { self.id = id; self.center = center; self.radiusM = radiusM }
    }

    public static let spotPrefix = "fog.spot."
    /// 記録中の釣行の境界（始めた場所が中心。出たら終了の判定を動かす）
    public static let sessionID = "fog.session"
    /// アプリが置いた境界の識別子の接頭辞
    public static let prefix = "fog."
    public static let maxSpotRegions = 19

    /// 見張る釣り場の境界。`near`（最後に分かっている位置）に近い順に `limit` 個。位置が無効な釣り場は除く。
    /// `near` が分からなければ渡された順（呼び出し側が最近使った順に並べる）
    public static func regions(spots: [(id: UUID, coordinate: Coordinate)], near: Coordinate?, radiusM: Double, limit: Int = maxSpotRegions) -> [Region] {
        var usable = spots.filter { $0.coordinate.isPlausible }
        if let near, near.isPlausible {
            usable.sort { Geo.distanceMeters($0.coordinate, near) < Geo.distanceMeters($1.coordinate, near) }
        }
        var seen = Set<UUID>()
        var out: [Region] = []
        for s in usable where seen.insert(s.id).inserted {
            if out.count >= max(0, limit) { break }
            out.append(Region(id: spotPrefix + s.id.uuidString, center: s.coordinate, radiusM: radiusM))
        }
        return out
    }

    /// 境界の識別子 → 釣り場の ID（釣り場の境界でなければ nil）
    public static func spotID(from identifier: String) -> UUID? {
        guard identifier.hasPrefix(spotPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(spotPrefix.count)))
    }

    /// いま置いてある境界と、置きたい境界の差。中心が 1 m 以上・半径が 1 m 以上違えば置き直す
    public static func diff(current: [Region], wanted: [Region]) -> (add: [Region], remove: [String]) {
        let wantedByID = Dictionary(wanted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var kept = Set<String>()
        var remove: [String] = []
        for c in current {
            if let w = wantedByID[c.id], Geo.distanceMeters(c.center, w.center) < 1, abs(c.radiusM - w.radiusM) < 1 {
                kept.insert(c.id)
            } else {
                remove.append(c.id)
            }
        }
        var added = Set<String>()
        let add = wanted.filter { !kept.contains($0.id) && added.insert($0.id).inserted }
        return (add, remove)
    }
}
