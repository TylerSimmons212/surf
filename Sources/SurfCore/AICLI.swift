import Foundation

/// The pure half of the AI CLI integration: which CLIs Surf knows about, how to
/// read their on-disk auth state, and which models each can be asked to run.
///
/// Everything here is data-in / data-out so it can be tested without touching
/// the filesystem. `AICLIDetector` in the app target owns the file reads and
/// process spawns.
///
/// Login detection reads *state*, never secrets. Claude Code's tokens live in
/// the macOS Keychain and are never requested; its `~/.claude.json` config
/// carries a plain `oauthAccount` block naming the account. Codex's
/// `~/.codex/auth.json` does contain tokens, but only the identity claims of
/// the (already locally readable) ID token are decoded — nothing is sent
/// anywhere, and no token value ever leaves this parse.
public enum AICLIProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    public var vendor: String {
        switch self {
        case .claude: "Anthropic"
        case .codex: "OpenAI"
        }
    }

    public var executableName: String { rawValue }

    /// Where the CLI records who is signed in, relative to the home directory.
    public var authStatePath: String {
        switch self {
        case .claude: ".claude.json"
        case .codex: ".codex/auth.json"
        }
    }
}

/// Who a CLI is signed in as. Only what's worth showing in Settings.
public struct AIAccount: Equatable, Sendable {
    public var email: String?
    /// The organisation or plan the account is on — "Acme Inc" for a Claude
    /// team account, "plus"/"pro" for a ChatGPT plan. Display colour, not data.
    public var detail: String?

    public init(email: String? = nil, detail: String? = nil) {
        self.email = email
        self.detail = detail
    }
}

/// Three states, not two: a config file that's missing or in a shape we don't
/// recognise is *unknown*, and must not be reported as "not signed in" — both
/// CLIs are free to change their formats, and a wrong "logged out" would send
/// the user off to re-authenticate something that's working.
public enum AILoginState: Equatable, Sendable {
    case loggedIn(AIAccount)
    /// The config names an account but the CLI's own probe says the session
    /// is dead — an expired OAuth token the CLI couldn't refresh. Distinct
    /// from `loggedOut` because the fix reads differently: sign in *again*.
    case expired(AIAccount)
    case loggedOut
    case unknown
}

public enum AICLIAuth {

    // MARK: - Claude Code

    /// Reads login state out of `~/.claude.json`.
    ///
    /// A logged-in Claude Code writes an `oauthAccount` object there —
    /// email, organisation, tiers. Logging out removes it. The file itself
    /// exists from first launch, so "file present, no account block" is a real
    /// logged-out signal, not an unknown.
    ///
    /// API-key auth is the other door in: no OAuth session exists, but the
    /// config records each key the user has approved for use. An approved key
    /// means the CLI works, so it must not be reported as logged out.
    public static func claudeLogin(fromConfigJSON data: Data) -> AILoginState {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unknown
        }
        if let account = root["oauthAccount"] as? [String: Any] {
            return .loggedIn(AIAccount(
                email: account["emailAddress"] as? String,
                detail: account["organizationName"] as? String
            ))
        }
        if let keys = root["customApiKeyResponses"] as? [String: Any],
           let approved = keys["approved"] as? [Any], !approved.isEmpty {
            return .loggedIn(AIAccount(detail: "API key"))
        }
        return .loggedOut
    }

    // MARK: - Codex

    /// Reads login state out of `~/.codex/auth.json`.
    ///
    /// Two ways to be signed in: a ChatGPT login (a `tokens` object holding an
    /// ID token whose claims name the account) or a bare API key. The key's
    /// *presence* is the signal; its value is never surfaced.
    public static func codexLogin(fromAuthJSON data: Data) -> AILoginState {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unknown
        }

        if let tokens = root["tokens"] as? [String: Any] {
            var account = AIAccount()
            if let idToken = tokens["id_token"] as? String,
               let claims = jwtClaims(idToken) {
                // Top-level in current tokens; older ones tuck it inside a
                // namespaced profile claim. Take either.
                account.email = claims["email"] as? String
                    ?? (claims["https://api.openai.com/profile"] as? [String: Any])?["email"]
                        as? String
                // Plan type hides inside OpenAI's namespaced auth claim.
                if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
                   let plan = auth["chatgpt_plan_type"] as? String {
                    account.detail = planLabel(plan)
                }
            }
            return .loggedIn(account)
        }

        if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty {
            return .loggedIn(AIAccount(detail: "API key"))
        }

        // The file only exists after `codex login` has run at least once, so a
        // recognisable shape with no credentials in it means logged out.
        return .loggedOut
    }

    // MARK: - Probes

    /// Reads `claude auth status --json`: `{"loggedIn": true, ...}`. Nil for
    /// anything unparseable — older CLIs without the subcommand print usage
    /// text, and a probe that can't answer must not overrule the config file.
    public static func claudeProbeLoggedIn(fromAuthStatusJSON data: Data) -> Bool? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let loggedIn = root["loggedIn"] as? Bool else {
            return nil
        }
        return loggedIn
    }

    /// Reconciles what the config file says with what the CLI's own probe
    /// says. The file knows *who*; the probe knows *whether*. A probe that
    /// contradicts a logged-in file is how an expired session — the file's
    /// blind spot — gets caught.
    public static func mergedLogin(file: AILoginState, probeLoggedIn: Bool?) -> AILoginState {
        switch probeLoggedIn {
        case nil:
            return file
        case true?:
            if case .loggedIn = file { return file }
            // The probe is authoritative that a session exists, even when the
            // file couldn't name the account.
            return .loggedIn(AIAccount())
        case false?:
            if case .loggedIn(let account) = file { return .expired(account) }
            return .loggedOut
        }
    }

    /// "plus" → "ChatGPT Plus". Unknown plans pass through capitalised rather
    /// than vanish — a new tier shouldn't render as no information.
    static func planLabel(_ plan: String) -> String {
        let trimmed = plan.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "ChatGPT" }
        return "ChatGPT " + trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    // MARK: - JWT

    /// Decodes the claims segment of a JWT. Local decode only — no verification
    /// and no network, because the question is "who does this file say you
    /// are", not "is this token valid".
    public static func jwtClaims(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return nil }
        guard let data = base64URLDecode(String(segments[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// JWTs use base64url without padding; `Data(base64Encoded:)` wants the
    /// classic alphabet with it.
    static func base64URLDecode(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}

// MARK: - Models

/// One model a CLI can be told to use.
public struct AIModelOption: Equatable, Sendable, Identifiable {
    /// What gets passed on the command line (`--model` / `-m`). Empty means
    /// "pass nothing" — the CLI's own default, whatever it currently is.
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

extension AICLIProvider {

    /// The models known to exist when nothing better is available. Codex
    /// publishes what the account can actually use (`CodexModelsCache`), and a
    /// live list always replaces this one; Claude Code has no such file, so
    /// its aliases — which the CLI resolves to the newest model of each tier,
    /// exactly as `/model` would — are the accurate list, not a fallback.
    public var curatedModels: [AIModelOption] {
        switch self {
        case .claude:
            [
                AIModelOption(id: "opus", label: "Opus"),
                AIModelOption(id: "sonnet", label: "Sonnet"),
                AIModelOption(id: "haiku", label: "Haiku"),
            ]
        case .codex:
            [
                AIModelOption(id: "gpt-5.6-sol", label: "GPT-5.6-Sol"),
                AIModelOption(id: "gpt-5.6-terra", label: "GPT-5.6-Terra"),
                AIModelOption(id: "gpt-5.6-luna", label: "GPT-5.6-Luna"),
            ]
        }
    }

    /// Resolves a stored preference against the current menu. Empty means
    /// "Fast" — Surf's recommended default — and a pinned model that has since
    /// left the menu degrades to Fast too, rather than sending the CLI an
    /// identifier it may refuse.
    public func validatedModel(
        _ stored: String?, options: [AIModelOption], descriptions: [String: String] = [:]
    ) -> AIModelOption? {
        if let stored, !stored.isEmpty,
           let match = options.first(where: { $0.id == stored && !$0.id.isEmpty }) {
            return match
        }
        return fastModel(from: options, descriptions: descriptions)
    }
}

// MARK: - Asking a model one thing

/// Builds the command line for a single non-interactive question.
///
/// Both CLIs are agents, and both are held to a plain answer here: Claude's
/// print mode does that by design; Codex is pinned to its read-only sandbox
/// and told to write the final message to a file, which arrives clean of the
/// session log it prints around it. `--skip-git-repo-check` because the
/// working directory is a scratch folder, not a repo — Codex refuses to run
/// outside one otherwise.
public enum AICLIInvocation {

    /// - Parameters:
    ///   - model: the model id, or empty to let the CLI choose.
    ///   - lastMessageFile: where Codex should write the answer. Unused by Claude.
    public static func arguments(
        provider: AICLIProvider, model: String, prompt: String, lastMessageFile: String
    ) -> [String] {
        switch provider {
        case .claude:
            var args = ["-p"]
            if !model.isEmpty { args += ["--model", model] }
            args.append(prompt)
            return args
        case .codex:
            var args = ["exec", "--skip-git-repo-check", "-s", "read-only"]
            if !model.isEmpty { args += ["-m", model] }
            args += ["-o", lastMessageFile, prompt]
            return args
        }
    }

    /// The command a Terminal window should run to sign this CLI in. Login is
    /// deliberately *not* something Surf drives itself: both flows can turn
    /// interactive (SSO, paste-a-code), and credentials should only ever pass
    /// through the vendor's own tool in the user's own terminal.
    public static func loginArguments(provider: AICLIProvider) -> [String] {
        switch provider {
        case .claude: ["auth", "login"]
        case .codex: ["login"]
        }
    }
}

// MARK: - Locating the binary

public enum AICLIInstall {

    /// Directories worth checking for a CLI binary, in preference order.
    ///
    /// A GUI app inherits launchd's PATH, not the user's shell PATH, so the
    /// usual homes have to be named outright — same constraint, and same list
    /// shape, as `MediaExtractor`. `nodeBinDirectories` is passed in because
    /// enumerating version managers' install trees is filesystem work that
    /// belongs to the caller; here it's just ordered.
    ///
    /// - Parameters:
    ///   - home: the user's home directory path, no trailing slash.
    ///   - nodeBinDirectories: bin directories from node version managers
    ///     (nvm/fnm/volta), newest version first.
    public static func candidateDirectories(
        home: String, nodeBinDirectories: [String] = []
    ) -> [String] {
        // The native installers first: that's where `claude install` and the
        // codex standalone land, and where the freshest copy usually is.
        var dirs = [home + "/.local/bin"]
        dirs += nodeBinDirectories
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return dirs
    }

    /// Extracts a bare version from CLI `--version` output.
    ///
    /// Both CLIs decorate: "1.0.24 (Claude Code)", "codex-cli 0.21.0". The
    /// number is the part worth keeping; a format we don't recognise yields
    /// nil rather than a mangled string.
    public static func version(fromVersionOutput output: String) -> String? {
        let pattern = /(\d+\.\d+(?:\.\d+)?)/
        guard let match = output.firstMatch(of: pattern) else { return nil }
        return String(match.1)
    }
}

// MARK: - Which CLI runs the features

extension AICLIProvider {
    /// The provider Surf uses when the user hasn't picked one, or their pick
    /// has vanished from the machine: the first that's ready, in declaration
    /// order. No "automatic" mode to explain — an unset choice and a stale
    /// one both land here.
    public static func defaultProvider(usable: [AICLIProvider]) -> AICLIProvider? {
        usable.first
    }
}

// MARK: - Features

/// The things Surf actually uses a model for. Each is its own toggle and its
/// own model choice: renaming a tab and renaming a download are both two-word
/// asks, but nothing says they must always be — a feature added later can
/// default to a stronger tier without dragging the others with it.
public enum AIFeature: String, CaseIterable, Sendable, Identifiable {
    /// Retitle tabs with names better than the page's own `<title>`.
    case tabRenaming
    /// Rename finished downloads to something worth keeping.
    case downloadRenaming

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .tabRenaming: "Better tab names"
        case .downloadRenaming: "Better download names"
        }
    }

    /// Defaults keys, derived so a new feature can't forget to invent them.
    /// The model key is per provider: a pinned Claude model must not be
    /// replayed onto Codex when the provider changes.
    public var enabledKey: String { "aiFeature.\(rawValue).enabled" }
    public func modelKey(for provider: AICLIProvider) -> String {
        "aiFeature.\(rawValue).model.\(provider.rawValue)"
    }
}

// MARK: - Live model lists

/// Codex writes the models the signed-in account can actually use to
/// `~/.codex/models_cache.json` — slugs, display names, and a visibility flag
/// for the ones its own picker shows. Reading it is how Surf's menu stays
/// accurate without inventing a model list of its own.
public enum CodexModelsCache {

    /// The models the cache says are offered, in Codex's own priority order.
    /// Nil when the file can't be read as expected — the caller falls back to
    /// the curated list rather than showing an empty menu.
    public static func models(fromCacheJSON data: Data) -> [AIModelOption]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["models"] as? [[String: Any]] else {
            return nil
        }

        let listed = entries.compactMap { entry -> (option: AIModelOption, priority: Int)? in
            guard let slug = entry["slug"] as? String, !slug.isEmpty else { return nil }
            // "hide" marks internal models (auto-review helpers and the like)
            // that accept no user work.
            guard (entry["visibility"] as? String) == "list" else { return nil }
            let label = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return (
                AIModelOption(id: slug, label: label ?? slug),
                entry["priority"] as? Int ?? .max
            )
        }
        guard !listed.isEmpty else { return nil }
        return listed.sorted { $0.priority < $1.priority }.map(\.option)
    }

    /// Descriptions from the cache, keyed by slug — "Fast and affordable…" is
    /// the signal `fastModel` falls back on when slugs have all changed.
    public static func descriptions(fromCacheJSON data: Data) -> [String: String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["models"] as? [[String: Any]] else {
            return [:]
        }
        var out: [String: String] = [:]
        for entry in entries {
            if let slug = entry["slug"] as? String,
               let description = entry["description"] as? String {
                out[slug] = description
            }
        }
        return out
    }
}

extension AICLIProvider {

    /// Model ids known to be the small-and-quick tier, best first. Used to
    /// resolve what "Fast" means against whatever list is current.
    var preferredFastIDs: [String] {
        switch self {
        case .claude: ["haiku"]
        case .codex: ["gpt-5.6-luna", "gpt-5.4-mini"]
        }
    }

    /// The model Surf's own features default to.
    ///
    /// Deliberately *not* the CLI's default: the CLIs default to their
    /// strongest coding models, sized for hour-long agent sessions. Surf asks
    /// for two-word answers — a tab name, a filename — where the latency gap
    /// between tiers is the entire user experience and the quality gap is
    /// invisible. Fast is the right default; strength is the opt-in.
    ///
    /// - Parameters:
    ///   - options: the current menu (live list when detection has one).
    ///   - descriptions: model descriptions keyed by id, for the fallback.
    public func fastModel(
        from options: [AIModelOption], descriptions: [String: String] = [:]
    ) -> AIModelOption? {
        let real = options.filter { !$0.id.isEmpty }
        for id in preferredFastIDs {
            if let match = real.first(where: { $0.id == id }) { return match }
        }
        // Names churn; vendors keep describing the quick tier as fast.
        if let described = real.first(where: {
            descriptions[$0.id]?.localizedCaseInsensitiveContains("fast") == true
        }) {
            return described
        }
        return real.last
    }
}

// MARK: - Updates

/// Where a CLI came from decides how it updates. Derived from the executable's
/// path — nothing else about an install is inspectable without running it.
public enum AICLIInstallKind: Equatable, Sendable {
    /// The vendor's own installer (`~/.local/bin`), which self-updates.
    case native
    /// A Node package manager's bin directory; updates via that npm.
    case npm(binDirectory: String)
    /// A Homebrew prefix; updates via brew.
    case homebrew(brewPath: String)
    /// Somewhere we don't recognise — offer no button rather than guess.
    case unknown
}

extension AICLIInstall {

    public static func installKind(ofPath path: String, home: String) -> AICLIInstallKind {
        let directory = (path as NSString).deletingLastPathComponent

        if directory == home + "/.local/bin" { return .native }
        if directory.hasPrefix("/opt/homebrew/") { return .homebrew(brewPath: "/opt/homebrew/bin/brew") }
        // Node version managers and volta all keep an npm beside the CLI;
        // that npm is the one that installed it, so it's the one that updates it.
        let nodeManagers = ["/.nvm/", "/.volta/", "/.fnm/"]
        if nodeManagers.contains(where: { directory.contains($0) }) {
            return .npm(binDirectory: directory)
        }
        // /usr/local is ambiguous — Intel Homebrew and npm's default prefix
        // both live there. An npm binary sitting beside the CLI settles it.
        if directory == "/usr/local/bin" {
            return .homebrew(brewPath: "/usr/local/bin/brew")
        }
        return .unknown
    }

    /// The npm package each CLI is published as — also the authority on what
    /// the latest version is, whichever way the CLI was installed.
    public static func npmPackage(for provider: AICLIProvider) -> String {
        switch provider {
        case .claude: "@anthropic-ai/claude-code"
        case .codex: "@openai/codex"
        }
    }

    /// The npm registry's "latest" document for a package.
    public static func npmLatestURL(for provider: AICLIProvider) -> URL {
        // Scoped names keep their slash un-encoded in the registry's URL scheme.
        URL(string: "https://registry.npmjs.org/\(npmPackage(for: provider))/latest")!
    }

    /// Reads the version out of that document.
    public static func version(fromNPMLatestJSON data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = root["version"] as? String, !version.isEmpty else {
            return nil
        }
        return version
    }
}
