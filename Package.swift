// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Surf",
    // String form: PackageDescription 6.0's enum stops short of .v26.
    platforms: [.macOS("27.0")],
    targets: [
        // Pure logic, no AppKit/WebKit — so it can be unit tested.
        .target(
            name: "SurfCore",
            path: "Sources/SurfCore"
        ),
        // Struct layouts for the downloaded TTS runtime, pinned to its
        // version. Nothing links against it — the dylib is dlopen'd — but the
        // compiler checking these offsets is what stands between the enhanced
        // voice and garbage audio with no error attached.
        .target(
            name: "SherpaTTSABI",
            path: "Sources/SherpaTTSABI"
        ),
        .executableTarget(
            name: "Surf",
            dependencies: ["SurfCore", "SherpaTTSABI"],
            path: "Sources/Surf"
        ),
        .testTarget(
            name: "SurfCoreTests",
            dependencies: ["SurfCore"],
            path: "Tests/SurfCoreTests"
        ),
    ]
)
