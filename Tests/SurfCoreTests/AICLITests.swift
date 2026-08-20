import Foundation
import Testing
@testable import SurfCore

// MARK: - Helpers

/// A structurally valid JWT with the given claims. Signature is junk — decode
/// never verifies, and the tests shouldn't imply it does.
private func jwt(claims: [String: Any]) -> String {
    func segment(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return segment(["alg": "RS256"]) + "." + segment(claims) + ".sig"
}

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

// MARK: - Claude login

@Suite("Claude Code login state")
struct ClaudeLoginTests {

    @Test("An oauthAccount block means logged in, with email and organisation")
    func oauthAccount() {
        let state = AICLIAuth.claudeLogin(fromConfigJSON: json([
            "oauthAccount": [
                "emailAddress": "surf@example.com",
                "organizationName": "Example Org",
            ],
            "other": "noise",
        ]))
        #expect(state == .loggedIn(AIAccount(email: "surf@example.com", detail: "Example Org")))
    }

    @Test("Approved API keys count as signed in — the CLI works without OAuth")
    func apiKeyApproved() {
        let state = AICLIAuth.claudeLogin(fromConfigJSON: json([
            "customApiKeyResponses": ["approved": ["sk-tail"], "rejected": []]
        ]))
        #expect(state == .loggedIn(AIAccount(detail: "API key")))
    }

    @Test("No account and no approved keys is logged out")
    func loggedOut() {
        let empty = AICLIAuth.claudeLogin(fromConfigJSON: json(["numStartups": 4]))
        #expect(empty == .loggedOut)
        // Rejected-only keys don't authenticate anything.
        let rejected = AICLIAuth.claudeLogin(fromConfigJSON: json([
            "customApiKeyResponses": ["approved": [], "rejected": ["sk-bad"]]
        ]))
        #expect(rejected == .loggedOut)
    }

    @Test("Unreadable config is unknown, not logged out")
    func unreadable() {
        // A wrong "logged out" sends the user to re-auth something working.
        #expect(AICLIAuth.claudeLogin(fromConfigJSON: Data("not json".utf8)) == .unknown)
    }
}

// MARK: - Codex login

@Suite("Codex login state")
struct CodexLoginTests {

    @Test("A ChatGPT login carries email and plan out of the ID token")
    func chatGPTLogin() {
        let token = jwt(claims: [
            "email": "surf@example.com",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"],
        ])
        let state = AICLIAuth.codexLogin(fromAuthJSON: json([
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "tokens": ["id_token": token, "access_token": "a", "refresh_token": "r"],
        ]))
        #expect(state == .loggedIn(AIAccount(email: "surf@example.com", detail: "ChatGPT Plus")))
    }

    @Test("Older tokens keep email inside the namespaced profile claim")
    func namespacedEmail() {
        let token = jwt(claims: [
            "https://api.openai.com/profile": ["email": "old@example.com"]
        ])
        let state = AICLIAuth.codexLogin(fromAuthJSON: json(["tokens": ["id_token": token]]))
        #expect(state == .loggedIn(AIAccount(email: "old@example.com")))
    }

    @Test("A token whose claims can't be read is still a login")
    func opaqueToken() {
        // The tokens object is the credential; the claims are just its label.
        let state = AICLIAuth.codexLogin(fromAuthJSON: json(["tokens": ["id_token": "junk"]]))
        #expect(state == .loggedIn(AIAccount()))
    }

    @Test("An API key alone is signed in, without naming an account")
    func apiKey() {
        let state = AICLIAuth.codexLogin(fromAuthJSON: json(["OPENAI_API_KEY": "sk-x"]))
        #expect(state == .loggedIn(AIAccount(detail: "API key")))
    }

    @Test("Recognisable file with no credentials is logged out; garbage is unknown")
    func emptyAndGarbage() {
        #expect(AICLIAuth.codexLogin(fromAuthJSON: json(["last_refresh": "2026"])) == .loggedOut)
        #expect(AICLIAuth.codexLogin(fromAuthJSON: Data("{".utf8)) == .unknown)
    }

    @Test("Plan labels read as product names, and new tiers survive")
    func planLabels() {
        #expect(AICLIAuth.planLabel("plus") == "ChatGPT Plus")
        #expect(AICLIAuth.planLabel("pro") == "ChatGPT Pro")
        // A tier we've never heard of passes through rather than vanishing.
        #expect(AICLIAuth.planLabel("galactic") == "ChatGPT Galactic")
        #expect(AICLIAuth.planLabel("") == "ChatGPT")
    }
}

// MARK: - JWT decoding

@Suite("JWT decoding")
struct JWTTests {

    @Test("base64url survives the characters classic base64 chokes on")
    func base64URL() {
        // 0xfb 0xef encodes to "--" / "++" — the url alphabet's whole reason.
        let data = Data([0xfb, 0xef, 0xbe])
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(AICLIAuth.base64URLDecode(encoded) == data)
    }

    @Test("Claims come back; malformed tokens come back nil")
    func claims() {
        let token = jwt(claims: ["email": "a@b.c"])
        #expect(AICLIAuth.jwtClaims(token)?["email"] as? String == "a@b.c")
        #expect(AICLIAuth.jwtClaims("only.two") == nil)
        #expect(AICLIAuth.jwtClaims("") == nil)
    }
}

// MARK: - Models

@Suite("Model selection")
struct ModelSelectionTests {

    @Test("A stored model that's still on the menu is honoured")
    func validStored() {
        let picked = AICLIProvider.claude.validatedModel(
            "opus", options: AICLIProvider.claude.curatedModels
        )
        #expect(picked?.id == "opus")
    }

    @Test("Empty, absent, and stale stored models all resolve to Fast")
    func fastFallback() {
        let claude = AICLIProvider.claude.curatedModels
        // A renamed model must not reach the CLI as a dead identifier.
        #expect(AICLIProvider.claude.validatedModel("claude-2", options: claude)?.id == "haiku")
        #expect(AICLIProvider.claude.validatedModel("", options: claude)?.id == "haiku")
        #expect(AICLIProvider.claude.validatedModel(nil, options: claude)?.id == "haiku")
    }

    @Test("Fast is the known quick tier while it exists")
    func fastKnownTier() {
        #expect(
            AICLIProvider.codex.fastModel(from: AICLIProvider.codex.curatedModels)?.id
                == "gpt-5.6-luna"
        )
    }

    @Test("When every known name is gone, Fast follows the vendor's own description")
    func fastByDescription() {
        let options = [
            AIModelOption(id: "gpt-7-alpha", label: "Alpha"),
            AIModelOption(id: "gpt-7-beta", label: "Beta"),
        ]
        let fast = AICLIProvider.codex.fastModel(
            from: options,
            descriptions: ["gpt-7-beta": "Fast and affordable agentic coding model."]
        )
        #expect(fast?.id == "gpt-7-beta")
    }

    @Test("With no names and no descriptions, Fast still picks something real")
    func fastLastResort() {
        let options = [AIModelOption(id: "mystery", label: "Mystery")]
        #expect(AICLIProvider.claude.fastModel(from: options)?.id == "mystery")
        #expect(AICLIProvider.claude.fastModel(from: []) == nil)
    }
}

// MARK: - Codex models cache

@Suite("Codex models cache")
struct CodexModelsCacheTests {

    private let cache = json([
        "fetched_at": "2026-08-18T05:20:50Z",
        "models": [
            [
                "slug": "gpt-5.6-luna", "display_name": "GPT-5.6-Luna",
                "description": "Fast and affordable.", "visibility": "list", "priority": 3,
            ],
            [
                "slug": "gpt-5.6-sol", "display_name": "GPT-5.6-Sol",
                "description": "Latest frontier model.", "visibility": "list", "priority": 1,
            ],
            [
                "slug": "codex-auto-review", "display_name": "Codex Auto Review",
                "description": "Internal.", "visibility": "hide", "priority": 43,
            ],
        ],
    ])

    @Test("Listed models come back in Codex's own priority order")
    func priorityOrder() {
        let models = CodexModelsCache.models(fromCacheJSON: cache)
        #expect(models?.map(\.id) == ["gpt-5.6-sol", "gpt-5.6-luna"])
        #expect(models?.first?.label == "GPT-5.6-Sol")
    }

    @Test("Hidden models never reach the menu")
    func hiddenExcluded() {
        // "hide" marks internal helpers that accept no user work.
        let models = CodexModelsCache.models(fromCacheJSON: cache)
        #expect(models?.contains { $0.id == "codex-auto-review" } == false)
    }

    @Test("An unreadable or empty cache yields nil, so the curated list stands in")
    func unreadable() {
        #expect(CodexModelsCache.models(fromCacheJSON: Data("nope".utf8)) == nil)
        #expect(CodexModelsCache.models(fromCacheJSON: json(["models": []])) == nil)
    }

    @Test("Descriptions ride along for the Fast heuristic")
    func descriptions() {
        let all = CodexModelsCache.descriptions(fromCacheJSON: cache)
        #expect(all["gpt-5.6-luna"] == "Fast and affordable.")
    }
}

// MARK: - Updates

@Suite("CLI update plumbing")
struct CLIUpdateTests {

    @Test("Install kind is read off the executable's path")
    func installKinds() {
        let home = "/Users/kai"
        #expect(
            AICLIInstall.installKind(ofPath: home + "/.local/bin/claude", home: home) == .native
        )
        #expect(
            AICLIInstall.installKind(
                ofPath: home + "/.nvm/versions/node/v22.0.0/bin/codex", home: home
            ) == .npm(binDirectory: home + "/.nvm/versions/node/v22.0.0/bin")
        )
        #expect(
            AICLIInstall.installKind(ofPath: "/opt/homebrew/bin/claude", home: home)
                == .homebrew(brewPath: "/opt/homebrew/bin/brew")
        )
        #expect(
            AICLIInstall.installKind(ofPath: "/somewhere/odd/claude", home: home) == .unknown
        )
    }

    @Test("The npm registry's latest document yields a bare version")
    func npmLatest() {
        #expect(
            AICLIInstall.version(fromNPMLatestJSON: json(["version": "2.1.237"])) == "2.1.237"
        )
        #expect(AICLIInstall.version(fromNPMLatestJSON: json(["error": "Not found"])) == nil)
        #expect(AICLIInstall.version(fromNPMLatestJSON: Data("html".utf8)) == nil)
    }

    @Test("Registry URLs keep the scope's slash intact")
    func registryURL() {
        // The registry routes scoped packages by path, not percent-encoding.
        #expect(
            AICLIInstall.npmLatestURL(for: .claude).absoluteString
                == "https://registry.npmjs.org/@anthropic-ai/claude-code/latest"
        )
    }
}

// MARK: - Provider and features

@Suite("Provider resolution")
struct ProviderResolutionTests {

    @Test("The default provider is the first usable one, in declared order")
    func firstUsable() {
        #expect(AICLIProvider.defaultProvider(usable: [.claude, .codex]) == .claude)
        #expect(AICLIProvider.defaultProvider(usable: [.codex]) == .codex)
        #expect(AICLIProvider.defaultProvider(usable: []) == nil)
    }
}

@Suite("Feature preference keys")
struct FeatureKeyTests {

    @Test("Keys are derived, distinct per feature, and per provider for models")
    func derivedKeys() {
        // A pinned Claude model replayed onto Codex would be a dead
        // identifier at best and someone else's bill at worst.
        #expect(AIFeature.tabRenaming.enabledKey == "aiFeature.tabRenaming.enabled")
        #expect(
            AIFeature.tabRenaming.modelKey(for: .claude)
                != AIFeature.tabRenaming.modelKey(for: .codex)
        )
        let allKeys = AIFeature.allCases.flatMap { feature in
            [feature.enabledKey] + AICLIProvider.allCases.map { feature.modelKey(for: $0) }
        }
        #expect(Set(allKeys).count == allKeys.count)
    }
}

// MARK: - Locating

@Suite("Install detection")
struct InstallDetectionTests {

    @Test("Native installs beat version-manager copies beat system paths")
    func searchOrder() {
        let dirs = AICLIInstall.candidateDirectories(
            home: "/Users/kai",
            nodeBinDirectories: ["/Users/kai/.nvm/versions/node/v22.0.0/bin"]
        )
        let local = dirs.firstIndex(of: "/Users/kai/.local/bin")
        let nvm = dirs.firstIndex(of: "/Users/kai/.nvm/versions/node/v22.0.0/bin")
        let brew = dirs.firstIndex(of: "/opt/homebrew/bin")
        #expect(local != nil && nvm != nil && brew != nil)
        #expect(local! < nvm! && nvm! < brew!)
    }

    @Test("Versions are read out of each CLI's own decoration")
    func versionParsing() {
        #expect(AICLIInstall.version(fromVersionOutput: "2.1.211 (Claude Code)") == "2.1.211")
        #expect(AICLIInstall.version(fromVersionOutput: "codex-cli 0.21.0") == "0.21.0")
        #expect(AICLIInstall.version(fromVersionOutput: "\n1.0.24 (Claude Code)\n") == "1.0.24")
        #expect(AICLIInstall.version(fromVersionOutput: "error: no tty") == nil)
        #expect(AICLIInstall.version(fromVersionOutput: "") == nil)
    }
}
