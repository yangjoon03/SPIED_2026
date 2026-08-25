//
//  WalkingPathView.swift
//  SPIED_2026
//
//  Screen that shows the pedestrian path traced from the Galaxy phone's
//  live GPS stream on a KakaoMap.
//

import SwiftUI
import CoreLocation

struct WalkingPathView: View {
    @StateObject private var galaxy = GalaxyBridgeClient(host: "192.168.65.240", port: 8080)
    @StateObject private var segmentation = SegmentationController()
    @StateObject private var announcer = DetectionAnnouncer()
    @StateObject private var voiceFinder = VoiceFinderController()
    @StateObject private var arduino = ArduinoSocket()
    @State private var isActive = true
    @State private var isRecording = false
    @State private var isAccessibilityMode = false
    @State private var showSettings = false

    @State private var destinationQuery = ""
    @State private var routeCoordinates: [CLLocationCoordinate2D] = []
    @State private var routeSummary: String?
    @State private var routeErrorMessage: String?
    @State private var isSearchingRoute = false

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height {
                landscapeLayout(width: geo.size.width, height: geo.size.height)
            } else {
                portraitLayout
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            isActive = true
            galaxy.connect()
            arduino.connect()
            voiceFinder.requestAuthorization()
            voiceFinder.detectionsProvider = { segmentation.detections }
        }
        .onDisappear {
            isActive = false
            galaxy.disconnect()
            arduino.disconnect()
            segmentation.stop()
            voiceFinder.stopListening()
        }
        .onChange(of: arduino.remaining) { _, newValue in
            // 방향이 맞고 틀리고를 떠나, 그냥 느려서 1초밖에 안 남았는데 아직
            // 다 못 건넌 상태(tracking 중)면 방향 이탈 여부와 무관하게 연장한다.
            guard arduino.trafficState == "GREEN", newValue == 1, segmentation.isCrossingInProgress else { return }
            arduino.extendGreen()
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
    }

    private var portraitLayout: some View {
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
                    galaxy: galaxy,
                    isActive: $isActive,
                    isRecording: $isRecording,
                    routeCoordinates: $routeCoordinates
                )
                destinationBar
            }
        }
    }

    /// 가로모드: 왼쪽에 카메라를 최대한 크게, 오른쪽은 위쪽에 음성 안내 로그 /
    /// 아래쪽에 지도를 배치한다.
    private func landscapeLayout(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                cameraView
                primaryActionButton
                    .padding(.bottom, 14)
            }
            .frame(width: width * 0.6)
            .clipped()

            VStack(spacing: 0) {
                VoiceLogView(announcer: announcer)
                    .frame(height: height * 0.3)

                ZStack(alignment: .top) {
                    KakaoPathMapView(
                        galaxy: galaxy,
                        isActive: $isActive,
                        isRecording: $isRecording,
                        routeCoordinates: $routeCoordinates
                    )
                    destinationBar
                }
            }
            .frame(width: width * 0.4)
        }
    }

    // MARK: - 카메라 오버레이 (최소한만: 연결 표시, 설정 버튼, FPS, 핵심 액션 버튼)

    private var cameraView: some View {
        ZStack {
            Color.black

            if segmentation.isEnabled, let vis = segmentation.visualizationImage {
                Image(uiImage: vis)
                    .resizable()
                    .scaledToFit()
            } else if let frame = galaxy.latestFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("카메라 대기 중...")
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
                                .fill(galaxy.isConnected ? Color.green : Color.red)
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

                    if galaxy.latestFrame != nil || arduino.isConnected {
                        VStack(alignment: .trailing, spacing: 4) {
                            if galaxy.latestFrame != nil {
                                Text("\(galaxy.fps) FPS")
                                if segmentation.isEnabled {
                                    Text("감지 \(segmentation.detectionCount)개 · \(Int(segmentation.inferenceMs.rounded()))ms · \(String(format: "%.1f", segmentation.effectiveFPS))fps")
                                }
                            }
                            if arduino.isConnected {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(trafficLightColor)
                                        .frame(width: 8, height: 8)
                                    Text("\(arduino.trafficState) \(arduino.remaining)s")
                                }
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

    private var trafficLightColor: Color {
        switch arduino.trafficState {
        case "GREEN": return .green
        case "YELLOW": return .yellow
        case "RED": return .red
        default: return .gray
        }
    }

    /// 일반 모드에서는 스피커(수동 안내), 시각장애인 모드에서는 마이크(음성 명령) 버튼.
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

    // MARK: - 설정 시트

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section("갤럭시 연결") {
                    HStack {
                        Circle()
                            .fill(galaxy.isConnected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(galaxy.isConnected ? "연결됨" : "연결 안 됨")
                        Spacer()
                        Button(galaxy.isConnected ? "연결 해제" : "연결") {
                            if galaxy.isConnected {
                                galaxy.disconnect()
                            } else {
                                galaxy.connect()
                            }
                        }
                    }
                    if let gps = galaxy.latestGPS {
                        Text(String(format: "%.5f, %.5f", gps.latitude, gps.longitude))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("횡단보도 신호 하드웨어") {
                    HStack {
                        Circle()
                            .fill(arduino.isConnected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(arduino.isConnected ? "연결됨" : "연결 안 됨")
                        Spacer()
                        Button(arduino.isConnected ? "연결 해제" : "연결") {
                            if arduino.isConnected {
                                arduino.disconnect()
                            } else {
                                arduino.connect()
                            }
                        }
                    }
                    if arduino.isConnected {
                        Text("신호: \(arduino.trafficState) · 남은 시간 \(arduino.remaining)초")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("이탈 경고가 뜨면 보행 신호(초록불)를 5초씩 자동 연장합니다 (최대 4회).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("경로 기록") {
                    Toggle("도보 경로 기록", isOn: $isRecording)
                }

                Section("AI 인식") {
                    Toggle("실시간 AI 인식", isOn: Binding(
                        get: { segmentation.isEnabled },
                        set: { newValue in
                            if newValue {
                                segmentation.start(galaxy: galaxy, announcer: announcer, arduino: arduino)
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
            .navigationTitle("설정")
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

    // MARK: - 목적지 검색 (지도 위 오버레이)

    private var destinationBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("목적지 검색 (예: 김해대곡초등학교)", text: $destinationQuery)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit { searchRoute() }

                Button {
                    searchRoute()
                } label: {
                    if isSearchingRoute {
                        ProgressView()
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .disabled(destinationQuery.trimmingCharacters(in: .whitespaces).isEmpty || isSearchingRoute)

                if !routeCoordinates.isEmpty {
                    Button {
                        routeCoordinates = []
                        routeSummary = nil
                        routeErrorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let routeSummary {
                Text(routeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let routeErrorMessage {
                Text(routeErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private func searchRoute() {
        let query = destinationQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        guard let currentGPS = galaxy.latestGPS else {
            routeErrorMessage = "현재 위치를 아직 알 수 없습니다. 갤럭시 연결 후 다시 시도해주세요."
            return
        }

        isSearchingRoute = true
        routeErrorMessage = nil

        Task {
            do {
                let destinationCoordinate = try await RouteService.geocode(query: query)
                let origin = CLLocationCoordinate2D(latitude: currentGPS.latitude, longitude: currentGPS.longitude)
                let route = try await RouteService.walkingRoute(from: origin, to: destinationCoordinate)

                await MainActor.run {
                    routeCoordinates = route.coordinates
                    let minutes = max(1, route.durationSeconds / 60)
                    routeSummary = "\(route.distanceMeters)m · 약 \(minutes)분"
                    isSearchingRoute = false
                }
            } catch {
                await MainActor.run {
                    routeErrorMessage = error.localizedDescription
                    isSearchingRoute = false
                }
            }
        }
    }
}

#Preview {
    WalkingPathView()
}
