import Foundation

/// Turns the detector's raw readings into a verdict.
///
/// In Swift rather than in the injected script, deliberately: thresholds are
/// judgements, judgements get revised, and a revision you can't test is a
/// regression you find on someone's blog. The script counts; this decides.
public enum FocusClassification {

    /// Below this the affordance stays hidden. Manual activation (the menu
    /// item) ignores it — extraction itself is the better judge, and its
    /// failure mode is a message rather than a mangled page.
    public static let offerThreshold = 0.6

    /// What the page is, or nil when it is none of the things Focus knows.
    public static func classify(_ signals: FocusSignals) -> FocusDetection? {
        let ldTypes = Set(signals.jsonLDTypes.map { $0.lowercased() })

        // Recipes first, and on one signal: recipe SEO lives and dies by this
        // JSON-LD type, so its presence is close to ground truth — and a
        // recipe page usually *also* reads as an article, which is the wrong
        // lens for it.
        if ldTypes.contains("recipe") {
            return FocusDetection(kind: .recipe, confidence: 0.95)
        }

        // Declared article types, from the two places sites actually declare
        // them. Matched by suffix because the vocabulary is a family:
        // NewsArticle, BlogPosting's parent chain, TechArticle, and the
        // OpenGraph `article` all end the same way.
        let declaresArticle =
            signals.ogType == "article"
            || ldTypes.contains(where: { $0.hasSuffix("article") || $0 == "blogposting" })

        // Declared but empty is a lie worth catching: an index page routinely
        // wears `og:type article` over a list of teasers.
        if declaresArticle && signals.wordCount >= 150 {
            return FocusDetection(kind: .article, confidence: 0.9)
        }

        // Undeclared but shaped like one: a real element plus enough prose.
        if signals.hasArticleElement,
           signals.wordCount >= 400, signals.paragraphCount >= 4 {
            return FocusDetection(kind: .article, confidence: 0.75)
        }

        // No markup help at all — just a lot of paragraphs. The threshold is
        // high because this tier is where index pages and dashboards would
        // sneak in.
        if signals.wordCount >= 800, signals.paragraphCount >= 8 {
            return FocusDetection(kind: .article, confidence: 0.6)
        }

        // A page that is mostly a video player. The stage lens can only
        // address a video that has *started* — the media bridge tracks
        // elements from their first play — so the offer is additionally
        // gated on live media state, on the tab, where that state lives.
        if signals.videoCount > 0, signals.wordCount < 150 {
            return FocusDetection(kind: .video, confidence: 0.75)
        }

        return nil
    }
}
