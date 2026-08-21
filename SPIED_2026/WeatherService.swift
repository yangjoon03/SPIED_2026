//
//  WeatherService.swift
//  SPIED_2026
//
//  Thin client for the free Open-Meteo forecast API (no API key required).
//

import CoreLocation
import Foundation

enum WeatherServiceError: LocalizedError {
    case invalidURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "잘못된 요청 URL입니다."
        case .invalidResponse: return "서버 응답을 처리할 수 없습니다."
        }
    }
}

struct WeatherService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchWeather(for coordinate: CLLocationCoordinate2D) async throws -> WeatherData {
        guard var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else {
            throw WeatherServiceError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "current", value: [
                "temperature_2m", "relative_humidity_2m", "apparent_temperature",
                "is_day", "precipitation", "weather_code", "wind_speed_10m",
                "wind_direction_10m", "surface_pressure", "cloud_cover"
            ].joined(separator: ",")),
            URLQueryItem(name: "hourly", value: [
                "temperature_2m", "weather_code", "precipitation_probability", "is_day"
            ].joined(separator: ",")),
            URLQueryItem(name: "daily", value: [
                "weather_code", "temperature_2m_max", "temperature_2m_min",
                "sunrise", "sunset", "uv_index_max", "precipitation_probability_max"
            ].joined(separator: ",")),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7")
        ]

        guard let url = components.url else {
            throw WeatherServiceError.invalidURL
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WeatherServiceError.invalidResponse
        }

        let decoder = JSONDecoder()
        let raw = try decoder.decode(OpenMeteoResponse.self, from: data)
        return Self.process(raw)
    }

    private static func process(_ raw: OpenMeteoResponse) -> WeatherData {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFraction = ISO8601DateFormatter()
        isoFormatterNoFraction.formatOptions = [.withInternetDateTime]

        // Open-Meteo returns local, timezone-naive timestamps like "2026-08-21T14:00".
        let naiveFormatter = DateFormatter()
        naiveFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        naiveFormatter.timeZone = TimeZone(identifier: raw.timezone) ?? .current
        naiveFormatter.locale = Locale(identifier: "en_US_POSIX")

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: raw.timezone) ?? .current
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")

        func parseNaive(_ string: String) -> Date {
            naiveFormatter.date(from: string) ?? Date()
        }

        func parseDay(_ string: String) -> Date {
            dayFormatter.date(from: string) ?? Date()
        }

        let now = Date()
        var hourly: [HourlyForecast] = []
        for index in raw.hourly.time.indices {
            let date = parseNaive(raw.hourly.time[index])
            guard date >= now.addingTimeInterval(-3600) else { continue }
            hourly.append(
                HourlyForecast(
                    date: date,
                    temperature: raw.hourly.temperature[index],
                    weatherCode: raw.hourly.weatherCode[index],
                    precipitationProbability: raw.hourly.precipitationProbability[index],
                    isDay: raw.hourly.isDay[index] == 1
                )
            )
        }
        hourly = Array(hourly.prefix(24))

        var daily: [DailyForecast] = []
        for index in raw.daily.time.indices {
            daily.append(
                DailyForecast(
                    date: parseDay(raw.daily.time[index]),
                    weatherCode: raw.daily.weatherCode[index],
                    tempMax: raw.daily.tempMax[index],
                    tempMin: raw.daily.tempMin[index],
                    sunrise: parseNaive(raw.daily.sunrise[index]),
                    sunset: parseNaive(raw.daily.sunset[index]),
                    uvIndexMax: raw.daily.uvIndexMax[index],
                    precipitationProbabilityMax: raw.daily.precipitationProbabilityMax[index]
                )
            )
        }

        return WeatherData(timezone: raw.timezone, current: raw.current, hourly: hourly, daily: daily)
    }
}
