import SurfCore
import SwiftUI

/// One product, as a page that answers the question you arrived with.
///
/// Amazon's own product page is a scroll of recommendation rails, sponsored
/// carousels and cross-sells with the decision buried in the middle — Nielsen
/// Norman counted 259 links and buttons on a single book page, with the
/// publication date three screenfuls below the fold. This is the decision:
/// what it is, what it costs, what it costs *per unit*, what people think,
/// when it arrives, and who is actually shipping it.
///
/// The layout follows the eye-tracking rather than taste. 57% of viewing time
/// is above the fold and 74% is inside the first two screenfuls, so
/// everything needed to decide sits in the first screen and everything that
/// merely supports the decision sits below it, in one column, reachable by
/// ordinary scrolling. No tabs: content behind horizontal tabs is overlooked
/// by roughly a quarter of users, and this page has no reason to hide
/// anything.
///
/// One principle resolves most of the smaller questions. The persuasion
/// literature and the comparison literature disagree about how to present a
/// price, and they disagree in a consistent direction: the tactics that lift
/// conversion work by making comparison harder. This page is read by the
/// person spending the money, so it takes the comparison side every time —
/// both discount frames rather than the flattering one, the unit price
/// always, no synthetic urgency, and never a "from" price sitting next to a
/// button that will charge something else.
struct AmazonProductView: View {
    @Bindable var lens: AmazonLens

    @State private var selectedImage = 0
    @State private var quantity = 1
    @State private var showsReviews = false
    @State private var showsAllSpecs = false

    /// Prose is capped near seventy characters. Longer measures read as
    /// "intimidating and overwhelming" and get abandoned; WCAG puts the
    /// ceiling at eighty.
    private let proseWidth: CGFloat = 620

    private var product: AmazonProduct? { lens.product }

    var body: some View {
        ScrollView {
            if let product {
                VStack(alignment: .leading, spacing: 30) {
                    backControl
                    decisionBlock(product)
                    if !product.keySpecs.isEmpty { keySpecs(product) }
                    if !product.highlights.isEmpty { highlights(product) }
                    if !product.remainingSpecs.isEmpty { fullSpecs(product) }
                }
                .padding(.horizontal, 34)
                .padding(.top, 88)
                .padding(.bottom, 64)
                .frame(maxWidth: 1080, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showsReviews) {
            AmazonReviewsSheet(lens: lens) { showsReviews = false }
        }
        .onChange(of: product?.id) { _, _ in
            selectedImage = 0
            quantity = 1
            showsAllSpecs = false
        }
    }

    private var backControl: some View {
        Button {
            lens.showResults()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("Results")
                    .font(Typeface.figtree(size: 12, weight: 500))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Everything needed to decide, in the first screen

    private func decisionBlock(_ product: AmazonProduct) -> some View {
        HStack(alignment: .top, spacing: 34) {
            gallery(product).frame(maxWidth: 430)
            decision(product).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Gallery

    private func gallery(_ product: AmazonProduct) -> some View {
        let pictures = product.pictures
        return VStack(spacing: 12) {
            ThumbnailImage(
                address: product.imageURL(at: selectedImage, width: 900)
                    ?? product.imageURL(at: 0, width: 900) ?? "",
                maxPixel: 900,
                contentMode: .fit
            )
            .padding(20)
            .frame(height: 380)
            .frame(maxWidth: .infinity)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08))
            }
            // The gallery *is* the product, so it gets a real description.
            // Amazon's own alt text when the seller wrote one, the product's
            // name when they didn't — never "product image".
            .accessibilityLabel(pictureDescription(product, at: selectedImage))

            if pictures.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(pictures.indices), id: \.self) { index in
                            thumbnail(product, index)
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollIndicators(.hidden)
                .frame(height: 62)
                // Without this the strip ends mid-thumbnail against a hard
                // edge, which reads as a rendering fault rather than as more
                // pictures one scroll away.
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.93),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                }
            }
        }
    }

    private func pictureDescription(_ product: AmazonProduct, at index: Int) -> String {
        let pictures = product.pictures
        if pictures.indices.contains(index), !pictures[index].alt.isEmpty {
            return pictures[index].alt
        }
        return "\(product.title), picture \(index + 1) of \(pictures.count)"
    }

    private func thumbnail(_ product: AmazonProduct, _ index: Int) -> some View {
        Button {
            selectedImage = index
        } label: {
            ThumbnailImage(
                address: product.pictures[index].thumb.isEmpty
                    ? (product.imageURL(at: index, width: 160) ?? "")
                    : product.pictures[index].thumb,
                maxPixel: 160,
                contentMode: .fit
            )
            .padding(5)
            .frame(width: 58, height: 58)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        index == selectedImage
                            ? Color.accentColor : .primary.opacity(0.10),
                        lineWidth: index == selectedImage ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Picture \(index + 1)")
        .accessibilityAddTraits(index == selectedImage ? [.isSelected] : [])
    }

    // MARK: - The decision column

    private func decision(_ product: AmazonProduct) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(product.title)
                    .font(Typeface.figtree(size: 21, weight: 600))
                    .fixedSize(horizontal: false, vertical: true)
                if !product.brand.isEmpty {
                    Text(product.brand)
                        .font(Typeface.figtree(size: 12.5, weight: 500))
                        .foregroundStyle(.secondary)
                }
            }

            if let stars = product.stars {
                ratingControl(product, stars: stars)
            }

            if product.isAmazonsChoice || !product.boughtRecently.isEmpty {
                proof(product)
            }

            price(product)

            ForEach(product.variations) { group in
                variation(group, product: product)
            }

            fulfilment(product)
            purchase(product)
        }
    }

    private func ratingControl(_ product: AmazonProduct, stars: Double) -> some View {
        Button { showsReviews = true } label: {
            HStack(spacing: 7) {
                AmazonStars(stars: stars, count: product.reviewCount, size: 13)
                Text("Read reviews")
                    .font(Typeface.figtree(size: 12, weight: 500))
                    .foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(lens.reviews.isEmpty && lens.histogram == nil)
        .accessibilityLabel(
            "\(AmazonStars.spoken(stars: stars, count: product.reviewCount)). Read reviews"
        )
    }

    /// Price, both discount frames, and the unit price.
    ///
    /// Both frames because picking one means picking whichever number
    /// flatters the offer, and the reader is here to judge it. The unit price
    /// because 81% of product pages omit it and its absence is what turns
    /// "which of these two is cheaper" into arithmetic done by hand.
    private func price(_ product: AmazonProduct) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                if let now = product.price {
                    Text(now.display)
                        .font(.system(size: 27, weight: .semibold).monospacedDigit())
                }
                if let was = product.listPrice, product.savingsPercent != nil {
                    Text(was.display)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .strikethrough()
                }
                if let percent = product.savingsPercent {
                    Text(savingsLabel(product, percent: percent))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Color(red: 0.78, green: 0.15, blue: 0.15),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
            }
            .accessibilityElement(children: .combine)

            if let unit = product.unitPrice {
                Text(unit)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func savingsLabel(_ product: AmazonProduct, percent: Int) -> String {
        guard let saved = product.savingsAmount else { return "\(percent)% off" }
        return "Save \(saved.display) \u{2014} \(percent)%"
    }

    // MARK: - Variations

    /// Buttons, always, and never a dropdown: a hidden selector is one users
    /// overlook entirely, then discover their size was never available after
    /// they've already spent the effort deciding they want it.
    private func variation(
        _ group: AmazonVariationGroup, product: AmazonProduct
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(group.label)
                    .font(Typeface.figtree(size: 12, weight: 600))
                    .foregroundStyle(.secondary)
                if !group.selected.isEmpty {
                    Text(group.selected)
                        .font(Typeface.figtree(size: 12, weight: 400))
                        .foregroundStyle(.primary)
                }
            }
            FlowRow(spacing: 6) {
                ForEach(group.options) { option in
                    swatch(option, group: group, product: product)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.label)
    }

    /// The selected state is filled, not outlined.
    ///
    /// A thin ring is the specific failure Baymard recorded verbatim — *"This
    /// just has a ring around. I don't know if that means it is selected?"* —
    /// and users stall verifying the system heard them before they will press
    /// a buy button. Unavailable options are struck through rather than
    /// greyed out, because low-contrast disabled controls are routinely not
    /// noticed at all, and they keep their label so the reason is legible
    /// rather than implied by colour.
    private func swatch(
        _ option: AmazonVariationOption,
        group: AmazonVariationGroup,
        product: AmazonProduct
    ) -> some View {
        let isCurrent = option.value == group.selected || option.asin == product.id
        let isPending = lens.pendingVariation == option.asin
        return Button {
            lens.choose(option)
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 5) {
                    if isPending {
                        ProgressView().controlSize(.mini)
                    }
                    Text(option.value)
                        .font(Typeface.figtree(size: 11.5, weight: isCurrent ? 600 : 400))
                        .strikethrough(!option.isAvailable)
                }
                // What this one costs, where Amazon prints it. Seeing that
                // black is $9.99 and red is $12.99 without opening both is
                // the comparison this whole page is arranged around.
                if let price = option.price {
                    Text(price)
                        .font(.system(size: 10).monospacedDigit())
                        .opacity(isCurrent ? 0.85 : 0.6)
                }
            }
            .foregroundStyle(swatchInk(isCurrent: isCurrent, available: option.isAvailable))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            // Comfortably past the 24-point minimum for a pointer target.
            .frame(minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? Color.accentColor : .clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isCurrent ? Color.accentColor : .primary.opacity(0.22),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!option.isAvailable || option.asin.isEmpty || lens.pendingVariation != nil)
        .accessibilityLabel(
            option.isAvailable
                ? "\(group.label) \(option.value)"
                : "\(group.label) \(option.value), unavailable"
        )
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private func swatchInk(isCurrent: Bool, available: Bool) -> Color {
        if isCurrent { return .white }
        return available ? .primary : .secondary
    }

    // MARK: - Trust, as content rather than as a banner

    /// Stock, arrival and seller.
    ///
    /// Styled as ordinary text on purpose. Anything that looks like a promo
    /// strip gets skipped — eye-tracking put a single fixation out of 132 in
    /// the right rail, and users describe skipping instructional content
    /// purely because it looked like an advert. The most useful facts on this
    /// page are the ones most easily mistaken for marketing, so they are
    /// dressed as prose.
    private func fulfilment(_ product: AmazonProduct) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !product.availability.isEmpty {
                Text(product.availability)
                    .font(Typeface.figtree(size: 13, weight: 600))
                    .foregroundStyle(
                        product.canAddToCart
                            ? Color(red: 0.10, green: 0.52, blue: 0.20) : .secondary
                    )
            }
            deliveryBadge(product)

            if !product.delivery.isEmpty {
                Text(product.delivery)
                    .font(Typeface.figtree(size: 12, weight: 400))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !sellerLine(product).isEmpty {
                // `.secondary`, not `.tertiary`. Who ships it and who takes
                // the returns are the two facts this block exists for, and
                // they were the two drawn faintest on the page — a comment
                // four lines up calls them the most useful facts here while
                // the code rendered them as the least.
                Text(sellerLine(product))
                    .font(Typeface.figtree(size: 12, weight: 400))
                    .foregroundStyle(.secondary)
            }
            if !product.returnsPolicy.isEmpty {
                Text(product.returnsPolicy)
                    .font(Typeface.figtree(size: 12, weight: 400))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What kind of free the delivery is.
    ///
    /// "FREE delivery" is the same sentence whether it is free because the
    /// account is Prime or free because the order clears $35, and the
    /// difference is the whole question when deciding whether to add one more
    /// thing to the basket. The chip says which.
    ///
    /// Drawn, never Amazon's asset. The Prime mark is a trademark, and the
    /// same reasoning that keeps `AmazonMark` and `YouTubeMark` hand-drawn
    /// applies to a delivery badge — a checkmark and the word, in Amazon's own
    /// blue, is a description of the offer rather than a reproduction of a logo.
    ///
    /// `.unknown` draws nothing at all. That is the honest reading of a token
    /// nobody has seen: silence rather than a claim about somebody's delivery.
    @ViewBuilder
    private func deliveryBadge(_ product: AmazonProduct) -> some View {
        switch product.deliveryBenefit {
        case .prime:
            deliveryChip(
                "checkmark.seal.fill", "Prime delivery",
                Color(red: 0.0, green: 0.63, blue: 0.85)
            )
        case .conditionallyFree:
            deliveryChip(
                "shippingbox.fill", "Free over $35",
                Color(red: 0.10, green: 0.52, blue: 0.20)
            )
        case .standard, .unknown:
            EmptyView()
        }
    }

    private func deliveryChip(_ symbol: String, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(Typeface.figtree(size: 11, weight: 600))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(tint.opacity(0.12))
        }
        .accessibilityElement(children: .combine)
    }

    /// Sold by and shipped by on one line, and only once when they are the
    /// same party. "Sold by Amazon, ships from Amazon" is a sentence that
    /// says one thing twice.
    private func sellerLine(_ product: AmazonProduct) -> String {
        let sold = product.seller, ships = product.shipsFrom
        if sold.isEmpty, ships.isEmpty { return "" }
        if sold.isEmpty { return "Ships from \(ships)" }
        if ships.isEmpty || ships.caseInsensitiveCompare(sold) == .orderedSame {
            return "Sold by \(sold)"
        }
        return "Sold by \(sold), ships from \(ships)"
    }

    /// Amazon's badge and Amazon's count, presented as facts about the
    /// listing rather than restyled into a recommendation of ours — and as
    /// ordinary text, because anything shaped like a promo strip gets
    /// skipped by the eye that most needs to read it.
    private func proof(_ product: AmazonProduct) -> some View {
        HStack(spacing: 8) {
            if product.isAmazonsChoice {
                Text("Amazon's Choice")
                    .font(Typeface.figtree(size: 10.5, weight: 600))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Color(red: 0.13, green: 0.19, blue: 0.27),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
            }
            if !product.boughtRecently.isEmpty {
                Text(product.boughtRecently)
                    .font(Typeface.figtree(size: 11.5, weight: 500))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - The only control that writes

    @ViewBuilder
    private func purchase(_ product: AmazonProduct) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if product.canAddToCart {
                HStack(spacing: 12) {
                    quantityControl(max: product.quantityMax)

                    // The one control on the page anybody came here to press,
                    // sized like it. A capsule rather than a rounded rectangle
                    // because it is the only fully round thing in the column
                    // and has nothing to be confused with, and given the width
                    // that is left over rather than a minimum — the quantity
                    // stepper is a small fixed thing and this is not.
                    Button {
                        lens.addToCart(quantity: quantity)
                    } label: {
                        HStack(spacing: 7) {
                            if lens.addingToCart == product.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "cart.badge.plus")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            Text("Add to Cart")
                                .font(Typeface.figtree(size: 15, weight: 600))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(lens.addingToCart != nil || lens.pendingVariation != nil)
                    // Wide, but not the whole column. A pill stretched across
                    // five hundred points stops reading as a button and starts
                    // reading as a banner, which is the one thing on this page
                    // that must not happen to it.
                    .frame(maxWidth: 340)
                }
            }

            // Buying is Amazon's page, permanently and by design. Payment
            // details and order confirmation never render in Surf's chrome
            // and never pass through Surf's code — so this is a door, not a
            // button that spends money.
            Button {
                lens.handBack(to: AmazonPage.productURL(asin: product.id))
            } label: {
                HStack(spacing: 5) {
                    Text(product.canAddToCart ? "Buy on Amazon" : "Open on Amazon")
                        .font(Typeface.figtree(size: 12, weight: 500))
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Quantity, at the height of the button it stands next to.
    ///
    /// A stock `Stepper` is a small pair of arrows with a label, which beside a
    /// 46-point capsule reads as an afterthought — and quantity is not an
    /// afterthought when the thing next to it puts items in a cart. Bounded by
    /// what Amazon will actually sell: measured at 99 on a cable and 4 on a
    /// streaming stick, and a control offering thirty of something capped at
    /// four only produces an error on the other side.
    private func quantityControl(max limit: Int) -> some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: quantity > 1) { quantity -= 1 }
            Text("\(quantity)")
                .font(Typeface.figtree(size: 14, weight: 600).monospacedDigit())
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            stepButton("plus", enabled: quantity < limit) { quantity += 1 }
        }
        .padding(.horizontal, 4)
        .frame(height: 46)
        .background {
            Capsule().fill(Color.primary.opacity(0.06))
        }
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.10))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quantity")
        .accessibilityValue("\(quantity)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment where quantity < limit: quantity += 1
            case .decrement where quantity > 1: quantity -= 1
            default: break
            }
        }
    }

    private func stepButton(
        _ symbol: String, enabled: Bool, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.primary.opacity(0.25))
        .disabled(!enabled)
    }

    // MARK: - Key specifications

    /// Amazon's own curated overview, put above the full sheet instead of
    /// below it.
    ///
    /// Summarising the critical specifications at the top of a page is
    /// something roughly 3% of retailers do. Amazon does the curation and
    /// then buries the result; this only has to not throw it away.
    private func keySpecs(_ product: AmazonProduct) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("At a glance")
            FlowRow(spacing: 10) {
                ForEach(product.keySpecs) { spec in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spec.label)
                            .font(Typeface.figtree(size: 11, weight: 500))
                            .foregroundStyle(.secondary)
                        Text(spec.value)
                            .font(Typeface.figtree(size: 13, weight: 600))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: 210, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - Highlights

    /// The description as headline-and-paragraph, which is the shape 78% of
    /// retailers fail to give it. Amazon writes its bullets that way already
    /// and then flattens them into a list; this only un-flattens them.
    private func highlights(_ product: AmazonProduct) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("What it does")
            ForEach(product.highlights) { highlight in
                VStack(alignment: .leading, spacing: 3) {
                    if !highlight.headline.isEmpty {
                        Text(highlight.headline)
                            .font(Typeface.figtree(size: 13, weight: 600))
                    }
                    Text(highlight.body)
                        .font(Typeface.figtree(size: 12.5, weight: 400))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: proseWidth, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - The full sheet

    /// One column, never two.
    ///
    /// A two-column specification sheet is read as a comparison of two
    /// products — which makes every number on it wrong. Rows alternate shade
    /// because eye-tracking shows the banding measurably helps the eye get
    /// from a label to its value, and the sheet truncates in place with an
    /// expander rather than moving anything to a tab or another view.
    private func fullSpecs(_ product: AmazonProduct) -> some View {
        let rows = product.remainingSpecs
        let shown = showsAllSpecs ? rows : Array(rows.prefix(8))
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Specifications")
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, spec in
                    HStack(alignment: .top, spacing: 14) {
                        Text(spec.label)
                            .font(Typeface.figtree(size: 12, weight: 500))
                            .foregroundStyle(.secondary)
                            .frame(width: 170, alignment: .leading)
                        Text(spec.value)
                            .font(Typeface.figtree(size: 12, weight: 400))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        index.isMultiple(of: 2)
                            ? Color.primary.opacity(0.035) : .clear
                    )
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if rows.count > 8 {
                Button {
                    showsAllSpecs.toggle()
                } label: {
                    Text(showsAllSpecs
                        ? "Show fewer"
                        : "Show all \(rows.count) specifications")
                        .font(Typeface.figtree(size: 12, weight: 500))
                        .foregroundStyle(.tint)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(Typeface.figtree(size: 15, weight: 600))
            .accessibilityAddTraits(.isHeader)
    }
}
