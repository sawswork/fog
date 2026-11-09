import Foundation

/// 釣果1尾。撮影だけで成立する（§4）。魚種・サイズは後から修正できる（F-24）。
public struct Catch: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    /// 立ち位置（メッシュ）。L4 以降で付く。
    public var pointID: UUID?
    public var at: Date
    public var coordinate: Coordinate

    /// 確定した魚種の標準和名。低確信度でも最有力候補が入る。
    public var species: String
    public var speciesConfidence: Double
    /// 判定時の候補（最有力を先頭に最大3種）。
    public var speciesCandidates: [SpeciesCandidate]
    /// ユーザーが魚種を修正したか（判定モデルの補正に使う）。
    public var speciesCorrected: Bool

    /// 全長（cm）。LiDAR 深度のない写真は nil（サイズ未計測、F-12）。
    public var lengthCm: Double?
    /// 推定幅（±cm）。自己記録の判定に使う。
    public var lengthErrorCm: Double?

    /// ベストショットの PHAsset localIdentifier。アプリ内に写真そのものは持たない（§6）。
    public var photoLocalIdentifier: String?
    /// 同一個体にまとめた全写真（ベストショットを含む。F-13）。
    public var photoLocalIdentifiers: [String]

    public var tackle: TackleKind?
    public var tackleID: UUID?
    public var rigID: UUID?

    /// 撮影時刻の環境（直近スナップショットの補間。潮と月は撮影時刻で再計算）。
    public var env: EnvSnapshot?
    /// 既定はリリース（§4）。
    public var released: Bool
    /// 写真の背景から推定した足場・時間帯・天気（F-31）。古いデータは nil
    public var sceneTags: [String]?
    /// 釣った人（F-54）。nil は自分（この端末の持ち主）。他の人の魚を自分の端末で撮ったときに名前が入る
    public var angler: String?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        at: Date,
        coordinate: Coordinate,
        species: String,
        speciesConfidence: Double,
        lengthCm: Double? = nil,
        lengthErrorCm: Double? = nil,
        photoLocalIdentifier: String? = nil,
        tackle: TackleKind? = nil,
        rigID: UUID? = nil,
        env: EnvSnapshot? = nil,
        released: Bool = true,
        pointID: UUID? = nil,
        speciesCandidates: [SpeciesCandidate] = [],
        speciesCorrected: Bool = false,
        photoLocalIdentifiers: [String] = [],
        tackleID: UUID? = nil,
        sceneTags: [String]? = nil,
        angler: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.pointID = pointID
        self.at = at
        self.coordinate = coordinate
        self.species = species
        self.speciesConfidence = speciesConfidence
        self.speciesCandidates = speciesCandidates
        self.speciesCorrected = speciesCorrected
        self.lengthCm = lengthCm
        self.lengthErrorCm = lengthErrorCm
        self.photoLocalIdentifier = photoLocalIdentifier
        self.photoLocalIdentifiers = photoLocalIdentifiers
        self.tackle = tackle
        self.tackleID = tackleID
        self.rigID = rigID
        self.env = env
        self.released = released
        self.sceneTags = sceneTags
        self.angler = angler
    }

    /// 自分の釣果か。`ownName` は設定した自分の名前（nil や空なら、名前の入っていない釣果だけが自分）
    public func isOwn(ownName: String?) -> Bool {
        guard let angler, !angler.isEmpty else { return true }
        guard let ownName, !ownName.isEmpty else { return false }
        return angler == ownName
    }

    public var isSizeMeasured: Bool { lengthCm != nil }
}
