// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Surf",
    // String form: PackageDescription 6.0's enum stops short of .v26.
    platforms: [.macOS("26.0")],
    targets: [
        // Pure logic, no AppKit/WebKit — so it can be unit tested.
        .target(
            name: "SurfCore",
            path: "Sources/SurfCore"
        ),
        .executableTarget(
            name: "Surf",
            dependencies: ["SurfCore"],
            path: "Sources/Surf"
        ),
        .testTarget(
            name: "SurfCoreTests",
            dependencies: ["SurfCore"],
            path: "Tests/SurfCoreTests"
        ),
    ]
)
