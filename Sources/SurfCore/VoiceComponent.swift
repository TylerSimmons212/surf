import Foundation

/// The enhanced reading voice: what gets downloaded, from where, and how to
/// know it arrived intact.
///
/// Unlike yt-dlp and ffmpeg — which update on a schedule because sites change
/// under them — the voice is *pinned*. The runtime's struct layouts are
/// compiled into Surf (see `SherpaTTSABI`), so a newer dylib isn't an upgrade,
/// it's an ABI roulette. New voice versions ship the way Surf ships: in a
/// build that pins the next release and its layouts together.
public enum VoiceComponent {

    /// One downloadable archive: where it lives, what it unpacks to, and the
    /// hash nothing is installed without matching.
    public struct Package: Equatable, Sendable {
        public var assetName: String
        public var downloadURL: URL
        /// Lowercase hex SHA-256 of the archive as published by the release.
        public var sha256: String
        /// The directory the archive unpacks to, relative to the voice
        /// directory — how installation is detected and how it's removed.
        public var unpackedDirectory: String
        /// For the download UI, and for saying so before starting.
        public var approximateMegabytes: Int

        public init(
            assetName: String, downloadURL: URL, sha256: String,
            unpackedDirectory: String, approximateMegabytes: Int
        ) {
            self.assetName = assetName
            self.downloadURL = downloadURL
            self.sha256 = sha256
            self.unpackedDirectory = unpackedDirectory
            self.approximateMegabytes = approximateMegabytes
        }
    }

    /// The inference runtime: sherpa-onnx's C API and its ONNX Runtime, as
    /// built and published by the k2-fsa project.
    public static let runtime = Package(
        assetName: "sherpa-onnx-v1.13.6-osx-universal2-shared.tar.bz2",
        downloadURL: URL(string:
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.6/sherpa-onnx-v1.13.6-osx-universal2-shared.tar.bz2"
        )!,
        sha256: "05ed5839bbdfb2da36bb9095961e6b4cfa470d55e29a9795100627dbc36df2ba",
        unpackedDirectory: "sherpa-onnx-v1.13.6-osx-universal2-shared",
        approximateMegabytes: 40
    )

    /// The Kokoro model, English, full precision — the quality tier the
    /// download exists for.
    public static let model = Package(
        assetName: "kokoro-en-v0_19.tar.bz2",
        downloadURL: URL(string:
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-en-v0_19.tar.bz2"
        )!,
        sha256: "912804855a04745fa77a30be545b3f9a5d15c4d66db00b88cbcd4921df605ac7",
        unpackedDirectory: "kokoro-en-v0_19",
        approximateMegabytes: 304
    )

    public static let packages = [runtime, model]

    public static var totalMegabytes: Int {
        packages.reduce(0) { $0 + $1.approximateMegabytes }
    }

    /// The files an installation stands on, relative to the voice directory.
    /// All present means installed; any missing means not — a half-extracted
    /// archive must read as absent, not as broken-in-interesting-ways.
    public static let requiredFiles = [
        "\(runtime.unpackedDirectory)/lib/libsherpa-onnx-c-api.dylib",
        "\(runtime.unpackedDirectory)/lib/libonnxruntime.dylib",
        "\(model.unpackedDirectory)/model.onnx",
        "\(model.unpackedDirectory)/voices.bin",
        "\(model.unpackedDirectory)/tokens.txt",
        "\(model.unpackedDirectory)/espeak-ng-data/phontab",
    ]

    /// The voice spoken by default. Kokoro v0.19 ships eleven; zero is "af",
    /// the blend its authors present as the flagship.
    public static let defaultSpeaker: Int32 = 0

    /// Fraction of a combined download a finished `package` represents, for
    /// one progress bar over two archives — sized by bytes, because a bar
    /// that jumps to half after the 40 MB archive lies about the 304 MB one.
    public static func progress(
        finished: [Package], current: Package?, currentFraction: Double
    ) -> Double {
        let total = Double(totalMegabytes)
        guard total > 0 else { return 0 }
        var done = finished.reduce(0.0) { $0 + Double($1.approximateMegabytes) }
        if let current {
            done += Double(current.approximateMegabytes) * min(1, max(0, currentFraction))
        }
        return min(1, done / total)
    }
}
