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
