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
            guard let image = await library.image(for: asset) else { continue }
            let location = asset.location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
            if await capture.recordImported(image: image, photoIdentifier: id, at: asset.creationDate ?? end, coordinate: location, session: session) != nil {
                count += 1
            }
            done.insert(id)
        }
        imported = done
        return count
    }
}
