import Foundation
import SwiftData
import Core

/// `Core.Catch` の SwiftData 表現。釣果時の環境は不変のスナップショットなので JSON で埋め込む。
@Model
final class CatchRecord {
    var uuid: UUID = UUID()
    var pointID: UUID? = nil
    var at: Date = Date()
    var latitude: Double = 0
    var longitude: Double = 0

    var species: String = ""
    var speciesConfidence: Double = 0
    /// `[SpeciesCandidate]` の JSON。
    var speciesCandidatesData: Data? = nil
    var speciesCorrected: Bool = false

    var lengthCm: Double? = nil
    var lengthErrorCm: Double? = nil

    var photoLocalIdentifier: String? = nil
    /// `[String]` の JSON。
    var photoLocalIdentifiersData: Data? = nil
    /// アプリ内に持つのはサムネイルだけ（§6）。L5 で入れる。
    @Attribute(.externalStorage) var thumbnailJPEG: Data? = nil

    var tackleKindRaw: String? = nil
    var tackleID: UUID? = nil
    var rigID: UUID? = nil

    /// `EnvSnapshot` の JSON。
    var envData: Data? = nil
    var released: Bool = true
    /// `[String]` の JSON（足場・時間帯・天気。F-31）
    var sceneTagsData: Data? = nil
    /// 釣った人（F-54）。nil は自分
    var angler: String? = nil

    var session: SessionRecord? = nil

    init(core: Catch, session: SessionRecord?) {
        uuid = core.id
        self.session = session
        apply(core)
    }

    func apply(_ core: Catch) {
        pointID = core.pointID
        at = core.at
        latitude = core.coordinate.latitude
        longitude = core.coordinate.longitude
        species = core.species
        speciesConfidence = core.speciesConfidence
        speciesCandidatesData = core.speciesCandidates.isEmpty ? nil : BlobCodec.encode(core.speciesCandidates)
        speciesCorrected = core.speciesCorrected
        lengthCm = core.lengthCm
        lengthErrorCm = core.lengthErrorCm
        photoLocalIdentifier = core.photoLocalIdentifier
        photoLocalIdentifiersData = core.photoLocalIdentifiers.isEmpty ? nil : BlobCodec.encode(core.photoLocalIdentifiers)
        tackleKindRaw = core.tackle?.rawValue
        tackleID = core.tackleID
        rigID = core.rigID
        envData = BlobCodec.encode(core.env)
        released = core.released
        sceneTagsData = core.sceneTags.flatMap { $0.isEmpty ? nil : BlobCodec.encode($0) }
        angler = core.angler
    }

    func core(sessionID: UUID) -> Catch {
        Catch(
            id: uuid,
            sessionID: sessionID,
            at: at,
            coordinate: Coordinate(latitude: latitude, longitude: longitude),
            species: species,
            speciesConfidence: speciesConfidence,
            lengthCm: lengthCm,
            lengthErrorCm: lengthErrorCm,
            photoLocalIdentifier: photoLocalIdentifier,
            tackle: tackleKindRaw.flatMap(TackleKind.init(rawValue:)),
            rigID: rigID,
            env: BlobCodec.decode(EnvSnapshot.self, from: envData),
            released: released,
            pointID: pointID,
            speciesCandidates: BlobCodec.decode([SpeciesCandidate].self, from: speciesCandidatesData) ?? [],
            speciesCorrected: speciesCorrected,
            photoLocalIdentifiers: BlobCodec.decode([String].self, from: photoLocalIdentifiersData) ?? [],
            tackleID: tackleID,
            sceneTags: BlobCodec.decode([String].self, from: sceneTagsData),
            angler: angler
        )
    }
}
