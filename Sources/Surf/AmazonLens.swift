import Foundation
import SurfCore

/// The Amazon lens's state, and the navigation that drives it.
///
/// Shaped after `YouTubeLens`, and different in the two places Amazon is
/// genuinely a different problem.
///
/// The first is that `loading` remembers where it was going. YouTube hands
/// back the address you asked for, so re-deriving everything from the URL
/// after the fact works. Amazon redirects — between marketplaces, from a
/// product id to its canonical twin, to a sign-in wall, and to a bot check
/// served at the address you requested. Without the destination recorded,
/// none of that is detectable, and the lens would confidently report "nothing
/// came back" for a page it was never shown.
///
/// The second is that this one writes. Everything the YouTube lens can do
/// wrong is cosmetic; this one can put the wrong thing in someone's cart. So
/// the write path is deliberately narrow: one in flight at a time, refused
/// outright when the product on screen and the document underneath disagree,
/// and confirmed by watching the page rather than by trusting a return value.
@MainActor
@Observable
final class AmazonLens {

    enum Phase: Equatable {
        /// The blank: one search field and nothing else. This is the front
        /// page too — a focused Amazon has no deals rail by design.
        case searching
        case loading(AmazonDestination)
        case results
        case product
        /// Amazon genuinely found nothing, positively identified.
        case empty(query: String)
        /// The lens has to get out of the way. See `AmazonBlock`.
        case blocked(AmazonBlock)
        /// We could not read a page we should have been able to, and trying
        /// again is reasonable.
        case failed(String)
    }

    private(set) var phase: Phase = .searching

    /// What is in the field, re-filled from the address when a results page
    /// loads so it says what the grid is showing rather than what was typed.
    var query = ""

    private(set) var results: [AmazonResult] = []
    private(set) var product: AmazonProduct?
    private(set) var reviews: [AmazonReview] = []
    private(set) var histogram: AmazonHistogram?

    /// Amazon's own navigation, which it renders into every page it serves.
    private(set) var cart = CartBadge()
    private(set) var account = ""

    /// The product a write is in flight for, or nil. One at a time, keyed to
    /// the id, because a click resolves instantly while the request behind it
    /// lands a second or two later — and two adds is a bug that costs money.
    private(set) var addingToCart: String?

    // MARK: - The cart

    /// The cart's contents, held here rather than in `phase` for the same
    /// reason the results are: closing the sidebar must not cost a read, and
    /// reopening it should show what was there while the fresh one loads.
    private(set) var cartContents: AmazonCart?
    private(set) var isCartOpen = false
    private(set) var isReadingCart = false
    /// The line a write is in flight against. One at a time, and named rather
    /// than a bool so the row that is changing can say so and the others stay
    /// pressable.
    private(set) var writingLine: String?
    /// Where to go back to when the sidebar closes. The cart is a real
    /// navigation — Amazon's cart lives at a URL like everything else — so
    /// opening it leaves the page the user was on, and closing it has to
    /// return them.
    private var whereWeWere: URL?
    private var cartReadTask: Task<Void, Never>?

    /// The variation being navigated to, if one is.
    ///
    /// A swatch is a page load, not a toggle, and pretending otherwise leaves
    /// the row looking inert for a second while the whole product is
    /// replaced underneath it. Users stall verifying that a selector heard
    /// them before they will press a buy button, so the row says so.
    var pendingVariation: String? {
        if case .loading(.product(let asin)) = phase, product != nil { return asin }
        return nil
    }

    private weak var tab: Tab?
    private var readTask: Task<Void, Never>?
    private var cartTask: Task<Void, Never>?

    init(tab: Tab) {
        self.tab = tab
    }

    // MARK: - What the view asks for

    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = AmazonPage.searchURL(for: trimmed), let tab else { return }
        query = trimmed
        phase = .loading(.search(query: trimmed))
        tab.loadInSiteLens(url)
    }

    func open(_ result: AmazonResult) {
        open(asin: result.id)
    }

    /// Choosing a variation. A different size is a different product with a
    /// different price, which means a navigation — not a picker over local
    /// state, however much it looks like one.
    func choose(_ option: AmazonVariationOption) {
        // An option with no id of its own is the one already on screen.
        guard !option.asin.isEmpty, option.asin != product?.id else { return }
        open(asin: option.asin)
    }

    private func open(asin: String) {
        guard let url = AmazonPage.productURL(asin: asin), let tab else { return }
        // What survives the switch and what must not. A stale title and
        // gallery are nearly right and worth keeping so the page doesn't
        // flash white; a stale price, delivery date or seller is dangerous,
        // and those go immediately.
        product = product.map { previous in
            var carried = previous
            carried.id = asin
            carried.price = nil
            carried.listPrice = nil
            carried.availability = ""
            carried.delivery = ""
            carried.seller = ""
            carried.canAddToCart = false
            return carried
        }
        reviews = []
        histogram = nil
        phase = .loading(.product(asin: asin))
        tab.loadInSiteLens(url)
    }

    /// Back to the grid — free, because the results never left memory.
    func showResults() {
        phase = results.isEmpty ? .searching : .results
    }

    func startOver() {
        results = []
        product = nil
        query = ""
        phase = .searching
    }

    /// Hand the page back. Every route out of the lens ends here: checkout,
    /// sign-in, order history, a bot check, and any page we cannot read.
    func handBackToAmazon() {
        tab?.exitSiteFocus()
    }

    /// Go to a page on the real site, out of the lens. Used for the controls
    /// this lens deliberately does not implement.
    func handBack(to url: URL?) {
        guard let tab else { return }
        if let url { tab.loadInSiteLens(url) }
        tab.exitSiteFocus()
    }

    // MARK: - The one thing that writes

    /// Adds the product on screen to the cart, by pressing Amazon's own
    /// button.
    ///
    /// Three guards, and each is here because of a specific way this goes
    /// wrong. The page must have a button — we never draw one it doesn't
    /// have, and never a dead one. Only one write may be in flight — a click
    /// returns before the request lands, and an impatient second press is a
    /// second item. And the product on screen must be the product the
    /// document is showing, because the display is cached across navigations
    /// and the document is not.
    func addToCart(quantity: Int = 1) {
        guard let tab, let product, product.canAddToCart else { return }
        guard addingToCart == nil else { return }
        guard AmazonPage.of(tab.currentSiteLensURL).productASIN == product.id else {
            debugLog("amazon: refusing to add \(product.id) — the page is elsewhere")
            return
        }

        addingToCart = product.id
        cartTask?.cancel()
        cartTask = Task { @MainActor in
            let clicked = await tab.amazonAddToCart(quantity: quantity)
            guard !Task.isCancelled else { return }
            guard clicked else {
                addingToCart = nil
                return
            }
            // Optimism, then evidence. The badge says what we expect until
            // the page agrees, and stops claiming to know if it never does.
            let expected = cart.assuming(added: quantity)
            cart = expected
            for delay in [400, 900, 1600] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                guard let nav = await tab.amazonNav() else { continue }
                let observed = cart.observing(nav.cartCount)
                if observed.confidence == .observed, observed.count != expected.count - quantity {
                    cart = observed
                    addingToCart = nil
                    debugLog("amazon: cart is \(observed.count)")
                    return
                }
            }
            guard !Task.isCancelled else { return }
            cart = cart.givingUp()
            addingToCart = nil
            debugLog("amazon: cart never confirmed — badge is no longer claiming a number")
        }
    }

    /// Opens the cart, which means going to it.
    ///
    /// The lens renders natively, so what the web view is showing underneath
    /// does not have to match what is on screen — but the cart can only be
    /// *read* from the cart page, and reading it is the whole point. So the
    /// sidebar opens over whatever native screen is up, the document navigates
    /// behind it, and closing puts the document back.
    func openCart() {
        guard let tab, !isCartOpen else { return }
        isCartOpen = true
        whereWeWere = tab.currentSiteLensURL
        loadCart(navigating: true)
    }

    func closeCart() {
        guard isCartOpen else { return }
        isCartOpen = false
        cartReadTask?.cancel()
        isReadingCart = false
        // Back where they were. A cart you close should not leave you standing
        // somewhere you did not ask to be.
        if let tab, let back = whereWeWere,
           AmazonPage.of(tab.currentSiteLensURL).isCart {
            tab.loadInSiteLens(back)
        }
        whereWeWere = nil
    }

    /// Reads the cart, navigating there first when we are not already on it.
    private func loadCart(navigating: Bool) {
        guard let tab else { return }
        cartReadTask?.cancel()
        isReadingCart = true
        cartReadTask = Task { @MainActor in
            if navigating, !AmazonPage.of(tab.currentSiteLensURL).isCart {
                guard let destination = AmazonPage.cartURL else { return }
                tab.loadInSiteLens(destination)
                // The read waits for the document. `documentDidLoad` will call
                // back in when it arrives; this ladder is for the case where
                // the page was already there or the load resolves quickly.
            }
            for delay in [0, 400, 1000, 2000] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard !Task.isCancelled else { return }
                guard AmazonPage.of(tab.currentSiteLensURL).isCart else { continue }
                guard let reply = await tab.amazonCart() else { continue }
                guard !Task.isCancelled else { return }
                let parsed = reply.parsed
                // An empty read while Amazon's own badge says otherwise is a
                // page that has not finished drawing, not an empty cart. Taken
                // at face value it ends the ladder on nothing — which it did,
                // and only `documentDidLoad` firing afterwards rescued it.
                // A cart that really is empty has a badge saying zero and
                // still lands here.
                if parsed.isEmpty, let badge = AmazonRating.count(reply.cartCount ?? ""),
                   badge > 0, delay != 2000 {
                    continue
                }
                cartContents = parsed
                cart = cart.observing(reply.cartCount)
                isReadingCart = false
                debugLog("""
                    amazon: cart \(parsed.items.count) lines, \
                    \(parsed.countedUnits) units, \
                    subtotal \(parsed.subtotal?.display ?? "—")
                    """)
                return
            }
            guard !Task.isCancelled else { return }
            isReadingCart = false
        }
    }

    /// Changes one line's quantity, or takes it out, by pressing Amazon's own
    /// control.
    ///
    /// Every guard here answers a specific way this costs somebody money.
    ///
    /// The line has to be one we are currently showing, addressed by Amazon's
    /// own item id — never by ASIN, because one product in two variations is
    /// two lines sharing one, and a write addressed by ASIN changes whichever
    /// came back first.
    ///
    /// Only one write at a time, because a click returns long before the
    /// request lands and an impatient second press is a second change.
    ///
    /// The document has to still be the cart. The contents are cached for the
    /// sidebar and the document is not, so a stale line addressed against a
    /// page that has moved on is a write into the dark.
    ///
    /// And decrement is refused at the floor, which is the one that is not
    /// obvious: Amazon replaces its own minus with a *delete* once the
    /// quantity reaches the minimum. Wired straight through, "one less" would
    /// remove the line. `AmazonSelectors.cartDecrement` refuses it a second
    /// time by matching only a real decrease control, which does not exist
    /// there to be matched.
    func changeLine(_ item: AmazonCartItem, _ action: AmazonCartAction) {
        guard let tab, writingLine == nil else { return }
        guard cartContents?.item(id: item.id) != nil else { return }
        guard AmazonPage.of(tab.currentSiteLensURL).isCart else {
            debugLog("amazon: refusing a cart write — the page is elsewhere")
            return
        }
        if action == .decrement, !item.canDecrement {
            debugLog("amazon: refusing to decrement \(item.id) at its floor — that button deletes")
            return
        }

        writingLine = item.id
        cartReadTask?.cancel()
        cartReadTask = Task { @MainActor in
            let outcome = await tab.amazonCartWrite(itemID: item.id, action: action.rawValue)
            guard !Task.isCancelled else { return }
            guard outcome == "pressed" else {
                writingLine = nil
                debugLog("amazon: \(action.rawValue) on \(item.id) — \(outcome)")
                // The row has gone from under us. Whatever the sidebar is
                // showing is a cart that no longer exists, so re-read it
                // rather than leave a list nothing can act on.
                if outcome == "no-row" { loadCart(navigating: false) }
                return
            }
            // Observed, never assumed. Amazon rewrites the row asynchronously,
            // so the cart is read again until it disagrees with what it said
            // before — which is what "the write landed" actually looks like.
            for delay in [500, 1100, 2000, 3000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                guard let reply = await tab.amazonCart() else { continue }
                let parsed = reply.parsed
                if parsed.lostLine(item, underDecrement: action == .decrement) {
                    // Both guards failed and Amazon's minus deleted the line.
                    // Loud, because this is the failure the whole design is
                    // arranged around.
                    cartContents = parsed
                    cart = cart.observing(reply.cartCount)
                    writingLine = nil
                    debugLog("amazon: DECREMENT REMOVED \(item.id) — the floor guard did not hold")
                    return
                }
                guard parsed.reflects(action, on: item) else { continue }
                cartContents = parsed
                cart = cart.observing(reply.cartCount)
                writingLine = nil
                debugLog("amazon: \(action.rawValue) landed — \(parsed.countedUnits) units")
                return
            }
            guard !Task.isCancelled else { return }
            // The page never changed. Re-read once so the sidebar shows what
            // Amazon actually holds rather than what we hoped for.
            if let reply = await tab.amazonCart() { cartContents = reply.parsed }
            writingLine = nil
            debugLog("amazon: \(action.rawValue) on \(item.id) never took effect")
        }
    }

    // MARK: - What the tab tells it

    func documentWillChange() {
        readTask?.cancel()
    }

    func documentDidLoad() {
        // The cart arriving is not a change of screen. The sidebar is over
        // whatever was already up, and reconciling would move the lens off it
        // — so the cart is read and the phase is left alone.
        if isCartOpen, AmazonPage.of(tab?.currentSiteLensURL).isCart {
            loadCart(navigating: false)
            return
        }
        readTask?.cancel()
        let destination = expectation
        readTask = Task { @MainActor in
            await read(expecting: destination)
        }
    }

    func tearDown() {
        readTask?.cancel()
        readTask = nil
        cartTask?.cancel()
        cartTask = nil
        cartReadTask?.cancel()
        cartReadTask = nil
        isCartOpen = false
        writingLine = nil
    }

    /// Where the lens believes it is going, for the reconciler to compare
    /// against where it actually landed.
    private var expectation: AmazonDestination {
        if case .loading(let destination) = phase { return destination }
        return .whatever
    }

    // MARK: - Reading the page

    /// Reads, with a retry ladder, and knows when not to retry.
    ///
    /// Amazon renders its results server-side, so the first read usually
    /// works — but a redirect or an interstitial can land us mid-flight, and
    /// an empty grid is the one failure a user cannot tell from a broken
    /// feature.
    private func read(expecting destination: AmazonDestination) async {
        for delay in [0, 350, 800, 1600] {
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled, let tab else { return }

            let reply = await tab.amazonRead()
            guard !Task.isCancelled else { return }
            absorbNav(reply)

            let reading = AmazonReconcile.read(
                expected: destination, url: tab.currentSiteLensURL, reply: reply
            )
            switch reading {
            case .notReady:
                continue
            case .blocked(let block):
                // Never retried, and the bot check is the reason. Reading a
                // wall three times is how you convince Amazon it was right
                // about you.
                apply(block)
                return
            case .results(let found):
                results = found
                query = AmazonPage.of(tab.currentSiteLensURL).searchQuery ?? query
                phase = .results
                report(reply, expecting: Self.gridSelectors,
                       "\(found.count) results for \u{201C}\(query)\u{201D}")
                return
            case .product(let found):
                product = found
                reviews = reply?.parsedReviews ?? []
                histogram = reply?.parsedHistogram
                phase = .product
                report(reply, expecting: Self.productSelectors, """
                    \(found.title) — \(found.pictures.count) pictures, \
                    \(found.highlights.count) highlights, \
                    \(found.keySpecs.count)+\(found.remainingSpecs.count) specs, \
                    \(reviews.count) reviews, \
                    max qty \(found.quantityMax), \
                    \(found.price?.display ?? "no price")\
                    \(found.unitPrice.map { " (\($0))" } ?? "")\
                    \(found.listPrice.map { " was \($0.display)" } ?? "")\
                    \(found.savingsPercent.map { percent in
                        " save \(found.savingsAmount?.display ?? "?")/\(percent)%"
                    } ?? ""), \
                    variations [\(found.variations.map {
                        "\($0.label)=\($0.options.count)"
                    }.joined(separator: " "))], \
                    \(found.isAmazonsChoice ? "Choice, " : "")\
                    \(found.boughtRecently.isEmpty ? "" : found.boughtRecently + ", ")\
                    sold by \(found.seller.isEmpty ? "?" : found.seller)/\
                    ships \(found.shipsFrom.isEmpty ? "?" : found.shipsFrom), \
                    \(found.returnsPolicy.isEmpty ? "no returns line" : found.returnsPolicy), \
                    delivery \(found.deliveryBenefit)\
                    \(found.deliveryTime.isEmpty ? "" : " " + found.deliveryTime)\
                    \(found.deliveryPrice.isEmpty ? "" : " " + found.deliveryPrice), \
                    swatch prices \(found.variations.flatMap { $0.options }
                        .compactMap(\.price).joined(separator: "/"))
                    """)
                return
            case .noResults(let text):
                query = text
                results = []
                phase = .empty(query: text)
                return
            }
        }
        guard !Task.isCancelled else { return }
        // The ladder ran out with the page never resolving into anything.
        // Distinct from `blocked`: this is worth trying again.
        phase = .failed("Amazon didn\u{2019}t finish loading that.")
        debugLog("amazon: gave up reading \(tab?.currentSiteLensURL?.path ?? "?")")
    }

    private func apply(_ block: AmazonBlock) {
        phase = .blocked(block)
        switch block {
        case .botCheck:
            debugLog("amazon: bot check — handing the page back")
        case .signIn:
            debugLog("amazon: sign-in wall — handing the page back")
        case .unsupported:
            debugLog("amazon: no lens for this page")
        case .cannotRead:
            debugLog("amazon: page did not meet quorum — handing it back")
        }
    }

    /// The cart count and the account name ride along with every read,
    /// because Amazon renders them into every page it serves.
    private func absorbNav(_ reply: AmazonPageReply?) {
        guard let nav = reply?.nav else { return }
        cart = cart.observing(nav.cartCount)
        let name = AmazonText.tidy(nav.account ?? "")
        if !name.isEmpty { account = name }
    }

    /// The fields each kind of page is expected to have. Asked separately,
    /// because a search page has no product on it and a canary that reports
    /// the product selectors missing every time you search is a canary
    /// everyone learns to ignore.
    private static let gridSelectors =
        ["cardTitle", "cardPrices", "cardRating", "cardReviews", "cardImage"]
    private static let productSelectors =
        ["productTitle", "productPrices", "productImages"]

    /// The canary. A selector that stopped matching says so here, by name,
    /// rather than rendering as a blank nobody notices until someone
    /// complains that the grid has no prices.
    private func report(
        _ reply: AmazonPageReply?, expecting expected: [String], _ summary: String
    ) {
        guard let matches = reply?.matches, !matches.isEmpty else {
            debugLog("amazon: \(summary)")
            return
        }
        let quiet = expected.filter { matches[$0] == nil }
        if quiet.isEmpty {
            debugLog("amazon: \(summary)")
        } else {
            debugLog("amazon: \(summary) — no matches for \(quiet.joined(separator: ", "))")
        }
    }
}
