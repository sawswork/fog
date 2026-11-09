import Foundation
import Observation
import SwiftData
import Core

extension Notification.Name {
    /// ストアに書き込み・削除があった。分析の派生値はこれを見て捨てる。
    static let fogStoreDidChange = Notification.Name("fog.storeDidChange")
}

enum FogStoreError: LocalizedError {
    case missingSpot(UUID)
    case missingSession(UUID)

    var errorDescription: String? {
        switch self {
        case .missingSpot(let id): return "釣り場が見つかりません: \(id)"
        case .missingSession(let id): return "釣行が見つかりません: \(id)"
        }
    }
}

/// Core の値型で読み書きするリポジトリ。画面やサービスは SwiftData の型に触らず、ここを通す。
/// すべての変更で `revision` を進めて通知する。分析は保存データから毎回導出し、キャッシュは `revision` で無効化する（§6「削除は分析に即時反映」）。
@MainActor
@Observable
final class FogStore {
    private(set) var revision: Int = 0
    /// 分析に影響する変更（釣果・釣行の開始終了・釣り場・タックルなど）だけで進む版。
    /// 立ち位置・気圧ログ・スナップショットの追記は `revision` だけ進める（30 秒ごとの再計算やキャッシュの捨て直しを起こさない。2026-11-09 処理速度）
    private(set) var analysisRevision: Int = 0
    let context: ModelContext

    init(container: ModelContainer) {
        context = container.mainContext
        context.autosaveEnabled = false
    }

    // MARK: 釣り場

    @ObservationIgnored private var spotsMemo: (revision: Int, value: [Spot])?
    @ObservationIgnored private var sessionsMemo: (revision: Int, value: [Core.Session])?

    /// 同じ版の間は復号した結果を使い回す（ホームは 30 秒ごとに全釣行を読む）
    func spots() throws -> [Spot] {
        if let m = spotsMemo, m.revision == revision { return m.value }
        let v = try context.fetch(FetchDescriptor<SpotRecord>(sortBy: [SortDescriptor(\.createdAt)])).map(\.core)
        spotsMemo = (revision, v)
        return v
    }

    func spot(id: UUID) throws -> Spot? {
        try spotRecord(id: id)?.core
    }

    func upsert(_ spot: Spot) throws {
        if let existing = try spotRecord(id: spot.id) {
            existing.apply(spot)
        } else {
            context.insert(SpotRecord(core: spot))
        }
        try commit()
    }

    func deleteSpot(id: UUID) throws {
        guard let record = try spotRecord(id: id) else { return }
        context.delete(record)
        try commit()
    }

    // MARK: ポイント

    func points(spotID: UUID) throws -> [Point] {
        try context.fetch(FetchDescriptor<PointRecord>(predicate: #Predicate { $0.spot?.uuid == spotID }))
            .compactMap(\.core)
            .sorted { $0.createdAt < $1.createdAt }
    }

    func upsert(_ point: Point) throws {
        guard let spot = try spotRecord(id: point.spotID) else { throw FogStoreError.missingSpot(point.spotID) }
        let pointID = point.id
        if let existing = try fetchOne(PointRecord.self, #Predicate { $0.uuid == pointID }) {
            existing.apply(point)
            existing.spot = spot
        } else {
            context.insert(PointRecord(core: point, spot: spot))
        }
        try commit()
    }

    // MARK: 釣行

    func sessions() throws -> [Core.Session] {
        if let m = sessionsMemo, m.revision == revision { return m.value }
        let v = try Perf.measure("釣行の読み込み") { try context.fetch(FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])).compactMap(\.core) }
        sessionsMemo = (revision, v)
        return v
    }

    func sessions(spotID: UUID) throws -> [Core.Session] {
        try context.fetch(FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.spot?.uuid == spotID }, sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))
            .compactMap(\.core)
    }

    func session(id: UUID) throws -> Core.Session? {
        try sessionRecord(id: id)?.core
    }

    /// 記録中（終了していない）釣行。
    func activeSession() throws -> Core.Session? {
        try fetchOne(SessionRecord.self, #Predicate { $0.endedAt == nil })?.core
    }

    /// 自分の釣果だけにした釣行（他の人の魚を自分の端末で撮った分を除く。図鑑・自己記録・自分データの学習に使う。F-54）
    @ObservationIgnored private var ownSessionsMemo: (revision: Int, own: String, value: [Core.Session])?
    func ownSessions() throws -> [Core.Session] {
        let own = AnglerSettings.ownName
        if let m = ownSessionsMemo, m.revision == revision, m.own == own { return m.value }
        let v = try sessions().map { s in
            guard s.catches.contains(where: { !$0.isOwn(ownName: own) }) else { return s }
            var copy = s
            copy.catches = s.catches.filter { $0.isOwn(ownName: own) }
            return copy
        }
        ownSessionsMemo = (revision, own, v)
        return v
    }

    /// 釣行を子レコード（釣果・スナップショット・針イベント）まで含めて保存する。渡されなかった子は消える。
    /// `minor` は立ち位置・気圧・スナップショットの追記のように分析に影響しない保存（画面への通知を出さない）
    func upsert(_ session: Core.Session, minor: Bool = false) throws {
        guard let spot = try spotRecord(id: session.spotID) else { throw FogStoreError.missingSpot(session.spotID) }
        let record: SessionRecord
        if let existing = try sessionRecord(id: session.id) {
            record = existing
            record.spot = spot
            record.applyScalars(session)
        } else {
            record = SessionRecord(core: session, spot: spot)
            context.insert(record)
        }

        sync(existing: record.catches ?? [], with: session.catches, recordID: \.uuid, id: \.id,
             make: { CatchRecord(core: $0, session: record) },
             update: { $0.apply($1); $0.session = record })
        sync(existing: record.snapshots ?? [], with: session.snapshots, recordID: \.uuid, id: \.id,
             make: { EnvSnapshotRecord(core: $0, session: record) },
             update: { $0.apply($1); $0.session = record })
        sync(existing: record.hookEvents ?? [], with: session.hookEvents, recordID: \.uuid, id: \.id,
             make: { HookEventRecord(core: $0, session: record) },
             update: { $0.apply($1); $0.session = record })
        try commit(minor: minor)
    }

    func deleteSession(id: UUID) throws {
        guard let record = try sessionRecord(id: id) else { return }
        context.delete(record)
        try commit()
    }

    // MARK: 釣果

    /// 全釣果（釣行をまたいだ集計・図鑑用）。
    func catches() throws -> [Catch] {
        try context.fetch(FetchDescriptor<CatchRecord>(sortBy: [SortDescriptor(\.at, order: .reverse)]))
            .compactMap { record in record.session.map { record.core(sessionID: $0.uuid) } }
    }

    func upsert(_ item: Catch) throws {
        guard let session = try sessionRecord(id: item.sessionID) else { throw FogStoreError.missingSession(item.sessionID) }
        let catchID = item.id
        if let existing = try fetchOne(CatchRecord.self, #Predicate { $0.uuid == catchID }) {
            existing.apply(item)
            existing.session = session
        } else {
            context.insert(CatchRecord(core: item, session: session))
        }
        try commit()
    }

    /// サムネイル（アプリ内に持つのはこれだけ。写真本体はフォトライブラリ）。
    func setThumbnail(catchID: UUID, jpeg: Data) throws {
        guard let record = try fetchOne(CatchRecord.self, #Predicate { $0.uuid == catchID }) else { return }
        record.thumbnailJPEG = jpeg
        thumbnailCache[catchID] = jpeg
        // サムネイルは分析に影響しない。ただし画面（図鑑・ログのカード）は描き直す
        try commit(minor: true, notify: true)
    }

    /// 画面の body から何度も呼ばれるので、読んだサムネイルはメモリに持つ（1 回の fetch は数 ms。グリッドで毎回引くと固まる）
    @ObservationIgnored private var thumbnailCache: [UUID: Data?] = [:]
    func thumbnail(catchID: UUID) -> Data? {
        if let cached = thumbnailCache[catchID] { return cached }
        let data = (try? fetchOne(CatchRecord.self, #Predicate { $0.uuid == catchID }))?.thumbnailJPEG
        if thumbnailCache.count > 400 { thumbnailCache.removeAll() }
        thumbnailCache[catchID] = data
        return data
    }

    func deleteCatch(id: UUID) throws {
        guard let record = try fetchOne(CatchRecord.self, #Predicate { $0.uuid == id }) else { return }
        context.delete(record)
        thumbnailCache[id] = nil
        try commit()
    }

    // MARK: 針イベント

    func upsert(_ event: HookEvent) throws {
        guard let session = try sessionRecord(id: event.sessionID) else { throw FogStoreError.missingSession(event.sessionID) }
        let eventID = event.id
        if let existing = try fetchOne(HookEventRecord.self, #Predicate { $0.uuid == eventID }) {
            existing.apply(event)
            existing.session = session
        } else {
            context.insert(HookEventRecord(core: event, session: session))
        }
        try commit()
    }

    // MARK: タックル・リグ

    func tackles() throws -> [Tackle] {
        try context.fetch(FetchDescriptor<TackleRecord>(sortBy: [SortDescriptor(\.createdAt)])).map(\.core)
    }

    func upsert(_ tackle: Tackle) throws {
        let tackleID = tackle.id
        if let existing = try fetchOne(TackleRecord.self, #Predicate { $0.uuid == tackleID }) {
            existing.apply(tackle)
        } else {
            context.insert(TackleRecord(core: tackle))
        }
        try commit()
    }

    func deleteTackle(id: UUID) throws {
        guard let record = try fetchOne(TackleRecord.self, #Predicate { $0.uuid == id }) else { return }
        context.delete(record)
        try commit()
    }

    func rigs() throws -> [Rig] {
        try context.fetch(FetchDescriptor<RigRecord>(sortBy: [SortDescriptor(\.sortOrder)])).map(\.core)
    }

    func upsert(_ rig: Rig) throws {
        let rigID = rig.id
        if let existing = try fetchOne(RigRecord.self, #Predicate { $0.uuid == rigID }) {
            existing.apply(rig)
        } else {
            context.insert(RigRecord(core: rig))
        }
        try commit()
    }

    func deleteRig(id: UUID) throws {
        guard let record = try fetchOne(RigRecord.self, #Predicate { $0.uuid == id }) else { return }
        context.delete(record)
        try commit()
    }

    // MARK: 魚種

    func species() throws -> [Species] {
        try context.fetch(FetchDescriptor<SpeciesRecord>(sortBy: [SortDescriptor(\.key)])).map(\.core)
    }

    /// カタログを置き換える（キーが同じものは更新、無いものは追加。消しはしない）。
    func mergeSpecies(_ catalog: [Species]) throws {
        let existing = try context.fetch(FetchDescriptor<SpeciesRecord>())
        var byKey: [String: SpeciesRecord] = [:]
        for record in existing { byKey[record.key] = record }
        for item in catalog {
            if let record = byKey[item.id] {
                record.apply(item)
            } else {
                context.insert(SpeciesRecord(core: item))
            }
        }
        try commit()
    }

    // MARK: メモ（F-52）

    func notes() throws -> [Core.Note] {
        try context.fetch(FetchDescriptor<NoteRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])).map(\.core)
    }

    func upsert(_ note: Core.Note) throws {
        let noteID = note.id
        if let existing = try fetchOne(NoteRecord.self, #Predicate { $0.uuid == noteID }) {
            existing.apply(note)
        } else {
            context.insert(NoteRecord(core: note))
        }
        try commit()
    }

    func deleteNote(id: UUID) throws {
        guard let record = try fetchOne(NoteRecord.self, #Predicate { $0.uuid == id }) else { return }
        context.delete(record)
        try commit()
    }

    // MARK: 全削除

    func deleteAll() throws {
        thumbnailCache.removeAll()
        try context.delete(model: NoteRecord.self)
        try context.delete(model: SpotRecord.self)
        try context.delete(model: SessionRecord.self)
        try context.delete(model: CatchRecord.self)
        try context.delete(model: EnvSnapshotRecord.self)
        try context.delete(model: HookEventRecord.self)
        try context.delete(model: PointRecord.self)
        try context.delete(model: TackleRecord.self)
        try context.delete(model: RigRecord.self)
        try context.delete(model: SpeciesRecord.self)
        try commit()
    }

    // MARK: 内部

    private func spotRecord(id: UUID) throws -> SpotRecord? {
        try fetchOne(SpotRecord.self, #Predicate { $0.uuid == id })
    }

    private func sessionRecord(id: UUID) throws -> SessionRecord? {
        try fetchOne(SessionRecord.self, #Predicate { $0.uuid == id })
    }

    private func fetchOne<T: PersistentModel>(_ type: T.Type, _ predicate: Predicate<T>) throws -> T? {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// 子レコードを Core の配列に合わせる：同じ ID は更新、無いものは追加（`make` が親を設定する）、渡されなかったものは削除。
    private func sync<Record: PersistentModel, Value>(
        existing: [Record],
        with values: [Value],
        recordID: KeyPath<Record, UUID>,
        id: KeyPath<Value, UUID>,
        make: (Value) -> Record,
        update: (Record, Value) -> Void
    ) {
        var byID: [UUID: Record] = [:]
        for record in existing { byID[record[keyPath: recordID]] = record }
        for value in values {
            if let record = byID.removeValue(forKey: value[keyPath: id]) {
                update(record, value)
            } else {
                context.insert(make(value))
            }
        }
        for orphan in byID.values { context.delete(orphan) }
    }

    private func commit(minor: Bool = false, notify: Bool? = nil) throws {
        guard context.hasChanges else { return }
        try context.save()
        revision += 1
        if !minor { analysisRevision += 1 }
        if notify ?? !minor { NotificationCenter.default.post(name: .fogStoreDidChange, object: self) }
    }
}
