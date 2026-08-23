//
//  SPIED_2026App.swift
//  SPIED_2026
//
//  Created by yjy on 8/20/26.
//

import SwiftUI
import KakaoMapsSDK

@main
struct SPIED_2026App: App {
    @State private var selectedTab = 1

    init() {
        SDKInitializer.InitSDK(appKey: "3e5fd2d5cb569dd560d0b1a0f77271e8")
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                ContentView()
                    .tabItem { Label("날씨", systemImage: "cloud.sun.fill") }
                    .tag(0)
                WalkingPathView()
                    .tabItem { Label("걷는 길", systemImage: "figure.walk") }
                    .tag(1)
                ReplayView()
                    .tabItem { Label("재생 테스트", systemImage: "play.rectangle.fill") }
                    .tag(2)
            }
        }
    }
}
