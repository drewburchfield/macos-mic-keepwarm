// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mic-warm",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "mic-warm",
            path: "Sources/MicWarm",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        )
    ]
)
