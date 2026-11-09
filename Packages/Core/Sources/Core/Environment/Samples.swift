import Foundation

/// 気象の1時間値（WeatherKit の現在値・時間別予報を共通化）。
public struct WeatherSample: Codable, Hashable, Sendable {
    public var at: Date
    public var airTemperatureC: Double?
    public var humidity: Double?
    public var conditionCode: String?
    public var windSpeedMS: Double?
    public var windGustMS: Double?
    public var windDirectionDeg: Double?
    public var pressureHPa: Double?
    public var cloudCover: Double?
    public var precipitationMM: Double?
    /// 降水確率 0〜1
    public var precipitationChance: Double?
    public var visibilityM: Double?
    /// 実況（現在値・過去の観測ベース）なら false、予報なら true
    public var isForecast: Bool

    public init(at: Date, airTemperatureC: Double? = nil, humidity: Double? = nil, conditionCode: String? = nil,
                windSpeedMS: Double? = nil, windGustMS: Double? = nil, windDirectionDeg: Double? = nil, pressureHPa: Double? = nil,
                cloudCover: Double? = nil, precipitationMM: Double? = nil, visibilityM: Double? = nil, isForecast: Bool) {
        self.at = at; self.airTemperatureC = airTemperatureC; self.humidity = humidity; self.conditionCode = conditionCode
        self.windSpeedMS = windSpeedMS; self.windGustMS = windGustMS; self.windDirectionDeg = windDirectionDeg; self.pressureHPa = pressureHPa
        self.cloudCover = cloudCover; self.precipitationMM = precipitationMM; self.visibilityM = visibilityM; self.isForecast = isForecast
    }
}

/// 海況の1時間値（Open-Meteo Marine）。
public struct MarineSample: Codable, Hashable, Sendable {
    public var at: Date
    public var waveHeightM: Double?
    public var wavePeriodS: Double?
    public var waveDirectionDeg: Double?
    public var swellHeightM: Double?
    public var swellPeriodS: Double?
    public var seaSurfaceTempC: Double?
    public var oceanCurrentMS: Double?

    public init(at: Date, waveHeightM: Double? = nil, wavePeriodS: Double? = nil, waveDirectionDeg: Double? = nil,
                swellHeightM: Double? = nil, swellPeriodS: Double? = nil, seaSurfaceTempC: Double? = nil, oceanCurrentMS: Double? = nil) {
        self.at = at; self.waveHeightM = waveHeightM; self.wavePeriodS = wavePeriodS; self.waveDirectionDeg = waveDirectionDeg
        self.swellHeightM = swellHeightM; self.swellPeriodS = swellPeriodS; self.seaSurfaceTempC = seaSurfaceTempC; self.oceanCurrentMS = oceanCurrentMS
    }
}

/// 端末気圧計のサンプル。
public struct PressureSample: Codable, Hashable, Sendable {
    public var at: Date
    public var pressureHPa: Double
    public init(at: Date, pressureHPa: Double) { self.at = at; self.pressureHPa = pressureHPa }
}

/// 時系列から指定時刻に最も近い（または線形補間した）値を引く。
public enum Series {
    /// 指定時刻を挟む2点で線形補間。範囲外は端の値（maxGap 以内のときだけ）。
    /// 予報キャッシュの並びは時刻順なので、並んでいれば二分探索（毎回の並べ替えをやめた。1 スナップショットで 14 回呼ばれる）
    public static func interpolate(_ samples: [(Date, Double)], at date: Date, maxGap: TimeInterval = 3 * 3600) -> Double? {
        guard !samples.isEmpty else { return nil }
        var isSorted = true
        for i in 1..<samples.count where samples[i - 1].0 > samples[i].0 { isSorted = false; break }
        let sorted = isSorted ? samples : samples.sorted { $0.0 < $1.0 }
        // 最初に date 以上になる位置
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].0 < date { lo = mid + 1 } else { hi = mid }
        }
        if lo < sorted.count, sorted[lo].0 == date { return sorted[lo].1 }
        guard lo < sorted.count else {
            let last = sorted[sorted.count - 1]
            return date.timeIntervalSince(last.0) <= maxGap ? last.1 : nil
        }
        let after = sorted[lo]
        guard lo > 0 else {
            return after.0.timeIntervalSince(date) <= maxGap ? after.1 : nil
        }
        let before = sorted[lo - 1]
        let span = after.0.timeIntervalSince(before.0)
        guard span <= 2 * maxGap, span > 0 else { return nil }
        let t = date.timeIntervalSince(before.0) / span
        return before.1 + (after.1 - before.1) * t
    }

    /// 最も近いサンプル（maxGap 以内）。
    public static func nearest<T>(_ samples: [T], at date: Date, time: (T) -> Date, maxGap: TimeInterval = 3 * 3600) -> T? {
        guard let best = samples.min(by: { abs(time($0).timeIntervalSince(date)) < abs(time($1).timeIntervalSince(date)) }) else { return nil }
        return abs(time(best).timeIntervalSince(date)) <= maxGap ? best : nil
    }
}
