import Foundation
import Core

/// 釣行の時間範囲の釣れ率の推移を再計算する（答え合わせ F-29、精度の集計 F-42）。
/// 気象は予報キャッシュにその時間の値があればそれを、無ければ釣行中に保存したスナップショットを使う。
@MainActor
enum SessionReviewer {
    struct Output {
        let points: [ScorePoint]
        let result: SessionReview.Result?
        let accuracy: SessionReview.Accuracy
        /// 釣行の時間範囲（前後 1 時間）の潮位曲線（10 分刻み、推算）。釣行詳細の「条件の推移」に使う
        let tide: [(at: Date, levelCm: Double)]
        let extremes: [TideExtreme]
    }

    static func review(_ session: Core.Session, services: AppServices, engine: ScoreEngine? = nil) -> Output? {
        let env = services.environment
        let coordinate = (try? services.store.spot(id: session.spotID))?.coordinate ?? session.snapshots.first?.coordinate ?? session.catches.first?.coordinate
        guard let coordinate, coordinate.isPlausible else { return nil }
        let end = session.endedAt ?? Date()
        let from = session.startedAt.addingTimeInterval(-3600), to = end.addingTimeInterval(3600)
        var inputs = env.inputs(for: coordinate)
        if !inputs.weather.contains(where: { $0.at >= from && $0.at <= to }) {
            inputs.weather = session.snapshots.map { e in
                WeatherSample(at: e.at, airTemperatureC: e.airTemperatureC, humidity: e.humidity, conditionCode: e.conditionCode, windSpeedMS: e.windSpeedMS,
                              windGustMS: e.windGustMS, windDirectionDeg: e.windDirectionDeg, pressureHPa: e.pressureHPa, cloudCover: e.cloudCover,
                              precipitationMM: e.precipitationMM, visibilityM: e.visibilityM, isForecast: e.isForecast)
            }
        }
        let engine = engine ?? Self.engine(excluding: session.id, services: services)
        let tide = env.tideStation(near: coordinate).map { TideEngine(station: $0) }
        let extremes = tide?.extremes(from: from.addingTimeInterval(-6 * 3600), to: to.addingTimeInterval(6 * 3600)) ?? []
        let builder = env.builder(for: coordinate)
        let tz = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let points = ScoreTimeline.compute(engine: engine, coordinate: coordinate, from: from, to: to, stepMinutes: 15, timeZone: tz) { t in
            builder.build(at: t, coordinate: coordinate, inputs: inputs, tide: tide, extremes: extremes)
        }
        let times = session.catches.map(\.at)
        let curve: [(at: Date, levelCm: Double)] = tide.map { engine in
            stride(from: 0, through: to.timeIntervalSince(from), by: 600).map { (at: from.addingTimeInterval($0), levelCm: engine.level(at: from.addingTimeInterval($0))) }
        } ?? []
        return Output(points: points,
                      result: SessionReview.evaluate(points: points, catchTimes: times, from: session.startedAt, to: end),
                      accuracy: SessionReview.split(points: points, catchTimes: times, from: session.startedAt, to: end),
                      tide: curve, extremes: extremes.filter { $0.at >= from && $0.at <= to })
    }

    /// 自分データの重み付きエンジン（対象の釣行は学習から外す）
    static func engine(excluding id: UUID?, services: AppServices) -> ScoreEngine {
        let sessions = (try? services.store.ownSessions()) ?? []
        let spots = (try? services.store.spots()) ?? []
        let personal = PersonalModel.learn(from: sessions.filter { !$0.isActive && $0.id != id }, coordinateOf: { s in spots.first { $0.id == s.spotID }?.coordinate })
        return ScoreEngine(personal: personal.total.hours >= 1 ? personal : nil)
    }

    /// 全釣行の精度（終わった釣行だけ。学習は全釣行で 1 回）
    static func accuracy(services: AppServices) -> SessionReview.Accuracy {
        let sessions = ((try? services.store.sessions()) ?? []).filter { !$0.isActive }
        let engine = Self.engine(excluding: nil, services: services)
        return SessionReview.aggregate(sessions.compactMap { review($0, services: services, engine: engine)?.accuracy })
    }
}
