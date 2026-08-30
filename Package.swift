// swift-tools-version: 6.0
// Parallax — native macOS strategy game. Neutral identifiers only.
//
// Slice 1: TacticalCore (deterministic engine) + parallax-cli (match runner)
// Slice 2: TacticalRenderer (Metal 3D board) + TacticalInput (chorded keyboard)
//          + ParallaxApp (SwiftUI app shell, complete offline loop)
// Slice 3: TacticalAudio (AVAudioEngine procedural sound) + accessibility
// Slice 4: TacticalBots (search-driven Grandmaster AI) + Standoff mode
// Slice 5: Grandmaster 6-plateau board + content tools
// Slice 6: TacticalPersistence (SwiftData, replay format)
// Slice 7: TacticalNetworking (local/LAN play)
// Slice 8: TacticalServer (Vapor backend)
// Slice 9: Ranked/ratings/operations
// Slice 10: Release packaging (DMG, signing, notarization)

import PackageDescription

let package = Package(
    name: "parallax",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TacticalCore", targets: ["TacticalCore"]),
        .library(name: "TacticalRenderer", targets: ["TacticalRenderer"]),
        .library(name: "TacticalInput", targets: ["TacticalInput"]),
        .library(name: "TacticalAudio", targets: ["TacticalAudio"]),
        .library(name: "TacticalHaptics", targets: ["TacticalHaptics"]),
        .library(name: "TacticalBots", targets: ["TacticalBots"]),
        .library(name: "TacticalPersistence", targets: ["TacticalPersistence"]),
        .library(name: "TacticalNetworking", targets: ["TacticalNetworking"]),
        .executable(name: "parallax-cli", targets: ["parallax-cli"]),
        .executable(name: "ParallaxApp", targets: ["ParallaxApp"]),
        .executable(name: "parallax-tools", targets: ["parallax-tools"]),
        .executable(name: "parallax-render-check", targets: ["parallax-render-check"])
    ],
    targets: [
        .target(name: "TacticalCore", path: "Sources/TacticalCore"),
        .target(name: "TacticalRenderer", dependencies: ["TacticalCore"], path: "Sources/TacticalRenderer"),
        .target(name: "TacticalInput", dependencies: ["TacticalCore"], path: "Sources/TacticalInput"),
        .target(name: "TacticalAudio", dependencies: ["TacticalCore"], path: "Sources/TacticalAudio"),
        .target(name: "TacticalHaptics", dependencies: [], path: "Sources/TacticalHaptics"),
        .target(name: "TacticalBots", dependencies: ["TacticalCore"], path: "Sources/TacticalBots"),
        .target(name: "TacticalPersistence", dependencies: ["TacticalCore"], path: "Sources/TacticalPersistence"),
        .target(name: "TacticalNetworking", dependencies: ["TacticalCore"], path: "Sources/TacticalNetworking"),
        .executableTarget(name: "parallax-cli", dependencies: ["TacticalCore"], path: "Sources/parallax-cli"),
        .executableTarget(name: "ParallaxApp", dependencies: ["TacticalCore", "TacticalRenderer", "TacticalInput", "TacticalAudio", "TacticalHaptics", "TacticalBots", "TacticalPersistence", "TacticalNetworking"], path: "Sources/ParallaxApp"),
        .executableTarget(name: "parallax-tools", dependencies: ["TacticalCore", "TacticalBots", "TacticalPersistence"], path: "Sources/parallax-tools"),
        .executableTarget(name: "parallax-render-check", dependencies: ["TacticalCore", "TacticalRenderer"], path: "Sources/parallax-render-check"),
        .testTarget(name: "TacticalCoreTests", dependencies: ["TacticalCore"], path: "Tests/TacticalCoreTests"),
        .testTarget(name: "TacticalInputTests", dependencies: ["TacticalInput", "TacticalCore"], path: "Tests/TacticalInputTests"),
        .testTarget(name: "TacticalBotsTests", dependencies: ["TacticalBots", "TacticalCore"], path: "Tests/TacticalBotsTests"),
        .testTarget(name: "TacticalRendererTests", dependencies: ["TacticalRenderer", "TacticalCore"], path: "Tests/TacticalRendererTests"),
        .testTarget(name: "ParallaxAppTests", dependencies: ["ParallaxApp", "TacticalCore", "TacticalHaptics", "TacticalRenderer", "TacticalBots"], path: "Tests/ParallaxAppTests"),
        .testTarget(name: "TacticalAudioTests", dependencies: ["TacticalAudio"], path: "Tests/TacticalAudioTests"),
        .testTarget(name: "TacticalHapticsTests", dependencies: ["TacticalHaptics"], path: "Tests/TacticalHapticsTests"),
        .testTarget(name: "TacticalPersistenceTests", dependencies: ["TacticalPersistence", "TacticalCore"], path: "Tests/TacticalPersistenceTests"),
        .testTarget(name: "TacticalNetworkingTests", dependencies: ["TacticalNetworking", "TacticalCore"], path: "Tests/TacticalNetworkingTests")
    ]
)
