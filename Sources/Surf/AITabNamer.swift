import Foundation
import SurfCore

/// Runs one CLI call per page to get a better tab name.
///
/// The impure half of `AITabNaming`. Everything about *whether* and *what* to
/// ask is decided at the moment of use — provider, model, and the feature
/// toggle are read per request, so flipping the setting takes effect on the
/// very next page with nothing to restart.
///
/// Frugal by construction: one name per (URL, title) pair is ever requested,
/// remembered for the session, so reopening the same page or two tabs on the
/// same article costs one model call, not N. Failures are never retried — a
/// tab that keeps its real title is never wrong, only worse.
@MainActor
final class AITabNamer {
    static let shared = AITabNamer()

    private init() {}

    /// Names already fetched this session, including failures (nil), which are
    /// cached too — a page whose title the model refuses once will refuse it
    /// again, and each retry costs the user's quota.
    private var cache: [String: String?] = [:]

    /// In-flight requests, so two tabs on the same page share one call.
    private var inFlight: [String: Task<String?, Never>] = [:]

    /// A better name for this page, or nil to keep the real title.
    ///
    /// Checks the feature toggle and CLI state itself; callers just ask.
    func name(forURL url: String, pageTitle: String) async -> String? {
        guard AITabNaming.isNameable(url: url) else { return nil }
        // Detection may never have run — Settings is the only other trigger.
        await AICLIDetector.shared.ensureScanned()
        guard let (provider, model) = AIPreferences.resolved(.tabRenaming) else { return nil }
        guard let executable = AICLIDetector.shared.status(provider).executableURL ?? nil else {
            return nil
        }

        // Keyed by everything that shapes the answer: same page through a
        // different provider or model is a different question.
        let key = [provider.rawValue, model.id, url, pageTitle].joined(separator: "\u{1}")
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return await running.value }

        let task = Task<String?, Never> {
            let raw = await AIOneShot.ask(
                executable: executable,
                provider: provider,
                model: model.id,
                prompt: AITabNaming.prompt(pageTitle: pageTitle, url: url)
            )
            return raw.flatMap(AITabNaming.sanitizedName(from:))
        }
        inFlight[key] = task
        let name = await task.value
        inFlight[key] = nil
        cache[key] = .some(name)
        return name
    }

}

/// One question to a CLI's model, one plain-text answer.
///
/// Shared by every AI feature: builds the scratch environment, runs the CLI,
/// and hands back the raw reply for the feature's own sanitizer to judge.
enum AIOneShot {

    static func ask(
        executable: URL, provider: AICLIProvider, model: String, prompt: String
    ) async -> String? {
        // A scratch directory as cwd: both CLIs read project context from
        // wherever they run (CLAUDE.md, AGENTS.md), and a one-shot question
        // should see none of it — less to leak, less to bill, less to go weird.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("surf-ai-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let lastMessage = scratch.appendingPathComponent("answer.txt")
        let arguments = AICLIInvocation.arguments(
            provider: provider, model: model, prompt: prompt,
            lastMessageFile: lastMessage.path
        )

        guard let result = await CLIProcess.run(
            executable, arguments: arguments, currentDirectory: scratch, timeout: 60
        ), result.exitCode == 0 else { return nil }

        // Codex writes the clean answer to the file; Claude's print mode is
        // already clean on stdout.
        switch provider {
        case .claude:
            return result.stdout
        case .codex:
            return try? String(contentsOf: lastMessage, encoding: .utf8)
        }
    }
}
