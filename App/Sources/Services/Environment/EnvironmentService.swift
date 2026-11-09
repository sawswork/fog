import Foundation
import Core
import os

/// §2 の環境情報をまとめて扱う。
/// - 外部 API（WeatherKit / Open-Meteo）は釣り場ごとに 1 時間に 1 回まで（`FetchGate`）
/// - 取得結果は `ForecastCache` に保存し、圏外ではキャッシュだけで `EnvSnapshot` を組み立てる
/// - 潮汐・天文は Core で計算（通信なし）
@MainActor
@Observable
final class EnvironmentService {
    private(set) var cache = ForecastCache()
    private(set) var gate = FetchGate()
    private(set) var lastError: String?
    let barometer: BarometerService
    private let weather: WeatherProviding
    private let marine: MarineProviding
    private let catalog: TideCatalog
    private let storeURL: URL?
    private static let log = Logger(subsystem: "fog", category: "environment")

    /// 本番構成（WeatherKit / Open-Meteo / 端末気圧計 / 同梱分潮データ）。
    static func live() -> EnvironmentService {
        EnvironmentService(weather: WeatherKitProvider(), marine: OpenMeteoMarineClient(), barometer: BarometerService(),
                           catalog: .bundled(), storeURL: defaultStoreURL())
    }

    init(weather: WeatherProviding, marine: MarineProviding, barometer: BarometerService, catalog: TideCatalog, storeURL: URL?) {
        self.weather = weather
        self.marine = marine
        self.barometer = barometer
        self.catalog = catalog
        self.storeURL = storeURL
        load()
    }

    // MARK: 取得（1 時間に 1 回）

    /// 必要なら気象と海況を取得してキャッシュを更新する。圏外や失敗でも投げない（キャッシュで動く）。
    func refreshIfNeeded(at coordinate: Coordinate, now: Date = .now, force: Bool = false) async {
        let key = ForecastCache.key(for: coordinate)
        var changed = false
        if force || gate.tryAcquire("weather:" + key, now: now) {
            do {
                let samples = try await weather.fetch(at: coordinate, from: now.addingTimeInterval(-24 * 3600), to: now.addingTimeInterval(10 * 86_400))
                cache.mergeWeather(coordinate, samples: samples, fetchedAt: now)
                changed = true
                lastError = nil
            } catch {
                gate.release("weather:" + key)
                lastError = error.localizedDescription
                Self.log.error("weather fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if force || gate.tryAcquire("marine:" + key, now: now) {
            do {
                let target = cache.entry(for: coordinate)?.marineGrid ?? coordinate
                if let result = try await marine.fetch(around: target) {
                    cache.mergeMarine(coordinate, grid: result.grid, samples: result.samples, fetchedAt: now)
                    changed = true
                } else {
                    Self.log.notice("marine: no sea grid near \(key, privacy: .public)")
                }
            } catch {
                gate.release("marine:" + key)
                lastError = error.localizedDescription
                Self.log.error("marine fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // 変わったときだけ保存する（毎回のホーム再計算で全キャッシュを書き出して 3 秒止まっていた。2026-11-09 診断ログ）
        if changed {
            cache.prune(now: now)
            save()
        }
    }

    // MARK: スナップショット（通信なし）

    func tideStation(near coordinate: Coordinate) -> TideStation? { catalog.nearest(to: coordinate) }

    func builder(for coordinate: Coordinate) -> EnvSnapshotBuilder {
        EnvSnapshotBuilder(tideStation: tideStation(near: coordinate))
    }

    func inputs(for coordinate: Coordinate) -> EnvSnapshotBuilder.Inputs {
        let entry = cache.entry(for: coordinate)
        return EnvSnapshotBuilder.Inputs(weather: entry?.weather ?? [], marine: entry?.marine ?? [], pressure: barometer.samples)
    }

    /// 指定時刻・位置のスナップショット。予報・キャッシュ・端末計算だけで必ず組み立てる。
    func snapshot(at date: Date, coordinate: Coordinate) -> EnvSnapshot {
        builder(for: coordinate).build(at: date, coordinate: coordinate, inputs: inputs(for: coordinate))
    }

    /// 釣れ率の計算用：潮位・変化率・潮名・気象は入るが、次の満干は探さない（釣り場カード・港の候補のように点が多い所で使う。`snapshot` の 10 倍以上速い）
    func scoreSnapshot(at date: Date, coordinate: Coordinate) -> EnvSnapshot {
        let b = builder(for: coordinate)
        return b.buildForScore(at: date, coordinate: coordinate, inputs: inputs(for: coordinate), tide: b.tideStation.map { TideEngine(station: $0) })
    }

    /// 気象・海況だけのスナップショット（潮汐の満干探索をしない。表や週行・ウィジェットのように潮が要らない所で使う。10 倍以上速い）
    func weatherSnapshot(at date: Date, coordinate: Coordinate) -> EnvSnapshot {
        builder(for: coordinate).build(at: date, coordinate: coordinate, inputs: inputs(for: coordinate), tide: nil, extremes: [])
    }

    /// 予報が届いている最後の時刻（ホームのグラフで線を薄くする境界）。
    func forecastHorizon(for coordinate: Coordinate) -> Date? { cache.weatherHorizon(for: coordinate) }

    /// 通信復帰後：予報で埋めたスナップショットを実況に差し替える（F-06）。
    func backfill(_ session: Core.Session, now: Date = .now) async -> Core.Session {
        guard session.snapshots.contains(where: { $0.isForecast }) || session.catches.contains(where: { $0.env?.isForecast == true }) else { return session }
        guard let spotCoordinate = session.snapshots.first?.coordinate ?? session.catches.first?.coordinate else { return session }
        do {
            let observed = try await weather.fetch(at: spotCoordinate, from: session.startedAt.addingTimeInterval(-3600), to: min(now, session.endedAt ?? now))
            cache.mergeWeather(spotCoordinate, samples: observed, fetchedAt: now)
            save()
            let b = builder(for: spotCoordinate)
            var s = session
            s.snapshots = s.snapshots.map { b.replacingForecast(in: $0, with: observed) }
            s.catches = s.catches.map { c in
                var c = c
                if let env = c.env { c.env = b.replacingForecast(in: env, with: observed) }
                return c
            }
            return s
        } catch {
            Self.log.notice("backfill skipped: \(error.localizedDescription, privacy: .public)")
            return session
        }
    }

    // MARK: 永続化（App Group の JSON）

    struct Persisted: Codable {
        var cache: ForecastCache
        var gate: FetchGate
    }

    nonisolated static func defaultStoreURL() -> URL? {
        let base = PersistenceController.storeURL().deletingLastPathComponent()
        return base.appendingPathComponent("environment-cache.json")
    }

    private func load() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let p = Perf.measure("予報キャッシュの読み込み", { try? FogJSON.decode(Persisted.self, from: data) }) else { return }
        cache = p.cache
        gate = p.gate
    }

    /// 書き出しは裏で（数千の日付を JSON にする。メインスレッドでは行わない）
    private func save() {
        guard let storeURL else { return }
        let persisted = Persisted(cache: cache, gate: gate)
        Task.detached(priority: .utility) {
            guard let data = try? FogJSON.encode(persisted, pretty: false) else { return }
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    /// 設定画面「情報源」用のクレジット。
    static let openMeteoCredit = (text: OpenMeteoMarine.creditText, url: URL(string: OpenMeteoMarine.creditURL)!)
}
