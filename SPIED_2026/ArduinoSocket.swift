// ArduinoSocket.swift
import Foundation
import Network
import Combine

class ArduinoSocket: ObservableObject {

    private let host: String
    private let port: Int

    @Published var distance: Int        = -1
    @Published var avgDist: Double      = 0
    @Published var alertActive: Bool    = false
    @Published var isDark: Bool         = false
    @Published var trafficState: String = "GREEN"
    @Published var remaining: Int       = 0
    @Published var servoAngle: Int      = 0
    @Published var isConnected: Bool    = false

    private var connection: NWConnection?
    private var buffer = ""

    init(host: String = "192.168.65.163", port: Int = 9000) {
        self.host = host
        self.port = port
    }

    func connect() {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port))
        )
        connection = NWConnection(to: endpoint, using: .tcp)

        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isConnected = true
                    print("[SOCKET] 연결 성공 → 192.168.65.163:9000")
                    self?.receive()
                case .failed(let error):
                    self?.isConnected = false
                    print("[SOCKET] 연결 실패: \(error)")
                    self?.reconnect()
                case .cancelled:
                    self?.isConnected = false
                    print("[SOCKET] 연결 취소")
                default:
                    break
                }
            }
        }
        connection?.start(queue: .global())
    }

    private func reconnect() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            print("[SOCKET] 재연결 시도...")
            self?.connect()
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, isComplete, error in

            if let data = data, !data.isEmpty {
                let str = String(data: data, encoding: .utf8) ?? ""
                self?.buffer += str

                while let range = self?.buffer.range(of: "\n") {
                    let line = String(self?.buffer[..<range.lowerBound] ?? "")
                    self?.buffer.removeSubrange(..<range.upperBound)
                    self?.parseJSON(line.trimmingCharacters(in: .whitespaces))
                }
            }

            if error == nil {
                self?.receive()
            }
        }
    }

    private func parseJSON(_ str: String) {
        guard !str.isEmpty,
              let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        DispatchQueue.main.async { [weak self] in
            self?.distance     = json["dist"]      as? Int    ?? -1
            self?.avgDist      = json["avg"]       as? Double ?? 0
            self?.alertActive  = json["alert"]     as? Bool   ?? false
            self?.isDark       = json["dark"]      as? Bool   ?? false
            self?.trafficState = json["traffic"]   as? String ?? "GREEN"
            self?.remaining    = json["remaining"] as? Int    ?? 0
            self?.servoAngle   = json["servo"]     as? Int    ?? 0
        }
    }

    func sendCommand(_ cmd: String) {
        let dict: [String: Any] = ["cmd": cmd]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var str  = String(data: data, encoding: .utf8)
        else { return }
        str += "\n"
        connection?.send(content: str.data(using: .utf8), completion: .idempotent)
        print("[SEND] \(cmd)")
    }

    /// 이탈(잘못된 방향)이나 지연 감지 시 보행 신호(GREEN)를 5초 연장.
    /// 최대 횟수 제한(4회)은 아두이노 펌웨어 쪽에서 처리하므로, 다 쓰고 나면
    /// 계속 호출해도 그냥 무시되고 원래 루틴(다음 YELLOW/RED 전환)이 그대로 진행된다.
    func extendGreen() { sendCommand("GREEN_EXTEND") }
    func toggleServo() { sendCommand("SERVO_TOGGLE") }

    func disconnect() {
        connection?.cancel()
        isConnected = false
    }
}
