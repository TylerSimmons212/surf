import CryptoKit
import Foundation
import SurfCore

/// Keeps Surf's helper binaries current, silently.
///
/// The user has a Surf version and nothing else. yt-dlp ships inside the app so
/// downloads work on first launch with no network; from then on this quietly
/// installs newer copies alongside it, because sites change their players and a
/// pinned extractor goes stale within weeks. ffmpeg has no bundled copy for
/// licensing reasons and arrives here on first check.
///
/// Nothing here ever prompts, blocks, or reports success. A failed update leaves
/// the previous copy in place and tries again next week; the only user-visible
/// consequence of this whole file working is that downloads keep working.
@MainActor
final class UpdateManager {
    static let shared = UpdateManager()

    private var isChecking = false

    private init() {}

    /// Where managed copies live. Deliberately not inside the app bundle:
    /// that's code-signed and read-only, and writing to it would break the
    /// signature.
    static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Surf/Components", isDirectory: true)
    }()

    /// The managed copy of a component, if one is installed and runnable.
    static func installedURL(_ component: Component) -> URL? {
        let url = directory.appendingPathComponent(component.executableName)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func installedVersion(_ component: Component) -> String? {
        UserDefaults.standard.string(forKey: "componentVersion.\(component.rawValue)")
    }

    private static func recordVersion(_ version: String, for component: Component) {
        UserDefaults.standard.set(version, forKey: "componentVersion.\(component.rawValue)")
    }

    // MARK: - Scheduling

    private var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: PreferenceKeys.lastComponentCheck) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKeys.lastComponentCheck) }
    }

    /// Called at launch. Returns immediately unless a check is actually due.
    func checkIfDue() {
        guard UpdateSchedule.isDue(lastCheck: lastCheck, now: Date()) else { return }
        checkNow()
    }

    func checkNow() {
        guard !isChecking else { return }
        isChecking = true

        Task { @MainActor in
            defer { isChecking = false }

            // Recorded before the work, not after: a component whose publisher
            // is down shouldn't mean a network round trip on every single launch.
            lastCheck = Date()

            for component in Component.allCases {
                await update(component)
            }
        }
    }

    // MARK: - Updating

    private func update(_ component: Component) async {
        guard let release = await latestRelease(for: component) else { return }

        // Nothing managed yet means install unconditionally — for ffmpeg that's
        // the first copy at all, and for yt-dlp it supersedes the bundled one,
        // whose version isn't recorded anywhere.
        guard Self.installedURL(component) == nil
                || ComponentVersion.isNewer(
                    release.version, than: Self.installedVersion(component)
                )
        else { return }

        guard let payload = await download(release) else { return }

        do {
            try install(payload, of: component, verifying: release)
            Self.recordVersion(release.version, for: component)
            // The resolved path may have just changed from bundled to managed.
            MediaExtractor.shared.invalidateResolution()
        } catch {
            try? FileManager.default.removeItem(at: payload)
        }
    }

    // MARK: - Discovery

    private func latestRelease(for component: Component) async -> ComponentRelease? {
        switch component {
        case .ytdlp: await latestYTDLP()
        case .ffmpeg: await latestFFmpeg()
        }
    }

    private func latestYTDLP() async -> ComponentRelease? {
        guard let json = await fetch(YTDLPRelease.latestReleaseAPI),
              let version = YTDLPRelease.version(fromReleaseJSON: json),
              let sumsURL = YTDLPRelease.checksumsURL(version: version),
              let sumsData = await fetch(sumsURL),
              let sums = String(data: sumsData, encoding: .utf8),
              let sha256 = YTDLPRelease.checksum(forAsset: YTDLPRelease.assetName, in: sums),
              let downloadURL = YTDLPRelease.downloadURL(version: version)
        else { return nil }

        return ComponentRelease(
            version: version, downloadURL: downloadURL, sha256: sha256, isZipped: false
        )
    }

    private func latestFFmpeg() async -> ComponentRelease? {
        let arch = FFmpegRelease.architecture(isAppleSilicon: Self.isAppleSilicon)

        guard let historyURL = FFmpegRelease.historyURL(architecture: arch),
              let historyData = await fetch(historyURL),
              let html = String(data: historyData, encoding: .utf8),
              let build = FFmpegRelease.latestBuild(inHistory: html, architecture: arch),
              let version = FFmpegRelease.version(ofBuild: build),
              let checksumURL = FFmpegRelease.checksumURL(architecture: arch, build: build),
              let sidecarData = await fetch(checksumURL),
              let sidecar = String(data: sidecarData, encoding: .utf8),
              let sha256 = FFmpegRelease.checksum(inSidecar: sidecar),
              let downloadURL = FFmpegRelease.downloadURL(architecture: arch, build: build)
        else {
            // The build ID is only discoverable by reading their history page,
            // so a redesign there would otherwise take ffmpeg with it.
            return FFmpegRelease.fallback(architecture: arch)
        }

        return ComponentRelease(
            version: version, downloadURL: downloadURL, sha256: sha256, isZipped: true
        )
    }

    /// Rosetta reports arm64 honestly here, which is what we want: the binary
    /// has to match the hardware, not the process.
    static var isAppleSilicon: Bool {
        var result = Int32(0)
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &result, &size, nil, 0) == 0 else {
            return false
        }
        return result == 1
    }

    // MARK: - Transfer

    private func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // GitHub's API rejects requests without one.
        request.setValue("Surf", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    private func download(_ release: ComponentRelease) async -> URL? {
        var request = URLRequest(url: release.downloadURL)
        request.timeoutInterval = 300
        request.setValue("Surf", forHTTPHeaderField: "User-Agent")

        guard let (temporary, response) = try? await URLSession.shared.download(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        // URLSession deletes its temp file as soon as this returns.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("surf-update-\(UUID().uuidString)")
        guard (try? FileManager.default.moveItem(at: temporary, to: kept)) != nil else {
            return nil
        }

        guard sha256(of: kept) == release.sha256 else {
            try? FileManager.default.removeItem(at: kept)
            return nil
        }
        return kept
    }

    private func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Streamed: these are tens of megabytes, and reading one whole into
        // memory to hash it is avoidable.
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Installing

    private enum InstallError: Error {
        case unpackFailed
        case untrustedSignature
    }

    private func install(
        _ payload: URL,
        of component: Component,
        verifying release: ComponentRelease
    ) throws {
        try FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true
        )

        let staged: URL
        if release.isZipped {
            staged = try unzipExecutable(payload, named: component.executableName)
        } else {
            staged = payload
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: staged.path
        )

        // Downloaded code is quarantined, and a quarantined binary can't be
        // exec'd by a process that isn't a document-opening app.
        _ = staged.withUnsafeFileSystemRepresentation { path in
            path.map { removexattr($0, "com.apple.quarantine", 0) }
        }

        // The hash proves the file is what the site advertised. For ffmpeg the
        // signature proves the site was advertising the publisher's own build —
        // a second, independent root, since a compromised site could restate a
        // hash but not forge a Developer ID.
        if component == .ffmpeg,
           !hasValidSignature(staged, teamID: FFmpegRelease.signingTeamID) {
            try? FileManager.default.removeItem(at: staged)
            throw InstallError.untrustedSignature
        }

        // Swapped in by rename, so a crash mid-update can't leave a half-written
        // binary where a working one used to be.
        let destination = Self.directory.appendingPathComponent(component.executableName)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            // replaceItemAt requires something to replace, so the very first
            // install — every install of ffmpeg, which isn't bundled — has to
            // take the other branch.
            try FileManager.default.moveItem(at: staged, to: destination)
        }

        if release.isZipped {
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        }
    }

    private func unzipExecutable(_ archive: URL, named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("surf-unzip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // ditto rather than unzip: it's what Archive Utility uses, and it keeps
        // the extended attributes a signed binary needs intact.
        unzip.arguments = ["-x", "-k", archive.path, directory.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()

        try? FileManager.default.removeItem(at: archive)
        guard unzip.terminationStatus == 0 else { throw InstallError.unpackFailed }

        let unpacked = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: unpacked.path) else {
            throw InstallError.unpackFailed
        }
        return unpacked
    }

    /// Checks the binary is signed by the expected team.
    private func hasValidSignature(_ url: URL, teamID: String) -> Bool {
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = [
            "--verify", "--strict",
            // Pins the publisher, not merely "signed by someone".
            "-R=anchor apple generic and certificate leaf[subject.OU] = \(teamID)",
            url.path,
        ]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice

        guard (try? codesign.run()) != nil else { return false }
        codesign.waitUntilExit()
        return codesign.terminationStatus == 0
    }
}
