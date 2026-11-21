import Foundation
import CoreLocation
import WeatherKit
import Core

/// 気象の取得元。テストではモックに差し替える。
protocol WeatherProviding: Sendable {
    /// 現在値と、`from`〜`to` の時間別値（WeatherKit は過去も約 10 日先も返す）。
    func fetch(at coordinate: Coordinate, from: Date, to: Date) async throws -> [WeatherSample]
}

/// WeatherKit（Apple 公式）。端末から直接取得し、位置は 0.01° に丸めて送る。
struct WeatherKitProvider: WeatherProviding {
    func fetch(at coordinate: Coordinate, from: Date, to: Date) async throws -> [WeatherSample] {
        let lat = (coordinate.latitude * 100).rounded() / 100
        let lon = (coordinate.longitude * 100).rounded() / 100
        let location = CLLocation(latitude: lat, longitude: lon)
        let now = Date()
        let (current, hourly) = try await WeatherService.shared.weather(for: location, including: .current, .hourly(startDate: from, endDate: to))
        var samples: [WeatherSample] = hourly.forecast.map { h in
            var s = WeatherSample(at: h.date, isForecast: h.date > now.addingTimeInterval(-3600))
            s.airTemperatureC = h.temperature.converted(to: .celsius).value
            s.humidity = h.humidity
            s.conditionCode = h.condition.rawValue
            s.windSpeedMS = h.wind.speed.converted(to: .metersPerSecond).value
            s.windGustMS = h.wind.gust?.converted(to: .metersPerSecond).value
            s.windDirectionDeg = h.wind.direction.converted(to: .degrees).value
            s.pressureHPa = h.pressure.converted(to: .hectopascals).value
            s.cloudCover = h.cloudCover
            s.precipitationMM = h.precipitationAmount.converted(to: .millimeters).value
            s.precipitationChance = h.precipitationChance
            s.visibilityM = h.visibility.converted(to: .meters).value
            return s
        }
        var c = WeatherSample(at: current.date, isForecast: false)
        c.airTemperatureC = current.temperature.converted(to: .celsius).value
        c.humidity = current.humidity
        c.conditionCode = current.condition.rawValue
        c.windSpeedMS = current.wind.speed.converted(to: .metersPerSecond).value
        c.windGustMS = current.wind.gust?.converted(to: .metersPerSecond).value
        c.windDirectionDeg = current.wind.direction.converted(to: .degrees).value
        c.pressureHPa = current.pressure.converted(to: .hectopascals).value
        c.cloudCover = current.cloudCover
        c.visibilityM = current.visibility.converted(to: .meters).value
        samples.append(c)
        return samples
    }

    /// 設定画面に出す Apple Weather の帰属表示。
    static func attribution() async -> (serviceName: String, legalURL: URL)? {
        guard let a = try? await WeatherService.shared.attribution else { return nil }
        return (a.serviceName, a.legalPageURL)
    }
}

/// 雨の前の通知（F-69）に使う降水の予報。WeatherKit の分単位の予報（約 1 時間先まで。出ない地域では空）と、1 時間ごとの予報（3 時間先まで）。
/// 位置は 0.01° に丸めて送る。取れなければ nil
enum RainForecastProvider {
    static func fetch(at coordinate: Coordinate, now: Date = .now) async -> (minutes: [RainPlanner.Minute], hours: [RainPlanner.Hour])? {
        let lat = (coordinate.latitude * 100).rounded() / 100
        let lon = (coordinate.longitude * 100).rounded() / 100
        let location = CLLocation(latitude: lat, longitude: lon)
        do {
            let (minute, hourly) = try await WeatherService.shared.weather(
                for: location, including: .minute, .hourly(startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(3 * 3600)))
            let minutes: [RainPlanner.Minute] = (minute?.forecast ?? []).map { m in
                // 強さは速さの単位（m/s）で来る。mm/h に直す
                RainPlanner.Minute(at: m.date, chance: m.precipitationChance,
                                   intensityMMH: m.precipitationIntensity.converted(to: .metersPerSecond).value * 3_600_000,
                                   kind: kind(m.precipitation))
            }
            let hours: [RainPlanner.Hour] = hourly.forecast.map { h in
                RainPlanner.Hour(at: h.date, chance: h.precipitationChance,
                                 amountMM: h.precipitationAmount.converted(to: .millimeters).value, kind: kind(h.precipitation))
            }
            return (minutes, hours)
        } catch {
            return nil
        }
    }

    private static func kind(_ p: Precipitation) -> RainPlanner.Kind {
        switch p {
        case .snow: return .snow
        case .sleet, .mixed, .hail: return .sleet
        default: return .rain
        }
    }
}
