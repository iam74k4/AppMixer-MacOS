// swift-tools-version: 5.9
import PackageDescription

// AppMixer — macOS per-app volume mixer (menu-bar resident app).
// 方式B: Core Audio Process Tap (macOS 14.4+).
//
// SwiftPM のプラットフォーム指定は major 単位のため .v14 を指定し、
// 14.2+ で追加された Process Tap API は各コード側で `@available(macOS 14.2, *)`
// で保護する。実行時の対象は Info.plist の LSMinimumSystemVersion = 14.4。
let package = Package(
    name: "AppMixer",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "AppMixer",
            path: "Sources/AppMixer"
        )
    ]
)
