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
    @StateObject private var galaxy = GalaxyBridgeClient(host: "192.168.50.50", port: 8080)
    @StateObject private var segmentation = SegmentationController()
    @State private var isActive = true
    @State private var isRecording = false

    @State private var destinationQuery = ""
    @State private var routeCoordinates: [CLLocationCoordinate2D] = []
    @State private var routeSummary: String?
    @State private var routeErrorMessage: String?
    @State private var isSearchingRoute = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                cameraView
                statusBar
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
        }
        .onDisappear {
            isActive = false
            galaxy.disconnect()
            segmentation.stop()
        }
    }

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

            if galaxy.latestFrame != nil {
                VStack {
                    HStack {
                        Spacer()
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
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(galaxy.isConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(galaxy.isConnected ? "갤럭시 연결됨" : "연결 안 됨")
                    .font(.subheadline)

                if let gps = galaxy.latestGPS {
                    Text("· \(String(format: "%.5f, %.5f", gps.latitude, gps.longitude))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(galaxy.isConnected ? "연결 해제" : "연결") {
                    if galaxy.isConnected {
                        galaxy.disconnect()
                    } else {
                        galaxy.connect()
                    }
                }
                .font(.subheadline.bold())
            }

            HStack {
                Text(isRecording ? "경로 기록 중" : "경로 기록 안 함")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(isRecording ? "기록 중지" : "기록 시작") {
                    isRecording.toggle()
                }
                .font(.subheadline.bold())
                .foregroundStyle(isRecording ? .red : .accentColor)
            }

            HStack {
                Text(segmentationStatusText)
                    .font(.caption)
                    .foregroundStyle(segmentation.errorMessage != nil ? .red : .secondary)

                Spacer()

                Button(segmentation.isEnabled ? "AI 인식 중지" : "AI 인식 시작") {
                    if segmentation.isEnabled {
                        segmentation.stop()
                    } else {
                        segmentation.start(galaxy: galaxy)
                    }
                }
                .font(.subheadline.bold())
                .foregroundStyle(segmentation.isEnabled ? .red : .accentColor)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private var segmentationStatusText: String {
        if let errorMessage = segmentation.errorMessage {
            return "AI 인식 오류: \(errorMessage)"
        }
        return segmentation.isEnabled ? "AI 인식 켜짐" : "AI 인식 꺼짐"
    }
}

#Preview {
    WalkingPathView()
}
