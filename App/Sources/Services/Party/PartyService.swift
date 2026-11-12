import Foundation
import CloudKit
import Photos
import UIKit
import Core
import os

/// 仲間との釣果共有（F-54）。自分の端末で保存した釣果の要約とサムネイルを、アプリの CloudKit コンテナの
/// **公開データベース**に置き、仲間の端末はそれを読んで「釣果情報」（一覧と地図のピン）に出す。
///
/// - 自前サーバーは使わない（原則 3）。送るのは魚種・サイズ・時刻・位置・釣り場名・釣った人・サムネイルだけ。写真本体は送らない
/// - 公開データベースはこのアプリ（同じコンテナ）を入れた人なら読める。アプリは App Store に出さず本人と同行者の 2 台だけなので許容
/// - 取得は 30 分に 1 回（前面復帰・釣果情報を開いたとき・釣果の保存直後）。圏外でも手元の記事で動く
/// - 開発者の作業：CloudKit Console で `SharedCatch` レコード型を Production に配備する（Development では自動で作られる）
@MainActor
@Observable
final class PartyService {
    static let recordType = "SharedCatch"
    static let enabledKey = "fog.party.enabled"
    private static let log = Logger(subsystem: "fog", category: "party")

    private(set) var items: [SharedCatch] = []
    /// 全員の釣行の要約（F-62）。自分の端末の分も含む
    private(set) var sessions: [SharedSession] = []
    private(set) var revision = 0
    private(set) var lastError: String?
    private(set) var lastSyncAt: Date?
    private(set) var syncing = false
    private var gate = FetchGate(minimumInterval: 1800)
    /// アップロード済みの釣果の内容キー（内容が変わったときだけ送り直す）
    private var uploaded: [String: String] = [:]
    /// アップロード済みの釣行の内容キー（釣行の id → `SharedSession.contentKey`）
    private var uploadedSessions: [String: String] = [:]
    private var pendingDeletes: [String] = []
    private let container: CKContainer?

    private var storeURL: URL { FogShared.containerURL.appendingPathComponent("party.json") }
    private var thumbsDir: URL {
        let d = FogShared.containerURL.appendingPathComponent("party-thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// 取りに行った写真本体（長辺 1,600 px の JPEG）。全画面で見たときだけ取る
    private var photosDir: URL {
        let d = FogShared.containerURL.appendingPathComponent("party-photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// 写真本体の最大辺（px）と JPEG の画質。1 枚 300〜600 KB 程度
    static let photoMaxPixel: CGFloat = 1600
    static let photoQuality: CGFloat = 0.8
    private var photoInFlight: Set<UUID> = []

    init() {
        container = PersistenceController.configuredCloudKitContainerIdentifier().map { CKContainer(identifier: $0) }
        load()
    }

    /// 共有のオンオフ（設定 > 釣り人）。既定はオン
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    var isAvailable: Bool { container != nil && Self.isEnabled }

    /// 仲間の投稿（自分の端末からの投稿を除く）。新しい順。サイズが無いものは、この端末で入れた値があればそれを入れて返す
    /// 魚が写っていないと判定した釣果は、隠す設定（既定）なら外す（F-67）
    var others: [SharedCatch] {
        let me = AnglerSettings.deviceID
        let hide = Self.hidesNoFish
        return items.filter { $0.device != me && !(hide && noFishIDs.contains($0.id.uuidString)) }.map { withLocalLength($0) }.sorted { $0.at > $1.at }
    }

    // MARK: 魚が写っていない釣果（この端末の表示から外す。F-67）

    private static let noFishKey = "fog.party.noFish"
    private static let fishCheckedKey = "fog.party.fishChecked"
    private static let hideNoFishKey = "fog.party.hideNoFish"

    /// 魚が写っていない写真の釣果を隠すか（設定 > 釣り人。既定はオン）
    static var hidesNoFish: Bool {
        get { UserDefaults.standard.object(forKey: hideNoFishKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hideNoFishKey) }
    }

    /// サムネイルに魚が写っていないと判定した仲間の釣果。相手の記録は変えず、この端末の表示にだけ使う
    private(set) var noFishIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "fog.party.noFish") ?? [])
    private var fishChecked: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "fog.party.fishChecked") ?? [])
    private var screening = false

    /// いま隠している件数（設定の表示用）
    var hiddenNoFishCount: Int {
        let me = AnglerSettings.deviceID
        return items.filter { $0.device != me && noFishIDs.contains($0.id.uuidString) }.count
    }

    /// 設定の切替のあと、表示を作り直させる
    func noFishSettingChanged() { revision += 1 }

    /// 仲間の釣果のうち、まだ見ていないサムネイルに魚が写っているかを端末内で判定する（1 件につき 1 回）。
    /// サムネイルがまだ届いていないものは次の回に見る
    func screenThumbnails() async {
        guard !screening else { return }
        screening = true
        defer { screening = false }
        let me = AnglerSettings.deviceID
        var changed = false
        for s in items where s.device != me && !fishChecked.contains(s.id.uuidString) {
            guard let data = thumbnail(for: s.id), let cg = UIImage(data: data)?.cgImage else { continue }
            let result = await FishDetector.check(cg)
            FishDetector.note(result, source: "仲間の釣果 \(s.species)")
            fishChecked.insert(s.id.uuidString)
            if !result.hasFish { noFishIDs.insert(s.id.uuidString); changed = true }
        }
        // 消えた釣果の分は片づける
        if !items.isEmpty {
            let alive = Set(items.map { $0.id.uuidString })
            noFishIDs.formIntersection(alive)
            fishChecked.formIntersection(alive)
        }
        UserDefaults.standard.set(Array(noFishIDs), forKey: Self.noFishKey)
        UserDefaults.standard.set(Array(fishChecked), forKey: Self.fishCheckedKey)
        if changed { revision += 1 }
    }

    // MARK: 仲間の釣果のサイズ（この端末だけの手入力）

    /// 仲間の釣果に、この端末で入れたサイズ（cm）。相手の記録は相手しか直せないので、こちらの表示にだけ使う。
    /// 相手があとでサイズを入れたら、相手の値を使う
    private(set) var localLengths: [String: Double] = (UserDefaults.standard.dictionary(forKey: "fog.party.localLengths") as? [String: Double]) ?? [:]

    func setLocalLength(id: UUID, cm: Double?) {
        if let cm, cm > 0 { localLengths[id.uuidString] = cm } else { localLengths[id.uuidString] = nil }
        UserDefaults.standard.set(localLengths, forKey: "fog.party.localLengths")
        revision += 1
    }

    func withLocalLength(_ item: SharedCatch) -> SharedCatch {
        guard item.lengthCm == nil, let cm = localLengths[item.id.uuidString] else { return item }
        var copy = item
        copy.lengthCm = cm
        return copy
    }

    /// 相手の記録にサイズが無いか（この端末で入れた値は数えない）
    func isUnmeasured(_ item: SharedCatch) -> Bool { (items.first { $0.id == item.id } ?? item).lengthCm == nil || isLocalLength(item) }

    /// そのサイズは、この端末で入れたものか
    func isLocalLength(_ item: SharedCatch) -> Bool {
        localLengths[item.id.uuidString] != nil && (items.first { $0.id == item.id }?.lengthCm == nil)
    }

    /// 仲間の端末の釣行（F-62）。新しい順
    var otherSessions: [SharedSession] {
        let me = AnglerSettings.deviceID
        return sessions.filter { $0.device != me }.sorted { $0.startedAt > $1.startedAt }
    }

    /// 仲間の投稿のサムネイル（取得済みのものだけ）
    func thumbnail(for id: UUID) -> Data? { try? Data(contentsOf: thumbsDir.appendingPathComponent(id.uuidString + ".jpg")) }

    /// 取得済みの写真本体（無ければ nil。`fetchPhoto` で取りに行く）
    func cachedPhoto(for id: UUID) -> Data? { try? Data(contentsOf: photosDir.appendingPathComponent(id.uuidString + ".jpg")) }

    /// 仲間の釣果の写真本体を取りに行く（全画面で見たときだけ。取れたら端末に残し、次からは通信しない）
    func fetchPhoto(for id: UUID) async -> Data? {
        if let d = cachedPhoto(for: id) { return d }
        guard let db = container?.publicCloudDatabase, !photoInFlight.contains(id) else { return nil }
        photoInFlight.insert(id)
        defer { photoInFlight.remove(id) }
        do {
            let result = try await db.records(for: [CKRecord.ID(recordName: id.uuidString)], desiredKeys: ["photo"])
            guard case .success(let record)? = result[CKRecord.ID(recordName: id.uuidString)],
                  let asset = record["photo"] as? CKAsset, let url = asset.fileURL, let data = try? Data(contentsOf: url) else { return nil }
            try? data.write(to: photosDir.appendingPathComponent(id.uuidString + ".jpg"), options: .atomic)
            return data
        } catch {
            Self.log.notice("party photo fetch failed: \(error.localizedDescription, privacy: .public)")
            lastError = Self.describe(error)
            return nil
        }
    }

    /// 写真本体（長辺 1,600 px の JPEG）をフォトライブラリから作る。無ければ nil
    private func photoJPEG(localIdentifier: String?) async -> Data? {
        guard let localIdentifier, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
              let cg = await PhotoLibraryService().image(for: asset, maxPixel: Self.photoMaxPixel) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: Self.photoQuality)
    }

    // MARK: 同期

    /// 画面を開いたとき用：前の同期から `maxAge` 秒たっていれば、30 分の間隔を待たずに取り直す。
    /// 仲間がサイズや釣った人を直したあと、こちらの画面が古いままにならないように（2026-11-12 開発者の指摘）
    func syncIfStale(store: FogStore, maxAge: TimeInterval = 60, now: Date = .now) async {
        if let last = lastSyncAt, now.timeIntervalSince(last) < maxAge { await screenThumbnails(); return }
        await syncIfNeeded(store: store, now: now, force: true)
    }

    /// 未送信の釣果を送り、全員の釣果を取る。30 分に 1 回（`force` で無視）
    func syncIfNeeded(store: FogStore, now: Date = .now, force: Bool = false) async {
        guard isAvailable, !syncing else { return }
        guard force || gate.tryAcquire("party", now: now) else { await screenThumbnails(); return }
        syncing = true
        defer { syncing = false }
        await uploadPending(store: store)
        await fetchAll()
        lastSyncAt = now
        save()
        await screenThumbnails()
    }

    /// 釣果の保存直後：その 1 件だけすぐ送る
    func upload(_ item: Catch, store: FogStore) async {
        guard isAvailable, let shared = shared(from: item, store: store) else { return }
        await upload([(shared, item.photoLocalIdentifier ?? item.photoLocalIdentifiers.first)], store: store)
    }

    /// 釣果を直した・消したあと：その釣行の要約（釣った人・尾数）をすぐ送り直す。仲間の画面の「仲間の釣行」に出る数が変わる
    func refreshSummary(sessionID: UUID, store: FogStore) async {
        guard isAvailable, let session = try? store.session(id: sessionID) else { return }
        await uploadSessions([session], store: store)
    }

    /// 釣果の削除：公開 DB からも消す（圏外なら次の同期で）
    func delete(catchID: UUID) async {
        uploaded[catchID.uuidString] = nil
        items.removeAll { $0.id == catchID }
        pendingDeletes.append(catchID.uuidString)
        save()
        await flushDeletes()
    }

    // MARK: 内部

    private func shared(from item: Catch, store: FogStore) -> SharedCatch? {
        guard item.coordinate.isPlausible || !item.species.isEmpty else { return nil }
        let spotName = (try? store.session(id: item.sessionID)).flatMap { try? store.spot(id: $0.spotID) }?.name ?? ""
        return SharedCatch.make(from: item, ownName: AnglerSettings.ownName, device: AnglerSettings.deviceID, spotName: spotName)
    }

    /// 内容の鍵。写真本体を付けるようになった（v2）ので、以前に送った分は一度だけ送り直す
    private func contentKey(_ s: SharedCatch, photo: String?) -> String {
        "v2|\(s.angler)|\(s.species)|\(s.lengthCm ?? -1)|\(s.at.timeIntervalSince1970)|\(s.spotName)|\(s.coordinate.latitude),\(s.coordinate.longitude)|\(photo ?? "")"
    }

    private func uploadPending(store: FogStore) async {
        let sessions = (try? store.sessions()) ?? []
        var todo: [(SharedCatch, String?)] = []
        for s in sessions {
            for c in s.catches {
                guard let shared = shared(from: c, store: store) else { continue }
                let photo = c.photoLocalIdentifier ?? c.photoLocalIdentifiers.first
                if uploaded[shared.id.uuidString] != contentKey(shared, photo: photo) { todo.append((shared, photo)) }
            }
        }
        // 消した釣行は公開 DB からも消す（F-62）
        let alive = Set(sessions.map { $0.id.uuidString })
        for id in Array(uploadedSessions.keys) where !alive.contains(id) {
            uploadedSessions[id] = nil
            pendingDeletes.append(SharedSession.recordPrefix + id)
        }
        await flushDeletes()
        // 1 回に 10 件まで（写真本体が 1 枚 数百 KB 付くため）
        for chunk in stride(from: 0, to: todo.count, by: 10).map({ Array(todo[$0..<min($0 + 10, todo.count)]) }) {
            await upload(chunk, store: store)
        }
        await uploadSessions(sessions, store: store)
    }

    /// 釣行の要約を送る（F-62）。内容が変わったものだけ。釣果と同じレコード型に `payload` の JSON として置く（新しいレコード型は要らない）
    private func uploadSessions(_ list: [Core.Session], store: FogStore) async {
        guard let db = container?.publicCloudDatabase else { return }
        var pending: [SharedSession] = []
        for s in list {
            let shared = SharedSession.make(from: s, spot: try? store.spot(id: s.spotID), ownName: AnglerSettings.ownName, device: AnglerSettings.deviceID)
            if uploadedSessions[s.id.uuidString] != shared.contentKey { pending.append(shared) }
        }
        guard !pending.isEmpty else { return }
        for chunk in stride(from: 0, to: pending.count, by: 50).map({ Array(pending[$0..<min($0 + 50, pending.count)]) }) {
            var records: [CKRecord] = []
            for s in chunk {
                guard let payload = try? FogJSON.encode(s, pretty: false) else { continue }
                let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: s.recordName))
                record["payload"] = String(decoding: payload, as: UTF8.self)
                record["at"] = s.startedAt
                record["updatedAt"] = s.updatedAt
                record["angler"] = s.owner
                record["device"] = s.device
                record["species"] = ""
                records.append(record)
            }
            guard !records.isEmpty else { continue }
            do {
                let result = try await db.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
                for (id, r) in result.saveResults {
                    switch r {
                    case .success:
                        if let s = chunk.first(where: { $0.recordName == id.recordName }) {
                            uploadedSessions[s.id.uuidString] = s.contentKey
                            self.sessions.removeAll { $0.id == s.id }
                            self.sessions.append(s)
                        }
                    case .failure(let e):
                        Self.log.notice("party session save failed \(id.recordName, privacy: .public): \(e.localizedDescription, privacy: .public)")
                        lastError = Self.describe(e)
                    }
                }
                revision += 1
                save()
            } catch {
                lastError = Self.describe(error)
                Self.log.notice("party session upload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func upload(_ list: [(SharedCatch, String?)], store: FogStore) async {
        guard let db = container?.publicCloudDatabase else { return }
        var records: [CKRecord] = []
        var tempFiles: [URL] = []
        var keys: [String: String] = [:]
        for (s, photoID) in list {
            let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: s.id.uuidString))
            guard let payload = try? FogJSON.encode(s, pretty: false) else { continue }
            keys[s.id.uuidString] = contentKey(s, photo: photoID)
            // 写真本体（長辺 1,600 px）。相手は全画面で見たときだけ取りに来る
            if let jpeg = await photoJPEG(localIdentifier: photoID) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("party-photo-\(s.id.uuidString).jpg")
                if (try? jpeg.write(to: url, options: .atomic)) != nil {
                    record["photo"] = CKAsset(fileURL: url)
                    tempFiles.append(url)
                }
            }
            record["payload"] = String(decoding: payload, as: UTF8.self)
            record["at"] = s.at
            record["updatedAt"] = s.updatedAt
            record["angler"] = s.angler
            record["device"] = s.device
            record["species"] = s.species
            if let thumb = store.thumbnail(catchID: s.id) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("party-\(s.id.uuidString).jpg")
                if (try? thumb.write(to: url, options: .atomic)) != nil {
                    record["thumbnail"] = CKAsset(fileURL: url)
                    tempFiles.append(url)
                }
            }
            records.append(record)
        }
        defer { tempFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        guard !records.isEmpty else { return }
        do {
            let result = try await db.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
            for (id, r) in result.saveResults {
                switch r {
                case .success:
                    if let s = list.first(where: { $0.0.id.uuidString == id.recordName })?.0 {
                        uploaded[id.recordName] = keys[id.recordName]
                        items.removeAll { $0.id == s.id }
                        items.append(s)
                    }
                case .failure(let e):
                    Self.log.notice("party save failed \(id.recordName, privacy: .public): \(e.localizedDescription, privacy: .public)")
                    lastError = Self.describe(e)
                }
            }
            revision += 1
            save()
        } catch {
            lastError = Self.describe(error)
            Self.log.notice("party upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func flushDeletes() async {
        guard let db = container?.publicCloudDatabase, !pendingDeletes.isEmpty else { return }
        let ids = pendingDeletes.map { CKRecord.ID(recordName: $0) }
        do {
            let result = try await db.modifyRecords(saving: [], deleting: ids, savePolicy: .allKeys, atomically: false)
            for (id, r) in result.deleteResults {
                switch r {
                case .success: pendingDeletes.removeAll { $0 == id.recordName }
                case .failure(let e):
                    // もう無いなら消えたものとして扱う
                    if let ck = e as? CKError, ck.code == .unknownItem { pendingDeletes.removeAll { $0 == id.recordName } }
                }
            }
            save()
        } catch {
            Self.log.notice("party delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 公開 DB の全件（本人と同行者の 2 台分なので多くて数百件）。サムネイルは仲間の分だけ取る
    private func fetchAll() async {
        guard let db = container?.publicCloudDatabase else { return }
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(format: "at > %@", Date(timeIntervalSince1970: 0) as NSDate))
        query.sortDescriptors = [NSSortDescriptor(key: "at", ascending: false)]
        var fetched: [SharedCatch] = []
        var fetchedSessions: [SharedSession] = []
        var assets: [UUID: URL] = [:]
        do {
            // 写真本体（photo）は一覧では取らない（全画面で見たときだけ）
            let keys = ["payload", "at", "updatedAt", "angler", "device", "species", "thumbnail"]
            var result = try await db.records(matching: query, inZoneWith: nil, desiredKeys: keys, resultsLimit: 200)
            var pages = 0
            while true {
                for (_, r) in result.matchResults {
                    guard case .success(let record) = r, let json = record["payload"] as? String else { continue }
                    // 釣行の要約（F-62）は同じレコード型に入っている。JSON の形で見分ける
                    if let session = try? FogJSON.decode(SharedSession.self, from: Data(json.utf8)), session.kind == SharedSession.kindValue {
                        fetchedSessions.append(session)
                        continue
                    }
                    guard let s = try? FogJSON.decode(SharedCatch.self, from: Data(json.utf8)) else { continue }
                    fetched.append(s)
                    if let asset = record["thumbnail"] as? CKAsset, let url = asset.fileURL { assets[s.id] = url }
                }
                pages += 1
                guard let cursor = result.queryCursor, pages < 10 else { break }
                result = try await db.records(continuingMatchFrom: cursor, desiredKeys: keys, resultsLimit: 200)
            }
        } catch {
            if let ck = error as? CKError, ck.code == .unknownItem {
                // レコード型がまだ無い（誰も投稿していない）
                lastError = nil
            } else {
                lastError = Self.describe(error)
                Self.log.notice("party fetch failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        let me = AnglerSettings.deviceID
        for s in fetched where s.device != me {
            let dest = thumbsDir.appendingPathComponent(s.id.uuidString + ".jpg")
            if let src = assets[s.id], !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: src, to: dest)
            }
        }
        // 消えた仲間の投稿のサムネイルを片づける
        let alive = Set(fetched.map { $0.id.uuidString + ".jpg" })
        for dir in [thumbsDir, photosDir] {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for f in files where !alive.contains(f) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
            }
        }
        items = fetched
        sessions = fetchedSessions
        lastError = nil
        revision += 1
    }

    private static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        switch ck.code {
        case .notAuthenticated: return "iCloud にサインインしていません"
        case .networkUnavailable, .networkFailure: return "圏外のため共有できません（次回に送ります）"
        case .permissionFailure: return "共有の権限がありません（CloudKit の設定を確認）"
        case .quotaExceeded: return "iCloud の容量が足りません"
        default: return ck.localizedDescription
        }
    }

    // MARK: 保存（App Group の JSON）

    private struct Persisted: Codable {
        var items: [SharedCatch]; var uploaded: [String: String]; var pendingDeletes: [String]; var gate: FetchGate; var lastSyncAt: Date?
        /// F-62 で追加（古い保存データには無い）
        var sessions: [SharedSession]?
        var uploadedSessions: [String: String]?
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL), let p = try? FogJSON.decode(Persisted.self, from: data) else { return }
        items = p.items; uploaded = p.uploaded; pendingDeletes = p.pendingDeletes; gate = p.gate; lastSyncAt = p.lastSyncAt
        sessions = p.sessions ?? []; uploadedSessions = p.uploadedSessions ?? [:]
        revision += 1
    }

    private func save() {
        guard let data = try? FogJSON.encode(Persisted(items: items, uploaded: uploaded, pendingDeletes: pendingDeletes, gate: gate, lastSyncAt: lastSyncAt, sessions: sessions, uploadedSessions: uploadedSessions), pretty: false) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
