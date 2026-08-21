// swift-tools-version: 5.8
// Vendored + patched copy of https://github.com/kakao-mapsSDK/KakaoMapsSDK-SPM
//
// The upstream Package.swift names its wrapper target "KakaoMapsSDK-SPM", which
// Xcode rejects as a Swift module name (hyphens aren't valid identifiers):
//   error: module name "KakaoMapsSDK-SPM" is not a valid identifier
// This copy only renames the product/target to "KakaoMapsSDKKit" (module you
// depend on) while keeping the original folder layout and the untouched
// KakaoMapsSDK.xcframework binary (whose own embedded module is "KakaoMapsSDK",
// imported as `import KakaoMapsSDK` in app code).

import PackageDescription

let package = Package(
    name: "KakaoMapsSDKKit",
    platforms: [.iOS(.v13), .macCatalyst(.v13)],

    products: [
        .library(
            name: "KakaoMapsSDKKit",
            targets: ["KakaoMapsSDKKit"]),
    ],
    targets: [
        .target(
            name: "KakaoMapsSDKKit",
            dependencies: ["framework"],
            path: "Sources/KakaoMapsSDK-SPM",
            resources: [.copy("KakaoMapsSDKBundle.bundle/assets")]),
        .binaryTarget(name: "framework", path: "BinaryFramework/KakaoMapsSDK.xcframework")
    ],
    swiftLanguageVersions: [.v5]
)
