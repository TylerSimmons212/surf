import SurfCore
import SwiftUI

/// The cart, as a panel over whatever screen is up.
///
/// A sidebar rather than a screen of its own, because a cart is a thing you
/// glance at on the way to deciding something else — and a screen would mean
/// leaving the product you were looking at to check what the cart costs, then
/// finding your way back.
///
/// Underneath, the document really has gone to Amazon's cart: it is the only
/// place a cart can be read. That is invisible from here, and closing the
/// panel puts the document back where it was.
struct AmazonCartSidebar: View {
    @Bindable var lens: AmazonLens

    private var cart: AmazonCart? { lens.cartContents }

    var body: some View {
        HStack(spacing: 0) {
            // The page keeps its own clicks up to the panel's edge; the scrim
            // is only as wide as the space beside it, and dismisses.
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture { lens.closeCart() }

            panel
                .frame(width: 380)
                .transition(.move(edge: .trailing))
        }
        .ignoresSafeArea()
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            if let cart, !cart.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(cart.items) { item in
                            AmazonCartRow(lens: lens, item: item)
                            Divider().opacity(0.35).padding(.leading, 84)
                        }
                    }
                }
                footer(cart)
            } else if lens.isReadingCart {
                centred { ProgressView().controlSize(.small) }
            } else if lens.cartUnreadable {
                // Amazon says there is something in there and we could not read
                // it. Telling somebody their cart is empty when it is not is
                // the worst thing this panel can do, so it says what happened
                // and opens the real page.
                centred {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Couldn\u{2019}t read your cart")
                            .font(Typeface.figtree(size: 13, weight: 600))
                        Text("Amazon says there\u{2019}s something in it.")
                            .font(Typeface.figtree(size: 12, weight: 400))
                            .foregroundStyle(.secondary)
                        Button("Open cart on Amazon") {
                            lens.handBack(to: AmazonPage.cartURL)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .padding(.top, 2)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                }
            } else {
                centred {
                    VStack(spacing: 8) {
                        Image(systemName: "cart")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("Your cart is empty")
                            .font(Typeface.figtree(size: 13, weight: 500))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .leading) { Divider().opacity(0.6) }
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Cart")
                .font(Typeface.figtree(size: 16, weight: 700))
            if let cart, !cart.isEmpty {
                Text("\(cart.unitCount ?? cart.countedUnits)")
                    .font(Typeface.figtree(size: 12, weight: 600).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background { Capsule().fill(Color.primary.opacity(0.08)) }
            }
            Spacer()
            if lens.isReadingCart, cart != nil {
                ProgressView().controlSize(.small)
            }
            IconButton(
                systemName: "xmark",
                size: 11, weight: .bold, width: 26, height: 26, cornerRadius: 8,
                help: "Close the cart"
            ) { lens.closeCart() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    /// The subtotal is Amazon's own number, and checkout is Amazon's own page.
    ///
    /// Neither of those is a shortcut. A subtotal summed here could not know
    /// about a coupon or a subscription discount, and would be confidently
    /// wrong exactly when it mattered. And payment details never render in
    /// Surf's chrome and never pass through Surf's code — this is a door.
    private func footer(_ cart: AmazonCart) -> some View {
        VStack(spacing: 12) {
            Divider().opacity(0.5)
            if let subtotal = cart.subtotal {
                HStack {
                    Text("Subtotal")
                        .font(Typeface.figtree(size: 13, weight: 500))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(subtotal.display)
                        .font(Typeface.figtree(size: 17, weight: 700).monospacedDigit())
                }
                .padding(.horizontal, 16)
            }

            Button {
                lens.handBack(to: AmazonPage.cartURL)
            } label: {
                HStack(spacing: 6) {
                    Text("Checkout on Amazon")
                        .font(Typeface.figtree(size: 14, weight: 600))
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .contentShape(Capsule())
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
    }
}

/// One line, with the two controls that can change it.
private struct AmazonCartRow: View {
    @Bindable var lens: AmazonLens
    let item: AmazonCartItem

    private var isWriting: Bool { lens.writingLine == item.id }
    /// Any write in flight freezes every row, not just its own. Amazon
    /// renumbers the cart under a change that is still landing, so a second
    /// press during the first is aimed at a row that may not mean what it did.
    private var isFrozen: Bool { lens.writingLine != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailImage(
                address: AmazonImage.sized(item.image, width: 160) ?? item.image,
                maxPixel: 160,
                contentMode: .fit
            )
            .padding(4)
            .frame(width: 60, height: 60)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(Typeface.figtree(size: 12.5, weight: 500))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if item.isOutOfStock {
                    Text("Out of stock")
                        .font(Typeface.figtree(size: 11.5, weight: 600))
                        .foregroundStyle(.red)
                }

                HStack(spacing: 8) {
                    if let total = item.lineTotal ?? item.price {
                        Text(total.display)
                            .font(Typeface.figtree(size: 14, weight: 700).monospacedDigit())
                    }
                    // Only when it says something the line total doesn't. One
                    // of something priced $9.99 does not need "$9.99 each".
                    if item.quantity > 1, let each = item.price {
                        Text("\(each.display) each")
                            .font(Typeface.figtree(size: 11, weight: 400))
                            .foregroundStyle(.secondary)
                    }
                }

                controls
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(isWriting ? 0.5 : 1)
        .animation(.easeOut(duration: 0.15), value: isWriting)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                // Refused at the floor, where Amazon's own control in this
                // position is a delete rather than a minus. Removing a line is
                // something to be asked for, never something "one less" does.
                step("minus", enabled: item.canDecrement && !isFrozen) {
                    lens.changeLine(item, .decrement)
                }
                Text("\(item.quantity)")
                    .font(Typeface.figtree(size: 12.5, weight: 600).monospacedDigit())
                    .frame(minWidth: 20)
                step("plus", enabled: !isFrozen) {
                    lens.changeLine(item, .increment)
                }
            }
            .padding(.horizontal, 3)
            .frame(height: 28)
            .background { Capsule().fill(Color.primary.opacity(0.06)) }
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.10)) }

            Button {
                lens.changeLine(item, .remove)
            } label: {
                Text("Remove")
                    .font(Typeface.figtree(size: 11.5, weight: 500))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isFrozen)

            if isWriting { ProgressView().controlSize(.small) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
    }

    private func step(
        _ symbol: String, enabled: Bool, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.primary.opacity(0.25))
        .disabled(!enabled)
        .accessibilityLabel(symbol == "minus" ? "One fewer" : "One more")
    }
}
