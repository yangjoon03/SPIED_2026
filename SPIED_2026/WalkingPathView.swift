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
    @StateObject private var galaxy = GalaxyBridgeClient(host: "192.168.0.90", port: 8080)
    @StateObject private var segmentation = SegmentationController()
    @StateObject private var announcer = DetectionAnnouncer()
    @StateObject private var voiceFinder = VoiceFinderController()
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
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            isActive = true
            galaxy.connect()
            voiceFinder.requestAuthorization()
            voiceFinder.detectionsProvider = { segmentation.detections }
        }
        .onDisappear {
            isActive = false
            galaxy.disconnect()
            segmentation.stop()
            voiceFinder.stopListening()
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
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

                    if galaxy.latestFrame != nil {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(galaxy.fps) FPS")
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

                Section("경로 기록") {
                    Toggle("도보 경로 기록", isOn: $isRecording)
                }

                Section("AI 인식") {
                    Toggle("실시간 AI 인식", isOn: Binding(
                        get: { segmentation.isEnabled },
                        set: { newValue in
                            if newValue {
                                segmentation.start(galaxy: galaxy, announcer: announcer)
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
