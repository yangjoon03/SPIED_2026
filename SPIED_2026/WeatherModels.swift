//
//  WeatherModels.swift
//  SPIED_2026
//
//  Open-Meteo API (https://api.open-meteo.com) response models.
//

import Foundation

struct OpenMeteoResponse: Decodable {
    let timezone: String
    let current: CurrentWeather
    let hourly: HourlyWeather
    let daily: DailyWeather
}

struct CurrentWeather: Decodable {
    let time: String
    let temperature: Double
    let apparentTemperature: Double
    let humidity: Int
    let isDay: Int
    let precipitation: Double
    let weatherCode: Int
    let windSpeed: Double
    let windDirection: Double
    let pressure: Double
    let cloudCover: Int

    enum CodingKeys: String, CodingKey {
        case time
        case temperature = "temperature_2m"
        case apparentTemperature = "apparent_temperature"
        case humidity = "relative_humidity_2m"
        case isDay = "is_day"
        case precipitation
        case weatherCode = "weather_code"
        case windSpeed = "wind_speed_10m"
        case windDirection = "wind_direction_10m"
        case pressure = "surface_pressure"
        case cloudCover = "cloud_cover"
    }
}

struct HourlyWeather: Decodable {
    let time: [String]
    let temperature: [Double]
    let weatherCode: [Int]
    let precipitationProbability: [Int]
    let isDay: [Int]

    enum CodingKeys: String, CodingKey {
        case time
        case temperature = "temperature_2m"
        case weatherCode = "weather_code"
        case precipitationProbability = "precipitation_probability"
        case isDay = "is_day"
    }
}

struct DailyWeather: Decodable {
    let time: [String]
    let weatherCode: [Int]
    let tempMax: [Double]
    let tempMin: [Double]
    let sunrise: [String]
    let sunset: [String]
    let uvIndexMax: [Double]
    let precipitationProbabilityMax: [Int]

    enum CodingKeys: String, CodingKey {
        case time
        case weatherCode = "weather_code"
        case tempMax = "temperature_2m_max"
        case tempMin = "temperature_2m_min"
        case sunrise
        case sunset
        case uvIndexMax = "uv_index_max"
        case precipitationProbabilityMax = "precipitation_probability_max"
    }
}

/// A single hour slot ready for display in the UI.
struct HourlyForecast: Identifiable {
    let id = UUID()
    let date: Date
    let temperature: Double
    let weatherCode: Int
    let precipitationProbability: Int
    let isDay: Bool
}

/// A single day slot ready for display in the UI.
struct DailyForecast: Identifiable {
    let id = UUID()
    let date: Date
    let weatherCode: Int
    let tempMax: Double
    let tempMin: Double
    let sunrise: Date
    let sunset: Date
    let uvIndexMax: Double
    let precipitationProbabilityMax: Int
}

/// Fully processed weather bundle consumed by the views.
struct WeatherData {
    let timezone: String
    let current: CurrentWeather
    let hourly: [HourlyForecast]
    let daily: [DailyForecast]
}
