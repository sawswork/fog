import Foundation
import CoreGraphics
import UIKit
import Core
import os

/// 撮影 1 回を釣果 1 尾にする（§4）。時刻・位置・セッション・ポイント・タックル・リグ・環境を自動で付け、
/// 連続撮影は同一個体にまとめ、写真はライブラリに保存してアプリにはサムネイルだけ持つ。
@MainActor
@Observable
final class CaptureService {
    struct Outcome: Sendable {
        var catchRecord: Catch
        var merged: Bool
        var record: Analytics.RecordJudgement?
    }

    private let store: FogStore
    private let environment: EnvironmentService
    private let detection: SessionDetectionService
    private let classifier: SpeciesClassifying
    private let library = PhotoLibraryService()
    private static let log = Logger(subsystem: "fog", category: "capture")

    /// 撮影画面の例外的入力（タックル・リグ）。次回へ引き継ぐ（F-14）
    /// App Group に置き、ウィジェットのタックル切替と同じ値を見る（F-14）。
    var currentTackle: TackleKind? {
        get { FogShared.currentTackle }
        set { FogShared.currentTackle = newValue; WidgetSync.setTackle(newValue) }
    }
    var currentRigID: UUID? {
        get { UserDefaults.standard.string(forKey: "fog.currentRig").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "fog.currentRig") }
    }
    /// 撮影画面で選んだ釣った人（F-54）。nil は自分。同じ釣行の間は引き継ぎ、釣行が変わったら自分に戻る
    var currentAngler: String? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "fog.currentAngler"), !raw.isEmpty else { return nil }
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let active = try? store.activeSession(), active.id.uuidString == parts[0] else { return nil }
            return parts[1] == AnglerSettings.ownName ? nil : parts[1]
        }
        set {
            let sessionID = (try? store.activeSession())?.id.uuidString ?? ""
            UserDefaults.standard.set(newValue.map { "\(sessionID)|\($0)" } ?? "", forKey: "fog.currentAngler")
        }
    }
    /// 釣果を保存したあとに呼ばれる（仲間との共有のアップロード。F-54）
    var onCatchSaved: ((Catch) -> Void)?
    /// 釣果を後から直した・消したあとに呼ばれる（その釣行のレポートと、仲間へ送る要約を作り直す）
    var onSessionEdited: ((UUID) -> Void)?

    init(store: FogStore, environment: EnvironmentService, detection: SessionDetectionService, classifier: SpeciesClassifying = CoreMLSpeciesClassifier()) {
        self.store = store
        self.environment = environment
        self.detection = detection
        self.classifier = classifier
    }

    /// シャッター：画像（縦向き）と計測結果から釣果を保存する。2 秒以内に返す（写真保存は非同期で続ける）。
    func record(jpeg: Data, image: CGImage, measurement: LengthMeasurement?, at date: Date = .now, coordinate: Coordinate?) async -> Outcome? {
        let candidates = await classifier.classify(image)
        let session = await ensureSession(at: date, coordinate: coordinate)
        let location = coordinate ?? (try? store.spot(id: session.spotID))?.coordinate ?? Coordinate(latitude: 0, longitude: 0)
        var item = Catch(
            sessionID: session.id, at: date, coordinate: location,
            species: candidates.first?.species ?? "", speciesConfidence: candidates.first?.confidence ?? 0,
            lengthCm: measurement?.lengthCm, lengthErrorCm: measurement?.errorCm,
            tackle: currentTackle ?? session.tackle, rigID: currentRigID ?? session.rigID,
            env: environment.snapshot(at: date, coordinate: location),
            pointID: detection.currentPointID(), speciesCandidates: candidates, tackleID: session.tackleID,
            angler: currentAngler
        )
        // 背景のタグ（足場・時間帯・天気。F-31）
        item.sceneTags = await SceneClassifier.tags(for: image)
        // 写真をライブラリへ（失敗しても釣果は残す）
        if let identifier = try? await library.save(jpeg: jpeg, at: date, coordinate: coordinate) {
            item.photoLocalIdentifier = identifier
            item.photoLocalIdentifiers = [identifier]
        }
        return persist(item, in: session, thumbnail: PhotoLibraryService.thumbnailJPEG(from: image))
    }

    /// 取り込み（標準カメラの写真）：メジャーが写っていればそこから全長（F-61）、無ければ未計測で保存。
    func recordImported(image: CGImage, photoIdentifier: String, at date: Date, coordinate: Coordinate?, session: Core.Session, measurement: LengthMeasurement? = nil) async -> Outcome? {
        let candidates = await classifier.classify(image)
        let location = coordinate ?? (try? store.spot(id: session.spotID))?.coordinate ?? Coordinate(latitude: 0, longitude: 0)
        var item = Catch(
            sessionID: session.id, at: date, coordinate: location,
            species: candidates.first?.species ?? "", speciesConfidence: candidates.first?.confidence ?? 0,
            lengthCm: measurement?.lengthCm, lengthErrorCm: measurement?.errorCm,
            photoLocalIdentifier: photoIdentifier, tackle: session.tackle, rigID: session.rigID,
            env: environment.snapshot(at: date, coordinate: location),
            speciesCandidates: candidates, photoLocalIdentifiers: [photoIdentifier], tackleID: session.tackleID
        )
        item.sceneTags = await SceneClassifier.tags(for: image)
        return persist(item, in: session, thumbnail: PhotoLibraryService.thumbnailJPEG(from: image))
    }

    private func persist(_ item: Catch, in session: Core.Session, thumbnail: Data?) -> Outcome? {
        guard var current = try? store.session(id: session.id) else { return nil }
        var merged = false
        var saved = item
        if let same = CatchMerger.findSameIndividual(for: item, in: current.catches) {
            saved = CatchMerger.merge(base: same, new: item)
            current.catches = current.catches.map { $0.id == same.id ? saved : $0 }
            merged = true
        } else {
            current.catches.append(saved)
        }
        do {
            try store.upsert(current)
            if let thumbnail, !merged || saved.photoLocalIdentifier == item.photoLocalIdentifier {
                try store.setThumbnail(catchID: saved.id, jpeg: thumbnail)
            }
        } catch {
            Self.log.error("catch save failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // 記録更新の判定は自分の魚だけ（他の人の魚は図鑑・自己記録に入れない。F-54）
        let record = (merged || !saved.isOwn(ownName: AnglerSettings.ownName)) ? nil : judge(saved, spotID: current.spotID)
        // 記録更新の通知はアプリを閉じているときだけ（撮影直後はシートで見せる。§8）
        if let record, record.hasAny, UIApplication.shared.applicationState != .active {
            SessionNotifications.record(species: saved.species, lengthCm: saved.lengthCm, judgement: record)
        }
        onCatchSaved?(saved)
        return Outcome(catchRecord: saved, merged: merged, record: record)
    }

    private func judge(_ new: Catch, spotID: UUID) -> Analytics.RecordJudgement {
        let all = (try? store.ownSessions()) ?? []
        let existing = all.flatMap { s in s.catches.map { ($0, s.spotID) } }
        return Analytics.judge(new: new, newSpotID: spotID, existing: existing)
    }

    /// 記録中の釣行。無ければ撮影位置で手動の釣行を始める（撮影は釣行の証拠）。
    /// 位置が取れないときは (0, 0) の釣り場を作らず、ホームで選んだ釣り場 → 直近の釣行の釣り場 → 「位置不明」（未登録）の順で使う。
    func ensureSession(at date: Date, coordinate: Coordinate?) async -> Core.Session {
        if let active = try? store.activeSession() { return active }
        let spot = spotForSession(at: date, coordinate: coordinate)
        let previous = (try? store.sessions())?.first
        var session = Core.Session(spotID: spot.id, startedAt: date, tackle: previous?.tackle, rigID: previous?.rigID,
                                   track: [TrackSample(at: date, coordinate: (coordinate?.isPlausible == true ? coordinate : nil) ?? spot.coordinate)], tackleID: previous?.tackleID, isAutoDetected: false)
        // 位置が無い釣行は自動では終われない（位置で終了を判定するため）ので、その場で終えておく。ホームの「記録中」にもしない
        if !spot.coordinate.isPlausible { session.endedAt = date }
        try? store.upsert(session)
        // 位置のある釣行はそのまま「記録中」にする（立ち位置・スナップショット・安全通知を始める。終了はホームのボタン）
        if session.isActive { detection.adopt(session: session, coordinate: coordinate ?? spot.coordinate) }
        return session
    }

    /// 過去の写真の取り込み用（F-61）：撮影時刻を含む終了済みの釣行を作る（進行中の釣行には混ぜない。「記録中」にもしない）
    func pastSession(at date: Date, coordinate: Coordinate?) -> Core.Session {
        let spot = spotForSession(at: date, coordinate: coordinate)
        let previous = (try? store.sessions())?.first { $0.startedAt < date }
        var session = Core.Session(spotID: spot.id, startedAt: date.addingTimeInterval(-30 * 60), tackle: previous?.tackle, rigID: previous?.rigID,
                                   track: [TrackSample(at: date, coordinate: (coordinate?.isPlausible == true ? coordinate : nil) ?? spot.coordinate)], tackleID: previous?.tackleID, isAutoDetected: false)
        session.endedAt = date.addingTimeInterval(30 * 60)
        try? store.upsert(session)
        return session
    }

    /// 新しい釣行の釣り場：近くの登録釣り場 → 位置から作る → ホームの釣り場 → 直近の釣り場 → 位置不明
    private func spotForSession(at date: Date, coordinate: Coordinate?) -> Spot {
        let spots = (try? store.spots()) ?? []
        let spot: Spot
        if let location = coordinate, location.isPlausible {
            let near = spots.filter { $0.isRegistered && $0.coordinate.isPlausible }
                .min { Geo.distanceMeters($0.coordinate, location) < Geo.distanceMeters($1.coordinate, location) }
            if let near, Geo.distanceMeters(near.coordinate, location) <= SessionDetectionService.registeredSpotRadiusM {
                spot = near
            } else {
                spot = Spot(name: "釣り場", coordinate: location, isRegistered: true, createdAt: date)
                try? store.upsert(spot)
            }
        } else if let homeID = UserDefaults.standard.string(forKey: "fog.homeSpotID").flatMap(UUID.init(uuidString:)),
                  let home = spots.first(where: { $0.id == homeID }) {
            spot = home
        } else if let last = (try? store.sessions())?.first, let lastSpot = spots.first(where: { $0.id == last.spotID }), lastSpot.coordinate.isPlausible {
            spot = lastSpot
        } else if let unknown = spots.first(where: { !$0.coordinate.isPlausible }) {
            spot = unknown
        } else {
            spot = Spot(name: "位置不明", coordinate: Coordinate(latitude: 0, longitude: 0), isRegistered: false, createdAt: date)
            try? store.upsert(spot)
        }
        return spot
    }

    /// タックル・リグの後からの設定（シンカー・フック・ワームはリグのプリセット。2026-11-09 開発者の指示）
    func setRig(catchID: UUID, tackle: TackleKind?, rigID: UUID?) {
        guard let all = try? store.sessions(), var session = all.first(where: { $0.catches.contains { $0.id == catchID } }),
              let index = session.catches.firstIndex(where: { $0.id == catchID }) else { return }
        session.catches[index].tackle = tackle
        session.catches[index].rigID = rigID
        try? store.upsert(session)
    }

    /// 釣れた位置の手直し（F-59、2026-11-09 開発者の指示）。立ち位置のメッシュとの紐付けは外す（位置が変わったので）
    func setCoordinate(catchID: UUID, coordinate: Coordinate) {
        guard coordinate.isPlausible, let all = try? store.sessions(), var session = all.first(where: { $0.catches.contains { $0.id == catchID } }),
              let index = session.catches.firstIndex(where: { $0.id == catchID }) else { return }
        session.catches[index].coordinate = coordinate
        session.catches[index].pointID = nil
        try? store.upsert(session)
        onCatchSaved?(session.catches[index])
    }

    /// 釣った人の変更（F-54）
    func setAngler(catchID: UUID, angler: String?) {
        guard let all = try? store.sessions(), var session = all.first(where: { $0.catches.contains { $0.id == catchID } }),
              let index = session.catches.firstIndex(where: { $0.id == catchID }) else { return }
        session.catches[index].angler = (angler == AnglerSettings.ownName || angler?.isEmpty == true) ? nil : angler
        try? store.upsert(session)
        onCatchSaved?(session.catches[index])
        onSessionEdited?(session.id)
    }

    /// 釣果の削除。写真は求められたときだけライブラリからも消す（削除は分析に即時反映）。
    /// 釣果を消したあとに呼ばれる（共有の取り消し。F-54）
    var onCatchDeleted: ((UUID) -> Void)?

    func deleteCatch(id: UUID, deletePhoto: Bool) async {
        let item = (try? store.catches())?.first { $0.id == id }
        try? store.deleteCatch(id: id)
        onCatchDeleted?(id)
        if let item { onSessionEdited?(item.sessionID) }
        if deletePhoto, let item {
            await PhotoLibraryService.delete(identifiers: [item.photoLocalIdentifier].compactMap { $0 } + item.photoLocalIdentifiers)
        }
    }

    /// サイズの手入力・修正（F-12/F-24）。手入力は推定幅 0.5 cm とする。
    func setLength(catchID: UUID, lengthCm: Double?) {
        guard let all = try? store.sessions(), var session = all.first(where: { $0.catches.contains { $0.id == catchID } }),
              let index = session.catches.firstIndex(where: { $0.id == catchID }) else { return }
        session.catches[index].lengthCm = lengthCm
        session.catches[index].lengthErrorCm = lengthCm == nil ? nil : 0.5
        try? store.upsert(session)
        onCatchSaved?(session.catches[index])
        onSessionEdited?(session.id)
    }

    /// 魚種の確定（候補 3 種の 1 タップ、F-10）／後からの修正（F-24）。
    func setSpecies(catchID: UUID, species: String, corrected: Bool) {
        guard let all = try? store.sessions(), var session = all.first(where: { $0.catches.contains { $0.id == catchID } }),
              let index = session.catches.firstIndex(where: { $0.id == catchID }) else { return }
        let predicted = session.catches[index].speciesCandidates.first?.species ?? session.catches[index].species
        session.catches[index].species = species
        session.catches[index].speciesCorrected = corrected
        if corrected { session.catches[index].speciesConfidence = 1 }
        try? store.upsert(session)
        onCatchSaved?(session.catches[index])
        onSessionEdited?(session.id)
        // 端末内の補正テーブルに学習（次回の候補順に反映。F-24）
        CoreMLSpeciesClassifier.learn(predicted: predicted, corrected: species)
    }
}
