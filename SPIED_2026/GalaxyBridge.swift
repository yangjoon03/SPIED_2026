import Foundation
import UIKit
import Combine

// ── 데이터 모델 ────────────────────────────────────────────────

struct Vector3: Codable {
    let x: Double?
    let y: Double?
    let z: Double?
}

struct Orientation: Codable {
    let alpha: Double?
    let beta: Double?
    let gamma: Double?
}

struct SensorPayload: Codable {
    let type: String
    let ts: TimeInterval
    let accelerometer: Vector3?
    let gyroscope: Vector3?
    let orientation: Orientation?
}

struct CameraPayload: Codable {
    let type: String
    let ts: TimeInterval
    let data: String      // Base64 JPEG
    let width: Int
    let height: Int
}

struct GPSPayload: Codable {
    let type: String
    let ts: TimeInterval
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let accuracy: Double?
    let speed: Double?
    let heading: Double?
}

// ── 이벤트 타입 ────────────────────────────────────────────────

enum GalaxyEvent {
    case sensorUpdate(SensorPayload)
    case gpsUpdate(GPSPayload)
    case cameraFrame(UIImage)
    case connected
    case disconnected
    case error(Error)
}

// ── GalaxyBridgeClient ─────────────────────────────────────────

@MainActor
final class GalaxyBridgeClient: NSObject, ObservableObject {

    // 퍼블리셔 — SwiftUI / UIKit 어디서든 구독 가능
    let events = PassthroughSubject<GalaxyEvent, Never>()

    @Published var isConnected = false
    @Published var latestSensor: SensorPayload?
    @Published var latestGPS: GPSPayload?
    @Published var latestFrame: UIImage?
    @Published var fps: Int = 0

    private var webSocketTask: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var fpsCounter = 0
    private var fpsTimer: Timer?

    private let serverURL: URL

    // 이 와이파이/공유기가 mDNS 멀티캐스트를 제대로 릴레이하지 않아 "yjyui-macbookair.local"
    // 호스트명이 간헐적으로 실패해서(dns-sd로 직접 확인함) 다시 IP로 되돌림.
    // Mac의 IP가 바뀌면 `ipconfig getifaddr en0`으로 확인해서 여기를 갱신해야 한다.
    // 서버(galaxy-bridge/server.js)가 HTTPS/WSS로 떠 있으므로 wss:// 로 접속해야 합니다.
    init(host: String = "192.168.0.90", port: Int = 8080) {
        serverURL = URL(string: "wss://\(host):\(port)/xcode")!
    }

    // ── 연결 ──────────────────────────────────────────────────

    func connect() {
        // 서버가 자체 서명 인증서(cert.pem)를 쓰므로 세션 델리게이트에서 신뢰 처리한다.
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        webSocketTask = session.webSocketTask(with: serverURL)
        webSocketTask?.resume()

        isConnected = true
        events.send(.connected)

        startReceiving()
        startPing()
        startFpsCounter()

        print("✅ Galaxy Bridge 연결: \(serverURL)")
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        pingTimer?.invalidate()
        fpsTimer?.invalidate()
        events.send(.disconnected)
    }

    // ── 수신 루프 ─────────────────────────────────────────────

    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.startReceiving()   // 재귀로 계속 수신

            case .failure(let error):
                Task { @MainActor in
                    self.isConnected = false
                    self.events.send(.error(error))
                    print("❌ WebSocket 오류: \(error)")
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8) else { return }
            handleJSONPayload(data)

        case .data(let data):
            // 서버(Node "ws")는 릴레이 시 원본 프레임 타입을 보존하지 않고
            // Buffer를 그대로 보내는 경우가 있어, 텍스트 프레임이었어도 여기로
            // 들어올 수 있다. 그래서 바이너리로 와도 동일하게 JSON으로 처리한다.
            handleJSONPayload(data)

        @unknown default:
            break
        }
    }

    private func handleJSONPayload(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        Task { @MainActor in
            switch type {
            case "sensors":
                if let sensor = try? JSONDecoder().decode(SensorPayload.self, from: data) {
                    self.latestSensor = sensor
                    self.events.send(.sensorUpdate(sensor))
                }

            case "gps":
                if let gps = try? JSONDecoder().decode(GPSPayload.self, from: data) {
                    self.latestGPS = gps
                    self.events.send(.gpsUpdate(gps))
                }

            case "camera":
                if let camera = try? JSONDecoder().decode(CameraPayload.self, from: data),
                   let imgData = Data(base64Encoded: camera.data),
                   let image = UIImage(data: imgData) {
                    self.latestFrame = image
                    self.fpsCounter += 1
                    self.events.send(.cameraFrame(image))
                }

            default:
                break
            }
        }
    }

    // ── Ping / FPS ────────────────────────────────────────────

    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.webSocketTask?.sendPing { error in
                if let error { print("Ping 실패: \(error)") }
            }
        }
    }

    private func startFpsCounter() {
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.fps = self.fpsCounter
                self.fpsCounter = 0
            }
        }
    }
}

// ── 자체 서명 인증서 신뢰 ─────────────────────────────────────
//
// galaxy-bridge/server.js 는 로컬 개발용 자체 서명 인증서(cert.pem)로
// HTTPS/WSS를 서빙하므로, 기본 시스템 신뢰 체인 검증을 건너뛴다.
extension GalaxyBridgeClient: URLSessionDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// ── SwiftUI 예제 뷰 ────────────────────────────────────────────
//
//  struct ContentView: View {
//      @StateObject private var bridge = GalaxyBridgeClient(host: "192.168.0.x")
//
//      var body: some View {
//          VStack {
//              if let frame = bridge.latestFrame {
//                  Image(uiImage: frame)
//                      .resizable().scaledToFit()
//              }
//              if let s = bridge.latestSensor?.accelerometer {
//                  Text("가속도: x:\(s.x ?? 0, specifier: "%.2f") y:\(s.y ?? 0, specifier: "%.2f")")
//              }
//              Text("FPS: \(bridge.fps)")
//          }
//          .onAppear { bridge.connect() }
//          .onDisappear { bridge.disconnect() }
//      }
//  }
