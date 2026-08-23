//
//  ReplayView.swift
//  SPIED_2026
//
//  WalkingPathView와 동일한 레이아웃(위: 카메라, 아래: 지도)이지만, 라이브 갤럭시
//  스트림 대신 녹화된 mp4 + 센서/GPS JSON 타임라인을 재생해서 같은 AI 파이프라인
//  (SegmentationController/DetectionAnnouncer/VoiceFinderController)에 흘려보낸다.
//
//  녹화 파일은 galaxy-bridge 웹페이지의 "🔴 녹화" 기능으로 만들어지며(webm + json),
//  webm은 iOS가 디코딩 못 하므로 미리 mp4로 변환해서 넣어야 한다:
//    ffmpeg -i in.webm -c:v libx264 -pix_fmt yuv420p out.mp4
//

import SwiftUI
import UniformTypeIdentifiers

struct ReplayView: View {
    @StateObject private var replay = ReplayController()
    @StateObject private var segmentation = SegmentationController()
    @StateObject private var announcer = DetectionAnnouncer()
    @StateObject private var voiceFinder = VoiceFinderController()
    @State private var isAccessibilityMode = false
    @State private var showSettings = false
    @State private var isMapActive = true

    @State private var pickedVideoURL: URL?
    @State private var pickedJSONURL: URL?
    /// .fileImporter를 두 개 겹쳐서 달면(영상용/데이터용 각각) SwiftUI가 안쪽 것을
    /// 제대로 못 띄우는 알려진 이슈가 있어서, 하나의 상태로 어떤 걸 고르는 중인지만
    /// 구분하고 fileImporter는 하나만 쓴다.
    /// isPickerPresented와 별도로 둔다 — 같은 바인딩의 get/set에서 activePicker를
    /// 같이 건드리면, "피커 닫힘"과 "선택 결과 completion" 두 콜백의 호출 순서가
    /// 보장되지 않아 completion이 실행될 때 activePicker가 이미 nil이 되어 결과를
    /// 잃어버리는 경쟁 상태가 생긴다(실제로 이 버그로 선택한 파일이 유실됐었음).
    @State private var activePicker: PickerTarget?
    @State private var isPickerPresented = false

    private enum PickerTarget: Identifiable {
        case video, json
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                cameraView
                primaryActionButton
                    .padding(.bottom, 14)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()

            ZStack(alignment: .top) {
                KakaoPathMapView(
                    galaxy: replay.galaxy,
                    isActive: $isMapActive,
                    isRecording: .constant(false),
                    routeCoordinates: .constant([])
                )
                playbackBar
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            voiceFinder.requestAuthorization()
            voiceFinder.detectionsProvider = { segmentation.detections }
        }
        .onDisappear {
            replay.pause()
            segmentation.stop()
            voiceFinder.stopListening()
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .fileImporter(
            isPresented: $isPickerPresented,
            // Safari로 다운로드된 파일은 확장자가 .json이어도 시스템 UTI 태그가
            // application/octet-stream 등으로 붙어서 [.json] 단독 필터에는 안 보일 수 있다.
            // .data(범용 바이너리)를 같이 허용해 그런 경우에도 목록에 뜨게 한다.
            allowedContentTypes: activePicker == .json ? [.json, .data] : [.movie]
        ) { result in
            switch activePicker {
            case .video: handlePicked(result) { pickedVideoURL = $0 }
            case .json: handlePicked(result) { pickedJSONURL = $0 }
            case nil: break
            }
            activePicker = nil
        }
    }

    // MARK: - 카메라 오버레이 (라이브 화면과 동일)

    private var cameraView: some View {
        ZStack {
            Color.black

            if segmentation.isEnabled, let vis = segmentation.visualizationImage {
                Image(uiImage: vis)
                    .resizable()
                    .scaledToFit()
            } else if let frame = replay.galaxy.latestFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(replay.isLoaded ? "재생 버튼을 눌러주세요" : "녹화 파일을 불러와주세요")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            VStack {
                HStack {
                    Button {
                        showSettings = true
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(replay.isLoaded ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Image(systemName: "gearshape.fill")
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.4), in: Capsule())
                    }
                    .padding(10)

                    Spacer()

                    if replay.galaxy.latestFrame != nil {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(replay.galaxy.fps) FPS")
                            if segmentation.isEnabled {
                                Text("감지 \(segmentation.detectionCount)개 · \(Int(segmentation.inferenceMs.rounded()))ms · \(String(format: "%.1f", segmentation.effectiveFPS))fps")
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.4), in: Capsule())
                        .padding(10)
                    }
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var primaryActionButton: some View {
        Button {
            if isAccessibilityMode {
                if voiceFinder.isListening {
                    voiceFinder.stopListening()
                } else {
                    voiceFinder.startListening()
                }
            } else {
                announcer.announce(segmentation.detections)
            }
        } label: {
            Image(systemName: primaryActionIcon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(primaryActionColor, in: Circle())
                .shadow(radius: 4)
        }
        .disabled(!segmentation.isEnabled)
        .opacity(segmentation.isEnabled ? 1 : 0.4)
    }

    private var primaryActionIcon: String {
        if isAccessibilityMode {
            return voiceFinder.isListening ? "mic.fill" : "mic"
        }
        return "speaker.wave.2.fill"
    }

    private var primaryActionColor: Color {
        isAccessibilityMode && voiceFinder.isListening ? .red : .accentColor
    }

    // MARK: - 재생 컨트롤 (지도 위 오버레이)

    private var playbackBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("영상 선택") { activePicker = .video; isPickerPresented = true }
                Button("데이터 선택") { activePicker = .json; isPickerPresented = true }
                Spacer()
                Button("불러오기") {
                    guard let video = pickedVideoURL, let json = pickedJSONURL else { return }
                    replay.load(videoURL: video, jsonURL: json)
                }
                .disabled(pickedVideoURL == nil || pickedJSONURL == nil)
            }
            .font(.caption)

            if let name = pickedVideoURL?.lastPathComponent {
                Text("영상: \(name)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let name = pickedJSONURL?.lastPathComponent {
                Text("데이터: \(name)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }

            if let errorMessage = replay.errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            if replay.isLoaded {
                HStack {
                    Button {
                        if replay.isPlaying { replay.pause() } else { replay.play() }
                    } label: {
                        Image(systemName: replay.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button {
                        replay.reset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }

                    ProgressView(value: replay.progress)

                    Text("\(formatTime(replay.elapsedSeconds)) / \(formatTime(replay.durationSeconds))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func handlePicked(_ result: Result<URL, Error>, assign: (URL) -> Void) {
        switch result {
        case .success(let url):
            do {
                assign(try copyToLocalTemp(from: url))
            } catch {
                replay.errorMessage = "파일을 불러오지 못했습니다: \(error.localizedDescription)"
            }
        case .failure(let error):
            replay.errorMessage = "파일 선택 실패: \(error.localizedDescription)"
        }
    }

    /// 피커로 고른 파일은 보안 스코프 접근이라 나중에(재생 중) 접근이 끊길 수 있으므로,
    /// 앱 tmp 디렉토리로 즉시 복사해서 안정적으로 계속 읽을 수 있게 한다.
    private func copyToLocalTemp(from url: URL) throws -> URL {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    // MARK: - 설정 시트

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section("재생 상태") {
                    HStack {
                        Circle()
                            .fill(replay.isLoaded ? Color.green : Color.gray)
                            .frame(width: 10, height: 10)
                        Text(replay.isLoaded ? "녹화 파일 로드됨" : "로드된 파일 없음")
                    }
                    if let name = replay.loadedFileName {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                    if let gps = replay.galaxy.latestGPS {
                        Text(String(format: "%.5f, %.5f", gps.latitude, gps.longitude))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("AI 인식") {
                    Toggle("실시간 AI 인식", isOn: Binding(
                        get: { segmentation.isEnabled },
                        set: { newValue in
                            if newValue {
                                segmentation.start(galaxy: replay.galaxy, announcer: announcer)
                            } else {
                                segmentation.stop()
                            }
                        }
                    ))
                    if let errorMessage = segmentation.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if segmentation.isEnabled {
                        Text("감지 \(segmentation.detectionCount)개 · \(Int(segmentation.inferenceMs.rounded()))ms · \(String(format: "%.1f", segmentation.effectiveFPS))fps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("모드") {
                    Toggle("시각장애인 모드 (음성 명령)", isOn: Binding(
                        get: { isAccessibilityMode },
                        set: { newValue in
                            isAccessibilityMode = newValue
                            segmentation.isAccessibilityMode = newValue
                            if !newValue { voiceFinder.stopListening() }
                        }
                    ))
                    if isAccessibilityMode {
                        Text(voiceStatusText)
                            .font(.caption)
                            .foregroundStyle(voiceFinder.errorMessage != nil ? .red : .secondary)
                    } else {
                        Text("일반 모드: 스피커 버튼을 누르면 감지된 사물 위치를 읽어줍니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("재생 테스트 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { showSettings = false }
                }
            }
        }
    }

    private var voiceStatusText: String {
        if let errorMessage = voiceFinder.errorMessage { return errorMessage }
        if voiceFinder.isListening { return "Listening..." }
        if !voiceFinder.lastAnswer.isEmpty { return voiceFinder.lastAnswer }
        return segmentation.isEnabled ? "카메라 화면의 마이크 버튼을 누르고 “find door”처럼 말해보세요" : "AI 인식을 켜야 사용 가능"
    }
}

#Preview {
    ReplayView()
}
