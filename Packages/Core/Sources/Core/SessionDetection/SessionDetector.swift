import Foundation

/// 釣行の自動開始・終了の状態機械（純粋ロジック。位置の供給と釣り場・海岸の判定は App 側）。
///
/// - 開始：登録釣り場のジオフェンス内、または海岸近傍に `dwellToStart` 滞在したら開始（通過だけでは始まらない）
/// - 終了：釣り場から `awayDistanceM` 以上離れて `awayToEnd` 経過、または車の速度が `drivingToEnd` 続いたら終了
/// - ランガン：終了後 `runAndGunMaxGap` 以内・`runAndGunMaxDistanceM` 以内で再開したら同じ釣行として再開
public struct SessionDetector: Sendable {
    public struct Context: Sendable {
        /// 位置が登録釣り場のジオフェンス内ならその釣り場
        public var registeredSpotID: UUID?
        /// 海岸線（漁港・岸壁・海岸）の近くか。不明なら nil（登録釣り場でなければ開始しない）
        public var nearShore: Bool?
        public init(registeredSpotID: UUID? = nil, nearShore: Bool? = nil) {
            self.registeredSpotID = registeredSpotID; self.nearShore = nearShore
        }
    }

    public enum Event: Equatable, Sendable {
        /// 釣行開始。`spotID` が nil なら釣り場を自動作成する（`anchor` が中心）
        case start(at: Date, anchor: Coordinate, spotID: UUID?)
        /// ランガン：直前の釣行を再開
        case resume(previousEndedAt: Date, at: Date, anchor: Coordinate)
        /// 釣行終了（`at` は離れ始めた／走り始めた時刻）
        case end(at: Date)
        /// 立ち位置のサンプル（釣行中のみ、低頻度）
        case track(TrackSample)
    }

    public enum State: Equatable, Sendable {
        case idle
        case candidate(since: Date, anchor: Coordinate, spotID: UUID?)
        case active(ActiveState)
        /// 終了直後。ランガンの再開待ち
        case cooldown(endedAt: Date, anchor: Coordinate)
        /// 手動で終了した直後。その場に居続けても自動では始めない（`awayDistanceM` 以上離れたら通常に戻る）
        case suppressed(anchor: Coordinate)
    }

    public struct ActiveState: Equatable, Sendable {
        public var startedAt: Date
        public var anchor: Coordinate
        public var awaySince: Date?
        public var drivingSince: Date?
        public var lastTrackAt: Date?
        public var lastTrack: Coordinate?
    }

    public var settings: DetectionSettings
    public private(set) var state: State = .idle
    /// cooldown から候補に移ったとき、開始が確定したら resume に差し替えるための記憶
    private var pendingResume: (Date, Coordinate)?

    public init(settings: DetectionSettings = .default) {
        self.settings = settings
    }

    /// 位置を 1 件処理してイベントを返す。
    public mutating func process(_ fix: LocationFix, context: Context) -> [Event] {
        // 精度の悪い位置は無視（滞在判定が広がりすぎるため）
        guard fix.horizontalAccuracyM <= 200 else { return [] }
        let fishingPlace = context.registeredSpotID != nil || context.nearShore == true
        let moving = (fix.speedMS ?? 0) >= settings.drivingSpeedMS

        switch state {
        case .idle:
            pendingResume = nil
            guard fishingPlace, !moving else { return [] }
            state = .candidate(since: fix.at, anchor: fix.coordinate, spotID: context.registeredSpotID)
            return []

        case .candidate(let since, let anchor, let spotID):
            if moving || !fishingPlace {
                state = .idle
                return []
            }
            if Geo.distanceMeters(anchor, fix.coordinate) > settings.dwellRadiusM {
                state = .candidate(since: fix.at, anchor: fix.coordinate, spotID: context.registeredSpotID)
                return []
            }
            if fix.at.timeIntervalSince(since) >= settings.dwellToStart {
                var active = ActiveState(startedAt: since, anchor: anchor)
                active.lastTrackAt = fix.at
                active.lastTrack = fix.coordinate
                state = .active(active)
                return [.start(at: since, anchor: anchor, spotID: spotID ?? context.registeredSpotID), .track(TrackSample(at: fix.at, coordinate: fix.coordinate))]
            }
            return []

        case .active(var active):
            var events: [Event] = []
            let distance = Geo.distanceMeters(active.anchor, fix.coordinate)
            if distance > settings.awayDistanceM {
                if active.awaySince == nil { active.awaySince = fix.at }
            } else {
                active.awaySince = nil
            }
            if moving {
                if active.drivingSince == nil { active.drivingSince = fix.at }
            } else {
                active.drivingSince = nil
            }
            if let away = active.awaySince, fix.at.timeIntervalSince(away) >= settings.awayToEnd {
                state = .cooldown(endedAt: away, anchor: active.anchor)
                return [.end(at: away)]
            }
            if let driving = active.drivingSince, fix.at.timeIntervalSince(driving) >= settings.drivingToEnd {
                state = .cooldown(endedAt: driving, anchor: active.anchor)
                return [.end(at: driving)]
            }
            // 立ち位置（低頻度）
            if active.awaySince == nil, !moving {
                let dueByTime = active.lastTrackAt.map { fix.at.timeIntervalSince($0) >= settings.trackInterval } ?? true
                let dueByDistance = active.lastTrack.map { Geo.distanceMeters($0, fix.coordinate) >= settings.trackMinDistanceM } ?? true
                if dueByTime && dueByDistance {
                    active.lastTrackAt = fix.at
                    active.lastTrack = fix.coordinate
                    events.append(.track(TrackSample(at: fix.at, coordinate: fix.coordinate)))
                }
            }
            state = .active(active)
            return events

        case .cooldown(let endedAt, let previousAnchor):
            if fix.at.timeIntervalSince(endedAt) > settings.runAndGunMaxGap {
                state = .idle
                return process(fix, context: context)
            }
            guard fishingPlace, !moving else { return [] }
            // 近接釣り場なら候補（滞在後に resume）、遠ければ通常の候補
            let near = Geo.distanceMeters(previousAnchor, fix.coordinate) <= settings.runAndGunMaxDistanceM
            state = .candidate(since: fix.at, anchor: fix.coordinate, spotID: context.registeredSpotID)
            if near {
                pendingResume = (endedAt, previousAnchor)
            } else {
                pendingResume = nil
            }
            return []

        case .suppressed(let anchor):
            guard Geo.distanceMeters(anchor, fix.coordinate) > settings.awayDistanceM || moving else { return [] }
            state = .idle
            return process(fix, context: context)
        }
    }

    /// ワンタップの開始（F-48）。滞在判定を待たずに今すぐ釣行中にする。以後の終了判定・立ち位置の記録は自動と同じ
    public mutating func beginManually(at: Date, anchor: Coordinate) {
        var active = ActiveState(startedAt: at, anchor: anchor)
        active.lastTrackAt = at
        active.lastTrack = anchor
        state = .active(active)
        pendingResume = nil
    }

    /// ワンタップの終了（F-48）。その場に居続けても自動で再開しないよう、離れるまで開始判定を止める。
    /// `anchor` が nil（位置不明）なら通常の待機に戻る
    public mutating func endManually(anchor: Coordinate?) {
        pendingResume = nil
        state = anchor.map { .suppressed(anchor: $0) } ?? .idle
    }

    /// `process` の結果の `.start` をランガンなら `.resume` に置き換える。呼び出し側はこちらを使う。
    public mutating func handle(_ fix: LocationFix, context: Context) -> [Event] {
        let events = process(fix, context: context)
        guard let pending = pendingResume else { return events }
        return events.map { e in
            if case .start(let at, let anchor, _) = e {
                pendingResume = nil
                return .resume(previousEndedAt: pending.0, at: at, anchor: anchor)
            }
            return e
        }
    }

    /// その場所を離れた（釣り場の境界を出た、または位置が長く途切れた）。
    /// 手動で終えたあとの「開始を止めている」状態と、滞在を数えている途中の候補を、待機に戻す。記録中・ランガン待ちは変えない。
    /// 候補を残したままだと、次に同じ場所へ来たときに古い開始時刻で滞在時間が一気に満たされて、着いた瞬間に始まってしまう
    public mutating func leftPlace() {
        switch state {
        case .suppressed, .candidate:
            state = .idle
            pendingResume = nil
        default:
            break
        }
    }

    public var isCandidate: Bool {
        if case .candidate = state { return true }
        return false
    }

    public var isSuppressed: Bool {
        if case .suppressed = state { return true }
        return false
    }

    /// 記録中の釣行の中心（始めた場所）
    public var activeAnchor: Coordinate? {
        if case .active(let a) = state { return a.anchor }
        return nil
    }

    /// 通知からの「停止」や誤検出の破棄。
    public mutating func reset() {
        state = .idle
        pendingResume = nil
    }

    public var isActive: Bool {
        if case .active = state { return true }
        return false
    }
}
