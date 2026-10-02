import SwiftUI

/// Which SF Symbols effect an icon plays when activated.
///
/// These are Apple's built-in symbol animations, not hand-rolled ones — they're
/// authored per-symbol by the SF Symbols team, so each glyph animates in a way
/// that suits its own shape.
enum IconMotion {
    /// A quick nudge. The right default for "that press registered".
    case bounce
    /// A soft fade in place — for things that are waiting rather than acting.
    case pulse
    /// A refusal.
    case wiggle
    case none
}

/// Every icon control in the chrome, so hover and press feedback is identical
/// everywhere instead of being re-implemented per button.
///
/// Three layers of feedback, each doing a different job:
/// - a background that fades in on hover, to say "this is a target"
/// - a scale that grows on hover and dips on press, to say "this is a button"
/// - a symbol effect on activation, to say "that worked"
struct IconButton: View {

    let systemName: String

    /// Swapped in while hovered. Lets one button show state at rest and the
    /// action it offers on hover — a spinner that becomes a stop button.
    var hoverSymbol: String?

    var size: CGFloat = 12
    var weight: Font.Weight = .medium
    // Every call site states its own size, so these are only a floor. They
    // were named constants shared with the sidebar's action row, back when
    // there was one — the window's controls live in the top bar now and the
    // page's behind the address, and nothing was left reading them.
    var width: CGFloat = 28
    var height: CGFloat = 28
    var cornerRadius: CGFloat = 8
    var tint: Color?
    var isEnabled: Bool = true
    var motion: IconMotion = .bounce
    /// Spins continuously — for work in progress, not for feedback.
    var isSpinning: Bool = false
    /// Draws itself in stroke-by-stroke on first appearance.
    var drawsIn: Bool = false

    var help: String
    let action: () -> Void

    @State private var isHovering = false
    /// Incremented per activation to retrigger the symbol effect; the effect
    /// fires on value *change*, so a Bool would only work once.
    @State private var activations = 0

    private var displayedSymbol: String {
        if isHovering, let hoverSymbol { return hoverSymbol }
        return systemName
    }

    var body: some View {
        Button {
            activations += 1
            action()
        } label: {
            symbol
                .frame(width: width, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(
            IconButtonStyle(
                isHovering: isHovering && isEnabled,
                isEnabled: isEnabled,
                cornerRadius: cornerRadius,
                tint: tint
            )
        )
        .disabled(!isEnabled)
        .onHover { hovering in
            guard isEnabled else { return }
            isHovering = hovering
        }
        // A button disabled while hovered would otherwise keep its highlight.
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { isHovering = false }
        }
        .help(help)
    }

    @ViewBuilder
    private var symbol: some View {
        let base = Image(systemName: displayedSymbol)
            .font(.system(size: size, weight: weight))
            // Morphs between paired icons — reload/stop, pin/unpin,
            // link/checkmark — instead of hard-swapping them.
            .contentTransition(.symbolEffect(.replace.downUp))

        if isSpinning {
            // `.rotate` spins the symbol's own geometry rather than the
            // rendered image, so strokes stay optically correct throughout.
            base.symbolEffect(.rotate, options: .repeating)
        } else {
            activation(base)
        }
    }

    @ViewBuilder
    private func activation(_ base: some View) -> some View {
        let drawn = drawIn(base)

        switch motion {
        case .bounce:
            drawn.symbolEffect(.bounce, value: activations)
        case .pulse:
            drawn.symbolEffect(.pulse, value: activations)
        case .wiggle:
            drawn.symbolEffect(.wiggle, value: activations)
        case .none:
            drawn
        }
    }

    /// Stroke-by-stroke draw-in, applied as a *transition* rather than a state
    /// effect.
    ///
    /// `.symbolEffect(.drawOn, isActive:)` renders the symbol undrawn — i.e.
    /// invisible — whenever `isActive` is false. If the appear animation
    /// doesn't run, the icon never comes back. A transition only participates
    /// in insertion, so the steady state is always a fully drawn icon.
    @ViewBuilder
    private func drawIn(_ base: some View) -> some View {
        if drawsIn {
            base.transition(.symbolEffect(.drawOn))
        } else {
            base
        }
    }
}

/// The look of a chrome control: the hover plate, the press dip, and the
/// foreground that brightens under the pointer.
///
/// Not private, because `IconButton` is not the only thing that has to wear it.
/// `ScreenshotButton` is a `Menu` rather than a `Button` and so cannot be an
/// `IconButton` at all — and for as long as this style was private, the only
/// way to put it in the same row was to leave it plain. It was the one control
/// there that did not respond to the pointer.
struct IconButtonStyle: ButtonStyle {
    let isHovering: Bool
    let isEnabled: Bool
    let cornerRadius: CGFloat
    let tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed

        return configuration.label
            .foregroundStyle(foreground(pressed: pressed))
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(pressed ? 0.16 : (isHovering ? 0.09 : 0)))
            }
            // Press dips below rest size, hover lifts slightly above it, so the
            // click reads as a physical push rather than a colour change.
            .scaleEffect(pressed ? 0.86 : (isHovering ? 1.07 : 1))
            // Snappier, springier on press; gentler on hover, which fires
            // constantly as the pointer crosses the strip.
            .animation(.spring(response: 0.2, dampingFraction: 0.5), value: pressed)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isHovering)
    }

    private func foreground(pressed: Bool) -> some ShapeStyle {
        guard isEnabled else { return AnyShapeStyle(.tertiary) }
        if let tint { return AnyShapeStyle(tint) }
        // Hover brightens from secondary to full strength — the icon itself
        // responds, not just the plate behind it.
        return AnyShapeStyle(isHovering || pressed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }
}
