import CryptoKit
import Foundation
import Observation
import SurfCore

/// Downloads, verifies, and installs the enhanced reading voice.
///
/// User-initiated, unlike the component updater: a third of a gigabyte is a
/// decision, not maintenance, so nothing here runs until the button in
/// Settings is pressed — and the button says the size before it's pressed.
@MainActor
@Observable
final class VoiceInstaller {
    static let shared = VoiceInstaller()

    enum Phase: Equatable {
        case absent
        /// 0…1 across both archives, weighted by size.
        case downloading(Double)
        case installing
        case installed
        case failed(String)
    }

    private(set) var phase: Phase

    private init() {
        phase = Self.isInstalled ? .installed : .absent
    }

    // The path facts are nonisolated: the synthesiser actor builds itself
    // from them off the main actor, and a path is a value, not UI state.

    /// Where the voice lives, beside the helper binaries' directory.
    nonisolated static var directory: URL { SupportDirectory.subdirectory("Voice") }

    /// Present means every file inference stands on is there. A partial
    /// extraction reads as absent — reinstalling is cheap, debugging a voice
    /// that loads half a model is not.
    nonisolated static var isInstalled: Bool {
        VoiceComponent.requiredFiles.allSatisfy {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0).path
            )
        }
    }

    nonisolated static var runtimeLibrary: URL {
        directory.appendingPathComponent(
            "\(VoiceComponent.runtime.unpackedDirectory)/lib/libsherpa-onnx-c-api.dylib"
        )
    }

    nonisolated static var modelDirectory: URL {
        directory.appendingPathComponent(VoiceComponent.model.unpackedDirectory)
    }

    /// Whether narration should speak through the downloaded voice.
    var isReady: Bool { phase == .installed }

    // MARK: - Install

    func install() {
        guard phase == .absent || phase.isFailure else { return }
        phase = .downloading(0)
        Task { @MainActor in
            do {
                var finished: [VoiceComponent.Package] = []
                for package in VoiceComponent.packages {
                    let archive = try await download(package, finished: finished)
                    phase = .installing
                    try await unpack(archive, into: Self.directory)
                    try? FileManager.default.removeItem(at: archive)
                    finished.append(package)
                    if finished.count < VoiceComponent.packages.count {
                        phase = .downloading(
                            VoiceComponent.progress(
                                finished: finished, current: nil, currentFraction: 0
                            )
                        )
                    }
                }
                guard Self.isInstalled else {
                    throw InstallFailure.incomplete
                }
                phase = .installed
                // A load that failed while the files were absent is allowed
                // to try again now that they aren't.
                await KokoroSynthesizer.shared.retryAfterInstall()
                debugLog("voice: installed")
            } catch {
                // Whatever half-arrived must not read as installed next launch.
                try? FileManager.default.removeItem(at: Self.directory)
                phase = .failed(message(for: error))
                debugLog("voice: install failed — \(error)")
            }
        }
    }

    func remove() {
        guard phase == .installed else { return }
        try? FileManager.default.removeItem(at: Self.directory)
        phase = .absent
        debugLog("voice: removed")
    }

    // MARK: - The pipeline

    private enum InstallFailure: Error {
        case network
        case checksum
        case unpack
        case incomplete
    }

    private func message(for error: Error) -> String {
        switch error {
        case InstallFailure.checksum:
            return "The download didn't match its published checksum, so it wasn't installed."
        case InstallFailure.unpack, InstallFailure.incomplete:
            return "The download couldn't be unpacked. Try again."
        default:
            return "The download couldn't be completed. Check the connection and try again."
        }
    }

    /// Streams one archive to disk, reporting combined progress, then
    /// verifies it against the pinned hash. Nothing unverified is unpacked.
    private func download(
        _ package: VoiceComponent.Package,
        finished: [VoiceComponent.Package]
    ) async throws -> URL {
        var request = URLRequest(url: package.downloadURL)
        request.timeoutInterval = 600
        request.setValue("Surf", forHTTPHeaderField: "User-Agent")

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("surf-voice-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let file = try? FileHandle(forWritingTo: destination) else {
            throw InstallFailure.network
        }
        defer { try? file.close() }

        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { throw InstallFailure.network }

        let expected = response.expectedContentLength
        var hasher = SHA256()
        var received: Int64 = 0
        var chunk = Data(capacity: 1 << 16)

        do {
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= 1 << 16 {
                    try file.write(contentsOf: chunk)
                    hasher.update(data: chunk)
                    received += Int64(chunk.count)
                    chunk.removeAll(keepingCapacity: true)
                    if expected > 0 {
                        phase = .downloading(
                            VoiceComponent.progress(
                                finished: finished,
                                current: package,
                                currentFraction: Double(received) / Double(expected)
                            )
                        )
                    }
                }
            }
            if !chunk.isEmpty {
                try file.write(contentsOf: chunk)
                hasher.update(data: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw InstallFailure.network
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == package.sha256 else {
            try? FileManager.default.removeItem(at: destination)
            throw InstallFailure.checksum
        }
        return destination
    }

    /// The system tar, which handles bz2 itself. Extraction happens off the
    /// main actor — the model archive is a third of a gigabyte.
    private func unpack(_ archive: URL, into directory: URL) async throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let ok = await Task.detached(priority: .userInitiated) {
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["xjf", archive.path, "-C", directory.path]
            tar.standardOutput = FileHandle.nullDevice
            tar.standardError = FileHandle.nullDevice
            do {
                try tar.run()
                tar.waitUntilExit()
            } catch { return false }
            return tar.terminationStatus == 0
        }.value
        guard ok else { throw InstallFailure.unpack }

        // Downloaded code is quarantined, and dlopen refuses a quarantined
        // dylib. Same move the component updater makes for its binaries,
        // swept here because an archive holds many files.
        for path in VoiceComponent.requiredFiles where path.hasSuffix(".dylib") {
            removexattr(
                directory.appendingPathComponent(path).path,
                "com.apple.quarantine", 0
            )
        }
    }
}

private extension VoiceInstaller.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
