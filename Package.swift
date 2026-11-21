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
        // The capture engine (AVCaptureSession, CoreAudio listeners, recovery), shared by the
        // CLI daemon and the app.
        .target(
            name: "MicWarmEngine",
            dependencies: ["MicWarmCore"],
            path: "Sources/MicWarmEngine",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .executableTarget(
            name: "mic-warm",
            dependencies: ["MicWarmCore", "MicWarmEngine"],
            path: "Sources/MicWarm"
        ),
        // The Mic Warm menu-bar app. scripts/build-app.sh wraps it in "Mic Warm.app".
        .executableTarget(
            name: "MicWarmApp",
            dependencies: ["MicWarmCore", "MicWarmEngine"],
            path: "Sources/MicWarmApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "MicWarmCoreTests",
            dependencies: ["MicWarmCore"],
            path: "Tests/MicWarmCoreTests"
        ),
    ]
)
