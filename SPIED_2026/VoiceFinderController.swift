//
//  VoiceFinderController.swift
//  SPIED_2026
//
//  "시각장애인 모드" 전용: 음성 명령("find door") -> 최신 세그멘테이션 결과에서
//  매칭되는 사물을 찾아 화면 내 위치(왼쪽/가운데/오른쪽)를 영어 TTS로 알려준다.
//
//  참고: iOS 시뮬레이터는 온디바이스 음성인식에 필요한 "Siri Understanding"
//  애셋이 없는 경우가 많아 kLSRErrorDomain Code=300으로 실패할 수 있다.
//  실기기에서는 정상 동작한다.
//

import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class VoiceFinderController: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var isAuthorized = false
    @Published var lastHeardText = ""
    @Published var lastAnswer = ""
    @Published var errorMessage: String?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var autoStopTask: Task<Void, Never>?

    /// 명령을 처리할 시점의 최신 감지 목록을 가져오는 클로저. WalkingPathView가 주입한다.
    var detectionsProvider: (() -> [SegmentationDetection])?

    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.isAuthorized = (status == .authorized)
                if status != .authorized {
                    self?.errorMessage = "음성 인식 권한이 필요합니다."
                }
            }
        }
        AVAudioApplication.requestRecordPermission { _ in }
    }

    func startListening() {
        guard !isListening else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "Speech recognizer unavailable."
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "오디오 세션을 시작할 수 없습니다: \(error.localizedDescription)"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            errorMessage = "마이크를 시작할 수 없습니다: \(error.localizedDescription)"
            recognitionRequest = nil
            return
        }

        errorMessage = nil
        lastHeardText = ""
        isListening = true

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.lastHeardText = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.handleCommand(result.bestTranscription.formattedString)
                        self.stopListening()
                    }
                }
                if let error {
                    self.errorMessage = error.localizedDescription
                    self.stopListening()
                }
            }
        }

        // 침묵이 길어져 SFSpeechRecognizer가 스스로 끝내지 않을 때를 대비한 안전장치.
        // endAudio() 이후에도 콜백이 영영 안 오는 경우까지 대비해 강제 종료도 건다.
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.recognitionRequest?.endAudio()

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, self.isListening else { return }
            self.errorMessage = "No speech detected (timeout)."
            self.stopListening()
        }
    }

    func stopListening() {
        guard isListening else { return }
        autoStopTask?.cancel()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 명령 처리

    private func handleCommand(_ text: String) {
        let lower = text.lowercased()
        guard let range = lower.range(of: "find ") else {
            speak("Say 'find' followed by an object, like find door.")
            return
        }

        let target = lower[range.upperBound...]
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        guard !target.isEmpty else {
            speak("What should I find?")
            return
        }

        let detections = detectionsProvider?() ?? []
        let matches = detections.filter {
            $0.class_name_en.lowercased().replacingOccurrences(of: "_", with: " ").contains(target)
        }

        guard let best = matches.max(by: { $0.confidence < $1.confidence }) else {
            speak("No \(target) found.")
            return
        }

        let positionPhrase: String
        switch best.position {
        case "left": positionPhrase = "on your left"
        case "right": positionPhrase = "on your right"
        default: positionPhrase = "in front of you"
        }
        speak("\(target.capitalized) found \(positionPhrase).")
    }

    private func speak(_ text: String) {
        lastAnswer = text
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }
}
