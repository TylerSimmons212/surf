import SurfCore
import SwiftUI

/// Amazon's reviews, which Amazon buries below three rails of things nobody
/// asked for.
///
/// A sheet rather than a screen, because dismissing it must cost nothing — no
/// navigation, no second read of the page. The distribution sits at the top
/// and expanded: a ratings summary is what tells four-and-a-half stars from
/// eighty-seven per cent five-star with a hard core of one-star complaints,
/// and those are different products. Nothing is filtered out, least of all
/// the one-star reviews, which is where people go first.
struct AmazonReviewsSheet: View {
    @Bindable var lens: AmazonLens
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let histogram = lens.histogram { distribution(histogram) }
                    ForEach(lens.reviews) { review in
                        AmazonReviewRow(review: review)
                    }
                    footer
                }
                .padding(24)
            }
        }
        .frame(width: 640, height: 660)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reviews")
                    .font(Typeface.figtree(size: 15, weight: 600))
                    .accessibilityAddTraits(.isHeader)
                if let stars = lens.product?.stars {
                    AmazonStars(stars: stars, count: lens.product?.reviewCount, size: 12)
                }
            }
            Spacer()
            IconButton(
                systemName: "xmark",
                size: 11, weight: .bold, width: 26, height: 26, cornerRadius: 8,
                help: "Close"
            ) { close() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func distribution(_ histogram: AmazonHistogram) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(histogram.percentages.enumerated()), id: \.offset) { index, percent in
                let stars = 5 - index
                HStack(spacing: 10) {
                    Text("\(stars) star")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(Color(red: 0.96, green: 0.62, blue: 0.04))
                                .frame(width: geometry.size.width * CGFloat(percent) / 100)
                        }
                    }
                    .frame(height: 9)
                    Text("\(percent)%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(percent) percent of reviews are \(stars) star")
            }
        }
    }

    /// We show what the page carried, which is a dozen or so. Paginating
    /// Amazon's review corpus is Amazon's job, and it does it well.
    private var footer: some View {
        Button {
            lens.handBack(to: lens.product.flatMap {
                URL(string: "https://www.amazon.com/product-reviews/\($0.id)")
            })
        } label: {
            HStack(spacing: 5) {
                Text("Read all reviews on Amazon")
                    .font(Typeface.figtree(size: 12, weight: 500))
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}

private struct AmazonReviewRow: View {
    let review: AmazonReview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let stars = review.stars {
                    AmazonStars(stars: stars, size: 11)
                }
                if !review.title.isEmpty {
                    Text(review.title)
                        .font(Typeface.figtree(size: 13, weight: 600))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                if !review.author.isEmpty {
                    Text(review.author)
                        .font(Typeface.figtree(size: 11, weight: 500))
                        .foregroundStyle(.secondary)
                }
                if !review.date.isEmpty {
                    Text(review.date)
                        .font(Typeface.figtree(size: 11, weight: 400))
                        .foregroundStyle(.tertiary)
                }
                if review.isVerified {
                    Text("Verified purchase")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.78, green: 0.35, blue: 0.05))
                }
            }

            // Which variation it was written against. A review of the
            // three-foot cable is not a review of the ten-foot one, and
            // Amazon knows this — it records the variation and then prints it
            // in grey six point.
            if !review.variation.isEmpty {
                Text(review.variation)
                    .font(Typeface.figtree(size: 10.5, weight: 400))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(review.body)
                .font(Typeface.figtree(size: 12.5, weight: 400))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                // Around seventy characters. Longer measures read as
                // intimidating and get abandoned mid-paragraph.
                .frame(maxWidth: 560, alignment: .leading)

            if !review.helpful.isEmpty {
                Text(review.helpful)
                    .font(Typeface.figtree(size: 10.5, weight: 400))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - A row that wraps

/// Swatch rows are as long as the seller made them: "3.3FT*2 (Pack of 2)" ten
/// times over. A plain `HStack` would run off the edge of the column.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
