import SwiftUI

/// What a new tab shows behind the address palette.
///
/// Deliberately almost nothing. A new tab immediately opens the floating
/// address bar, so this is a backdrop rather than a screen — anything more
/// would compete with the palette sitting on top of it, and would be a second
/// place to type an address when there should only ever be one.
struct EmptyTabView: View {
    let onOpenAddressBar: () -> Void

    @State private var isHovering = false

    /// Matches the palette's width exactly — the click is supposed to look
    /// like this bar coming forward, not like a second control appearing.
    private let barWidth: CGFloat = 620

    var body: some View {
        VStack(spacing: 22) {
            Text("Surf")
                .font(Typeface.outfit(size: 40))
                .foregroundStyle(.primary.opacity(0.5))

            searchBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shaped like the field it opens, at the size the palette will appear —
    /// so clicking it reads as the same object coming forward rather than one
    /// control being swapped for another.
    private var searchBar: some View {
        Button(action: onOpenAddressBar) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)

                Text("Search or enter address")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Text("⌘L")
                    .font(.system(size: 12, weight: .medium).monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .frame(width: barWidth)
            // A capsule rather than a rounded rectangle, so the ends stay true
            // semicircles at whatever height the type sets. The tint warms on
            // hover instead of a plate fading in behind it: glass is the
            // surface, so the surface itself should respond.
            .glassEffect(
                .regular
                    .tint(isHovering ? Color.accentColor.opacity(0.10) : nil)
                    .interactive(),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(isHovering ? 0.20 : 0.12), radius: isHovering ? 22 : 14, y: 6)
        .scaleEffect(isHovering ? 1.012 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovering)
        .onHover { isHovering = $0 }
        .help("Search or enter address (⌘L)")
    }
}
