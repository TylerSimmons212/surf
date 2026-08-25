import SurfCore
import SwiftUI

/// The Amazon lens's face: a field, a grid, and a product.
///
/// The chrome — search, cart, close — is a shell around every screen rather
/// than something each screen draws. It has to appear on all of them, and
/// four copies of a cart count is four chances for three of them to be stale.
struct AmazonLensView: View {
    let tab: Tab
    @Bindable var lens: AmazonLens

    /// Hover effects are suppressed mid-scroll. Recomputing sixteen hover
    /// states per frame is most of what a grid that "isn't smooth" is.
    @State private var isScrolling = false

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)

            switch lens.phase {
            case .searching:
                openingScreen
            case .loading:
                loadingScreen
            case .results:
                resultsScreen
            case .product:
                AmazonProductView(lens: lens)
                    .overlay(alignment: .top) { searchBar }
                    .overlay(alignment: .topTrailing) { corner }
            case .empty(let query):
                emptyScreen(query)
            case .blocked(let block):
                handoffScreen(block)
            case .failed(let message):
                failureScreen(message)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lens.phase)
        // Over every screen rather than inside one. A cart is something you
        // glance at on the way to deciding something else, and a screen of its
        // own would mean leaving the product to look at it.
        .overlay {
            if lens.isCartOpen {
                AmazonCartSidebar(lens: lens)
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .animation(.easeOut(duration: 0.22), value: lens.isCartOpen)
    }

    // MARK: - The opening: one field, and no deals rail

    private var openingScreen: some View {
        VStack(spacing: 22) {
            SiteMark(site: .amazon, height: 30)
            AmazonSearchField(lens: lens, isLarge: true)
                .frame(maxWidth: 620)
            Text("Search Amazon")
                .font(Typeface.figtree(size: 12, weight: 500))
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { corner }
    }

    private var loadingScreen: some View {
        VStack(spacing: 18) { ProgressView().controlSize(.large) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { searchBar }
            .overlay(alignment: .topTrailing) { corner }
    }

    // MARK: - The grid

    private var resultsScreen: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 22)],
                spacing: 30
            ) {
                ForEach(lens.results) { result in
                    AmazonResultCard(result: result, isScrolling: isScrolling) {
                        lens.open(result)
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 44)
            .padding(.top, 96)
        }
        .onScrollPhaseChange { _, phase in isScrolling = phase != .idle }
        .overlay(alignment: .top) {
            // Eight points taller than the grid's inset, so content dissolves
            // under the bar rather than being sliced by it.
            LinearGradient(
                colors: [Color(nsColor: .textBackgroundColor),
                         Color(nsColor: .textBackgroundColor).opacity(0)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 104)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .top) { searchBar }
        .overlay(alignment: .topTrailing) { corner }
    }

    // MARK: - Nothing found, which is different from something broken

    private func emptyScreen(_ query: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Nothing for \u{201C}\(query)\u{201D}")
                .font(.title3.weight(.medium))
            Text("Amazon had only sponsored listings for that search.")
                .font(Typeface.figtree(size: 12, weight: 400))
                .foregroundStyle(.tertiary)
            Button("Search Again") { lens.startOver() }
                .buttonStyle(.glassProminent)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { searchBar }
        .overlay(alignment: .topTrailing) { corner }
    }

    // MARK: - Getting out of the way

    /// The screen that hands the page back.
    ///
    /// It apologises for nothing and offers no retry, because in every case
    /// that lands here Amazon's own page works perfectly well and this lens
    /// is the thing in the way. The one button leaves.
    private func handoffScreen(_ block: AmazonBlock) -> some View {
        VStack(spacing: 14) {
            Image(systemName: block.symbol)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(block.headline)
                .font(.title3.weight(.medium))
            Text(block.detail)
                .font(Typeface.figtree(size: 12, weight: 400))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Show the Amazon Page") { lens.handBackToAmazon() }
                .buttonStyle(.glassProminent)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { corner }
    }

    private func failureScreen(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.trianglehead.clockwise")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.title3.weight(.medium))
            Button("Search Again") { lens.startOver() }
                .buttonStyle(.glassProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { searchBar }
        .overlay(alignment: .topTrailing) { corner }
    }

    // MARK: - The shell

    private var searchBar: some View {
        AmazonSearchField(lens: lens, isLarge: false)
            .frame(maxWidth: 560)
            .padding(.top, 16)
    }

    /// Cart and close. Orders and account are not here: they are pages behind
    /// a password, and this lens hands those back rather than framing them.
    private var corner: some View {
        HStack(spacing: 6) {
            AmazonCartBadge(cart: lens.cart) { lens.openCart() }
            IconButton(
                systemName: "xmark",
                size: 11, weight: .bold, width: 26, height: 26, cornerRadius: 8,
                help: "Leave Focus (\u{21E7}\u{2318}F)"
            ) { tab.exitFocus() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .padding(.top, 16)
        .padding(.trailing, 16)
    }
}

// MARK: - The cart badge

/// What the lens believes is in the cart, drawn only as confidently as it
/// actually knows.
///
/// When a write went out and the page never agreed, the number stops being
/// shown. A count that is confidently wrong about someone's cart is the worst
/// thing this feature can put on screen, and a dash is not worse than that.
private struct AmazonCartBadge: View {
    let cart: CartBadge
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: "cart")
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(cart.isTrustworthy ? .primary : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(cart.isTrustworthy ? "Cart on Amazon" : "Cart — count unconfirmed")
    }

    private var label: String {
        cart.isTrustworthy ? "\(cart.count)" : "\u{2013}"
    }
}

// MARK: - The field

private struct AmazonSearchField: View {
    @Bindable var lens: AmazonLens
    var isLarge: Bool

    @State private var text = ""
    @State private var focusToken = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: isLarge ? 16 : 13, weight: .medium))
                .foregroundStyle(.secondary)

            SurfTextField(
                text: $text,
                placeholder: "Search Amazon",
                font: .systemFont(ofSize: isLarge ? 18 : 14, weight: .regular),
                focusToken: focusToken,
                onSubmit: { lens.search(text) }
            )
            .frame(height: isLarge ? 26 : 22)

            if !text.isEmpty {
                IconButton(
                    systemName: "xmark.circle.fill",
                    size: 13, width: 20, height: 20, cornerRadius: 10, help: "Clear"
                ) {
                    text = ""
                    focusToken += 1
                }
            }
        }
        .padding(.horizontal, isLarge ? 20 : 16)
        .padding(.vertical, isLarge ? 15 : 11)
        .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        .onAppear { text = lens.query }
        .onChange(of: lens.query) { _, query in if query != text { text = query } }
    }
}

// MARK: - One product in the grid

private struct AmazonResultCard: View {
    let result: AmazonResult
    let isScrolling: Bool
    let open: () -> Void

    @State private var isHovering = false
    private var showsHover: Bool { isHovering && !isScrolling }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                picture
                metadata
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(showsHover ? 1.02 : 1)
        .animation(.easeOut(duration: 0.16), value: showsHover)
        .onHover { isHovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// On a plate, and fitted rather than filled. Sellers photograph products
    /// in whatever proportion they like, on white — cropping one to a fixed
    /// frame cuts the shoes off the shoes.
    private var picture: some View {
        ThumbnailImage(
            address: result.imageURL(width: 679),
            maxPixel: 680,
            contentMode: .fit
        )
        .padding(14)
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .background(Color.white)
        .overlay(alignment: .topLeading) { badge }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(showsHover ? 0.20 : 0.08))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var badge: some View {
        if !result.badge.isEmpty {
            Text(result.badge)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Color(red: 0.13, green: 0.36, blue: 0.68),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .padding(7)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.title)
                .font(Typeface.figtree(size: 13.5, weight: 500))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                // A fixed two-line box, so every card's price sits on the
                // same line however long its title runs.
                .frame(height: 36, alignment: .topLeading)

            if let stars = result.stars {
                AmazonStars(stars: stars, count: result.reviewCount)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let price = result.price {
                    Text(price.display)
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                if let unit = result.unitPrice {
                    Text(unit)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            if !result.delivery.isEmpty {
                Text(result.delivery)
                    .font(Typeface.figtree(size: 11, weight: 400))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Stars

struct AmazonStars: View {
    let stars: Double
    var count: Int?
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: symbol(at: index))
                        .font(.system(size: size))
                        .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
                }
            }
            if let count {
                Text(AmazonStars.compact(count))
                    .font(.system(size: size).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        // Five glyphs and an abbreviation are a picture of a rating, not a
        // reading of one. Read out one at a time they are gibberish, so the
        // row speaks as a single sentence instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AmazonStars.spoken(stars: stars, count: count))
    }

    /// "4.7 out of 5, 87,229 ratings".
    static func spoken(stars: Double, count: Int?) -> String {
        let rating = String(format: "%.1f", stars)
        guard let count else { return "\(rating) out of 5" }
        return "\(rating) out of 5, \(count.formatted()) ratings"
    }

    private func symbol(at index: Int) -> String {
        let filled = stars - Double(index)
        if filled >= 0.75 { return "star.fill" }
        if filled >= 0.25 { return "star.leadinghalf.filled" }
        return "star"
    }

    /// "87,229" is four characters too many under a card. Amazon compacts its
    /// own counts on the grid for the same reason.
    static func compact(_ count: Int) -> String {
        switch count {
        case 1_000_000...:
            return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(count) / 1_000)
        default:
            return "\(count)"
        }
    }
}

// MARK: - What a block says out loud

private extension AmazonBlock {
    var symbol: String {
        switch self {
        case .botCheck: return "hand.raised"
        case .signIn: return "lock"
        case .unsupported: return "arrow.up.forward.square"
        case .cannotRead: return "eye.trianglebadge.exclamationmark"
        }
    }

    var headline: String {
        switch self {
        case .botCheck: return "Amazon wants to check you\u{2019}re a person"
        case .signIn: return "This one needs your Amazon account"
        case .unsupported: return "This page is outside the lens"
        case .cannotRead: return "This page didn\u{2019}t read cleanly"
        }
    }

    var detail: String {
        switch self {
        case .botCheck:
            return "Surf won\u{2019}t answer it for you. The real page is right behind this."
        case .signIn:
            return "Signing in happens on Amazon\u{2019}s own page, never in Surf\u{2019}s chrome."
        case .unsupported:
            return "Focus covers search and product pages. Everything else is Amazon\u{2019}s own."
        case .cannotRead:
            return "Rather than show you half a page, Surf is stepping out of the way."
        }
    }
}
