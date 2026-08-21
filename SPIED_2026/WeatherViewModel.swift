//
//  WeatherViewModel.swift
//  SPIED_2026
//

import Combine
import CoreLocation
import Foundation

@MainActor
final class WeatherViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(WeatherData)
        case failed(String)
    }

    /// Fixed location: Inje University (Gimhae campus). Development happens on a
    /// MacBook with no GPS, so the app targets this coordinate instead of CoreLocation.
    static let fixedCoordinate = CLLocationCoordinate2D(latitude: 35.2287, longitude: 128.7802)
    let placeName = "인제대학교"

    @Published private(set) var state: State = .idle

    private let weatherService: WeatherService

    init(weatherService: WeatherService = WeatherService()) {
        self.weatherService = weatherService
    }

    func start() {
        guard case .idle = state else { return }
        refresh()
    }

    func refresh() {
        Task {
            state = .loading
            do {
                let data = try await weatherService.fetchWeather(for: Self.fixedCoordinate)
                state = .loaded(data)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
