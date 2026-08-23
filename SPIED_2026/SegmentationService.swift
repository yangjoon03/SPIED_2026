//
//  SegmentationService.swift
//  SPIED_2026
//
//  카메라 프레임을 베리어프리 세그멘테이션 서버(YOLO11)로 보내고 결과를 받아온다.
//

import Foundation
import UIKit

struct SegmentationDetection: Decodable {
    let class_name: String
    let class_name_en: String
    let confidence: Double
    /// 이미지 안에서의 좌우 위치: "left" / "center" / "right"
    let position: String
    /// 이미지 안에서의 세로 위치(대략적인 거리감): "near"(화면 아래, 가까움) /
    /// "mid" / "far"(화면 위, 멀리 뻗어있음)
    let depth: String
}

struct SegmentationResult: Decodable {
    let count: Int
    let inference_ms: Double
    let detections: [SegmentationDetection]
    let visualization: String
    let error: String?
}

enum SegmentationServiceError: Error, LocalizedError {
    case invalidImage
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "이미지를 인코딩할 수 없습니다."
        case .serverError(let message): return message
        }
    }
}

enum SegmentationService {
    // 이 Mac에서 로컬로 돌리는 세그멘테이션 서버(galaxy-bridge/local_segmentation_server.py).
    // Mac IP가 바뀌면 GalaxyBridge.swift/WalkingPathView.swift와 마찬가지로 여기도 갱신 필요.
    private static let baseURL = "http://192.168.0.90:8002"

    static func predict(image: UIImage, confidence: Double = 0.25) async throws -> SegmentationResult {
        guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
            throw SegmentationServiceError.invalidImage
        }

        var components = URLComponents(string: "\(baseURL)/predict")!
        components.queryItems = [URLQueryItem(name: "conf", value: String(confidence))]

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(boundary: boundary, jpegData: jpegData)

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(SegmentationResult.self, from: data)
        if let error = decoded.error {
            throw SegmentationServiceError.serverError(error)
        }
        return decoded
    }

    private static func multipartBody(boundary: String, jpegData: Data) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"frame.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
