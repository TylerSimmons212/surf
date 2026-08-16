// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Glass",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic, no AppKit/WebKit — so it can be unit tested.
        .target(
            name: "GlassCore",
            path: "Sources/GlassCore"
        ),
        .executableTarget(
            name: "Glass",
            dependencies: ["GlassCore"],
            path: "Sources/Glass"
        ),
        .testTarget(
            name: "GlassCoreTests",
            dependencies: ["GlassCore"],
            path: "Tests/GlassCoreTests"
        ),
    ]
)
