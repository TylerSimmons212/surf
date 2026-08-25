import Foundation

/// Where the Amazon lens looks for each thing it draws.
///
/// This is the one file that will go stale. Amazon changes its markup, A/B
/// tests two layouts at once, and spells the same hook two ways in two widget
/// versions — so every field is a *list* of candidates tried in order, and
/// the first that yields anything wins.
///
/// It lives in Swift, and crosses to the page as a call argument, for a
/// reason worth stating: it makes a selector change an edit to a Swift
/// constant with a test beside it, rather than an edit to a string of
/// JavaScript that nothing checks. The script that consumes this knows
/// nothing about Amazon at all — it is `querySelector` and a text walk, and
/// every piece of site knowledge in the feature is right here.
///
/// An entry is a CSS selector, optionally followed by `@` and an attribute
/// name to read instead of the element's text.
///
/// Two entries carry scars and should not be "simplified":
///
/// - `reviewCount` matches on the aria-label **ending** in "ratings". The
///   obvious `[aria-label*="rating"]` matches Amazon's rating popover
///   ("4.7 out of 5 stars, rating details") before it reaches the count link
///   ("87,229 ratings") — read as a number, that is 47 reviews for a product
///   with eighty-seven thousand.
/// - `delivery` is read through a text walk that skips `<script>` and
///   `<style>`, because Amazon puts an inline Prime-signup script inside the
///   delivery cell and `textContent` happily returns its source code.
public enum AmazonSelectors {

    // MARK: The results grid

    public static let card = "[data-component-type=\"s-search-result\"]"

    /// Amazon labels its own paid placements because it has to. That label is
    /// the only honest signal, and guessing which results are paid is a thing
    /// this lens should never do.
    public static let sponsored = [
        ".puis-sponsored-label-text",
        "[data-component-type=\"sp-sponsored-result\"]",
        "[aria-label=\"View Sponsored information\"]",
    ]

    public static let cardTitle = [
        "[data-cy=\"title-recipe\"] h2 span",
        "h2 span",
        "h2",
    ]
    public static let cardImage = ["img.s-image@src"]
    public static let cardPrices = [".a-price .a-offscreen"]
    public static let cardPriceText = ["[data-cy=\"price-recipe\"]"]
    public static let cardRating = [
        "[data-cy=\"reviews-ratings-slot\"]",
        "i.a-icon-star-small span.a-icon-alt",
        "a[aria-label*=\"out of 5 stars\"]@aria-label",
    ]
    /// See the note above. Ends-with, never contains.
    public static let cardReviews = [
        "a[aria-label$=\"ratings\"]@aria-label",
        "a[aria-label$=\"rating\"]@aria-label",
        "[data-cy=\"reviews-block\"] span.rush-component",
    ]
    public static let cardDelivery = ["[data-cy=\"delivery-recipe\"]"]
    /// Only Amazon's real placement badges. `s-pc-faceout-badge` is a
    /// sustainability tag ("Carbon impact") and is not what a shopper reads a
    /// badge as meaning.
    public static let cardBadge = [".a-badge-text"]

    // MARK: Whole-page markers

    /// "1-16 of over 70,000 results for …" — the positive evidence that this
    /// really is a results page that found things. Without it, an empty grid
    /// cannot be told from a broken parser.
    public static let resultBar = ["[data-component-type=\"s-result-info-bar\"]"]
    public static let noResults = [
        "[data-cel-widget*=\"NO_RESULTS\"]",
        ".s-no-results-result",
        "[data-component-type=\"s-no-results\"]",
    ]
    /// Never solved, only shown. See `AmazonBlock.botCheck`.
    public static let botCheck = [
        "form[action*=\"validateCaptcha\"]",
        "form[action*=\"/errors/validateCaptcha\"]",
    ]
    public static let signIn = ["input[type=\"password\"]"]

    // MARK: Amazon's own navigation, present on every page it serves

    public static let navCart = ["#nav-cart-count"]
    public static let navAccount = ["#nav-link-accountList-nav-line-1"]

    // MARK: The product page

    public static let productTitle = ["#productTitle"]
    public static let productByline = ["#bylineInfo"]
    public static let productPrices = [
        "#corePriceDisplay_desktop_feature_div .a-price .a-offscreen",
        "#corePrice_feature_div .a-price .a-offscreen",
        ".priceToPay .a-offscreen",
        "#price .a-offscreen",
    ]
    public static let productPriceText = [
        "#corePriceDisplay_desktop_feature_div",
        "#corePrice_feature_div",
    ]
    public static let productListPrice = [
        "#corePriceDisplay_desktop_feature_div .a-text-price .a-offscreen",
        ".basisPrice .a-offscreen",
    ]
    public static let productRating = [
        "#acrPopover@title",
        "[data-hook=\"rating-out-of-text\"]",
        "#averageCustomerReviews .a-icon-alt",
    ]
    public static let productReviews = [
        "#acrCustomerReviewText",
        "[data-hook=\"total-review-count\"]",
    ]
    public static let productAvailability = [
        "#availability span",
        "#availability",
        "#outOfStock",
    ]
    public static let productDelivery = [
        "#mir-layout-DELIVERY_BLOCK",
        "#deliveryBlockMessage",
        "#delivery-block-message",
    ]
    /// Who takes the money. `.offer-display-feature-text-message` is the one
    /// node holding only the value: the block around it repeats the label and
    /// the value three times over, so a text walk of the whole thing returns
    /// "Sold by AnkerDirect AnkerDirect Sold by AnkerDirect".
    public static let productSeller = [
        "#merchantInfoFeature_feature_div .offer-display-feature-text-message",
        "#sellerProfileTriggerId",
        "#merchant-info",
        "#tabular-buybox .tabular-buybox-text[tabular-attribute-name=\"Sold by\"]",
    ]
    /// Who actually posts it, which is a different question from who sold it
    /// — and the one that decides whose delivery estimate and whose returns
    /// desk you are relying on.
    public static let productShipsFrom = [
        "#fulfillerInfoFeature_feature_div .offer-display-feature-text-message",
        "#tabular-buybox .tabular-buybox-text[tabular-attribute-name=\"Ships from\"]",
    ]
    /// The returns headline only. The block behind it holds the full policy
    /// as popover prose, and the link's own text is the summary.
    public static let productReturns = [
        "#freeReturns_feature_div a.a-popover-trigger",
        "#freeReturns_feature_div .celwidget",
        "#tabular-buybox .tabular-buybox-text[tabular-attribute-name=\"Returns\"]",
        "#creturns-return-policy-message",
    ]
    /// Presence, not text. The badge's own element carries its explanatory
    /// tooltip as a child, so reading it yields "Amazon's Choice highlights
    /// highly rated, well-priced products…" — a paragraph where a chip
    /// belongs. What the badge says is a constant; whether it is there is the
    /// only question worth asking the page.
    public static let productChoiceBadge = ["#acBadge_feature_div"]
    /// "10K+ bought in past month" — Amazon's own count, not a claim of ours.
    public static let productBought = [
        "#socialProofingAsinFaceout_feature_div",
        "[id*=\"social-proofing\"]",
    ]
    public static let productImages = [
        "#altImages img@src",
        "#imageBlock img@src",
        "#landingImage@src",
    ]
    public static let productBullets = [
        "#feature-bullets li span.a-list-item",
        "#featurebullets_feature_div li span",
    ]
    /// The page decides whether there is a button. Our chrome never draws one
    /// the page does not have, and never a disabled one.
    public static let productAddToCart = ["#add-to-cart-button:not([disabled])"]
    /// The quantity selector, read for how many it actually offers.
    public static let productQuantity = ["#quantity", "#selectQuantity select"]

    // MARK: Specification rows

    /// Amazon's own curated overview — four or five rows it considers the
    /// ones that matter. Read separately from the full sheet because that is
    /// exactly the key-spec summary Baymard finds on 3% of sites, already
    /// chosen for us. On many products this table is populated and the full
    /// technical sheet is empty; on others the reverse.
    public static let keySpecRow = ["#productOverview_feature_div tr"]

    public static let specRow = [
        "#productDetails_techSpec_section_1 tr",
        "#technicalSpecifications_section_1 tr",
        "#productDetails_detailBullets_sections1 tr",
    ]
    public static let specLabel = ["th", "td:first-child", ".a-span3"]
    public static let specValue = ["td:last-child", ".a-span9"]

    // MARK: Variations

    public static let variationRow = ["[id^=\"inline-twister-row-\"]"]
    /// The row's own id carries the dimension: `inline-twister-row-size_name`.
    /// The prefix comes off in Swift, in `AmazonVariationWire.dimensionName`.
    public static let variationID = ["@id"]
    /// "Size:", "Color:", "Number of Items:" — the dimension's own heading.
    /// `.a-form-label` is the documented one and matches nothing on the
    /// inline twister, which is what ships today.
    public static let variationLabel = [
        ".dimension-text",
        ".a-form-label",
        ".twisterTextDiv",
        "label",
    ]
    /// The value currently chosen, which the row prints in bold beside its
    /// heading.
    public static let variationSelected = [
        "span.a-text-bold",
        ".selection",
        "[data-defaultasin] .a-button-selected .a-button-text",
    ]
    public static let variationOption = ["li[data-asin]", "li[data-defaultasin]"]
    /// What a swatch is called.
    ///
    /// There is deliberately no bare `span` here any more. A colour swatch is
    /// a picture, so its name lives in the image's alt text — and falling
    /// through to `span` picked up the whole option, which on this page is a
    /// buy-box block. The lens rendered "$9.99 $9.99 $5.00 per count ( $5.00
    /// $5.00 / count) In Stock" as the name of a colour.
    public static let variationOptionValue = [
        ".swatch-title-text-display",
        "img.swatch-image@alt",
        "img@alt",
        ".a-button-text .a-truncate-full",
    ]
    public static let variationOptionASIN = ["@data-asin", "@data-defaultasin"]
    /// What each variation costs, where Amazon prints it on the swatch. This
    /// is the one place a shopper can see that black is $9.99 and red is
    /// $12.99 without opening both — which is exactly the comparison this
    /// lens exists to make easier.
    public static let variationOptionPrice = [
        ".swatch-text",
        "[class*=\"apex_on_twister\"]",
    ]

    // MARK: Reviews

    public static let reviewRow = ["[data-hook=\"review\"]"]
    public static let reviewID = ["@id"]
    public static let reviewStars = [
        "[data-hook=\"review-star-rating\"] .a-icon-alt",
        "[data-hook=\"cmps-review-star-rating\"] .a-icon-alt",
        "i.a-icon-star .a-icon-alt",
    ]
    /// Both spellings, because Amazon ships both. This page used the camel
    /// case one; the documented one is hyphenated.
    /// Bare first. `span:last-child` looks more precise and matches nothing
    /// on either page tested — the title is the hook's own text.
    public static let reviewTitle = [
        "[data-hook=\"reviewTitle\"]",
        "[data-hook=\"review-title\"]",
        "[data-hook=\"review-title\"] span:last-child",
        "[data-hook=\"reviewTitle\"] span:last-child",
    ]
    public static let reviewAuthor = [".a-profile-name"]
    public static let reviewDate = ["[data-hook=\"review-date\"]"]
    public static let reviewVerified = ["[data-hook=\"avp-badge\"]"]
    /// The inner span, not the container: the container also holds the
    /// expander and the vote widget, and every one of their pre-rendered
    /// states comes back as text. `AmazonReview.strip` cleans what still
    /// gets through.
    public static let reviewBody = [
        "[data-hook=\"reviewText\"] span",
        "[data-hook=\"review-body\"] span",
        "[data-hook=\"reviewText\"]",
        "[data-hook=\"review-body\"]",
    ]
    public static let reviewHelpful = ["[data-hook=\"helpful-vote-statement\"]"]
    public static let reviewVariation = [
        "[data-hook=\"format-strip\"]",
        ".review-format-strip",
    ]

    /// The distribution.
    ///
    /// The aria-label first, and it is not a fallback — it is the only one
    /// that reliably yields one row per star. The visible rows nest such that
    /// a single `li` can contain all five percentages, which reads as "5 star
    /// 82% 10% 3% 1% 4%" and produces a chart of nothing. Verified on two
    /// products: the aria form gave five exact rows on both.
    public static let histogramRow = [
        "a[aria-label*=\"percent of reviews\"]@aria-label",
        "#histogramTable tr",
        "[data-hook=\"cr-filter-info-histogram\"] li",
        "#cm_cr_dp_d_rating_histogram ul li",
    ]

    /// The whole table, in the shape the page script consumes. Crossing as a
    /// call argument rather than being baked into the script is what keeps
    /// every piece of site knowledge on this side of the bridge.
    public static var payload: [String: Any] {
        [
            "card": card,
            "sponsored": sponsored,
            "cardTitle": cardTitle,
            "cardImage": cardImage,
            "cardPrices": cardPrices,
            "cardPriceText": cardPriceText,
            "cardRating": cardRating,
            "cardReviews": cardReviews,
            "cardDelivery": cardDelivery,
            "cardBadge": cardBadge,
            "resultBar": resultBar,
            "noResults": noResults,
            "botCheck": botCheck,
            "signIn": signIn,
            "navCart": navCart,
            "navAccount": navAccount,
            "productTitle": productTitle,
            "productByline": productByline,
            "productPrices": productPrices,
            "productPriceText": productPriceText,
            "productListPrice": productListPrice,
            "productRating": productRating,
            "productReviews": productReviews,
            "productAvailability": productAvailability,
            "productDelivery": productDelivery,
            "productSeller": productSeller,
            "productImages": productImages,
            "productBullets": productBullets,
            "productAddToCart": productAddToCart,
            "productQuantity": productQuantity,
            "variationOptionPrice": variationOptionPrice,
            "productBought": productBought,
            "productChoiceBadge": productChoiceBadge,
            "productReturns": productReturns,
            "productShipsFrom": productShipsFrom,
            "specRow": specRow,
            "keySpecRow": keySpecRow,
            "specLabel": specLabel,
            "specValue": specValue,
            "variationRow": variationRow,
            "variationID": variationID,
            "variationLabel": variationLabel,
            "variationSelected": variationSelected,
            "variationOption": variationOption,
            "variationOptionValue": variationOptionValue,
            "variationOptionASIN": variationOptionASIN,
            "reviewRow": reviewRow,
            "reviewID": reviewID,
            "reviewStars": reviewStars,
            "reviewTitle": reviewTitle,
            "reviewAuthor": reviewAuthor,
            "reviewDate": reviewDate,
            "reviewVerified": reviewVerified,
            "reviewBody": reviewBody,
            "reviewHelpful": reviewHelpful,
            "reviewVariation": reviewVariation,
            "histogramRow": histogramRow,
        ]
    }
}
