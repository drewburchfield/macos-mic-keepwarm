// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mic-warm",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic with no audio dependencies, so it can be unit tested.
        .target(
            name: "MicWarmCore",
            path: "Sources/MicWarmCore"
        ),
        .executableTarget(
            name: "mic-warm",
            dependencies: ["MicWarmCore"],
            path: "Sources/MicWarm",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        // The Mic Warm menu-bar app. scripts/build-app.sh wraps it in "Mic Warm.app".
        .executableTarget(
            name: "MicWarmApp",
            dependencies: ["MicWarmCore"],
            path: "Sources/MicWarmApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .testTarget(
            name: "MicWarmCoreTests",
            dependencies: ["MicWarmCore"],
            path: "Tests/MicWarmCoreTests"
        ),
    ]
)
