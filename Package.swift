// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Surf",
    // String form: PackageDescription 6.0's enum stops short of .v26.
    platforms: [.macOS("27.0")],
    // The only dependency Surf has, and it earns the exception. Replacing a
    // running, signed application with a newer one — verifying it, staging it,
    // swapping it, relaunching — is a job with a lot of ways to leave someone
    // holding a broken app, and Sparkle is the implementation everyone else
    // already trusts with it.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
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
            dependencies: [
                "SurfCore", "SherpaTTSABI",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Surf",
            linkerSettings: [
                // Sparkle is a framework, and `bundle.sh` assembles the .app
                // by hand rather than letting Xcode do it. This is what lets
                // the copy in Contents/Frameworks be found at launch; without
                // it the app builds and then dies on dyld.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .testTarget(
            name: "SurfCoreTests",
            dependencies: ["SurfCore"],
            path: "Tests/SurfCoreTests"
        ),
    ]
)
