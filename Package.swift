// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VolumeMixer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VolumeMixer",
            path: "Sources/VolumeMixer"
        ),
        .target(
            name: "MixerShared",
            path: "Sources/MixerShared"
        ),
        .executableTarget(
            name: "VolumeMixerControls",
            dependencies: ["MixerShared"],
            path: "Sources/VolumeMixerControls"
        )
    ]
)
