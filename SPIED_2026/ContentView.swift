//
//  ContentView.swift
//  SPIED_2026
//
//  Created by yjy on 8/20/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = WeatherViewModel()

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()

            switch viewModel.state {
            case .idle:
                Color.clear
                    .onAppear { viewModel.start() }
            case .loading where !hasLoadedData:
                ProgressView("날씨 정보를 불러오는 중...")
                    .tint(.white)
                    .foregroundStyle(.white)
            case .failed(let message) where !hasLoadedData:
                WeatherErrorView(message: message) {
                    viewModel.refresh()
                }
            default:
                if let data = currentData {
                    weatherScrollView(data)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var hasLoadedData: Bool {
        currentData != nil
    }

    private var currentData: WeatherData? {
        if case .loaded(let data) = viewModel.state {
            return data
        }
        return nil
    }

    private var backgroundGradient: LinearGradient {
        let isDay = currentData?.current.isDay == 1
        let code = currentData?.current.weatherCode ?? 0
        return LinearGradient(
            colors: WeatherCondition.gradient(for: code, isDay: isDay),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func weatherScrollView(_ data: WeatherData) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                CurrentWeatherHeader(viewModel: viewModel, data: data)
                    .padding(.top, 40)

                HourlyForecastCard(hourly: data.hourly)

                DailyForecastCard(daily: data.daily)

                WeatherDetailGrid(data: data)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .refreshable {
            viewModel.refresh()
        }
    }
}

// MARK: - Header

private struct CurrentWeatherHeader: View {
    @ObservedObject var viewModel: WeatherViewModel
    let data: WeatherData

    private var isDay: Bool { data.current.isDay == 1 }

    var body: some View {
        VStack(spacing: 8) {
            Text(viewModel.placeName)
                .font(.title2)
                .fontWeight(.medium)
                .foregroundStyle(.white)

            Image(systemName: WeatherCondition.symbolName(for: data.current.weatherCode, isDay: isDay))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 72))
                .padding(.vertical, 4)

            Text("\(Int(data.current.temperature.rounded()))°")
                .font(.system(size: 88, weight: .thin))
                .foregroundStyle(.white)

            Text(WeatherCondition.description(for: data.current.weatherCode))
                .font(.title3)
                .foregroundStyle(.white.opacity(0.9))

            Text("체감 \(Int(data.current.apparentTemperature.rounded()))°")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))

            if let daily = data.daily.first {
                Text("최고 \(Int(daily.tempMax.rounded()))° · 최저 \(Int(daily.tempMin.rounded()))°")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

// MARK: - Hourly forecast

private struct HourlyForecastCard: View {
    let hourly: [HourlyForecast]

    private var hourFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH시"
        return formatter
    }

    var body: some View {
        WeatherCardContainer(title: "시간별 예보") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(Array(hourly.enumerated()), id: \.element.id) { index, hour in
                        VStack(spacing: 10) {
                            Text(index == 0 ? "지금" : hourFormatter.string(from: hour.date))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))

                            Image(systemName: WeatherCondition.symbolName(for: hour.weatherCode, isDay: hour.isDay))
                                .symbolRenderingMode(.multicolor)
                                .font(.title3)
                                .frame(height: 22)

                            Text("\(hour.precipitationProbability)%")
                                .font(.caption2)
                                .foregroundStyle(.cyan.opacity(hour.precipitationProbability > 0 ? 1 : 0))

                            Text("\(Int(hour.temperature.rounded()))°")
                                .font(.headline)
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - Daily forecast

private struct DailyForecastCard: View {
    let daily: [DailyForecast]

    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        formatter.locale = Locale(identifier: "ko_KR")
        return formatter
    }

    private var overallMin: Double { daily.map(\.tempMin).min() ?? 0 }
    private var overallMax: Double { daily.map(\.tempMax).max() ?? 1 }

    var body: some View {
        WeatherCardContainer(title: "7일간 예보") {
            VStack(spacing: 14) {
                ForEach(Array(daily.enumerated()), id: \.element.id) { index, day in
                    HStack {
                        Text(index == 0 ? "오늘" : dayFormatter.string(from: day.date))
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .frame(width: 44, alignment: .leading)

                        Image(systemName: WeatherCondition.symbolName(for: day.weatherCode, isDay: true))
                            .symbolRenderingMode(.multicolor)
                            .frame(width: 28)

                        Text("\(day.precipitationProbabilityMax)%")
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                            .frame(width: 34, alignment: .trailing)
                            .opacity(day.precipitationProbabilityMax > 0 ? 1 : 0)

                        Text("\(Int(day.tempMin.rounded()))°")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 30, alignment: .trailing)

                        TemperatureRangeBar(
                            low: day.tempMin, high: day.tempMax,
                            overallLow: overallMin, overallHigh: overallMax
                        )
                        .frame(height: 4)

                        Text("\(Int(day.tempMax.rounded()))°")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
    }
}

private struct TemperatureRangeBar: View {
    let low: Double
    let high: Double
    let overallLow: Double
    let overallHigh: Double

    var body: some View {
        GeometryReader { geo in
            let totalRange = max(overallHigh - overallLow, 1)
            let startFraction = (low - overallLow) / totalRange
            let endFraction = (high - overallLow) / totalRange
            let width = geo.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.2))

                Capsule()
                    .fill(
                        LinearGradient(colors: [.cyan, .yellow, .orange], startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: max(width * (endFraction - startFraction), 4))
                    .offset(x: width * startFraction)
            }
        }
    }
}

// MARK: - Detail grid

private struct WeatherDetailGrid: View {
    let data: WeatherData

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "a h:mm"
        formatter.locale = Locale(identifier: "ko_KR")
        return formatter
    }

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            DetailTile(
                icon: "humidity.fill",
                title: "습도",
                value: "\(data.current.humidity)%"
            )
            DetailTile(
                icon: "wind",
                title: "바람",
                value: "\(Int(data.current.windSpeed.rounded())) km/h"
            )
            DetailTile(
                icon: "gauge.with.dots.needle.33percent",
                title: "기압",
                value: "\(Int(data.current.pressure.rounded())) hPa"
            )
            DetailTile(
                icon: "sun.max.trianglebadge.exclamationmark.fill",
                title: "자외선",
                value: uvDescription(data.daily.first?.uvIndexMax ?? 0)
            )
            if let sunrise = data.daily.first?.sunrise {
                DetailTile(
                    icon: "sunrise.fill",
                    title: "일출",
                    value: timeFormatter.string(from: sunrise)
                )
            }
            if let sunset = data.daily.first?.sunset {
                DetailTile(
                    icon: "sunset.fill",
                    title: "일몰",
                    value: timeFormatter.string(from: sunset)
                )
            }
            DetailTile(
                icon: "cloud.rain.fill",
                title: "강수량",
                value: String(format: "%.1f mm", data.current.precipitation)
            )
            DetailTile(
                icon: "cloud.fill",
                title: "구름량",
                value: "\(data.current.cloudCover)%"
            )
        }
    }

    private func uvDescription(_ value: Double) -> String {
        let level: String
        switch value {
        case ..<3: level = "낮음"
        case 3..<6: level = "보통"
        case 6..<8: level = "높음"
        case 8..<11: level = "매우 높음"
        default: level = "위험"
        }
        return "\(Int(value.rounded())) · \(level)"
    }
}

private struct DetailTile: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.white.opacity(0.7))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Shared card container

private struct WeatherCardContainer<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            content
        }
        .padding(16)
        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - Error state

private struct WeatherErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white)

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 32)

            Button {
                retry()
            } label: {
                Text("다시 시도")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.2), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }
}

#Preview {
    ContentView()
}
