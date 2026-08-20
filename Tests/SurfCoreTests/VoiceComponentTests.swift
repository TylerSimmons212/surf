import Testing

@testable import SurfCore

@Suite("Voice component")
struct VoiceComponentTests {

    @Test("Every package is pinned: https, a real hash, a directory to land in")
    func packagesArePinned() {
        for package in VoiceComponent.packages {
            #expect(package.downloadURL.scheme == "https")
            #expect(package.sha256.count == 64)
            #expect(package.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(!package.unpackedDirectory.isEmpty)
            #expect(package.approximateMegabytes > 0)
        }
    }

    /// Install detection stands on these; an empty list would make any
    /// directory read as installed.
    @Test("Required files cover both packages")
    func requiredFilesCoverBoth() {
        #expect(!VoiceComponent.requiredFiles.isEmpty)
        for package in VoiceComponent.packages {
            #expect(VoiceComponent.requiredFiles.contains {
                $0.hasPrefix(package.unpackedDirectory + "/")
            })
        }
    }

    /// One bar over two archives, weighted by bytes — a bar that jumps to
    /// half after the small archive lies about the big one.
    @Test("Progress weighs archives by size")
    func progressWeighting() {
        let runtime = VoiceComponent.runtime
        let model = VoiceComponent.model

        #expect(VoiceComponent.progress(finished: [], current: nil, currentFraction: 0) == 0)

        let afterRuntime = VoiceComponent.progress(
            finished: [runtime], current: model, currentFraction: 0
        )
        let runtimeShare = Double(runtime.approximateMegabytes)
            / Double(VoiceComponent.totalMegabytes)
        #expect(abs(afterRuntime - runtimeShare) < 0.001)
        #expect(afterRuntime < 0.5)

        let done = VoiceComponent.progress(
            finished: [runtime, model], current: nil, currentFraction: 0
        )
        #expect(done == 1)

        // A fraction the network reports past 1 must not push the bar past 1.
        let clamped = VoiceComponent.progress(
            finished: [runtime], current: model, currentFraction: 1.5
        )
        #expect(clamped <= 1)
    }
}
