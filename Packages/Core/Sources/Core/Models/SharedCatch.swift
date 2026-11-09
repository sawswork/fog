import Foundation

/// 仲間と共有する釣果（F-54）。2 台の iPhone（本人と同行者）の間で、どちらの端末で撮った魚も「釣果情報」として見えるようにする。
/// 写真そのものは送らず、サムネイルと要約だけ。保存先はアプリの CloudKit コンテナの公開データベース（自前サーバーなし）。
public struct SharedCatch: Codable, Identifiable, Hashable, Sendable {
    /// 元の `Catch.id`（端末をまたいで同じ）
    public var id: UUID
    /// 釣った人の名前
    public var angler: String
    /// 投稿した端末（自分の投稿を見分ける）
    public var device: String
    public var species: String
    public var lengthCm: Double?
    public var at: Date
    public var coordinate: Coordinate
    public var spotName: String
    public var sceneTags: [String]?
    public var tideName: String?
    public var updatedAt: Date

    public init(id: UUID, angler: String, device: String, species: String, lengthCm: Double?, at: Date, coordinate: Coordinate, spotName: String,
                sceneTags: [String]? = nil, tideName: String? = nil, updatedAt: Date) {
        self.id = id; self.angler = angler; self.device = device; self.species = species; self.lengthCm = lengthCm; self.at = at
        self.coordinate = coordinate; self.spotName = spotName; self.sceneTags = sceneTags; self.tideName = tideName; self.updatedAt = updatedAt
    }

    /// 釣果から作る。`angler` が無い釣果は端末の持ち主（`ownName`）の魚
    public static func make(from item: Catch, ownName: String, device: String, spotName: String, updatedAt: Date = .now) -> SharedCatch {
        SharedCatch(id: item.id, angler: (item.angler?.isEmpty == false ? item.angler : nil) ?? ownName, device: device, species: item.species,
                    lengthCm: item.lengthCm, at: item.at, coordinate: item.coordinate, spotName: spotName, sceneTags: item.sceneTags,
                    tideName: item.env?.tideName, updatedAt: updatedAt)
    }

    /// 「アイナメ 45cm」のような見出し
    public var headline: String {
        let name = species.isEmpty ? "魚" : species
        guard let l = lengthCm else { return name }
        return "\(name) \(Int(l.rounded()))cm"
    }

    /// 釣果情報の地図ピンに載せる形（F-44 と同じ `FeedCatch`）。出典は「仲間の釣果」
    public func feedCatch(sourceTitle: String = "仲間の釣果") -> FeedCatch {
        FeedCatch(itemID: "shared:" + id.uuidString, title: "\(headline)（\(angler)）", link: nil, publishedAt: at, feedTitle: sourceTitle,
                  placeName: spotName.isEmpty ? "釣り場" : spotName, coordinate: coordinate, species: species.isEmpty ? [] : [species])
    }
}
