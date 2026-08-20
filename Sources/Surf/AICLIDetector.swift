import AppKit
import Foundation
import SurfCore

/// Finds the AI CLIs on this Mac and reads whether they're signed in.
///
/// The impure half of `AICLI`: filesystem globs, config file reads, and one
/// `--version` spawn per CLI. Everything interpretable is interpreted in
/// `SurfCore` where it's tested; this file only fetches.
///
/// Detection is read-only and local. No CLI is ever run in a way that could
/// prompt, authenticate, or bill — `--version` is the only thing spawned. The
/// Keychain (where Claude Code keeps its tokens) is never touched, so checking
/// status can't trigger a Keychain permission dialog.
@MainActor
@Observable
final class AICLIDetector {
    static let shared = AICLIDetector()

    /// Everything Settings shows about one CLI.
    struct Status: Equatable {
        var provider: AICLIProvider
        /// nil until the first scan finishes, so the UI can tell "not found"
        /// from "not looked yet".
        var executableURL: URL??
        var version: String?
        var login: AILoginState = .unknown
        /// The models this account can use, straight from the CLI's own cache.
        /// Nil when the CLI keeps no such cache (Claude Code) or it couldn't
        /// be read — the curated list stands in.
        var liveModels: [AIModelOption]?
        var modelDescriptions: [String: String] = [:]
        /// The newest published version, from the npm registry. Nil until the
        /// check has run or when it failed; absence never blocks anything.
        var latestVersion: String?

        var isInstalled: Bool { (executableURL ?? nil) != nil }
        var isUsable: Bool {
            guard isInstalled, case .loggedIn = login else { return false }
            return true
        }

        /// The menu Settings shows and features pick from: live when the CLI
        /// publishes one, curated when it doesn't.
        var modelOptions: [AIModelOption] { liveModels ?? provider.curatedModels }

        var updateAvailable: Bool {
            guard let latestVersion, let version else { return false }
            return ComponentVersion.isNewer(latestVersion, than: version)
        }

        var installKind: AICLIInstallKind {
            guard let url = executableURL ?? nil else { return .unknown }
            return AICLIInstall.installKind(ofPath: url.path, home: NSHomeDirectory())
        }
    }

    private(set) var statuses: [AICLIProvider: Status]
    private(set) var isScanning = false
    /// Whether install/login state has been read at least once this launch.
    /// Features await this rather than trusting the zero state — Settings may
    /// never have been opened.
    private var hasScanned = false
    private var scanWaiters: [CheckedContinuation<Void, Never>] = []
    /// Providers with an update currently running, and the outcome of the last
    /// one that finished — Settings shows both.
    private(set) var updating: Set<AICLIProvider> = []
    private(set) var updateOutcomes: [AICLIProvider: UpdateOutcome] = [:]

    enum UpdateOutcome: Equatable {
        case updated
        case failed(String)
    }

    private init() {
        statuses = Dictionary(uniqueKeysWithValues: AICLIProvider.allCases.map {
            ($0, Status(provider: $0))
        })
    }

    func status(_ provider: AICLIProvider) -> Status {
        statuses[provider] ?? Status(provider: provider)
    }

    /// Providers that are installed and signed in, in declaration order —
    /// which makes `allCases` order the tiebreak "Automatic" uses.
    var usableProviders: [AICLIProvider] {
        AICLIProvider.allCases.filter { status($0).isUsable }
    }

    // MARK: - Scanning

    /// Re-reads everything. Cheap enough to run every time the AI tab appears:
    /// two file stats per candidate directory, two small JSON reads, and two
    /// `--version` spawns that only re-run when the binary path changed.
    func refresh() {
        guard !isScanning else { return }
        isScanning = true

        Task {
            var found: [AICLIProvider: Status] = [:]
            let previous = statuses

            for provider in AICLIProvider.allCases {
                var status = Status(provider: provider)
                let url = Self.locate(provider)
                status.executableURL = .some(url)
                status.login = Self.readLogin(provider)

                // The config file knows *who*; only the CLI itself knows
                // *whether* — a config that says "signed in" can be sitting on
                // an expired token the CLI failed to refresh. So every scan
                // asks the CLI too (`claude auth status`, `codex login
                // status` — both non-interactive, neither costs quota) and
                // reconciles: file + dead probe is `.expired`, which reads
                // differently in Settings than never having signed in. The
                // probe also covers auth the file can't see, like Codex's
                // Keychain storage mode.
                if let url {
                    status.login = AICLIAuth.mergedLogin(
                        file: status.login,
                        probeLoggedIn: await Self.probeLogin(provider, executable: url)
                    )
                }

                if let url {
                    // Version only changes when the binary does; asking a CLI
                    // for its version costs a process launch, so don't repeat
                    // it for the same file.
                    if let prior = previous[provider], (prior.executableURL ?? nil) == url,
                       let version = prior.version {
                        status.version = version
                    } else {
                        status.version = await Self.askVersion(of: url)
                    }
                }

                // Codex publishes the models this account can actually use;
                // the menu should show that list, not our guess at it.
                if provider == .codex {
                    let cache = URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent(".codex/models_cache.json")
                    if let data = try? Data(contentsOf: cache) {
                        status.liveModels = CodexModelsCache.models(fromCacheJSON: data)
                        status.modelDescriptions =
                            CodexModelsCache.descriptions(fromCacheJSON: data)
                    }
                }

                // Carry the last known answer while this scan's check runs (or
                // fails offline) — "no news" shouldn't erase news.
                status.latestVersion = previous[provider]?.latestVersion
                found[provider] = status
            }

            statuses = found

            // Install and login state is now real; anyone waiting on it can
            // go. The network check below is Settings decoration and mustn't
            // hold up a feature.
            hasScanned = true
            scanWaiters.forEach { $0.resume() }
            scanWaiters.removeAll()

            // Latest versions arrive separately: they need the network, and
            // installed-state shouldn't wait on it.
            for provider in AICLIProvider.allCases where found[provider]?.isInstalled == true {
                if let latest = await Self.fetchLatestVersion(for: provider) {
                    statuses[provider]?.latestVersion = latest
                }
            }

            isScanning = false
        }
    }

    /// Returns once at least one scan has completed this launch, starting one
    /// if needed. Instant after the first.
    func ensureScanned() async {
        if hasScanned { return }
        refresh()
        await withCheckedContinuation { scanWaiters.append($0) }
    }

    // MARK: - Updating

    /// Updates one CLI, preferring its own updater.
    ///
    /// `claude update` and `codex update` both exist, are non-interactive, and
    /// know their own install better than we do — Codex's even detects whether
    /// it came from npm or Homebrew. The exceptions we route around: Homebrew
    /// casks of Claude Code answer "up to date" without updating (only brew
    /// can move them), and older Codex builds predate the subcommand — for
    /// those the package manager that installed it is the fallback.
    func update(_ provider: AICLIProvider) {
        guard !updating.contains(provider) else { return }
        let status = status(provider)
        guard let executable = status.executableURL ?? nil else { return }
        let kind = status.installKind

        updating.insert(provider)
        updateOutcomes[provider] = nil

        Task {
            defer { updating.remove(provider) }

            var attempts: [(URL, [String])] = []
            switch (provider, kind) {
            case (.claude, .homebrew(let brew)):
                attempts.append((URL(fileURLWithPath: brew), ["upgrade", "claude-code"]))
            case (.codex, .homebrew(let brew)):
                attempts.append((executable, ["update"]))
                attempts.append((URL(fileURLWithPath: brew), ["upgrade", "codex"]))
            case (_, .npm(let binDir)):
                attempts.append((executable, ["update"]))
                // `install @latest`, not `npm update` — the docs' own advice,
                // since update respects whatever semver range installed it.
                attempts.append((
                    URL(fileURLWithPath: binDir + "/npm"),
                    ["install", "-g", AICLIInstall.npmPackage(for: provider) + "@latest"]
                ))
            default:
                attempts.append((executable, ["update"]))
            }

            var succeeded = false
            for (tool, arguments) in attempts {
                guard FileManager.default.isExecutableFile(atPath: tool.path) else { continue }
                // Installers download; give them minutes, not seconds.
                if let result = await Self.run(tool, arguments: arguments, timeout: 300),
                   result.exitCode == 0 {
                    succeeded = true
                    break
                }
            }

            updateOutcomes[provider] = succeeded
                ? .updated
                : .failed("The update didn't finish — try \(manualUpdateHint(provider, kind)).")

            // Whatever happened, re-read reality: drop the cached version so
            // the rescan asks the binary again.
            statuses[provider]?.version = nil
            refresh()
        }
    }

    private func manualUpdateHint(_ provider: AICLIProvider, _ kind: AICLIInstallKind) -> String {
        switch kind {
        case .homebrew:
            "brew upgrade \(provider == .claude ? "claude-code" : "codex") in a terminal"
        case .npm:
            "npm install -g \(AICLIInstall.npmPackage(for: provider))@latest in a terminal"
        case .native, .unknown:
            "\(provider.executableName) update in a terminal"
        }
    }

    // MARK: - Locating

    private nonisolated static func locate(_ provider: AICLIProvider) -> URL? {
        let name = provider.executableName
        let home = NSHomeDirectory()
        let dirs = AICLIInstall.candidateDirectories(
            home: home,
            nodeBinDirectories: nodeManagerBinDirectories(home: home)
        )
        for dir in dirs {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Node version managers bury global binaries per Node version:
    /// `~/.nvm/versions/node/v20.19.4/bin/claude`. The newest Node's bin is
    /// checked first — that's the one an `nvm use` shell would resolve.
    private nonisolated static func nodeManagerBinDirectories(home: String) -> [String] {
        let fm = FileManager.default
        var dirs: [String] = []

        let nvmVersions = home + "/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmVersions) {
            dirs += versions
                .filter { $0.hasPrefix("v") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { nvmVersions + "/" + $0 + "/bin" }
        }

        // Volta and fnm keep a single stable shim directory.
        dirs.append(home + "/.volta/bin")
        dirs.append(home + "/.fnm/aliases/default/bin")
        return dirs
    }

    // MARK: - Login state

    private nonisolated static func readLogin(_ provider: AICLIProvider) -> AILoginState {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(provider.authStatePath)
        // Missing file: for Claude that means the CLI has never run; for Codex
        // that `codex login` never has. Either way there's no session.
        guard let data = try? Data(contentsOf: url) else { return .loggedOut }
        switch provider {
        case .claude: return AICLIAuth.claudeLogin(fromConfigJSON: data)
        case .codex: return AICLIAuth.codexLogin(fromAuthJSON: data)
        }
    }

    // MARK: - Version

    /// Runs `<cli> --version` and reads the number out of whatever it prints.
    /// Nil on any failure — the version line is decoration, not a gate.
    private nonisolated static func askVersion(of executable: URL) async -> String? {
        guard let result = await run(executable, arguments: ["--version"]) else { return nil }
        return AICLIInstall.version(fromVersionOutput: result.stdout)
    }

    /// Asks the CLI itself whether a live session exists. Nil when the answer
    /// couldn't be had — spawn failure, or a build old enough not to know the
    /// subcommand — in which case the config file's word stands alone.
    ///
    /// - `claude auth status` exits 0 either way and answers in JSON.
    /// - `codex login status` answers with its exit code: 0 in, 1 out.
    private nonisolated static func probeLogin(
        _ provider: AICLIProvider, executable: URL
    ) async -> Bool? {
        switch provider {
        case .claude:
            // Exit code mirrors the answer (0 in, 1 out), so it can't be the
            // validity gate — the JSON parse is: an old CLI without the
            // subcommand prints usage text, which parses to nil and leaves
            // the config file's word standing.
            guard let result = await run(executable, arguments: ["auth", "status", "--json"])
            else { return nil }
            return AICLIAuth.claudeProbeLoggedIn(fromAuthStatusJSON: Data(result.stdout.utf8))
        case .codex:
            guard let result = await run(executable, arguments: ["login", "status"]) else {
                return nil
            }
            return result.exitCode == 0
        }
    }

    // MARK: - Signing in

    /// Opens a Terminal window running the CLI's own sign-in.
    ///
    /// Deliberately not driven by Surf: both flows can turn interactive (SSO,
    /// choose-an-account, paste-a-code), and credentials should only ever
    /// pass through the vendor's own tool where the user can see it. A
    /// `.command` file through `NSWorkspace` needs no automation permission,
    /// unlike scripting Terminal directly.
    func signIn(_ provider: AICLIProvider) {
        guard let executable = status(provider).executableURL ?? nil else { return }
        let script = """
        #!/bin/zsh
        clear
        echo "Signing in to \(provider.displayName) for Surf."
        echo "When you're done, close this window and Surf will pick it up."
        echo
        exec \(shellQuoted(executable.path)) \
            \(AICLIInvocation.loginArguments(provider: provider)
                .map(shellQuoted).joined(separator: " "))
        """
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("surf-signin-\(provider.rawValue).command")
        guard let data = script.data(using: .utf8),
              FileManager.default.createFile(
                atPath: file.path, contents: data,
                attributes: [.posixPermissions: 0o755]
              ) else { return }
        NSWorkspace.shared.open(file)
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Latest version

    /// Asks the npm registry what the newest published version is. Both CLIs
    /// are published there in lockstep with their other channels, so one
    /// endpoint answers for every install kind. A tiny anonymous GET, made
    /// only while the AI settings tab is open — never in the background.
    private nonisolated static func fetchLatestVersion(
        for provider: AICLIProvider
    ) async -> String? {
        var request = URLRequest(url: AICLIInstall.npmLatestURL(for: provider))
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return AICLIInstall.version(fromNPMLatestJSON: data)
    }

    // MARK: - Spawning

    private nonisolated static func run(
        _ executable: URL, arguments: [String], timeout: TimeInterval = 10
    ) async -> (exitCode: Int32, stdout: String)? {
        await CLIProcess.run(executable, arguments: arguments, timeout: timeout)
    }
}

/// One short-lived, non-interactive CLI process, with a watchdog so a CLI
/// that hangs can't hang its caller. Shared between detection (`--version`,
/// `login status`), updates, and the features that actually ask a model
/// something.
enum CLIProcess {

    static func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 10
    ) async -> (exitCode: Int32, stdout: String)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let currentDirectory {
                    process.currentDirectoryURL = currentDirectory
                }
                // Node-installed CLIs need their interpreter's bin on PATH.
                var environment = ProcessInfo.processInfo.environment
                let binDir = executable.deletingLastPathComponent().path
                environment["PATH"] = binDir + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
                process.environment = environment

                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                // No terminal and no stdin: anything that would prompt gets
                // EOF and exits instead.
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let watchdog = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Reading concurrently with the run, not after: a chatty CLI
                // (Codex logs its whole session to stdout) can fill the pipe's
                // buffer, and a full pipe deadlocks a process nobody is reading.
                var data = Data()
                let reader = out.fileHandleForReading
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }

                process.waitUntilExit()
                watchdog.cancel()

                continuation.resume(returning: (
                    process.terminationStatus,
                    String(data: data, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
