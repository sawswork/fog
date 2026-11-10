import Foundation

/// 仲間の釣行（F-62）。自分は行っていない釣行。複数の端末の記録が同じ時間・同じ場所なら 1 つにまとめる。
public struct PartyTrip: Identifiable, Hashable, Sendable {
    /// 1 台の端末の 1 回の釣行
    public struct Leg: Hashable, Sendable {
        public var sessionID: UUID
        public var device: String
        public var owner: String
        public var startedAt: Date
        public var endedAt: Date?
        public var spotName: String
        public var coordinate: Coordinate
        public var anglers: [String]
        public var catchCount: Int

        public init(sessionID: UUID, device: String, owner: String, startedAt: Date, endedAt: Date?, spotName: String, coordinate: Coordinate,
                    anglers: [String], catchCount: Int) {
            self.sessionID = sessionID; self.device = device; self.owner = owner; self.startedAt = startedAt; self.endedAt = endedAt
            self.spotName = spotName; self.coordinate = coordinate; self.anglers = anglers; self.catchCount = catchCount
        }

        public init(_ s: SharedSession) {
            self.init(sessionID: s.id, device: s.device, owner: s.owner, startedAt: s.startedAt, endedAt: s.endedAt, spotName: s.spotName,
                      coordinate: s.coordinate, anglers: s.anglers, catchCount: s.catchCount)
        }

        /// 終わりの時刻。記録中は今（始まりから 12 時間まで）
        public func end(now: Date) -> Date { endedAt ?? min(now, startedAt.addingTimeInterval(12 * 3600)) }
    }

    /// 最初の端末の釣行の id
    public var id: UUID
    public var legs: [Leg]
    public var startedAt: Date
    /// nil は記録中の端末がある
    public var endedAt: Date?
    public var spotName: String
    public var coordinate: Coordinate
    /// いっしょに行った人（重複なし、記録した順）
    public var members: [String]
    public var catchCount: Int

    public var isActive: Bool { endedAt == nil }
    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

/// 「誰といっしょに行ったか」を、記録の時間と場所から決める（F-62）。入力は不要。
///
/// - 違う端末の 2 つの釣行が、**時間が重なり（前後 30 分の余裕）**、**釣り場が 2 km 以内**（位置が無ければ釣り場名が同じ）なら同行
/// - 自分の端末で他の人の魚を記録していれば（撮影画面の「誰の魚か」）、その人も同行
/// - 自分の釣行と重ならない仲間の釣行は「仲間の釣行」として別に出す（自分が行っていなくても見える）
public enum PartyTrips {
    public static let timeSlack: TimeInterval = 30 * 60
    public static let maxDistanceM: Double = 2000
    /// 釣果を釣行に引き当てるときの余裕
    public static let catchSlack: TimeInterval = 10 * 60
    /// 名前を付けていない端末の既定の名前（相手の端末では「仲間」と出す）
    public static let unnamedOwner = "自分"
    public static let unnamedDisplay = "仲間"

    public struct Result: Hashable, Sendable {
        /// 自分の釣行ごとの同行者（自分を除く）
        public var companions: [UUID: [String]]
        /// 自分の釣行ごとの、同行した仲間の端末の釣行
        public var companionLegs: [UUID: [PartyTrip.Leg]]
        /// 自分が行っていない仲間の釣行（新しい順）
        public var friendTrips: [PartyTrip]
    }

    /// 2 つの釣行が同行か
    public static func together(_ a: PartyTrip.Leg, _ b: PartyTrip.Leg, now: Date) -> Bool {
        guard a.device != b.device else { return false }
        let aEnd = a.end(now: now), bEnd = b.end(now: now)
        guard a.startedAt.addingTimeInterval(-timeSlack) <= bEnd, b.startedAt.addingTimeInterval(-timeSlack) <= aEnd else { return false }
        if a.coordinate.isPlausible, b.coordinate.isPlausible {
            return Geo.distanceMeters(a.coordinate, b.coordinate) <= maxDistanceM
        }
        return !a.spotName.isEmpty && a.spotName == b.spotName
    }

    /// 相手の端末の持ち主の名前（未設定は「仲間」）
    public static func displayName(owner: String) -> String {
        let n = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty || n == unnamedOwner ? unnamedDisplay : n
    }

    /// 仲間の端末の釣行に出てくる人（持ち主と、その端末で魚を記録した人）
    static func names(of leg: PartyTrip.Leg) -> [String] {
        var out = [displayName(owner: leg.owner)]
        for a in leg.anglers {
            // 相手の端末の持ち主自身（未設定なら「自分」）は上で入れた
            let n = a == leg.owner ? displayName(owner: leg.owner) : a
            if !n.isEmpty, !out.contains(n) { out.append(n) }
        }
        return out
    }

    public static func resolve(own: [PartyTrip.Leg], others: [PartyTrip.Leg], ownName: String, now: Date = .now) -> Result {
        var companions: [UUID: [String]] = [:]
        var companionLegs: [UUID: [PartyTrip.Leg]] = [:]
        var matched = Set<UUID>()
        for mine in own {
            // 自分の端末で記録した他の人
            var names = mine.anglers.filter { !$0.isEmpty && $0 != ownName }
            var legs: [PartyTrip.Leg] = []
            for o in others where together(mine, o, now: now) {
                matched.insert(o.sessionID)
                legs.append(o)
                for n in Self.names(of: o) where n != ownName && !names.contains(n) { names.append(n) }
            }
            var seen = Set<String>()
            names = names.filter { seen.insert($0).inserted }
            if !names.isEmpty { companions[mine.sessionID] = names }
            if !legs.isEmpty { companionLegs[mine.sessionID] = legs.sorted { $0.startedAt < $1.startedAt } }
        }
        // 自分の釣行と重ならないものを、端末をまたいでまとめる
        let rest = others.filter { !matched.contains($0.sessionID) }.sorted { $0.startedAt < $1.startedAt }
        var parent = Array(rest.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in rest.indices {
            for j in rest.indices where j > i && together(rest[i], rest[j], now: now) {
                let a = find(i), b = find(j)
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        }
        var groups: [Int: [PartyTrip.Leg]] = [:]
        for i in rest.indices { groups[find(i), default: []].append(rest[i]) }
        let trips: [PartyTrip] = groups.values.map { group -> PartyTrip in
            let legs = group.sorted { $0.startedAt < $1.startedAt }
            var members: [String] = []
            for l in legs { for n in Self.names(of: l) where !members.contains(n) { members.append(n) } }
            let active = legs.contains { $0.endedAt == nil }
            let first = legs[0]
            let place = legs.first { !$0.spotName.isEmpty } ?? first
            return PartyTrip(id: first.sessionID, legs: legs, startedAt: first.startedAt,
                             endedAt: active ? nil : legs.compactMap(\.endedAt).max(),
                             spotName: place.spotName, coordinate: (legs.first { $0.coordinate.isPlausible } ?? first).coordinate,
                             members: members, catchCount: legs.reduce(0) { $0 + $1.catchCount })
        }
        return Result(companions: companions, companionLegs: companionLegs, friendTrips: trips.sorted { $0.startedAt > $1.startedAt })
    }

    /// その釣行（の端末と時間）に当たる仲間の釣果。時刻の順
    public static func catches(in legs: [PartyTrip.Leg], from shared: [SharedCatch], now: Date = .now) -> [SharedCatch] {
        var seen = Set<UUID>()
        var out: [SharedCatch] = []
        for l in legs {
            let lo = l.startedAt.addingTimeInterval(-catchSlack), hi = l.end(now: now).addingTimeInterval(catchSlack)
            for c in shared where c.device == l.device && c.at >= lo && c.at <= hi && seen.insert(c.id).inserted { out.append(c) }
        }
        return out.sorted { $0.at < $1.at }
    }
}
