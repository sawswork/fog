import Foundation
import Photos
import Core

/// 標準カメラで撮った写真の自動取り込み（F-08）。釣行中の時刻・位置に一致する写真を釣果にする。
/// 釣行終了時とフォアグラウンド復帰時に呼ぶ。取り込み済みの写真は再取り込みしない。
@MainActor
final class PhotoImportService {
    private let store: FogStore
    private let capture: CaptureService
    private let library = PhotoLibraryService()
    private static let importedKey = "fog.importedPhotoIdentifiers"

    init(store: FogStore, capture: CaptureService) {
        self.store = store
        self.capture = capture
    }

    private var imported: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.importedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(2000)), forKey: Self.importedKey) }
    }

    /// 釣行 1 件ぶんを取り込む。取り込んだ件数を返す。
    @discardableResult
    func importPhotos(for sessionID: UUID) async -> Int {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
              let session = try? store.session(id: sessionID) else { return 0 }
        let coordinate = (try? store.spot(id: session.spotID))?.coordinate
        let end = session.endedAt ?? Date()
        let known = Set(session.catches.flatMap { [$0.photoLocalIdentifier].compactMap { $0 } + $0.photoLocalIdentifiers })
        var done = imported
        var count = 0
        // 写真ライブラリの検索はメインでしない（ライブラリが大きいと数秒かかる）
        let library = self.library
        let from = session.startedAt
        let assets = await Task.detached(priority: .utility) { library.assets(from: from, to: end, near: coordinate) }.value
        for asset in assets {
            let id = asset.localIdentifier
            if known.contains(id) || done.contains(id) { continue }
            guard let image = await library.image(for: asset, maxPixel: 2048) else { continue }
            let location = asset.location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
            // メジャーが写っていればサイズも（F-61）
            let measurement = await TapeSizeEstimator.estimate(image)
            if await capture.recordImported(image: image, photoIdentifier: id, at: asset.creationDate ?? end, coordinate: location, session: session, measurement: measurement) != nil {
                count += 1
            }
            done.insert(id)
        }
        imported = done
        return count
    }

    struct ManualResult { var imported = 0; var measured = 0; var skipped = 0 }

    /// 選んだ写真を手で取り込む（F-61）。釣行中の写真はその釣行へ、そうでなければ撮影時刻・位置に釣行を作って入れる。
    /// 取り込み済みの写真は飛ばす
    func importAssets(identifiers: [String]) async -> ManualResult {
        var result = ManualResult()
        guard !identifiers.isEmpty else { return result }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { a, _, _ in assets.append(a) }
        let sessions = (try? store.sessions()) ?? []
        let knownPhotos = Set(sessions.flatMap(\.catches).flatMap { [$0.photoLocalIdentifier].compactMap { $0 } + $0.photoLocalIdentifiers })
        var done = imported
        for asset in assets.sorted(by: { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }) {
            let id = asset.localIdentifier
            if knownPhotos.contains(id) { result.skipped += 1; continue }
            guard let image = await library.image(for: asset, maxPixel: 2048) else { result.skipped += 1; continue }
            let date = asset.creationDate ?? Date()
            let location = asset.location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
            // 時刻を含む釣行があればそれ、無ければ作る
            let session: Core.Session
            if let s = ((try? store.sessions()) ?? []).first(where: { $0.startedAt <= date && date <= ($0.endedAt ?? $0.startedAt.addingTimeInterval(8 * 3600)) }) {
                session = s
            } else {
                session = capture.pastSession(at: date, coordinate: location)
            }
            let measurement = await TapeSizeEstimator.estimate(image)
            if await capture.recordImported(image: image, photoIdentifier: id, at: date, coordinate: location, session: session, measurement: measurement) != nil {
                result.imported += 1
                if measurement != nil { result.measured += 1 }
            } else { result.skipped += 1 }
            done.insert(id)
        }
        imported = done
        return result
    }
}
