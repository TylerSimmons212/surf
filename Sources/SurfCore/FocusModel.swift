import Foundation

/// What kind of page Focus thinks it is looking at.
///
/// The taxonomy Focus lenses are keyed by. Phase 1 renders only `.article`;
/// the others are detected and reported so the classifier's thresholds get
/// exercised on real pages before their lenses exist.
public enum FocusKind: String, Codable, Sendable {
    case article
    case recipe
    case video
}

/// The detector's raw readings, exactly as the page reports them.
///
/// Deliberately dumb: counts and declared types, no judgement. The judgement
/// is `FocusClassification`'s, in Swift, where it can be tested — the script's
/// only job is to say what's there.
public struct FocusSignals: Decodable, Equatable, Sendable {
    /// Words in the page's paragraph text, capped by the script so a
    /// pathological page can't make measuring it expensive.
    public var wordCount: Int
    /// How many paragraphs carried real text (a full sentence or more).
    public var paragraphCount: Int
    /// Whether the markup declares an `<article>` or `articleBody` at all.
    public var hasArticleElement: Bool
    /// The declared `og:type`, lowercased; empty when there isn't one.
    public var ogType: String
    /// Every `@type` found in the page's JSON-LD, flattened across `@graph`
    /// wrappers and arrays. Recipe SEO guarantees `Recipe` appears here.
    public var jsonLDTypes: [String]
    /// `<video>` elements in the main document.
    public var videoCount: Int

    public init(
        wordCount: Int = 0,
        paragraphCount: Int = 0,
        hasArticleElement: Bool = false,
        ogType: String = "",
        jsonLDTypes: [String] = [],
        videoCount: Int = 0
    ) {
        self.wordCount = wordCount
        self.paragraphCount = paragraphCount
        self.hasArticleElement = hasArticleElement
        self.ogType = ogType
        self.jsonLDTypes = jsonLDTypes
        self.videoCount = videoCount
    }
}

/// The classifier's verdict: what the page is, and how sure that is.
public struct FocusDetection: Equatable, Sendable {
    public var kind: FocusKind
    /// 0...1. Above `FocusClassification.offerThreshold` the affordance shows;
    /// manual activation ignores this entirely and trusts extraction instead.
    public var confidence: Double

    public init(kind: FocusKind, confidence: Double) {
        self.kind = kind
        self.confidence = confidence
    }
}

/// One block of extracted content, in reading order.
///
/// The normalized unit every lens renders and — later — every narration
/// engine reads. One shape for all lenses, so there is one decoder on the
/// Swift side and one contract with the extractor.
public struct FocusBlock: Decodable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Decodable, Sendable {
        case paragraph
        case heading
        case quote
        case code
        case image
        case list
    }

    /// Position in the article, assigned after decode — it is the identity
    /// the reader view scrolls by and the handle `focus.reveal` scrolls the
    /// page back to.
    public var id: Int = 0

    public var kind: Kind
    /// The text for paragraph/heading/quote/code; empty for image and list.
    public var text: String
    /// Heading depth 1–6; nil for everything else.
    public var level: Int?
    /// Absolute image URL; nil for everything else.
    public var src: String?
    /// The image's figcaption or alt text, when it has one.
    public var caption: String?
    /// The items of a list block, one string each.
    public var items: [String]?
    /// Whether a list block was ordered, so the lens numbers it.
    public var ordered: Bool?

    private enum CodingKeys: String, CodingKey {
        case kind = "type"
        case text, level, src, caption, items, ordered
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        level = try c.decodeIfPresent(Int.self, forKey: .level)
        src = try c.decodeIfPresent(String.self, forKey: .src)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        items = try c.decodeIfPresent([String].self, forKey: .items)
        ordered = try c.decodeIfPresent(Bool.self, forKey: .ordered)
    }

    /// Memberwise, for tests and previews.
    public init(
        id: Int = 0, kind: Kind, text: String = "", level: Int? = nil,
        src: String? = nil, caption: String? = nil,
        items: [String]? = nil, ordered: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.level = level
        self.src = src
        self.caption = caption
        self.items = items
        self.ordered = ordered
    }
}

/// Everything the article lens renders, as one decoded payload.
public struct FocusArticle: Decodable, Equatable, Sendable {
    public var title: String
    public var byline: String
    public var siteName: String
    public var heroImage: String
    public var blocks: [FocusBlock]
    /// Where the extractor decided the article lives — diagnostics for the
    /// debug log, never rendered.
    public var rootPath: String
    /// The page's raw JSON-LD scripts, for the lenses built on structured
    /// data — the recipe parser reads these, not the blocks.
    public var jsonLD: [String]

    private enum CodingKeys: String, CodingKey {
        case title, byline, siteName, heroImage, blocks, rootPath, jsonLD
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        byline = try c.decodeIfPresent(String.self, forKey: .byline) ?? ""
        siteName = try c.decodeIfPresent(String.self, forKey: .siteName) ?? ""
        heroImage = try c.decodeIfPresent(String.self, forKey: .heroImage) ?? ""
        rootPath = try c.decodeIfPresent(String.self, forKey: .rootPath) ?? ""
        jsonLD = try c.decodeIfPresent([String].self, forKey: .jsonLD) ?? []
        // A block the decoder can't read — an unknown type from a newer
        // extractor, a malformed one — drops out rather than failing the whole
        // article: the reader losing one figure is recoverable, losing the
        // page is not.
        let raw = try c.decodeIfPresent([FailableBlock].self, forKey: .blocks) ?? []
        var position = 0
        blocks = raw.compactMap { wrapper in
            guard var block = wrapper.block else { return nil }
            block.id = position
            position += 1
            return block
        }
    }

    public init(
        title: String = "", byline: String = "", siteName: String = "",
        heroImage: String = "", blocks: [FocusBlock] = [], rootPath: String = "",
        jsonLD: [String] = []
    ) {
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.heroImage = heroImage
        self.rootPath = rootPath
        self.jsonLD = jsonLD
        // Stamp identities the same way decoding does, so a hand-built
        // article behaves like a decoded one.
        var stamped = blocks
        for index in stamped.indices { stamped[index].id = index }
        self.blocks = stamped
    }

    /// Whether extraction produced something worth showing. A title with no
    /// body is a failure wearing a heading.
    public var isSubstantial: Bool {
        wordCount >= 60
    }

    /// Words across every text-bearing block.
    public var wordCount: Int {
        blocks.reduce(0) { total, block in
            let text: String
            switch block.kind {
            case .list: text = (block.items ?? []).joined(separator: " ")
            case .image: return total
            default: text = block.text
            }
            return total + text.split(whereSeparator: \.isWhitespace).count
        }
    }

    /// Estimated minutes to read, floored at one — "0 min read" is a lie told
    /// with arithmetic. 230 wpm is the middle of the measured adult range.
    public var readingMinutes: Int {
        max(1, Int((Double(wordCount) / 230.0).rounded()))
    }

    private struct FailableBlock: Decodable {
        let block: FocusBlock?
        init(from decoder: any Decoder) throws {
            block = try? FocusBlock(from: decoder)
        }
    }
}
