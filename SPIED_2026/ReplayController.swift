//
//  ReplayController.swift
//  SPIED_2026
//
//  녹화된 동영상(mp4) + 센서/GPS 타임라인(json)을 읽어서, 실제 GalaxyBridgeClient가
//  라이브로 받는 것과 똑같은 형태(galaxy.latestFrame / latestSensor / latestGPS)로
//  재생해준다. galaxy.connect()는 절대 호출하지 않고 이 컨트롤러가 값을 직접 채워
//  넣기 때문에, SegmentationController/KakaoPathMapView/DetectionAnnouncer 등
//  기존 실시간 파이프라인을 코드 수정 없이 그대로 재사용할 수 있다.
//
//  주의: iOS(AVFoundation)는 webm(vp8/vp9)을 디코딩하지 못한다. 갤럭시 브리지
//  웹페이지가 녹화하는 파일은 webm이라, 반드시 mp4(h264)로 변환한 뒤 불러와야 한다.
//  예: ffmpeg -i galaxy-recording_xxx.webm -c:v libx264 -pix_fmt yuv420p galaxy-recording_xxx.mp4
//

import Foundation
import AVFoundation
import UIKit
import Combine

struct RecordingTimeline: Decodable {
    let startTime: Double
    let endTime: Double
    let videoFile: String
    let videoWidth: Int
    let videoHeight: Int
    let camFps: Double
    let sensorHz: Double
    let sensors: [SensorPayload]
    let gps: [GPSPayload]
}

@MainActor
final class ReplayController: ObservableObject {
    @Published var isLoaded = false
    @Published var isPlaying = false
    @Published var errorMessage: String?
    @Published var progress: Double = 0
    @Published var elapsedSeconds: Double = 0
    @Published var durationSeconds: Double = 0
    @Published var loadedFileName: String?

    /// 실시간 화면과 동일한 파이프라인(SegmentationController 등)이 그대로 구독하는 대상.
    /// connect()는 절대 호출하지 않는다 — 이 컨트롤러가 재생 값을 직접 써넣는다.
    let galaxy = GalaxyBridgeClient()

    private var timeline: RecordingTimeline?
    private var imageGenerator: AVAssetImageGenerator?
    private var playbackTask: Task<Void, Never>?
    private var playbackSpeed: Double = 1.0
    private var sensorIndex = 0
    private var gpsIndex = 0
    private var lastSentGPSIndex = -1

    func load(videoURL: URL, jsonURL: URL) {
        pause()
        do {
            let jsonData = try Data(contentsOf: jsonURL)
            let timeline = try JSONDecoder().decode(RecordingTimeline.self, from: jsonData)
            guard !timeline.sensors.isEmpty || !timeline.gps.isEmpty || timeline.endTime > timeline.startTime else {
                errorMessage = "타임라인에 데이터가 없습니다."
                return
            }

            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            self.timeline = timeline
            self.imageGenerator = generator
            self.sensorIndex = 0
            self.gpsIndex = 0
            self.lastSentGPSIndex = -1
            durationSeconds = max((timeline.endTime - timeline.startTime) / 1000.0, 0)
            elapsedSeconds = 0
            progress = 0
            errorMessage = nil
            isLoaded = true
            loadedFileName = videoURL.lastPathComponent

            galaxy.isConnected = true
            galaxy.latestFrame = nil
            galaxy.latestGPS = nil
            galaxy.latestSensor = nil
        } catch {
            errorMessage = "로드 실패: \(error.localizedDescription)"
            isLoaded = false
        }
    }

    func play(speed: Double = 1.0) {
        guard isLoaded, !isPlaying, let timeline else { return }
        if elapsedSeconds >= durationSeconds { elapsedSeconds = 0; sensorIndex = 0; gpsIndex = 0; lastSentGPSIndex = -1 }
        playbackSpeed = speed
        isPlaying = true
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            await self?.runPlayback(timeline: timeline)
        }
    }

    func pause() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    func reset() {
        pause()
        elapsedSeconds = 0
        progress = 0
        sensorIndex = 0
        gpsIndex = 0
        lastSentGPSIndex = -1
        galaxy.latestFrame = nil
        galaxy.latestGPS = nil
        galaxy.latestSensor = nil
    }

    private func runPlayback(timeline: RecordingTimeline) async {
        guard let generator = imageGenerator else { return }
        let frameInterval = 1.0 / max(timeline.camFps, 1)
        let startWallClock = Date()
        let startElapsed = elapsedSeconds

        var frameCount = 0
        var lastFpsMark = Date()

        while isPlaying, !Task.isCancelled {
            let wallElapsed = Date().timeIntervalSince(startWallClock) * playbackSpeed
            elapsedSeconds = min(startElapsed + wallElapsed, durationSeconds)
            progress = durationSeconds > 0 ? min(elapsedSeconds / durationSeconds, 1) : 0

            if elapsedSeconds >= durationSeconds {
                isPlaying = false
                break
            }

            let cmTime = CMTime(seconds: elapsedSeconds, preferredTimescale: 600)
            if let result = try? await generator.image(at: cmTime) {
                galaxy.latestFrame = UIImage(cgImage: result.image)
            }

            let currentMs = timeline.startTime + elapsedSeconds * 1000
            advanceSensor(timeline: timeline, toMs: currentMs)
            advanceGPS(timeline: timeline, toMs: currentMs)

            frameCount += 1
            let now = Date()
            if now.timeIntervalSince(lastFpsMark) >= 1.0 {
                galaxy.fps = frameCount
                frameCount = 0
                lastFpsMark = now
            }

            let sleepSeconds = max(frameInterval / max(playbackSpeed, 0.01), 0.01)
            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }
    }

    /// 두 인덱스(sensorIndex/gpsIndex)는 재생 시간이 항상 앞으로만 흐른다는 가정 하에
    /// 한 번 지나간 지점으로는 되돌아가지 않는 포인터라, 매번 전체를 훑지 않고
    /// 이전 위치에서부터만 전진한다.
    private func advanceSensor(timeline: RecordingTimeline, toMs currentMs: Double) {
        while sensorIndex + 1 < timeline.sensors.count, timeline.sensors[sensorIndex + 1].ts <= currentMs {
            sensorIndex += 1
        }
        guard !timeline.sensors.isEmpty, timeline.sensors[sensorIndex].ts <= currentMs else { return }
        galaxy.latestSensor = timeline.sensors[sensorIndex]
    }

    private func advanceGPS(timeline: RecordingTimeline, toMs currentMs: Double) {
        while gpsIndex + 1 < timeline.gps.count, timeline.gps[gpsIndex + 1].ts <= currentMs {
            gpsIndex += 1
        }
        guard !timeline.gps.isEmpty, timeline.gps[gpsIndex].ts <= currentMs else { return }
        let gps = timeline.gps[gpsIndex]
        galaxy.latestGPS = gps
        // KakaoPathMapView의 현재 위치 마커는 latestGPS 값 자체가 아니라 이 이벤트를
        // 구독해서 움직이므로(라이브 GalaxyBridgeClient와 동일한 경로), 재생 중에도
        // 반드시 같이 보내줘야 지도 위 마커가 실제로 이동한다. 같은 포인트를 매 프레임
        // 다시 보내지 않도록 인덱스가 실제로 바뀐 경우에만 보낸다.
        guard gpsIndex != lastSentGPSIndex else { return }
        lastSentGPSIndex = gpsIndex
        galaxy.events.send(.gpsUpdate(gps))
    }
}
