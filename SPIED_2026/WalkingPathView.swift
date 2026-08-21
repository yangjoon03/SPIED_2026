//
//  WalkingPathView.swift
//  SPIED_2026
//
//  Screen that shows the pedestrian path traced from the Galaxy phone's
//  live GPS stream on a KakaoMap.
//

import SwiftUI

struct WalkingPathView: View {
    @StateObject private var galaxy = GalaxyBridgeClient(host: "192.168.0.90", port: 8080)
    @State private var isActive = true
    @State private var isRecording = false

    var body: some View {
        ZStack(alignment: .top) {
            KakaoPathMapView(galaxy: galaxy, isActive: $isActive, isRecording: $isRecording)
                .ignoresSafeArea()

            statusBar
        }
        .onAppear {
            isActive = true
            galaxy.connect()
        }
        .onDisappear {
            isActive = false
            galaxy.disconnect()
        }
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
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}

#Preview {
    WalkingPathView()
}
