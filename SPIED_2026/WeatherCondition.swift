//
//  WeatherCondition.swift
//  SPIED_2026
//
//  Maps Open-Meteo WMO weather codes to display info (icon, description, colors).
//

import SwiftUI

enum WeatherCondition {

    /// Korean description for a WMO weather code.
    static func description(for code: Int) -> String {
        switch code {
        case 0: return "맑음"
        case 1: return "대체로 맑음"
        case 2: return "구름 조금"
        case 3: return "흐림"
        case 45, 48: return "안개"
        case 51, 53, 55: return "이슬비"
        case 56, 57: return "어는 이슬비"
        case 61, 63, 65: return "비"
        case 66, 67: return "어는 비"
        case 71, 73, 75: return "눈"
        case 77: return "싸락눈"
        case 80, 81, 82: return "소나기"
        case 85, 86: return "눈 소나기"
        case 95: return "뇌우"
        case 96, 99: return "우박을 동반한 뇌우"
        default: return "알 수 없음"
        }
    }

    /// SF Symbol for a WMO weather code, day/night aware.
    static func symbolName(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0:
            return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2:
            return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3:
            return "cloud.fill"
        case 45, 48:
            return "cloud.fog.fill"
        case 51, 53, 55, 56, 57:
            return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67:
            return "cloud.rain.fill"
        case 71, 73, 75, 77:
            return "cloud.snow.fill"
        case 80, 81, 82:
            return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 85, 86:
            return "cloud.snow.fill"
        case 95:
            return "cloud.bolt.rain.fill"
        case 96, 99:
            return "cloud.bolt.rain.fill"
        default:
            return "questionmark.circle"
        }
    }

    /// Background gradient colors tailored to condition + time of day.
    static func gradient(for code: Int, isDay: Bool) -> [Color] {
        if !isDay {
            switch code {
            case 0, 1, 2:
                return [Color(red: 0.05, green: 0.07, blue: 0.25), Color(red: 0.16, green: 0.2, blue: 0.42)]
            default:
                return [Color(red: 0.08, green: 0.1, blue: 0.2), Color(red: 0.22, green: 0.24, blue: 0.32)]
            }
        }

        switch code {
        case 0:
            return [Color(red: 0.25, green: 0.62, blue: 0.96), Color(red: 0.45, green: 0.78, blue: 0.98)]
        case 1, 2:
            return [Color(red: 0.36, green: 0.66, blue: 0.94), Color(red: 0.62, green: 0.78, blue: 0.9)]
        case 3, 45, 48:
            return [Color(red: 0.55, green: 0.6, blue: 0.65), Color(red: 0.72, green: 0.76, blue: 0.8)]
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82:
            return [Color(red: 0.34, green: 0.44, blue: 0.56), Color(red: 0.5, green: 0.58, blue: 0.68)]
        case 71, 73, 75, 77, 85, 86:
            return [Color(red: 0.58, green: 0.68, blue: 0.78), Color(red: 0.8, green: 0.87, blue: 0.92)]
        case 95, 96, 99:
            return [Color(red: 0.22, green: 0.24, blue: 0.32), Color(red: 0.4, green: 0.42, blue: 0.5)]
        default:
            return [Color(red: 0.36, green: 0.66, blue: 0.94), Color(red: 0.62, green: 0.78, blue: 0.9)]
        }
    }
}
