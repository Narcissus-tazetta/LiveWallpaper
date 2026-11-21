import Foundation

enum ScheduleWeather: String, Codable, CaseIterable {
    case clear, cloudy, fog, rain, snow, thunder

    var title: String {
        switch self {
        case .clear: "晴れ"
        case .cloudy: "曇り"
        case .fog: "霧"
        case .rain: "雨"
        case .snow: "雪"
        case .thunder: "雷"
        }
    }

    init?(symbol: String) {
        if symbol.contains("thunder") {
            self = .thunder
        } else if symbol.contains("snow") || symbol.contains("sleet") {
            self = .snow
        } else if symbol.contains("rain") {
            self = .rain
        } else if symbol == "fog" {
            self = .fog
        } else if symbol == "cloudy" || symbol.hasPrefix("partlycloudy_") {
            self = .cloudy
        } else if symbol.hasPrefix("clearsky_") || symbol.hasPrefix("fair_") {
            self = .clear
        } else {
            return nil
        }
    }
}

struct ScheduleWeatherForecast {
    private struct Hour {
        let start: Date
        let weather: ScheduleWeather
    }

    private let hours: [Hour]
    private let responseData: Data
    private let lastModified: String?
    let refreshAfter: Date

    func weather(at date: Date) -> ScheduleWeather? {
        hours.last { $0.start <= date && date < $0.start.addingTimeInterval(3600) }?.weather
    }

    private struct Response: Decodable {
        struct Properties: Decodable {
            struct Entry: Decodable {
                struct Period: Decodable {
                    struct Summary: Decodable {
                        let symbolCode: String

                        enum CodingKeys: String, CodingKey {
                            case symbolCode = "symbol_code"
                        }
                    }

                    let summary: Summary
                }

                struct Periods: Decodable {
                    let next1Hours: Period?

                    enum CodingKeys: String, CodingKey {
                        case next1Hours = "next_1_hours"
                    }
                }

                let time: Date
                let data: Periods
            }

            let timeseries: [Entry]
        }

        let properties: Properties
    }

    static func fetch(for location: SolarLocation, previous: Self?) async throws -> Self {
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = "api.met.no"
        endpoint.path = "/weatherapi/locationforecast/2.0/compact"
        endpoint.queryItems = [
            URLQueryItem(name: "lat", value: coordinate(location.latitude)),
            URLQueryItem(name: "lon", value: coordinate(location.longitude))
        ]
        var request = URLRequest(
            url: endpoint.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15
        )
        request.setValue(
            "LiveWallpaper (https://github.com/Narcissus-tazetta/LiveWallpaper)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(previous?.lastModified, forHTTPHeaderField: "If-Modified-Since")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ForecastError.http(nil)
        }
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let expires = response.value(forHTTPHeaderField: "Expires").flatMap(formatter.date(from:))
        let lastModified = response.value(forHTTPHeaderField: "Last-Modified")
        switch response.statusCode {
        case 304:
            guard let previous else { throw ForecastError.http(304) }
            return try decode(
                previous.responseData, now: now, expires: expires,
                lastModified: lastModified ?? previous.lastModified
            )
        case 200, 203:
            if response.statusCode == 203 {
                AppLog.schedule
                    .warning("MET Norway marked the weather forecast endpoint as deprecated")
            }
            return try decode(data, now: now, expires: expires, lastModified: lastModified)
        default:
            throw ForecastError.http(response.statusCode)
        }
    }

    static func decode(
        _ data: Data, now: Date, expires: Date?, lastModified: String? = nil
    ) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode(Response.self, from: data).properties.timeseries
        let refreshAfter = max(now.addingTimeInterval(900), expires ?? now)
        let hours = entries.compactMap { entry -> Hour? in
            guard entry.time > now.addingTimeInterval(-3600),
                  entry.time <= refreshAfter.addingTimeInterval(3600),
                  let symbol = entry.data.next1Hours?.summary.symbolCode,
                  let weather = ScheduleWeather(symbol: symbol)
            else { return nil }
            return Hour(start: entry.time, weather: weather)
        }
        let forecast = Self(
            hours: hours, responseData: data, lastModified: lastModified,
            refreshAfter: refreshAfter
        )
        guard forecast.weather(at: now) != nil else {
            throw ForecastError.noCurrentForecast
        }
        return forecast
    }

    private static func coordinate(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private enum ForecastError: LocalizedError {
        case http(Int?)
        case noCurrentForecast

        var errorDescription: String? {
            switch self {
            case let .http(status): "Weather API returned HTTP \(status ?? 0)"
            case .noCurrentForecast: "Weather API did not return a current hourly condition"
            }
        }
    }
}
