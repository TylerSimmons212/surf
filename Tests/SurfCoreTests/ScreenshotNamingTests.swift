import Foundation
import Testing

@testable import SurfCore

@Suite("Screenshot naming")
struct ScreenshotNamingTests {

    private let noon = Date(timeIntervalSince1970: 1_755_691_200)  // 2026-08-20 12:00:00 UTC

    @Test("Title leads, moment follows")
    func shape() {
        let name = ScreenshotNaming.filename(title: "Bioluminescence - Wikipedia", date: noon)
        #expect(name.hasPrefix("Bioluminescence - Wikipedia — "))
        #expect(name.hasSuffix(".png"))
        // Local time by design — asserting the shape, not the machine's zone.
        #expect(name.range(
            of: #"\d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2}\.png$"#,
            options: .regularExpression
        ) != nil)
    }

    @Test("Characters a filesystem refuses become spaces")
    func illegalCharacters() {
        #expect(ScreenshotNaming.sanitize("a/b:c\\d?e*f|g\"h<i>j") == "a b c d e f g h i j")
    }

    @Test("No colons in the time — Finder still refuses them")
    func noColons() {
        let name = ScreenshotNaming.filename(title: "x", date: noon)
        #expect(!name.contains(":"))
    }

    @Test("An empty or all-illegal title still names the file")
    func emptyTitle() {
        #expect(ScreenshotNaming.sanitize("") == "Page")
        #expect(ScreenshotNaming.sanitize("///") == "Page")
        #expect(ScreenshotNaming.sanitize("   ") == "Page")
    }

    @Test("A very long title is trimmed, not rejected")
    func longTitle() {
        let long = String(repeating: "word ", count: 60)
        let out = ScreenshotNaming.sanitize(long)
        #expect(out.count <= 120)
        #expect(out.hasPrefix("word"))
    }
}
