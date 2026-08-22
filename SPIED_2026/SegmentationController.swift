//
//  SegmentationController.swift
//  SPIED_2026
//
//  GalaxyBridgeClient가 받는 카메라 프레임을 세그멘테이션 서버로 계속 보내고
//  결과를 최신 상태로 유지한다. 고정 타이머 대신, 직전 요청이 끝나는 즉시
//  그 시점의 최신 프레임으로 다음 요청을 보내는 루프라 서버/네트워크가
//  버틸 수 있는 최대 속도로 자연스럽게 맞춰진다(카메라 자체는 30fps로 계속
//  들어오지만, 서버 왕복 시간이 매 프레임 예산(약 33ms)보다 길기 때문에
//  진짜 30fps AI 인식은 물리적으로 불가능 — 이 루프가 낼 수 있는 최대치다).
//

import SwiftUI
import Combine

@MainActor
final class SegmentationController: ObservableObject {
    @Published var isEnabled = false
    @Published var isProcessing = false
    @Published var visualizationImage: UIImage?
    @Published var detectionCount = 0
    @Published var inferenceMs: Double = 0
    @Published var detections: [SegmentationDetection] = []
    @Published var errorMessage: String?
    /// 최근 결과 도착 간격으로부터 계산한 실측 처리 속도(fps).
    @Published var effectiveFPS: Double = 0

    private var loopTask: Task<Void, Never>?
    private weak var galaxy: GalaxyBridgeClient?
    private var lastResultTime: Date?

    func start(galaxy: GalaxyBridgeClient) {
        self.galaxy = galaxy
        isEnabled = true
        errorMessage = nil
        lastResultTime = nil
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        isEnabled = false
        loopTask?.cancel()
        loopTask = nil
        isProcessing = false
    }

    private func runLoop() async {
        while isEnabled, !Task.isCancelled {
            guard let frame = galaxy?.latestFrame else {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }

            isProcessing = true
            do {
                let result = try await SegmentationService.predict(image: frame)
                guard !Task.isCancelled else { break }
                applyResult(result)
            } catch {
                guard !Task.isCancelled else { break }
                errorMessage = error.localizedDescription
                isProcessing = false
                // 서버가 꺼져 있으면 요청이 거의 즉시 실패해서, 딜레이 없이 바로
                // 재시도하면 매번 JPEG 인코딩 + 요청을 초당 수백 번 반복하며
                // CPU를 과도하게 태운다. 실패 시에는 잠깐 쉬었다 재시도한다.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            isProcessing = false
        }
        isProcessing = false
    }

    private func applyResult(_ result: SegmentationResult) {
        let now = Date()
        if let lastResultTime {
            let elapsed = now.timeIntervalSince(lastResultTime)
            if elapsed > 0 { effectiveFPS = 1.0 / elapsed }
        }
        lastResultTime = now

        detectionCount = result.count
        inferenceMs = result.inference_ms
        detections = result.detections
        errorMessage = nil
        if let data = Data(base64Encoded: result.visualization), let image = UIImage(data: data) {
            visualizationImage = image
        }
    }
}
