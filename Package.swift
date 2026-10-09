// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "soundkeeper",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "soundkeeper", targets: ["soundkeeper"]),
        .executable(name: "SoundKeeperApp", targets: ["SoundKeeperApp"]),
    ],
    targets: [
        // Real-time safe part: signal generator and the CoreAudio IOProc. Plain C, no allocations or locks while rendering.
        .target(
            name: "CSoundKeeperRender",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        // Everything else: device selection, sessions, power events, single instance, login item.
        .target(
            name: "SoundKeeperCore",
            dependencies: ["CSoundKeeperRender"],
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AppKit")]
        ),
        // The command line tool: Sound Keeper without any user interface, like the original.
        .executableTarget(
            name: "soundkeeper",
            dependencies: ["SoundKeeperCore"]
        ),
        // The menu bar app. scripts/build-app.sh wraps the executable into SoundKeeper.app.
        .target(
            name: "SoundKeeperUI",
            dependencies: ["SoundKeeperCore"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "SoundKeeperApp",
            dependencies: ["SoundKeeperUI"]
        ),
        .testTarget(
            name: "SoundKeeperTests",
            dependencies: ["SoundKeeperCore", "SoundKeeperUI", "CSoundKeeperRender"]
        ),
    ]
)
