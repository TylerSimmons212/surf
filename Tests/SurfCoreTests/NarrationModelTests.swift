import Testing

@testable import SurfCore

@Suite("Narration script")
struct NarrationModelTests {

    private let article = FocusArticle(
        title: "On Tides",
        byline: "A. Mariner",
        blocks: [
            FocusBlock(kind: .heading, text: "The pull", level: 2),                    // 0
            FocusBlock(kind: .paragraph, text: "The moon does the work. The sun helps a little."),  // 1
            FocusBlock(kind: .code, text: "let tide = moon.pull()"),                   // 2
            FocusBlock(kind: .image, src: "https://x/a.jpg", caption: "High water"),   // 3
            FocusBlock(kind: .list, items: ["Spring", "Neap"]),                        // 4
            FocusBlock(kind: .paragraph, text: "The sea keeps time."),                 // 5
        ]
    )

    @Test("Reading order: header, sentences, items, captions; code skipped")
    func readingOrder() {
        let script = NarrationScript.build(from: article)
        #expect(script.utterances.map(\.blockID)
            == [NarrationScript.headerID, 0, 1, 1, 3, 4, 4, 5])
        #expect(script.utterances[0].text == "On Tides. A. Mariner")
        #expect(script.utterances[2].text == "The moon does the work.")
        #expect(script.utterances[3].text == "The sun helps a little.")
        // List items are separate utterances, so skipping moves item by item.
        #expect(script.utterances[5].text == "Spring")
        #expect(script.utterances[6].text == "Neap")
    }

    @Test("Sentences carry their true offsets in the block")
    func sentenceOffsets() {
        let script = NarrationScript.build(from: article)
        #expect(script.utterances[2].rangeInBlock == 0..<23)
        // "The sun helps a little." starts after "The moon does the work. "
        #expect(script.utterances[3].rangeInBlock == 24..<47)
    }

    @Test("Highlighting only where speech is verbatim block text")
    func highlightingFlags() {
        let script = NarrationScript.build(from: article)
        // Header, caption, and list items are rephrased or renumbered for
        // the ear; lighting inside them would light the wrong characters.
        #expect(!script.utterances[0].wordHighlighting)
        #expect(script.utterances[1].wordHighlighting)   // heading
        #expect(script.utterances[2].wordHighlighting)   // sentence
        #expect(!script.utterances[4].wordHighlighting)  // caption
        #expect(!script.utterances[5].wordHighlighting)  // list item
    }

    @Test("An article with nothing speakable makes an empty script")
    func emptyScript() {
        let silent = FocusArticle(blocks: [FocusBlock(kind: .code, text: "x")])
        #expect(NarrationScript.build(from: silent).isEmpty)
    }

    /// Tap-to-seek: a tapped block starts at its first sentence, and a tapped
    /// code block reads on from what follows it.
    @Test("Seeking lands on a block's first utterance, or the next spoken one")
    func seeking() {
        let script = NarrationScript.build(from: article)
        #expect(script.utteranceIndex(forBlock: 1) == 2)
        #expect(script.utteranceIndex(forBlock: 2) == 4)   // code → caption after it
        #expect(script.utteranceIndex(forBlock: 5) == 7)
        #expect(script.utteranceIndex(forBlock: 99) == nil)
    }

    /// The delegate reports ranges in utterance coordinates; the lens
    /// highlights in block coordinates. This translation is the lyric sync.
    @Test("A word range in a later sentence maps into block coordinates")
    func highlightMapping() {
        let script = NarrationScript.build(from: article)
        // Utterance 3 is "The sun helps a little." at offset 24 in block 1.
        // "sun" is at 4..<7 in the sentence — so 28..<31 in the block.
        let hit = script.highlight(utterance: 3, location: 4, length: 3)
        #expect(hit?.blockID == 1)
        #expect(hit?.range == 28..<31)
    }

    /// Some voices report a final range past the end of the string. Lighting
    /// most of the last word beats going dark on it.
    @Test("An overrunning range is clamped, an impossible one is refused")
    func rangeClamping() {
        let script = NarrationScript.build(from: article)
        let text = script.utterances[2].text
        let clamped = script.highlight(
            utterance: 2, location: text.utf16.count - 3, length: 10
        )
        #expect(clamped?.range == (text.utf16.count - 3)..<text.utf16.count)

        #expect(script.highlight(utterance: 2, location: text.utf16.count, length: 2) == nil)
        #expect(script.highlight(utterance: 2, location: -1, length: 2) == nil)
        #expect(script.highlight(utterance: 99, location: 0, length: 2) == nil)
        #expect(script.highlight(utterance: 0, location: 0, length: 2) == nil)  // header
    }

    /// What a neural engine with no word timings lights up: the sentence.
    @Test("Sentence highlight covers exactly the sentence, where it maps")
    func sentenceHighlight() {
        let script = NarrationScript.build(from: article)
        let hit = script.sentenceHighlight(utterance: 3)
        #expect(hit?.blockID == 1)
        #expect(hit?.range == 24..<47)
        #expect(script.sentenceHighlight(utterance: 0) == nil)  // header
        #expect(script.sentenceHighlight(utterance: 5) == nil)  // list item
    }

    @Test("Abbreviations don't end sentences")
    func abbreviations() {
        let split = NarrationScript.sentences(of: "Dr. Smith arrived early. He waved.")
        #expect(split.map(\.text) == ["Dr. Smith arrived early.", "He waved."])
    }

    @Test("Sentence ranges survive leading and trailing whitespace")
    func whitespaceRanges() {
        let text = "  First one.  Second one.  "
        let split = NarrationScript.sentences(of: text)
        #expect(split.count == 2)
        for sentence in split {
            let start = String.Index(utf16Offset: sentence.range.lowerBound, in: text)
            let end = String.Index(utf16Offset: sentence.range.upperBound, in: text)
            // The invariant everything stands on: the range names exactly the
            // spoken characters in the source string.
            #expect(String(text[start..<end]) == sentence.text)
        }
    }

    @Test("Text the tokenizer can't split still speaks as one sentence")
    func unsplittableText() {
        let split = NarrationScript.sentences(of: "· · ·")
        #expect(split.count == 1)
        #expect(split[0].text == "· · ·")
    }

    /// The stall this exists for: one 300-character sentence is ten seconds
    /// of a neural model saying nothing.
    @Test("An over-long sentence splits at clauses, offsets staying honest")
    func clauseChunking() {
        let clause = "the moon pulls the water toward itself across the whole basin"
        let text = "\(clause), \(clause), and \(clause)."
        let pieces = NarrationScript.chunks(of: text, at: 10)

        #expect(pieces.count > 1)
        for piece in pieces {
            #expect(piece.text.utf16.count <= NarrationScript.utteranceLimit)
            // The invariant everything stands on: each range names exactly
            // its own characters in the source (shifted by the offset).
            let start = String.Index(utf16Offset: piece.range.lowerBound - 10, in: text)
            let end = String.Index(utf16Offset: piece.range.upperBound - 10, in: text)
            #expect(String(text[start..<end]) == piece.text)
        }
        // A clause cut lands after its comma, not mid-word.
        #expect(pieces[0].text.hasSuffix(","))
    }

    @Test("A short sentence passes through chunking untouched")
    func shortSentenceUnchunked() {
        let pieces = NarrationScript.chunks(of: "Brief.", at: 4)
        #expect(pieces.count == 1)
        #expect(pieces[0].text == "Brief.")
        #expect(pieces[0].range == 4..<10)
    }

    @Test("No punctuation still splits, on a word boundary")
    func wordBoundaryFallback() {
        let text = Array(repeating: "word", count: 60).joined(separator: " ")
        let pieces = NarrationScript.chunks(of: text, at: 0)
        #expect(pieces.count > 1)
        for piece in pieces {
            #expect(!piece.text.hasPrefix(" "))
            #expect(!piece.text.hasSuffix(" "))
            #expect(piece.text.utf16.count <= NarrationScript.utteranceLimit)
        }
    }

    @Test("A long caption becomes several bounded utterances")
    func longCaptionChunked() {
        let caption = Array(repeating: "a schematic of the tidal bulge", count: 12)
            .joined(separator: ", ")
        let article = FocusArticle(blocks: [
            FocusBlock(kind: .image, src: "https://x/a.jpg", caption: caption)
        ])
        let script = NarrationScript.build(from: article)
        #expect(script.utterances.count > 1)
        for utterance in script.utterances {
            #expect(utterance.text.utf16.count <= NarrationScript.utteranceLimit)
            #expect(!utterance.wordHighlighting)
        }
    }
}
