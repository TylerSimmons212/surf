import Foundation
import Testing
@testable import GlassCore

@Suite("URL resolution")
struct URLResolverTests {

    private func resolved(_ input: String) -> String? {
        URLResolver.resolve(input)?.absoluteString
    }

    @Test("Explicit schemes pass through untouched", arguments: [
        "https://apple.com",
        "http://example.org/path?a=b",
        "about:blank",
    ])
    func explicitScheme(_ input: String) {
        #expect(resolved(input) == input)
    }

    @Test("Bare hosts become https", arguments: [
        ("example.com", "https://example.com"),
        ("docs.swift.org/guide", "https://docs.swift.org/guide"),
        ("sub.domain.co.uk", "https://sub.domain.co.uk"),
    ])
    func bareHost(_ input: String, _ expected: String) {
        #expect(resolved(input) == expected)
    }

    @Test("localhost is a host, not a search", arguments: [
        ("localhost", "http://localhost"),
        ("localhost:3000", "http://localhost:3000"),
    ])
    func localhost(_ input: String, _ expected: String) {
        #expect(resolved(input) == expected)
    }

    @Test("Multi-word input searches", arguments: [
        "apple pie recipe",
        "what is swift",
        "example.com vs example.org",
    ])
    func multiWordSearches(_ input: String) {
        let result = resolved(input)
        #expect(result?.hasPrefix("https://duckduckgo.com/?q=") == true)
    }

    @Test("Single words without a TLD search", arguments: [
        "swift",
        "3.14",
        "v1.2",
    ])
    func nonHostSearches(_ input: String) {
        #expect(resolved(input)?.contains("duckduckgo.com") == true)
    }

    @Test("Malformed hosts fall back to search", arguments: [
        "foo..com",
        ".com",
        "foo.",
    ])
    func malformedHosts(_ input: String) {
        #expect(resolved(input)?.contains("duckduckgo.com") == true)
    }

    @Test("Empty and whitespace-only input resolves to nothing", arguments: ["", "   ", "\n\t"])
    func emptyInput(_ input: String) {
        #expect(URLResolver.resolve(input) == nil)
    }

    @Test("Input is trimmed before resolving")
    func trimsWhitespace() {
        #expect(resolved("  example.com  ") == "https://example.com")
    }

    @Test("Query separators are encoded, not passed through")
    func encodesQuerySeparators() throws {
        let result = try #require(resolved("cats & dogs"))
        let query = try #require(URLComponents(string: result)?.queryItems?.first { $0.name == "q" })
        // The whole phrase must survive as ONE parameter — a raw "&" would
        // silently truncate the search to "cats".
        #expect(query.value == "cats & dogs")
    }

    @Test("Search engine selection is respected")
    func honorsEngine() {
        let url = URLResolver.resolve("swift lang", using: .google)?.absoluteString
        #expect(url?.hasPrefix("https://www.google.com/search?q=") == true)
    }
}
