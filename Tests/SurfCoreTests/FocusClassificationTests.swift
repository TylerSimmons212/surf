import Testing

@testable import SurfCore

@Suite("Focus classification")
struct FocusClassificationTests {

    /// A typical news page: declared type, plenty of prose.
    private let news = FocusSignals(
        wordCount: 1200, paragraphCount: 18,
        hasArticleElement: true, ogType: "article",
        jsonLDTypes: ["NewsArticle"], videoCount: 0
    )

    @Test("A declared article with real prose is a confident article")
    func declaredArticle() {
        let verdict = FocusClassification.classify(news)
        #expect(verdict?.kind == .article)
        #expect((verdict?.confidence ?? 0) >= FocusClassification.offerThreshold)
    }

    /// The case the recipe rule exists for: recipe pages are also long-form
    /// articles by every prose measure, and the article lens is the wrong one.
    @Test("Recipe JSON-LD beats every article signal")
    func recipeWins() {
        var signals = news
        signals.jsonLDTypes = ["Recipe", "Article"]
        #expect(FocusClassification.classify(signals)?.kind == .recipe)
    }

    @Test("JSON-LD types match regardless of case")
    func caseInsensitiveTypes() {
        var signals = FocusSignals()
        signals.jsonLDTypes = ["RECIPE"]
        #expect(FocusClassification.classify(signals)?.kind == .recipe)
    }

    /// The schema.org vocabulary is a family — NewsArticle, TechArticle,
    /// BlogPosting — and the classifier must not need a hand-kept list of it.
    @Test("Article subtypes count as declared articles")
    func articleSubtypes() {
        for type in ["NewsArticle", "TechArticle", "BlogPosting", "article"] {
            let signals = FocusSignals(wordCount: 500, jsonLDTypes: [type])
            #expect(
                FocusClassification.classify(signals)?.kind == .article,
                "\(type) should classify as an article"
            )
        }
    }

    /// An index page routinely wears `og:type article` over a list of teasers.
    /// The declaration alone must not be enough.
    @Test("A declared article with no prose is not offered")
    func declaredButEmpty() {
        let signals = FocusSignals(wordCount: 40, paragraphCount: 2, ogType: "article")
        let verdict = FocusClassification.classify(signals)
        #expect(verdict == nil || verdict!.confidence < FocusClassification.offerThreshold)
    }

    @Test("An undeclared page with an article element and prose still qualifies")
    func shapedLikeAnArticle() {
        let signals = FocusSignals(
            wordCount: 600, paragraphCount: 9, hasArticleElement: true
        )
        let verdict = FocusClassification.classify(signals)
        #expect(verdict?.kind == .article)
        #expect((verdict?.confidence ?? 0) >= FocusClassification.offerThreshold)
    }

    @Test("Plain prose with no markup help needs a lot of it")
    func bareProse() {
        let thin = FocusSignals(wordCount: 500, paragraphCount: 6)
        #expect(FocusClassification.classify(thin) == nil)

        let heavy = FocusSignals(wordCount: 1500, paragraphCount: 14)
        #expect(FocusClassification.classify(heavy)?.kind == .article)
    }

    /// A dashboard, a home page, a search screen: nothing to focus on.
    @Test("A page that is none of the kinds classifies as nothing")
    func nothing() {
        #expect(FocusClassification.classify(FocusSignals()) == nil)
    }

    /// Confident enough to offer — the tab additionally gates the offer on
    /// live media state, since the stage can only address a started video.
    @Test("A video page clears the offer threshold")
    func videoOffered() {
        let signals = FocusSignals(wordCount: 60, videoCount: 1)
        let verdict = FocusClassification.classify(signals)
        #expect(verdict?.kind == .video)
        #expect((verdict?.confidence ?? 0) >= FocusClassification.offerThreshold)
    }

    /// A prose page with an inline video is an article that happens to move.
    @Test("Prose beats an embedded video")
    func proseBeatsVideo() {
        let signals = FocusSignals(
            wordCount: 900, paragraphCount: 10, videoCount: 1
        )
        #expect(FocusClassification.classify(signals)?.kind == .article)
    }
}
