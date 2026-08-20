import Foundation
import NaturalLanguage

/// What the narrator reads, and how what it reads maps back onto the article.
///
/// Pure, deliberately: the karaoke sync — a character range the synthesiser
/// announces, turned into the words the reader should light up — is exactly
/// the kind of off-by-one factory that belongs behind tests rather than
/// inside a delegate callback.
public struct NarrationScript: Equatable, Sendable {

    /// One stretch of speech: a sentence of a block, or the article's header.
    ///
    /// A sentence rather than a whole block, deliberately: the utterance is
    /// the unit of everything — seeking, skipping, pause position, and the
    /// engines that report no word timings highlight exactly one of these —
    /// so its size is the resolution of the whole feature.
    public struct Utterance: Equatable, Sendable {
        /// The block this speech belongs to, or `headerID` for the title.
        public var blockID: Int
        /// Exactly what the synthesiser is handed. For word highlighting to
        /// land, this must be character-identical to a stretch of what the
        /// lens renders.
        public var text: String
        /// Where `text` sits inside its block's rendered text, in UTF-16
        /// units — what maps a spoken range back onto the page, and what an
        /// engine with no word timings lights up whole. Nil where the spoken
        /// text isn't verbatim block text: the header, a list read
        /// item-by-item, a caption.
        public var rangeInBlock: Range<Int>?

        /// Whether the lens can highlight inside this utterance.
        public var wordHighlighting: Bool { rangeInBlock != nil }

        public init(blockID: Int, text: String, rangeInBlock: Range<Int>? = nil) {
            self.blockID = blockID
            self.text = text
            self.rangeInBlock = rangeInBlock
        }
    }

    /// The header's stand-in block id. Negative so it can never collide with
    /// a real block, whose ids are positions.
    public static let headerID = -1

    public var utterances: [Utterance]

    public init(utterances: [Utterance]) {
        self.utterances = utterances
    }

    /// Builds the reading order from an article: title, then every block with
    /// something worth saying. Code is skipped — code read aloud is noise —
    /// and images contribute their captions, which are the one part of a
    /// figure a listener can use.
    public static func build(from article: FocusArticle) -> NarrationScript {
        var utterances: [Utterance] = []

        var opening = article.title
        if !article.byline.isEmpty {
            opening += opening.isEmpty ? article.byline : ". \(article.byline)"
        }
        if !opening.isEmpty {
            utterances.append(Utterance(blockID: headerID, text: opening))
        }

        for block in article.blocks {
            switch block.kind {
            case .paragraph, .heading, .quote:
                for sentence in sentences(of: block.text) {
                    for piece in chunks(of: sentence.text, at: sentence.range.lowerBound) {
                        utterances.append(
                            Utterance(
                                blockID: block.id,
                                text: piece.text,
                                rangeInBlock: piece.range
                            )
                        )
                    }
                }
            case .list:
                // Per item: skipping moves item by item, and an engine
                // without word timings still can't light one item — the
                // rendered text has bullets and numbers the speech doesn't —
                // so no range, and the block glows whole.
                for item in (block.items ?? []) where !item.isEmpty {
                    appendUnmapped(item, block: block.id, into: &utterances)
                }
            case .image:
                guard let caption = block.caption, !caption.isEmpty else { continue }
                appendUnmapped(caption, block: block.id, into: &utterances)
            case .code:
                continue
            }
        }
        return NarrationScript(utterances: utterances)
    }

    /// Splits rephrased text — items, captions — by the same sentence and
    /// clause rules as prose, without block ranges. The 300-character museum
    /// caption was the worst stall in the whole feature: one utterance,
    /// twenty seconds of audio, ten seconds of a neural model saying nothing.
    private static func appendUnmapped(
        _ text: String, block blockID: Int, into utterances: inout [Utterance]
    ) {
        for sentence in sentences(of: text) {
            for piece in chunks(of: sentence.text, at: 0) {
                utterances.append(Utterance(blockID: blockID, text: piece.text))
            }
        }
    }

    /// The longest stretch of speech worth synthesising as one piece, in
    /// UTF-16 units. Roughly ten seconds of audio: long enough that clause
    /// breaks stay rare, short enough that a neural engine's worst case is a
    /// few seconds of work rather than a stall that reads as a stop.
    public static let utteranceLimit = 160

    /// Splits one over-long sentence at clause punctuation — or, failing
    /// that, at a word boundary — into verbatim, offset-honest pieces.
    ///
    /// The invariant is the same one highlighting stands on everywhere: each
    /// piece's range names exactly its characters in the source block.
    static func chunks(
        of text: String, at offset: Int, limit: Int = utteranceLimit
    ) -> [(text: String, range: Range<Int>)] {
        let total = text.utf16.count
        guard total > limit else {
            return [(text, offset..<(offset + total))]
        }

        // The best cut inside the limit: after the last clause mark, else
        // before the last space, else — one unbroken token — hard at the
        // limit rather than not at all.
        var clause: Int?
        var space: Int?
        var position = 0
        for character in text {
            let width = String(character).utf16.count
            if position + width > limit { break }
            position += width
            if ",;:—–".contains(character) {
                clause = position
            } else if character.isWhitespace {
                space = position - width
            }
        }
        let cut = clause ?? space ?? min(limit, total)
        guard cut > 0, cut < total else {
            return [(text, offset..<(offset + total))]
        }

        let cutIndex = String.Index(utf16Offset: cut, in: text)
        let headRaw = String(text[..<cutIndex])
        let tailRaw = String(text[cutIndex...])

        let head = headRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else {
            return [(text, offset..<(offset + total))]
        }
        let headLeading = headRaw.prefix(while: \.isWhitespace).utf16.count
        let headStart = offset + headLeading
        var pieces: [(String, Range<Int>)] = [
            (head, headStart..<(headStart + head.utf16.count))
        ]

        let tailLeading = tailRaw.prefix(while: \.isWhitespace).utf16.count
        let tail = String(tailRaw.dropFirst(tailRaw.prefix(while: \.isWhitespace).count))
        if !tail.isEmpty {
            pieces.append(
                contentsOf: chunks(of: tail, at: offset + cut + tailLeading, limit: limit)
            )
        }
        return pieces
    }

    /// Splits prose into sentences with their UTF-16 positions in the source.
    ///
    /// `NLTokenizer` rather than splitting on full stops: "Dr. Smith arrived
    /// at 5 p.m." is one sentence, and every hand-rolled splitter learns that
    /// the hard way. The ranges come back in the source string's own indices,
    /// which is what keeps the spoken text character-identical to a stretch
    /// of the rendered text — the invariant highlighting stands on.
    static func sentences(of text: String) -> [(text: String, range: Range<Int>)] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(NLLanguage(rawValue:
            NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"))
        tokenizer.string = text

        var result: [(String, Range<Int>)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range])
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            // The tokenizer's range includes trailing whitespace; the spoken
            // text mustn't, but the block offsets must stay honest — so the
            // range is trimmed by the same amounts.
            let leading = sentence.prefix(while: \.isWhitespace).utf16.count
            let start = text.utf16.distance(
                from: text.utf16.startIndex,
                to: range.lowerBound.samePosition(in: text.utf16) ?? text.utf16.startIndex
            ) + leading
            result.append((trimmed, start..<(start + trimmed.utf16.count)))
            return true
        }

        // A tokenizer that found nothing (all-symbol text, an unsupported
        // script) must not silence the block: the whole text is one sentence.
        if result.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            let leading = text.prefix(while: \.isWhitespace).utf16.count
            return [(trimmed, leading..<(leading + trimmed.utf16.count))]
        }
        return result
    }

    public var isEmpty: Bool { utterances.isEmpty }

    /// Where to start speaking for a tapped block: the utterance for that
    /// block, or the next one after it — tapping a code block reads on from
    /// whatever follows it rather than doing nothing.
    public func utteranceIndex(forBlock blockID: Int) -> Int? {
        if let exact = utterances.firstIndex(where: { $0.blockID == blockID }) {
            return exact
        }
        return utterances.firstIndex(where: { $0.blockID > blockID })
    }

    /// The word the synthesiser is about to say, translated from utterance
    /// coordinates into block coordinates — or nil when it doesn't map: an
    /// utterance that isn't verbatim block text, or a range reported past
    /// the end, which some voices do on the final word.
    ///
    /// The range is clamped rather than rejected when it merely overruns:
    /// lighting most of the last word beats going dark on it.
    public func highlight(
        utterance index: Int, location: Int, length: Int
    ) -> (blockID: Int, range: Range<Int>)? {
        guard utterances.indices.contains(index) else { return nil }
        let utterance = utterances[index]
        guard utterance.blockID >= 0, let base = utterance.rangeInBlock else { return nil }

        let count = utterance.text.utf16.count
        guard location >= 0, length > 0, location < count else { return nil }
        let end = min(location + length, count)
        return (utterance.blockID, (base.lowerBound + location)..<(base.lowerBound + end))
    }

    /// The whole sentence as a highlight — the resolution for an engine that
    /// reports no word timings, which is every neural voice.
    public func sentenceHighlight(
        utterance index: Int
    ) -> (blockID: Int, range: Range<Int>)? {
        guard utterances.indices.contains(index) else { return nil }
        let utterance = utterances[index]
        guard utterance.blockID >= 0, let range = utterance.rangeInBlock else { return nil }
        return (utterance.blockID, range)
    }
}
