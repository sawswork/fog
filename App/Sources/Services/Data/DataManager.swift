import Foundation
import Photos
import UIKit
import Core
import os

/// データ管理（§6、L15）：CSV／JSON エクスポート、写真付き ZIP、JSON の復元、全データ削除。
@MainActor
final class DataManager {
    private let store: FogStore
    private static let log = Logger(subsystem: "fog", category: "data")

    init(store: FogStore) { self.store = store }

    private func bundle() throws -> ExportBundle {
        ExportBundle(spots: try store.spots(), sessions: try store.sessions(), tackles: try store.tackles(), rigs: try store.rigs(), species: try store.species())
    }

    private var exportDir: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"; return f.string(from: Date())
    }

    /// JSON（全データ）。復元に使える。
    func exportJSON() throws -> URL {
        let url = exportDir.appendingPathComponent("fog-\(stamp()).json")
        try bundle().jsonData().write(to: url, options: .atomic)
        return url
    }

    /// CSV 3 表をまとめたフォルダ。
    func exportCSV() throws -> [URL] {
        let b = try bundle()
        let base = exportDir.appendingPathComponent("fog-csv-\(stamp())", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let files = [("catches.csv", CSVExport.catches(b.sessions, spots: b.spots)),
                     ("sessions.csv", CSVExport.sessions(b.sessions, spots: b.spots)),
                     ("snapshots.csv", CSVExport.snapshots(b.sessions))]
        var urls: [URL] = []
        for (name, text) in files {
            let url = base.appendingPathComponent(name)
            try text.data(using: .utf8)!.write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }

    /// 写真付き ZIP：JSON と、各釣果の写真（フォトライブラリから書き出し）。
    func exportZipWithPhotos(progress: @escaping (Double) -> Void) async throws -> URL {
        let b = try bundle()
        let work = exportDir.appendingPathComponent("fog-\(stamp())", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try b.jsonData().write(to: work.appendingPathComponent("fog.json"), options: .atomic)
        let catches = b.sessions.flatMap(\.catches)
        let identifiers = catches.flatMap { [$0.photoLocalIdentifier].compactMap { $0 } + $0.photoLocalIdentifiers }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(Set(identifiers)), options: nil)
        var done = 0
        for i in 0..<assets.count {
            let asset = assets.object(at: i)
            let data: Data? = await withCheckedContinuation { cont in
                let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = true; options.deliveryMode = .highQualityFormat
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in cont.resume(returning: data) }
            }
            if let data {
                let safe = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
                try? data.write(to: work.appendingPathComponent("photos/\(safe).jpg"))
            }
            done += 1
            progress(Double(done) / Double(max(1, assets.count)))
        }
        let zip = exportDir.appendingPathComponent("fog-\(stamp()).zip")
        try? FileManager.default.removeItem(at: zip)
        try zipDirectory(work, to: zip)
        return zip
    }

    /// NSFileCoordinator の zip 読み出し（追加ライブラリなし）。
    private func zipDirectory(_ dir: URL, to zip: URL) throws {
        var error: NSError?
        var inner: Error?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &error) { tmp in
            do { try FileManager.default.copyItem(at: tmp, to: zip) } catch { inner = error }
        }
        if let error { throw error }
        if let inner { throw inner }
    }

    /// JSON の復元：同じ ID は上書き、無いものは追加。
    func importJSON(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let b = try ExportBundle.from(json: data)
        for s in b.spots { try store.upsert(s) }
        for t in b.tackles { try store.upsert(t) }
        for r in b.rigs { try store.upsert(r) }
        if !b.species.isEmpty { try store.mergeSpecies(b.species) }
        for p in b.points { try store.upsert(p) }
        for s in b.sessions { try store.upsert(s) }
        return b.sessions.count
    }

    /// 全データ削除（分析に即時反映）。キャッシュと設定も消す。
    func deleteAll() throws {
        try store.deleteAll()
        for key in ["fog.didSeedSampleSession", "fog.didRemoveSampleSession", "fog.importedPhotoIdentifiers", "fog.speciesCorrections", "fog.currentTackle", "fog.currentRig", "fog.homeSpotID", "fog.rigParts", "fog.rigCleared"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        FogShared.currentTackle = nil
        if let url = EnvironmentService.defaultStoreURL() { try? FileManager.default.removeItem(at: url) }
        try store.mergeSpecies(Species.initialCatalog)
    }
}
