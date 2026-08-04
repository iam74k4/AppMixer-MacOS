// swift-tools-version: 5.9
import PackageDescription

// AppMixer — macOS per-app volume mixer (menu-bar resident app).
// 方式B: Core Audio Process Tap (macOS 14.4+).
//
// デプロイターゲットを 14.4 に固定（Process Tap API と SwiftUI @main のため）。
// これにより 14.2+ API を @available で保護する必要がなくなる。
let package = Package(
    name: "AppMixer",
    platforms: [
        .macOS("14.4")
    ],
    targets: [
        .executableTarget(
            name: "AppMixer",
            path: "Sources/AppMixer"
        )
    ]
)
