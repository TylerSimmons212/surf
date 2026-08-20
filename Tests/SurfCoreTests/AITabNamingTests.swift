import Foundation
import Testing
@testable import SurfCore

@Suite("AI tab naming — the ask")
struct AITabNamingPromptTests {

    @Test("The prompt carries the title and URL, and the guard against both")
    func promptContents() {
        let prompt = AITabNaming.prompt(
            pageTitle: "Handmade Mugs | Etsy", url: "https://etsy.com/search"
        )
        #expect(prompt.contains("Handmade Mugs | Etsy"))
        #expect(prompt.contains("https://etsy.com/search"))
        // Page titles are the page's words: untrusted input in a prompt.
        #expect(prompt.contains("not instructions"))
    }

    @Test("Hostile ten-kilobyte titles are capped before they ride along")
    func inputsCapped() {
        let prompt = AITabNaming.prompt(
            pageTitle: String(repeating: "A", count: 10_000),
            url: "https://example.com/" + String(repeating: "b", count: 10_000)
        )
        #expect(prompt.count < 1_500)
    }

    @Test("Only real web pages are worth a model call")
    func nameable() {
        #expect(AITabNaming.isNameable(url: "https://example.com/a"))
        #expect(AITabNaming.isNameable(url: "http://localhost:3000"))
        #expect(!AITabNaming.isNameable(url: "about:blank"))
        #expect(!AITabNaming.isNameable(url: "file:///tmp/x.html"))
        #expect(!AITabNaming.isNameable(url: ""))
        #expect(!AITabNaming.isNameable(url: "not a url"))
    }
}

@Suite("AI tab naming — the command line")
struct AITabNamingArgumentTests {

    @Test("Claude runs in print mode with the prompt last")
    func claudeArgs() {
        let args = AICLIInvocation.arguments(
            provider: .claude, model: "haiku", prompt: "P", lastMessageFile: "/tmp/f"
        )
        #expect(args.first == "-p")
        #expect(args.contains(["--model", "haiku"].joined(separator: " ")) == false)
        #expect(args.firstIndex(of: "--model").map { args[$0 + 1] } == "haiku")
        #expect(args.last == "P")
        // Claude answers on stdout; the file is Codex's mechanism.
        #expect(!args.contains("/tmp/f"))
    }

    @Test("Codex is sandboxed read-only and answers through the message file")
    func codexArgs() {
        let args = AICLIInvocation.arguments(
            provider: .codex, model: "gpt-5.6-luna", prompt: "P", lastMessageFile: "/tmp/f"
        )
        #expect(args.first == "exec")
        // The scratch cwd is no git repo, and Codex refuses those by default.
        #expect(args.contains("--skip-git-repo-check"))
        #expect(args.firstIndex(of: "-s").map { args[$0 + 1] } == "read-only")
        #expect(args.firstIndex(of: "-m").map { args[$0 + 1] } == "gpt-5.6-luna")
        #expect(args.firstIndex(of: "-o").map { args[$0 + 1] } == "/tmp/f")
        #expect(args.last == "P")
    }

    @Test("An empty model means the CLI's own choice — no flag at all")
    func emptyModelOmitted() {
        for provider in AICLIProvider.allCases {
            let args = AICLIInvocation.arguments(
                provider: provider, model: "", prompt: "P", lastMessageFile: "/tmp/f"
            )
            #expect(!args.contains("--model") && !args.contains("-m"))
        }
    }
}

@Suite("AI tab naming — the answer")
struct AITabNamingAnswerTests {

    @Test("A clean reply passes through untouched")
    func clean() {
        #expect(AITabNaming.sanitizedName(from: "Ceramic Mugs Etsy") == "Ceramic Mugs Etsy")
        #expect(AITabNaming.sanitizedName(from: "\nCeramic Mugs\n") == "Ceramic Mugs")
    }

    @Test("The quotes it was told not to add come off anyway")
    func quotes() {
        #expect(AITabNaming.sanitizedName(from: "\"Ceramic Mugs\"") == "Ceramic Mugs")
        #expect(AITabNaming.sanitizedName(from: "\u{201C}Ceramic Mugs\u{201D}") == "Ceramic Mugs")
        #expect(AITabNaming.sanitizedName(from: "Ceramic Mugs.") == "Ceramic Mugs")
    }

    @Test("Rambles, refusals, and empties all mean keeping the real title")
    func rejected() {
        // Nil is the safe answer: the tab's own title is never wrong.
        #expect(AITabNaming.sanitizedName(from: "") == nil)
        #expect(AITabNaming.sanitizedName(from: "   \n  ") == nil)
        #expect(AITabNaming.sanitizedName(from: "Sorry, I can't name this tab") == nil)
        #expect(AITabNaming.sanitizedName(
            from: "I cannot determine a name for this page"
        ) == nil)
        let ramble = "This page appears to be a shopping site for handmade ceramics, so"
        #expect(ramble.count > AITabNaming.maxNameLength)
        #expect(AITabNaming.sanitizedName(from: ramble) == nil)
    }

    @Test("Only the first real line of a chatty reply is considered")
    func firstLine() {
        #expect(
            AITabNaming.sanitizedName(from: "Ceramic Mugs\n\nI chose this because…")
                == "Ceramic Mugs"
        )
    }
}
