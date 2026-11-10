import Foundation
import SwiftUI
import Core

/// ログ画面（§4）の状態。期間で絞った釣行と、その分析（時間帯別・潮別・釣り場別）を保存データから毎回導出する。
@MainActor
@Observable
final class LogViewModel {
    enum Period: String, CaseIterable, Identifiable {
        case month = "今月", season = "シーズン", all = "全期間"
        var id: String { rawValue }
    }

    struct SessionCard: Identifiable {
        let session: Core.Session
        let spotName: String
        let thumbnail: Data?
        /// いっしょに行った人（F-62。時間と場所から自動で決める）
        var companions: [String] = []
        var id: UUID { session.id }
    }

    /// 仲間の釣行（自分は行っていない。F-62）
    struct FriendTripCard: Identifiable {
        let trip: PartyTrip
        let catches: [SharedCatch]
        let thumbnail: Data?
        var id: UUID { trip.id }
    }

    /// ログの釣行の並び：自分の釣行と仲間の釣行を新しい順に混ぜる
    enum Item: Identifiable {
        case own(SessionCard)
        case friend(FriendTripCard)
        var id: UUID {
            switch self {
            case .own(let c): return c.id
            case .friend(let f): return f.id
            }
        }
        var startedAt: Date {
            switch self {
            case .own(let c): return c.session.startedAt
            case .friend(let f): return f.trip.startedAt
            }
        }
    }

    var period: Period = .month { didSet { refresh() } }
    private(set) var cards: [SessionCard] = []
    /// 自分の釣行と仲間の釣行（新しい順）
    private(set) var items: [Item] = []
    /// 自分の釣行ごとの同行者と、同行した仲間の端末の釣果
    private(set) var companions: [UUID: [String]] = [:]
    private(set) var companionCatches: [UUID: [SharedCatch]] = [:]
    private(set) var sessionCount = 0
    private(set) var catchCount = 0
    private(set) var latestReport: (summary: String, session: Core.Session)?
    private(set) var byHour: [(hour: Int, count: Int)] = []
    private(set) var byTide: [(label: String, count: Int)] = []
    private(set) var bySpot: [(name: String, perHour: Double, sessions: Int)] = []
    private(set) var allSessions: [Core.Session] = []
    private(set) var spots: [UUID: Spot] = [:]
    let timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current

    private var services: AppServices?

    func attach(_ services: AppServices) {
        self.services = services
        refresh()
    }

    func refresh() {
        guard let services else { return }
        let store = services.store
        allSessions = (try? store.sessions()) ?? []
        spots = Dictionary(uniqueKeysWithValues: ((try? store.spots()) ?? []).map { ($0.id, $0) })
        let filtered = allSessions.filter { !$0.isActive && inPeriod($0.startedAt) }
        // 誰といっしょに行ったか（F-62）：自分の釣行と仲間の端末の釣行を、時間と場所で突き合わせる
        let party = services.party
        let ownName = AnglerSettings.ownName, me = AnglerSettings.deviceID
        let ownLegs = allSessions.map { s in PartyTrip.Leg(SharedSession.make(from: s, spot: spots[s.spotID], ownName: ownName, device: me)) }
        let otherLegs = PartyService.isEnabled ? party.otherSessions.map { PartyTrip.Leg($0) } : []
        let sharedCatches = PartyService.isEnabled ? party.others : []
        let resolved = PartyTrips.resolve(own: ownLegs, others: otherLegs, ownName: ownName)
        companions = resolved.companions
        companionCatches = resolved.companionLegs.mapValues { PartyTrips.catches(in: $0, from: sharedCatches) }
        cards = filtered.map { s in
            let best = s.catches.filter { $0.lengthCm != nil }.max { ($0.lengthCm ?? 0) < ($1.lengthCm ?? 0) } ?? s.catches.first
            return SessionCard(session: s, spotName: spots[s.spotID]?.name ?? "釣り場", thumbnail: best.flatMap { store.thumbnail(catchID: $0.id) },
                               companions: resolved.companions[s.id] ?? [])
        }
        // 自分が行っていない仲間の釣行（記録中も出す）
        let friendCards: [FriendTripCard] = resolved.friendTrips.filter { inPeriod($0.startedAt) }.map { trip in
            let list = PartyTrips.catches(in: trip.legs, from: sharedCatches)
            let best = list.filter { $0.lengthCm != nil }.max { ($0.lengthCm ?? 0) < ($1.lengthCm ?? 0) } ?? list.first
            return FriendTripCard(trip: trip, catches: list, thumbnail: best.flatMap { party.thumbnail(for: $0.id) })
        }
        items = (cards.map { Item.own($0) } + friendCards.map { Item.friend($0) }).sorted { $0.startedAt > $1.startedAt }
        sessionCount = filtered.count
        catchCount = filtered.reduce(0) { $0 + $1.catches.count }
        if let latest = allSessions.first(where: { $0.report != nil }), let r = latest.report {
            latestReport = (r.summary, latest)
        } else {
            latestReport = nil
        }
        let catches = filtered.flatMap(\.catches)
        let hours = Analytics.catchesByHour(catches: catches, timeZone: timeZone)
        byHour = (0..<24).map { (hour: $0, count: hours[$0] ?? 0) }
        let dist = Analytics.conditionDistribution(of: catches, timeZone: timeZone)
        var tide: [(String, Int)] = []
        for k in ["上げ", "下げ", "潮止まり"] { tide.append((k, dist.byTide[k] ?? 0)) }
        for k in ["大潮", "中潮", "小潮", "長潮", "若潮"] { tide.append((k, dist.byTideName[k] ?? 0)) }
        byTide = tide.map { (label: $0.0, count: $0.1) }
        bySpot = Analytics.statsBySpot(sessions: filtered).map { id, st in
            (name: spots[id]?.name ?? "釣り場", perHour: st.catchesPerHour, sessions: st.sessions)
        }.sorted { $0.perHour > $1.perHour }
    }

    private func inPeriod(_ date: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let now = Date()
        switch period {
        case .month:
            return cal.isDate(date, equalTo: now, toGranularity: .month)
        case .season:
            // シーズン＝直近 6 か月
            return date >= cal.date(byAdding: .month, value: -6, to: now)!
        case .all:
            return true
        }
    }

    /// 長押しで誤検出の釣行を削除（分析に即時反映）。
    func delete(_ session: Core.Session) {
        guard let services else { return }
        // 自動検出で釣果の無い釣行を消すのは誤検出の合図とみなし、その場所では自動で始めないようにする
        if session.isAutoDetected, session.catches.isEmpty {
            SessionDetectionService.exclude(session: session, spot: try? services.store.spot(id: session.spotID))
        }
        try? services.store.deleteSession(id: session.id)
        refresh()
    }

    func durationText(_ s: Core.Session) -> String { durationText(s.duration ?? 0) }

    func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h\(minutes % 60 > 0 ? "\(minutes % 60)m" : "")" : "\(minutes)m"
    }
}
