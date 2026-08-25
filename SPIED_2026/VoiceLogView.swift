//
//  VoiceLogView.swift
//  SPIED_2026
//
//  가로모드 레이아웃에서 지도 위쪽에 놓는 음성 안내 로그. 최근 안내를
//  시간순으로 스크롤 목록으로 보여주고, 새 안내가 오면 자동으로 맨 아래로 스크롤한다.
//

import SwiftUI

struct VoiceLogView: View {
    @ObservedObject var announcer: DetectionAnnouncer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("음성 안내 로그")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if announcer.announcementLog.isEmpty {
                Text("아직 안내된 내용이 없습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(announcer.announcementLog) { entry in
                                Text(entry.text)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    }
                    .onChange(of: announcer.announcementLog.count) { _, _ in
                        guard let last = announcer.announcementLog.last else { return }
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
    }
}
