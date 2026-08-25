//
//  DetectionAnnouncer.swift
//  SPIED_2026
//
//  시각장애인용: 버튼 누르면 현재 감지된 사물과 화면 내 위치(왼쪽/가운데/오른쪽)를
//  영어 TTS로 읽어준다. (음성 "입력" 인식은 시뮬레이터에서 Siri Understanding
//  애셋 문제로 안정적으로 안 돼서, 버튼 트리거 + 음성 출력만으로 단순화했다.)
//

import Foundation
import AVFoundation
import Combine

struct AnnouncementLogEntry: Identifiable {
    let id = UUID()
    let text: String
    let timestamp: Date
}

@MainActor
final class DetectionAnnouncer: NSObject, ObservableObject {
    @Published var lastAnnouncement = ""
    /// 가로모드 화면의 음성 로그에 쓰인다. 오래된 게 앞, 최신이 뒤(append)라
    /// 로그 뷰에서 그대로 위→아래로 그리면 시간 순서가 맞는다.
    @Published var announcementLog: [AnnouncementLogEntry] = []
    private static let maxLogEntries = 30

    private let synthesizer = AVSpeechSynthesizer()

    /// 감지 목록을 confidence 높은 순으로 최대 `limit`개까지 읽어준다.
    func announce(_ detections: [SegmentationDetection], limit: Int = 3) {
        guard !detections.isEmpty else {
            speak("Nothing detected.")
            return
        }

        let top = detections
            .sorted { $0.confidence > $1.confidence }
            .prefix(limit)

        let sentences = top.map { detection -> String in
            let name = detection.class_name_en.replacingOccurrences(of: "_", with: " ").capitalized
            let positionPhrase: String
            switch detection.position {
            case "left": positionPhrase = "on your left"
            case "right": positionPhrase = "on your right"
            default: positionPhrase = "in front of you"
            }
            return "\(name) \(positionPhrase)."
        }

        speak(sentences.joined(separator: " "))
    }

    /// 바닥 상태 등 안전 경고를 큐에 끼워넣는다. `announce`와 별도 API로 두는 건
    /// 호출부에서 "이건 사용자가 요청한 안내"와 "이건 자동 경고"를 구분하기 위해서다.
    func speakCaution(_ text: String) {
        speak(text)
    }

    private func speak(_ text: String) {
        lastAnnouncement = text
        announcementLog.append(AnnouncementLogEntry(text: text, timestamp: Date()))
        if announcementLog.count > Self.maxLogEntries {
            announcementLog.removeFirst(announcementLog.count - Self.maxLogEntries)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }
}
