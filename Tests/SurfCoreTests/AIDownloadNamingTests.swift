import Foundation
import Testing
@testable import SurfCore

@Suite("AI download naming")
struct AIDownloadNamingTests {

    @Test("The extension is the file's, never the model's")
    func extensionPreserved() {
        // Clean reply gains the original extension back.
        #expect(
            AIDownloadNaming.filename(from: "Quarterly Report", originalFilename: "dl-8823.pdf")
                == "Quarterly Report.pdf"
        )
        // A reply that disobeyed and included it isn't doubled.
        #expect(
            AIDownloadNaming.filename(from: "Quarterly Report.pdf", originalFilename: "dl-8823.pdf")
                == "Quarterly Report.pdf"
        )
        // Extensionless files stay extensionless.
        #expect(
            AIDownloadNaming.filename(from: "Build Script", originalFilename: "x92kfa")
                == "Build Script"
        )
    }

    @Test("Path separators and hidden-file dots can't ride into a filename")
    func filesystemSafety() {
        // A model reply is untrusted output heading into a filesystem call.
        #expect(
            AIDownloadNaming.sanitizedBaseName(from: "../../etc/cron", originalExtension: "")
                == "etc cron"
        )
        #expect(
            AIDownloadNaming.sanitizedBaseName(from: ".hidden name", originalExtension: "")
                == "hidden name"
        )
        #expect(
            AIDownloadNaming.sanitizedBaseName(from: "a/b\\c:d", originalExtension: "")
                == "a b c d"
        )
    }

    // MARK: - Naming conventions

    /// The case that started this: a release artifact downloaded through Surf
    /// came out as `Surf 0.5.0.dmg`, which is a name you have to quote every
    /// time you touch it — and is not what the server called it.
    @Test("An installer keeps its hyphens instead of gaining spaces")
    func installerStaysHyphenated() {
        #expect(
            AIDownloadNaming.filename(from: "Surf 0.5.0", originalFilename: "Surf-0.5.0.dmg")
                == nil,
            "hyphenating the reply reproduces the original, so there is nothing to rename"
        )
        #expect(
            AIDownloadNaming.filename(from: "Surf 0.6.0", originalFilename: "download_9f2a.dmg")
                == "Surf-0.6.0.dmg"
        )
    }

    /// A document is the other way round. Most downloads are these, which is
    /// why spaces stay the default.
    @Test("A document keeps its spaces")
    func documentStaysSpaced() {
        #expect(
            AIDownloadNaming.filename(
                from: "Q3 Revenue Report", originalFilename: "dl_88213.pdf"
            ) == "Q3 Revenue Report.pdf"
        )
    }

    @Test(
        "Files that end up in a terminal are hyphenated; files that are read are not",
        arguments: [
            ("dmg", true), ("pkg", true), ("zip", true), ("tar", true),
            ("sh", true), ("py", true), ("json", true), ("yaml", true),
            ("pem", true), ("SWIFT", true),
            ("pdf", false), ("docx", false), ("png", false), ("mp4", false),
            ("epub", false), ("pages", false), ("", false),
        ]
    )
    func stylesFollowTheKindOfFile(ext: String, hyphenated: Bool) {
        let style = AIDownloadNaming.style(for: ext)
        #expect((style == .hyphenated) == hyphenated, "\(ext) got \(style)")
    }

    /// Asked for in the prompt *and* enforced afterwards, for the same reason
    /// the extension is: a model that ignores the instruction must not be able
    /// to put a space in a name that cannot have one.
    @Test("A model that ignores the instruction still can't produce a space")
    func styleIsEnforcedNotRequested() {
        #expect(
            AIDownloadNaming.sanitizedBaseName(
                from: "Node   Eighteen  Runtime", originalExtension: "tar"
            ) == "Node-Eighteen-Runtime"
        )
        // Underscores and stray dashes collapse into the same shape.
        #expect(
            AIDownloadNaming.sanitizedBaseName(
                from: "python_3.12 -- release", originalExtension: "pkg"
            ) == "python-3.12-release"
        )
    }

    /// Kebab-case is conventionally lowercase, and a version string is not.
    @Test("Hyphenating doesn't throw away capitals or version numbers")
    func hyphenatingKeepsInformation() {
        #expect(
            AIDownloadNaming.sanitizedBaseName(
                from: "Surf 0.5.0 Release", originalExtension: "dmg"
            ) == "Surf-0.5.0-Release"
        )
    }

    @Test("A reply of nothing but separators is not a filename")
    func allSeparatorsIsRejected() {
        #expect(AIDownloadNaming.sanitizedBaseName(from: "- _ -", originalExtension: "zip") == nil)
    }

    @Test("The prompt tells the model which convention to use")
    func promptNamesTheConvention() {
        let installer = AIDownloadNaming.prompt(filename: "a.dmg", sourceURL: "https://x.test")
        let document = AIDownloadNaming.prompt(filename: "a.pdf", sourceURL: "https://x.test")
        #expect(installer.contains("hyphens"))
        #expect(!document.contains("hyphens"))
        #expect(document.contains("spaces"))
    }

    @Test("A no-op rename is reported as nothing to do")
    func noOp() {
        #expect(
            AIDownloadNaming.filename(from: "report", originalFilename: "report.pdf")
                == nil
        )
    }

    @Test("Refusals, rambles, and empties mean keeping the original name")
    func rejected() {
        #expect(AIDownloadNaming.sanitizedBaseName(from: "", originalExtension: "pdf") == nil)
        #expect(
            AIDownloadNaming.sanitizedBaseName(
                from: "Sorry, I cannot rename this file", originalExtension: "pdf"
            ) == nil
        )
        let ramble = String(repeating: "very ", count: 20) + "long name"
        #expect(AIDownloadNaming.sanitizedBaseName(from: ramble, originalExtension: "") == nil)
    }

    @Test("Quotes come off and inner whitespace collapses")
    func tidying() {
        #expect(
            AIDownloadNaming.sanitizedBaseName(from: "\"Tax  Return   2026\"", originalExtension: "")
                == "Tax Return 2026"
        )
    }
}

@Suite("Login probes")
struct LoginProbeTests {

    private func json(_ o: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: o)
    }

    @Test("claude auth status parses to a definite yes or no")
    func claudeProbe() {
        #expect(AICLIAuth.claudeProbeLoggedIn(
            fromAuthStatusJSON: json(["loggedIn": true, "authMethod": "claude.ai"])
        ) == true)
        #expect(AICLIAuth.claudeProbeLoggedIn(
            fromAuthStatusJSON: json(["loggedIn": false, "authMethod": "none"])
        ) == false)
        // Usage text from an old CLI, or a changed shape: no answer, not "no".
        #expect(AICLIAuth.claudeProbeLoggedIn(fromAuthStatusJSON: Data("Usage:".utf8)) == nil)
        #expect(AICLIAuth.claudeProbeLoggedIn(fromAuthStatusJSON: json(["ok": 1])) == nil)
    }

    @Test("A dead probe over a logged-in file is an expired session")
    func expiredDetection() {
        let account = AIAccount(email: "surf@example.com")
        // The file names the account, the CLI says the session is gone: the
        // user needs "sign in again", not "sign in".
        #expect(
            AICLIAuth.mergedLogin(file: .loggedIn(account), probeLoggedIn: false)
                == .expired(account)
        )
        #expect(AICLIAuth.mergedLogin(file: .loggedOut, probeLoggedIn: false) == .loggedOut)
    }

    @Test("A live probe wins even when the file couldn't name the account")
    func probeWins() {
        // Codex's Keychain storage mode: no auth.json, but a real session.
        #expect(
            AICLIAuth.mergedLogin(file: .loggedOut, probeLoggedIn: true)
                == .loggedIn(AIAccount())
        )
        // And a file that could name it keeps the details.
        let account = AIAccount(email: "surf@example.com")
        #expect(
            AICLIAuth.mergedLogin(file: .loggedIn(account), probeLoggedIn: true)
                == .loggedIn(account)
        )
    }

    @Test("No probe answer leaves the file's word standing")
    func silentProbe() {
        let account = AIAccount(email: "surf@example.com")
        #expect(
            AICLIAuth.mergedLogin(file: .loggedIn(account), probeLoggedIn: nil)
                == .loggedIn(account)
        )
        #expect(AICLIAuth.mergedLogin(file: .unknown, probeLoggedIn: nil) == .unknown)
    }
}
