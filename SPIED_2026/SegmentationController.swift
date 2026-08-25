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

    /// WalkingPathView가 "시각장애인 모드" 토글에 맞춰 갱신한다.
    /// 켜져 있을 때만 점자블록 좌우 안내를 자동으로 읽어준다.
    var isAccessibilityMode = false

    private var loopTask: Task<Void, Never>?
    private weak var galaxy: GalaxyBridgeClient?
    private weak var announcer: DetectionAnnouncer?
    /// 이탈(방향 틀림) 경고가 뜰 때마다 하드웨어 보행 신호(초록불)를 5초씩 연장해달라고
    /// 알려준다. 신호 자체를 몇 번까지 늘릴지는 아두이노 펌웨어가 알아서 제한한다(최대 4회).
    private weak var arduino: ArduinoSocket?
    private var lastResultTime: Date?
    private var lastCautionTime: Date?
    private var lastBrailleGuidanceTime: Date?

    /// 바닥 평탄성이 이 등급으로 감지되면 자동으로 "Caution" 경고를 읽어준다.
    private static let cautionGrades: Set<String> = ["flatness_D", "flatness_E"]
    private static let cautionCooldown: TimeInterval = 6

    /// 점자블록(점형/선형)이 화면 중앙에서 벗어나 있으면 좌우로 붙으라고 안내한다.
    private static let brailleBlockClasses: Set<String> = ["brailleblock_dot", "brailleblock_line"]
    private static let brailleGuidanceCooldown: TimeInterval = 3

    // MARK: - 횡단보도 진행 방향 이탈 감지 상태

    /// 경사형 연석만으로는 횡단보도인지 확신할 수 없다(주차장 진입로 등 다른 곳에도 있음).
    /// 그래서 2단계로 확인한다: 경사로를 본 뒤 일정 시간 안에 실제 횡단보도 표면까지
    /// 보여야 "진짜 횡단보도"로 확정하고, 그 순간(경사로를 처음 본 순간)의 방향을 정방향으로 고정한다.
    /// 확정되고 나면 반대편 출구 경사로를 다시 봐도 새로 트리거되지 않는다(이미 tracking 상태이므로).
    private enum TrackingState {
        case idle
        /// hasRamp == true: 경사로를 먼저 봐서 들어온 경우 -> 표면이 한 번만 더 보이면 바로 확정.
        /// hasRamp == false: 경사로 없이 표면만 갑자기 보여서 들어온 경우(예: 앱을 이미 횡단보도
        /// 위에서 켰거나, 경사로를 놓친 경우) -> corroboration이 없으므로 표면이 일정 시간
        /// "꾸준히" 보여야만 확정한다(surfaceOnlyLastSeen으로 추적).
        case pendingEntry(candidateHeading: Double, seenAt: Date, hasRamp: Bool)
        case tracking(referenceHeading: Double)
    }

    private static let crosswalkEntryClasses: Set<String> = ["outcurb_slide", "outcurb_slide_broken"]
    private static let crosswalkSurfaceClasses: Set<String> = ["planecrosswalk_normal", "planecrosswalk_broken"]
    private static let crosswalkTrackingClasses: Set<String> = crosswalkEntryClasses.union(crosswalkSurfaceClasses)

    private static let entryConfirmationWindow: TimeInterval = 5  // 경사로 본 뒤 이 시간 안에 횡단보도가 안 보이면 오작동으로 보고 취소
    /// 경사로 없이 표면만으로 진입할 때: 이 시간만큼 꾸준히 보여야 진짜 횡단보도로 확정(오탐 방지).
    /// 실제 녹화(대각선으로 빠지며 이탈하는 케이스)로 검증해보니 1.5초는 너무 길어서
    /// 순간적으로만 잡히는 진짜 상황을 놓쳤다 — 0.5초로 줄여서 더 민감하게 확정한다.
    private static let surfaceOnlyConfirmationWindow: TimeInterval = 0.5
    /// 확정 대기 중 표면이 이 시간 이상 안 보이면 오탐으로 보고 취소(짧은 프레임 튐은 허용).
    private static let surfaceOnlyLossGrace: TimeInterval = 1.0
    private static let headingDeviationThreshold: Double = 30       // 도(°) — 이보다 더 틀어지면 이탈로 간주
    private static let headingDeviationSustain: TimeInterval = 1.5  // 노이즈 스파이크 무시: 이 시간 이상 지속돼야 경고
    private static let crosswalkTrackingTimeout: TimeInterval = 8   // 이 시간 동안 못 보면 추적 리셋(다 건넜다고 판단)
    private static let headingDeviationCooldown: TimeInterval = 5
    private static let headingSmoothingWeight: Double = 0.3         // 지수이동평균 가중치(노이즈 완화)

    /// 몸(카메라)은 정면을 향한 채 대각선으로 빠지면 나침반 방향은 거의 안 변해서
    /// headingDeviation으로는 못 잡는다. 대신 "정상적으로는 이만큼 빨리 다 건널 수 없는데
    /// 횡단보도가 벌써 한동안 안 보인다"는 시간 논리로 잡는다: tracking을 시작한 지
    /// minimumCrossingDuration이 지나기 전인데도 횡단보도가 crosswalkGoneWarningThreshold
    /// 이상 안 보이면, 진행 방향 자체가 횡단보도에서 벗어났다고 보고 경고한다.
    private static let crosswalkGoneWarningThreshold: TimeInterval = 2.0
    private static let minimumCrossingDuration: TimeInterval = 4.0

    private var crosswalkState: TrackingState = .idle
    /// 지금 횡단보도를 건너는 중(tracking 확정 상태)인지 — 방향이 맞든 틀리든, 아직 다
    /// 건넜다고 판단되지 않은 상태다. 하드웨어 신호 연장 여부 판단(느려도 연장) 등
    /// 뷰 쪽에서 참조한다.
    var isCrossingInProgress: Bool {
        if case .tracking = crosswalkState { return true }
        return false
    }
    private var smoothedHeading: Double?
    private var lastCrosswalkSeenTime: Date?
    private var surfaceOnlyLastSeen: Date?
    private var headingDeviationStartTime: Date?
    private var lastHeadingDeviationAnnounceTime: Date?
    /// tracking으로 확정된 시점. "아직 정상적으로 다 건넜을 시간이 안 지났다"를 판단하는 기준.
    private var trackingStartTime: Date?

    func start(galaxy: GalaxyBridgeClient, announcer: DetectionAnnouncer?, arduino: ArduinoSocket? = nil) {
        self.galaxy = galaxy
        self.announcer = announcer
        self.arduino = arduino
        isEnabled = true
        errorMessage = nil
        lastResultTime = nil
        lastCautionTime = nil
        resetCrosswalkTracking()
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// 횡단보도 추적 상태만 초기화한다. 재생 테스트에서 다른 녹화로 새로 불러올 때
    /// 반드시 호출해야 한다 — 안 그러면 AI 인식을 계속 켜둔 채로 파일만 바꿨을 때
    /// 이전 영상에서 확정된 tracking 상태가 새 영상으로 그대로 넘어와서, 새 영상엔
    /// 없는 횡단보도를 "갑자기 안 보인다"고 잘못 경고하게 된다.
    func resetCrosswalkTracking() {
        crosswalkState = .idle
        smoothedHeading = nil
        lastCrosswalkSeenTime = nil
        surfaceOnlyLastSeen = nil
        headingDeviationStartTime = nil
        lastHeadingDeviationAnnounceTime = nil
        trackingStartTime = nil
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

        checkGroundCaution(in: result.detections)
        if isAccessibilityMode {
            checkBrailleBlockGuidance(in: result.detections)
            checkCrosswalkHeading(in: result.detections)
        }
    }

    private func checkGroundCaution(in detections: [SegmentationDetection]) {
        guard let worst = detections.first(where: { Self.cautionGrades.contains($0.class_name_en) }) else { return }

        let now = Date()
        if let lastCautionTime, now.timeIntervalSince(lastCautionTime) < Self.cautionCooldown { return }
        lastCautionTime = now

        let severity = worst.class_name_en == "flatness_E" ? "very poor" : "poor"
        announcer?.speakCaution("Caution. \(severity) ground surface ahead.")
    }

    private func checkBrailleBlockGuidance(in detections: [SegmentationDetection]) {
        guard let block = detections.first(where: { Self.brailleBlockClasses.contains($0.class_name_en) }) else { return }
        guard block.position == "left" || block.position == "right" else { return }

        let now = Date()
        if let lastBrailleGuidanceTime, now.timeIntervalSince(lastBrailleGuidanceTime) < Self.brailleGuidanceCooldown { return }
        lastBrailleGuidanceTime = now

        announcer?.speakCaution("Tactile block on your \(block.position). Move \(block.position).")
    }

    /// 경사형 연석(횡단보도 진입부) → 실제 횡단보도 표면까지 확인되면 그 진입 시점의
    /// 방향을 "정방향"으로 고정하고, 그 뒤 방향이 계속 크게 벗어나 있으면 경로를
    /// 이탈했다고 보고 보정 방향을 안내한다.
    /// 방향센서(휴대폰 웹앱의 "센서" 스트림)가 꺼져 있으면 heading이 없어서 그냥 아무 것도 안 한다.
    private func checkCrosswalkHeading(in detections: [SegmentationDetection]) {
        guard let rawHeading = galaxy?.latestSensor?.orientation?.alpha else { return }

        smoothedHeading = Self.smoothHeading(
            previous: smoothedHeading,
            new: rawHeading,
            weight: Self.headingSmoothingWeight
        )
        guard let heading = smoothedHeading else { return }

        let now = Date()
        let sawEntry = detections.contains { Self.crosswalkEntryClasses.contains($0.class_name_en) }
        let sawSurfaceAny = detections.contains { Self.crosswalkSurfaceClasses.contains($0.class_name_en) }
        // 경사로 다음에 표면이 "한 프레임만" 보여도 바로 확정하는 경로라, 옆으로 스쳐
        // 지나가는 걸 걸러내려고 depth가 "near"(화면 아래쪽)가 아닌 것만 인정한다.
        // 표면만으로 들어오는 경로(surfaceOnly)는 대신 일정 시간 꾸준히 보여야 확정되므로
        // (surfaceOnlyConfirmationWindow) 그 자체가 오탐 방지 역할을 해서 near도 인정한다 —
        // 사용자가 횡단보도 바로 앞/위에 서 있으면 계속 near로만 잡히는 경우가 실제로 있다.
        let sawSurfaceFar = detections.contains {
            Self.crosswalkSurfaceClasses.contains($0.class_name_en) && $0.depth != "near"
        }
        let sawAnyTrackingClass = detections.contains { Self.crosswalkTrackingClasses.contains($0.class_name_en) }

        switch crosswalkState {
        case .idle:
            if sawEntry {
                crosswalkState = .pendingEntry(candidateHeading: heading, seenAt: now, hasRamp: true)
            } else if sawSurfaceAny {
                // 경사로를 못 봤거나(놓쳤거나) 앱을 이미 횡단보도 위에서 켠 경우.
                // corroboration이 없으니 표면이 꾸준히 보이는지로 대신 확인한다.
                crosswalkState = .pendingEntry(candidateHeading: heading, seenAt: now, hasRamp: false)
                surfaceOnlyLastSeen = now
            }

        case .pendingEntry(let candidateHeading, let seenAt, let hasRamp):
            if hasRamp {
                if sawSurfaceFar {
                    // 경사로 다음에 실제 횡단보도 표면까지 확인됨 -> 진짜 횡단보도로 확정.
                    // 기준 방향은 경사로를 "처음 만난 순간"의 방향을 쓴다.
                    crosswalkState = .tracking(referenceHeading: candidateHeading)
                    lastCrosswalkSeenTime = now
                    headingDeviationStartTime = nil
                    trackingStartTime = now
                } else if now.timeIntervalSince(seenAt) > Self.entryConfirmationWindow {
                    // 시간 내에 횡단보도가 확인되지 않음 -> 횡단보도가 아닌 다른 연석(주차장 진입로 등)으로 보고 취소.
                    crosswalkState = .idle
                }
            } else {
                if sawSurfaceAny {
                    surfaceOnlyLastSeen = now
                }
                if let lastSeen = surfaceOnlyLastSeen, now.timeIntervalSince(lastSeen) > Self.surfaceOnlyLossGrace {
                    // 표면이 잠깐 튄 게 아니라 실제로 사라짐 -> 오탐으로 보고 취소.
                    crosswalkState = .idle
                    surfaceOnlyLastSeen = nil
                } else if now.timeIntervalSince(seenAt) >= Self.surfaceOnlyConfirmationWindow {
                    // 꾸준히 보인 시간이 확인 기준을 넘김 -> 진짜 횡단보도로 확정.
                    crosswalkState = .tracking(referenceHeading: candidateHeading)
                    lastCrosswalkSeenTime = now
                    headingDeviationStartTime = nil
                    surfaceOnlyLastSeen = nil
                    trackingStartTime = now
                }
            }

        case .tracking(let referenceHeading):
            // 이 상태로 확정되는 데는 (경사로 corroboration이 없는 surfaceOnly 경로에서는)
            // 아주 짧고 확신도 낮은 감지 한두 번이면 충분하다. 실제 서버로 5개 테스트
            // 영상을 다 돌려본 결과, 이 "짧고 약한 신호"는 05번처럼 진짜로 잠깐 스쳐 지나가는
            // 이탈 상황에서도, 01/03번처럼 완전히 정상인 보행에서 모델이 순간적으로 오탐할 때도
            // 똑같은 모양(연속 1~2프레임, confidence 0.25~0.55)으로 나타나서 신호만으로는
            // 구분이 안 된다. 확정 기준을 더 엄격하게(예: 2번 이상 재확인) 하면 01/03의
            // 오탐은 줄지만 05 같은 진짜 이탈을 그대로 놓친다 — 실험으로 확인됨. 사용자 판단으로
            // "짧은 진짜 이탈을 놓치지 않는 것"을 "정상 보행에서 가끔 뜨는 오탐 경고"보다
            // 우선하기로 하고 현재 민감도를 그대로 유지한다.
            if sawAnyTrackingClass {
                lastCrosswalkSeenTime = now
            } else if let lastSeen = lastCrosswalkSeenTime, now.timeIntervalSince(lastSeen) > Self.crosswalkTrackingTimeout {
                // 한동안 횡단보도 관련 표식이 안 보이면 다 건넜다고 보고 추적을 종료한다.
                crosswalkState = .idle
                headingDeviationStartTime = nil
                return
            } else if let started = trackingStartTime, let lastSeen = lastCrosswalkSeenTime,
                      now.timeIntervalSince(started) < Self.minimumCrossingDuration,
                      now.timeIntervalSince(lastSeen) > Self.crosswalkGoneWarningThreshold {
                // 몸(카메라)은 정면을 향한 채 대각선으로 빠지면 나침반 방향은 거의 안 변해서
                // 아래 헤딩 이탈 체크로는 못 잡는다. 대신 "정상적으로는 아직 다 건넜을 리 없는
                // 시간인데 횡단보도가 벌써 한동안 안 보인다"는 걸로 방향이 틀렸다고 판단한다.
                if lastHeadingDeviationAnnounceTime == nil
                    || now.timeIntervalSince(lastHeadingDeviationAnnounceTime!) >= Self.headingDeviationCooldown {
                    lastHeadingDeviationAnnounceTime = now
                    announcer?.speakCaution("Crosswalk no longer visible. You may be walking off course.")
                    arduino?.extendGreen()
                }
                return
            }

            let deviation = Self.signedAngularDifference(heading, referenceHeading)
            guard abs(deviation) > Self.headingDeviationThreshold else {
                headingDeviationStartTime = nil
                return
            }

            if headingDeviationStartTime == nil {
                headingDeviationStartTime = now
            }
            guard let deviationStart = headingDeviationStartTime,
                  now.timeIntervalSince(deviationStart) >= Self.headingDeviationSustain else { return }

            if let last = lastHeadingDeviationAnnounceTime, now.timeIntervalSince(last) < Self.headingDeviationCooldown { return }
            lastHeadingDeviationAnnounceTime = now

            // signedAngularDifference는 "양수 = 시계방향(오른쪽)"을 가정하지만, 실제 heading은
            // 웹앱이 표준 deviceorientation의 alpha를 그대로 쓰고 있어서 반시계 방향으로
            // 증가한다(실제 나침반과 반대) — 그래서 deviation의 부호가 실제 좌/우와 반대로
            // 나온다. 보정 방향을 뒤집어서 실제 나침반 기준으로 맞는 좌/우를 안내한다.
            let correction = deviation > 0 ? "right" : "left"
            announcer?.speakCaution("You are drifting off course. Turn \(correction) to go straight.")
            arduino?.extendGreen()
        }
    }

    /// a - b의 최단 부호 있는 각도차(-180...180). 양수면 a가 시계방향(오른쪽)으로 더 돌아간 것.
    private static func signedAngularDifference(_ a: Double, _ b: Double) -> Double {
        var diff = (a - b).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return diff
    }

    /// 0/360 경계를 넘나드는 각도를 단순 선형평균하면 틀어지므로, 최단 각도 방향으로만 보정하는
    /// 지수이동평균을 쓴다. 매 프레임 살짝만 반영해서 센서 노이즈로 인한 급격한 튐을 완화한다.
    private static func smoothHeading(previous: Double?, new: Double, weight: Double) -> Double {
        guard let previous else { return new }
        let delta = signedAngularDifference(new, previous)
        var result = (previous + delta * weight).truncatingRemainder(dividingBy: 360)
        if result < 0 { result += 360 }
        return result
    }
}
