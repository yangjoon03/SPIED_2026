//
//  RouteService.swift
//  SPIED_2026
//
//  Destination geocoding + pedestrian route lookup, both via Tmap (SK Open API).
//

import Foundation
import CoreLocation

struct WalkingRoute {
    let coordinates: [CLLocationCoordinate2D]
    let distanceMeters: Int
    let durationSeconds: Int
}

enum RouteServiceError: Error, LocalizedError {
    case noResult
    case invalidResponse
    case missingAPIKey(String)

    var errorDescription: String? {
        switch self {
        case .noResult: return "검색 결과가 없습니다."
        case .invalidResponse: return "응답을 처리할 수 없습니다."
        case .missingAPIKey(let name): return "\(name) 키가 설정되지 않았습니다."
        }
    }
}

enum RouteService {
    // openapi.sk.com 가입 후 발급받은 앱 키. POI 검색 + 보행자 경로안내 둘 다 이 키 하나로 쓴다.
    private static let tmapAppKey = Secrets.tmapAppKey

    // MARK: - 목적지 검색 (Tmap 장소(POI) 통합검색)

    static func geocode(query: String) async throws -> CLLocationCoordinate2D {
        guard tmapAppKey != "YOUR_TMAP_APP_KEY" else {
            throw RouteServiceError.missingAPIKey("Tmap")
        }

        var components = URLComponents(string: "https://apis.openapi.sk.com/tmap/pois")!
        components.queryItems = [
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "searchKeyword", value: query),
            URLQueryItem(name: "count", value: "1"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(tmapAppKey, forHTTPHeaderField: "appKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, _) = try await URLSession.shared.data(for: request)

        struct PoiResponse: Decodable {
            struct SearchPoiInfo: Decodable {
                struct Pois: Decodable {
                    struct Poi: Decodable {
                        let noorLat: String
                        let noorLon: String
                    }
                    let poi: [Poi]
                }
                let pois: Pois
            }
            let searchPoiInfo: SearchPoiInfo
        }

        let decoded = try JSONDecoder().decode(PoiResponse.self, from: data)
        guard let first = decoded.searchPoiInfo.pois.poi.first,
              let lat = Double(first.noorLat), let lon = Double(first.noorLon) else {
            throw RouteServiceError.noResult
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - 도보 경로 조회 (Tmap 보행자 경로안내 API)

    static func walkingRoute(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async throws -> WalkingRoute {
        guard tmapAppKey != "YOUR_TMAP_APP_KEY" else {
            throw RouteServiceError.missingAPIKey("Tmap")
        }

        var request = URLRequest(url: URL(string: "https://apis.openapi.sk.com/tmap/routes/pedestrian?version=1")!)
        request.httpMethod = "POST"
        request.setValue(tmapAppKey, forHTTPHeaderField: "appKey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let startName = "출발".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "start"
        let endName = "도착".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "end"
        let body: [String: Any] = [
            "startX": origin.longitude,
            "startY": origin.latitude,
            "endX": destination.longitude,
            "endY": destination.latitude,
            "startName": startName,
            "endName": endName,
            "searchOption": "0",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(PedestrianFeatureCollection.self, from: data)

        guard let summary = decoded.features.first?.properties else {
            throw RouteServiceError.noResult
        }

        var coordinates: [CLLocationCoordinate2D] = []
        for feature in decoded.features {
            if case .lineString(let points) = feature.geometry.coordinates {
                for point in points where point.count == 2 {
                    coordinates.append(CLLocationCoordinate2D(latitude: point[1], longitude: point[0]))
                }
            }
        }
        guard !coordinates.isEmpty else { throw RouteServiceError.noResult }

        return WalkingRoute(
            coordinates: coordinates,
            distanceMeters: summary.totalDistance ?? 0,
            durationSeconds: summary.totalTime ?? 0
        )
    }
}

// MARK: - Tmap GeoJSON 응답 모델

private struct PedestrianFeatureCollection: Decodable {
    let features: [Feature]

    struct Feature: Decodable {
        let geometry: Geometry
        let properties: Properties
    }

    struct Properties: Decodable {
        let totalDistance: Int?
        let totalTime: Int?
    }

    struct Geometry: Decodable {
        let type: String
        let coordinates: GeoJSONCoordinates
    }
}

/// GeoJSON의 coordinates는 geometry.type에 따라 [Double](Point) 또는
/// [[Double]](LineString) 두 가지 형태로 오기 때문에 직접 분기해서 디코드한다.
private enum GeoJSONCoordinates: Decodable {
    case point([Double])
    case lineString([[Double]])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let line = try? container.decode([[Double]].self) {
            self = .lineString(line)
        } else if let point = try? container.decode([Double].self) {
            self = .point(point)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown GeoJSON coordinates shape")
        }
    }
}
