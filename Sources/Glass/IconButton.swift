import SwiftUI

/// Every icon control in the chrome, so hover and press feedback is identical
/// everywhere instead of being re-implemented per button.
///
/// Three layers of feedback, each doing a different job:
/// - a background that fades in on hover, to say "this is a target"
/// - a scale that grows on hover and dips on press, to say "this is a button"
/// - a symbol effect on activation, to say "that worked"
struct IconButton: View {
    let systemName: String

    var size: CGFloat = 12
    var weight: Font.Weight = .medium
    var width: CGFloat = 26
    var height: CGFloat = 22
    var cornerRadius: CGFloat = 6
    var tint: Color?
    var isEnabled: Bool = true
    var help: String
    let action: () -> Void

    @State private var isHovering = false
    /// Incremented per activation to retrigger the symbol effect; the effect
    /// fires on value *change*, so a Bool would only work once.
    @State private var activations = 0

    var body: some View {
        Button {
            activations += 1
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                // Morphs between paired icons — reload/stop, pin/unpin,
                // link/checkmark — instead of hard-swapping them.
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce, value: activations)
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
}

private struct IconButtonStyle: ButtonStyle {
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
