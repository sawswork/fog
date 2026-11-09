import Foundation
import XCTest
@testable import Core

/// L3 受け入れ条件: 任意の緯度経度・時刻で EnvSnapshot が組み立てられる。機内モード（キャッシュのみ）でも組み立てられる。
/// 漁港内の座標で Open-Meteo が陸扱いになるケースを回避できる。1 時間に 1 回を超えて外部 API を叩かない。
final class EnvironmentTests: XCTestCase {
    let hakodate = Coordinate(latitude: 41.7822, longitude: 140.7192)
    let t0 = Date(timeIntervalSince1970: 1_792_269_000) // 2026-10-18 05:30 JST

    func weather(hoursFrom start: Date, count: Int, forecast: Bool) -> [WeatherSample] {
        (0..<count).map { i in
            var s = WeatherSample(at: start.addingTimeInterval(Double(i) * 3600), isForecast: forecast)
            s.airTemperatureC = 10 + Double(i)
            s.windSpeedMS = 2 + Double(i) * 0.5
            s.windDirectionDeg = 300
            s.pressureHPa = 1015 - Double(i) * 0.4
            s.conditionCode = "clear"
            return s
        }
    }

    func testSnapshotFromCacheOnlyHasAllSections() {
        let station = TideCatalog.bundled().nearest(to: hakodate)
        let builder = EnvSnapshotBuilder(tideStation: station)
        let start = t0.addingTimeInterval(-2 * 3600)
        let inputs = EnvSnapshotBuilder.Inputs(
            weather: weather(hoursFrom: start, count: 12, forecast: true),
            marine: (0..<12).map { MarineSample(at: start.addingTimeInterval(Double($0) * 3600), waveHeightM: 0.3 + Double($0) * 0.01, seaSurfaceTempC: 15.5) },
            pressure: [PressureSample(at: t0.addingTimeInterval(-3 * 3600), pressureHPa: 1016.0), PressureSample(at: t0.addingTimeInterval(-600), pressureHPa: 1014.8)]
        )
        let env = builder.build(at: t0, coordinate: hakodate, inputs: inputs)
        XCTAssertEqual(env.airTemperatureC!, 12, accuracy: 0.01)     // 2 時間後 → 10 + 2
        XCTAssertEqual(env.windSpeedMS!, 3, accuracy: 0.01)
        XCTAssertEqual(env.windDirectionDeg, 300)
        XCTAssertEqual(env.conditionCode, "clear")
        XCTAssertTrue(env.isForecast)
        XCTAssertEqual(env.measuredPressureHPa, 1014.8)
        XCTAssertEqual(env.pressureTrend3hHPa!, -1.2, accuracy: 0.01)
        XCTAssertEqual(env.waveHeightM!, 0.32, accuracy: 0.001)
        XCTAssertEqual(env.seaSurfaceTempC, 15.5)
        XCTAssertNotNil(env.sunriseAt)
        XCTAssertNotNil(env.sunsetAt)
        XCTAssertNotNil(env.moonAge)
        XCTAssertNotNil(env.tideName)
        if station != nil {
            XCTAssertNotNil(env.tideLevelCm)
            XCTAssertNotNil(env.tideRateCmPerHour)
            XCTAssertNotNil(env.nextHighTideAt)
            XCTAssertNotNil(env.nextLowTideAt)
        }
    }

    func testSnapshotWithNoCacheStillHasOfflineItems() {
        let builder = EnvSnapshotBuilder(tideStation: nil)
        let env = builder.build(at: t0, coordinate: Coordinate(latitude: 35.0, longitude: 139.0), inputs: .init())
        XCTAssertNil(env.airTemperatureC)
        XCTAssertTrue(env.isForecast)
        XCTAssertNotNil(env.sunriseAt)
        XCTAssertNotNil(env.moonAge)
        XCTAssertNotNil(env.tideName)
    }

    func testObservationsReplaceForecast() {
        let builder = EnvSnapshotBuilder(tideStation: nil)
        var env = builder.build(at: t0, coordinate: hakodate, inputs: .init(weather: weather(hoursFrom: t0, count: 3, forecast: true)))
        XCTAssertTrue(env.isForecast)
        var obs = WeatherSample(at: t0.addingTimeInterval(600), isForecast: false)
        obs.airTemperatureC = 8.5
        obs.windSpeedMS = 6
        env = builder.replacingForecast(in: env, with: [obs])
        XCTAssertFalse(env.isForecast)
        XCTAssertEqual(env.airTemperatureC, 8.5)
        XCTAssertEqual(env.windSpeedMS, 6)
        XCTAssertEqual(env.windDirectionDeg, 300) // 観測に無い項目は予報値のまま
    }

    func testForecastCacheMergeKeepsObservations() {
        var cache = ForecastCache()
        let obs = weather(hoursFrom: t0, count: 2, forecast: false)
        cache.mergeWeather(hakodate, samples: obs, fetchedAt: t0)
        let fc = weather(hoursFrom: t0, count: 5, forecast: true)
        cache.mergeWeather(hakodate, samples: fc, fetchedAt: t0.addingTimeInterval(60))
        let e = cache.entry(for: hakodate)!
        XCTAssertEqual(e.weather.count, 5)
        XCTAssertFalse(e.weather[0].isForecast)
        XCTAssertFalse(e.weather[1].isForecast)
        XCTAssertTrue(e.weather[2].isForecast)
        XCTAssertEqual(cache.weatherHorizon(for: hakodate), t0.addingTimeInterval(4 * 3600))
        // 1 km 以内は同じキー
        XCTAssertEqual(ForecastCache.key(for: hakodate), ForecastCache.key(for: Coordinate(latitude: 41.7824, longitude: 140.7195)))
    }

    func testFetchGateAllowsOncePerHour() {
        var gate = FetchGate()
        let key = "weather:" + ForecastCache.key(for: hakodate)
        XCTAssertTrue(gate.tryAcquire(key, now: t0))
        XCTAssertFalse(gate.tryAcquire(key, now: t0.addingTimeInterval(1800)))
        XCTAssertFalse(gate.tryAcquire(key, now: t0.addingTimeInterval(3599)))
        XCTAssertTrue(gate.tryAcquire(key, now: t0.addingTimeInterval(3600)))
        XCTAssertTrue(gate.tryAcquire("marine:x", now: t0))
        gate.release("marine:x")
        XCTAssertTrue(gate.tryAcquire("marine:x", now: t0))
    }

    func testMarineGridSearchSkipsLand() async throws {
        var probed: [Coordinate] = []
        let result = await MarineGridSearch.find(around: hakodate) { c -> Int? in
            probed.append(c)
            return probed.count >= 4 ? 42 : nil
        }
        XCTAssertEqual(result?.1, 42)
        XCTAssertEqual(probed.count, 4)
        XCTAssertEqual(probed[0], hakodate)
        XCTAssertNotEqual(result?.0, hakodate)
        // 候補は中心から遠ざかる順
        let cands = MarineGridSearch.candidates(around: hakodate)
        XCTAssertEqual(cands.count, 25)
        XCTAssertLessThan(Geo.distanceMeters(hakodate, cands[1]), Geo.distanceMeters(hakodate, cands[9]))
    }

    func testOpenMeteoDecode() {
        let json = """
        {"latitude":41.8,"longitude":140.7,"hourly":{"time":[1792267200,1792270800],"wave_height":[0.3,0.35],"wave_direction":[200,210],
         "wave_period":[4.0,4.2],"swell_wave_height":[0.1,0.1],"swell_wave_period":[6.0,6.1],"sea_surface_temperature":[15.8,15.7],"ocean_current_velocity":[3.6,7.2]}}
        """
        guard case .samples(let s) = OpenMeteoMarine.decode(Data(json.utf8)) else { return XCTFail("samples expected") }
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[1].waveHeightM, 0.35)
        XCTAssertEqual(s[1].oceanCurrentMS!, 2.0, accuracy: 0.001)
        let land = """
        {"latitude":41.8,"longitude":140.7,"hourly":{"time":[1792267200],"wave_height":[null],"sea_surface_temperature":[null]}}
        """
        XCTAssertEqual(OpenMeteoMarine.decode(Data(land.utf8)), .land)
        XCTAssertEqual(OpenMeteoMarine.decode(Data(#"{"error":true,"reason":"bad"}"#.utf8)), .error("bad"))
        let url = OpenMeteoMarine.url(for: hakodate).absoluteString
        XCTAssertTrue(url.contains("latitude=41.78"))
        XCTAssertTrue(url.contains("longitude=140.72"))
        XCTAssertTrue(url.contains("sea_surface_temperature"))
    }

    func testPressureTrend() {
        let samples = [PressureSample(at: t0.addingTimeInterval(-4 * 3600), pressureHPa: 1018),
                       PressureSample(at: t0.addingTimeInterval(-3 * 3600), pressureHPa: 1017),
                       PressureSample(at: t0, pressureHPa: 1015)]
        XCTAssertEqual(PressureTrend.threeHourChange(samples, now: t0)!, -2, accuracy: 0.001)
        // 3 時間前が無ければ換算
        let short = [PressureSample(at: t0.addingTimeInterval(-5400), pressureHPa: 1016), PressureSample(at: t0, pressureHPa: 1015)]
        XCTAssertEqual(PressureTrend.threeHourChange(short, now: t0)!, -2, accuracy: 0.001)
        XCTAssertNil(PressureTrend.threeHourChange([PressureSample(at: t0, pressureHPa: 1015)], now: t0))
        XCTAssertEqual(PressureTrend.prune(samples, now: t0, keep: 3.5 * 3600).count, 2)
    }

    func testSeriesInterpolation() {
        let s = [(t0, 10.0), (t0.addingTimeInterval(3600), 20.0)]
        XCTAssertEqual(Series.interpolate(s, at: t0.addingTimeInterval(1800))!, 15, accuracy: 0.001)
        XCTAssertEqual(Series.interpolate(s, at: t0.addingTimeInterval(2 * 3600)), 20)
        XCTAssertNil(Series.interpolate(s, at: t0.addingTimeInterval(10 * 3600)))
    }

    func testPrecipitationChanceFlowsIntoSnapshot() {
        let t = Date(timeIntervalSince1970: 1_762_182_000)
        var sample = WeatherSample(at: t, isForecast: true)
        sample.precipitationChance = 0.4
        let inputs = EnvSnapshotBuilder.Inputs(weather: [sample], marine: [], pressure: [])
        let env = EnvSnapshotBuilder(tideStation: nil).build(at: t, coordinate: Coordinate(latitude: 41.77, longitude: 140.73), inputs: inputs)
        XCTAssertEqual(env.precipitationChance ?? -1, 0.4, accuracy: 0.001)
        let data = try! FogJSON.encode(env)
        XCTAssertEqual(try! FogJSON.decode(EnvSnapshot.self, from: data).precipitationChance ?? -1, 0.4, accuracy: 0.001)
    }

    /// 並んでいなくても、同じ時刻があっても、端でも正しく補間する（二分探索版）
    func testInterpolateHandlesUnsortedAndEdges() {
        let t0 = Date(timeIntervalSince1970: 1_792_269_000)
        let h: (Double) -> Date = { t0.addingTimeInterval($0 * 3600) }
        let unsorted: [(Date, Double)] = [(h(2), 20), (h(0), 0), (h(1), 10)]
        XCTAssertEqual(Series.interpolate(unsorted, at: h(0.5))!, 5, accuracy: 1e-9)
        XCTAssertEqual(Series.interpolate(unsorted, at: h(1))!, 10, accuracy: 1e-9)
        XCTAssertEqual(Series.interpolate(unsorted, at: h(2.5))!, 20, accuracy: 1e-9)   // 端の値（3 時間以内）
        XCTAssertNil(Series.interpolate(unsorted, at: h(6)))                            // 遠すぎる
        XCTAssertEqual(Series.interpolate(unsorted, at: h(-1))!, 0, accuracy: 1e-9)
        XCTAssertNil(Series.interpolate([], at: h(0)))
        // 2 点の間が開きすぎ（6 時間超）なら nil
        XCTAssertNil(Series.interpolate([(h(0), 0), (h(10), 1)], at: h(5)))
    }

    func testFogJSONDateRoundTripIsFast() throws {
        let d = Date(timeIntervalSince1970: 1_792_269_000.25)
        XCTAssertEqual(FogJSON.parse(FogJSON.format(d))!.timeIntervalSince1970, d.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNotNil(FogJSON.parse("2026-10-18T05:30:00Z"))
        let start = Date()
        for _ in 0..<2000 { _ = FogJSON.parse(FogJSON.format(d)) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testForecastCachePruneDropsOldAndCapsCount() {
        var cache = ForecastCache()
        let now = Date(timeIntervalSince1970: 1_792_269_000)
        for i in 0..<30 {
            let c = Coordinate(latitude: 41.0 + Double(i) * 0.1, longitude: 140.0)
            cache.mergeWeather(c, samples: [], fetchedAt: now.addingTimeInterval(-Double(i) * 86_400))
        }
        XCTAssertEqual(cache.entries.count, 30)
        cache.prune(now: now)
        // 14 日より古い 15 件（i = 15…29）が落ち、残り 15 件（ちょうど 14 日前は残す。24 件の上限内）
        XCTAssertEqual(cache.entries.count, 15)
        XCTAssertNotNil(cache.entry(for: Coordinate(latitude: 41.0, longitude: 140.0)))
        XCTAssertNil(cache.entry(for: Coordinate(latitude: 43.9, longitude: 140.0)))
        cache.prune(now: now, maxAge: 365 * 86_400, maxEntries: 5)
        XCTAssertEqual(cache.entries.count, 5)
        XCTAssertNotNil(cache.entry(for: Coordinate(latitude: 41.0, longitude: 140.0)))   // いちばん新しいものは残る
    }
}
