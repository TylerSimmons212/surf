import Foundation
import Testing

@testable import SurfCore

@Suite("Focus content model")
struct FocusModelTests {

    private func decode(_ json: String) throws -> FocusArticle {
        try JSONDecoder().decode(FocusArticle.self, from: Data(json.utf8))
    }

    @Test("An extractor payload decodes, in order, with identities stamped")
    func decodesPayload() throws {
        let article = try decode("""
        {
          "title": "On Tides",
          "byline": "A. Mariner",
          "siteName": "Sea Journal",
          "heroImage": "https://example.com/hero.jpg",
          "blocks": [
            { "type": "heading", "text": "The pull", "level": 2 },
            { "type": "paragraph", "text": "The moon does most of the work." },
            { "type": "quote", "text": "The sea refuses no river." },
            { "type": "code", "text": "let tide = moon.pull()" },
            { "type": "image", "src": "https://example.com/a.jpg", "caption": "High water" },
            { "type": "list", "items": ["Spring", "Neap"], "ordered": false }
          ]
        }
        """)
        #expect(article.title == "On Tides")
        #expect(article.blocks.count == 6)
        #expect(article.blocks.map(\.id) == [0, 1, 2, 3, 4, 5])
        #expect(article.blocks[0].kind == .heading)
        #expect(article.blocks[0].level == 2)
        #expect(article.blocks[5].items == ["Spring", "Neap"])
    }

    /// One unreadable block must cost that block, not the article. The reader
    /// losing a figure is recoverable; losing the page is not.
    @Test("An unknown block type drops out without failing the article")
    func unknownBlockDropsOut() throws {
        let article = try decode("""
        {
          "blocks": [
            { "type": "paragraph", "text": "Before." },
            { "type": "hologram", "text": "From a newer extractor." },
            { "type": "paragraph", "text": "After." }
          ]
        }
        """)
        #expect(article.blocks.count == 2)
        // Identities are positions in what survived, not in what arrived —
        // they must stay contiguous or the reader's scroll anchor lies.
        #expect(article.blocks.map(\.id) == [0, 1])
        #expect(article.blocks[1].text == "After.")
    }

    @Test("Missing metadata decodes as empty rather than failing")
    func sparsePayload() throws {
        let article = try decode(#"{ "blocks": [] }"#)
        #expect(article.title.isEmpty)
        #expect(article.blocks.isEmpty)
        #expect(!article.isSubstantial)
    }

    @Test("Word count spans paragraphs and lists, and skips images")
    func wordCount() {
        let article = FocusArticle(blocks: [
            FocusBlock(kind: .paragraph, text: "one two three"),
            FocusBlock(kind: .list, items: ["four five", "six"]),
            FocusBlock(kind: .image, src: "https://example.com/a.jpg", caption: "seven eight"),
        ])
        #expect(article.wordCount == 6)
    }

    /// "0 min read" is a lie told with arithmetic.
    @Test("Reading time floors at one minute")
    func readingFloor() {
        let short = FocusArticle(blocks: [FocusBlock(kind: .paragraph, text: "just a note")])
        #expect(short.readingMinutes == 1)
    }

    @Test("Reading time tracks 230 words a minute")
    func readingEstimate() {
        let words = Array(repeating: "word", count: 1150).joined(separator: " ")
        let article = FocusArticle(blocks: [FocusBlock(kind: .paragraph, text: words)])
        #expect(article.readingMinutes == 5)
    }

    /// The gate `Tab.enterFocus` trusts instead of the classifier: a title
    /// over a few words of boilerplate is a failure wearing a heading.
    @Test("Substantial means a real body, not a successful decode")
    func substantiality() {
        let stub = FocusArticle(
            title: "A Title",
            blocks: [FocusBlock(kind: .paragraph, text: "Subscribe to continue.")]
        )
        #expect(!stub.isSubstantial)

        let words = Array(repeating: "word", count: 80).joined(separator: " ")
        let real = FocusArticle(blocks: [FocusBlock(kind: .paragraph, text: words)])
        #expect(real.isSubstantial)
    }
}
