import SurfCore
import SwiftUI

/// The home screen: the name, and the thing you type into.
///
/// This used to be a backdrop — a button shaped like the palette, which opened
/// the palette on top of it. Clicking a text field and being handed a second
/// text field is a seam you can feel, so the field here is the real one. The
/// palette still exists for every other tab, where there is a page underneath
/// that has to stay visible; on home there is nothing to float over.
struct EmptyTabView: View {
    let session: BrowserSession
    let tab: Tab

    @State private var text = ""
    @State private var completions = SuggestionController()
    @State private var isHovering = false

    /// The palette's width, still — the two are different presentations of one
    /// control, and a different measure would say otherwise.
    private let barWidth: CGFloat = 620

    var body: some View {
        ZStack {
            // Backmost, and big enough that the window crops it rather than
            // containing it — a mark the screen is a window onto, not a label
            // sitting on one. Stroked, so the water reads through it.
            GlyphOutline(text: "SURF", family: "Outfit", weight: 500, tracking: 6)
                .stroke(
                    LinearGradient(
                        colors: [.primary.opacity(0.30), .primary.opacity(0.08)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 3, lineJoin: .round)
                )
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
                .allowsHitTesting(false)

            // Over the mark, so the water washes across its bottom half.
            WaterBackground(surface: waterline)
                .ignoresSafeArea()

            // On the water, at its own surface.
            VStack(spacing: 8) {
                field
                if completions.isShowing {
                    SuggestionList(
                        suggestions: completions.suggestions,
                        highlighted: completions.highlighted,
                        onPick: navigate
                    )
                    .frame(width: barWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Where the surface sits. The board is centred, so this is where the two
    /// meet — a fraction rather than a point, because the window resizes and a
    /// board floating above its own waterline is the one thing that would give
    /// the whole idea away.
    private let waterline = 0.5

    private var field: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(Typeface.figtree(size: 17, weight: 500))
                .foregroundStyle(isHovering || !text.isEmpty ? Color.accentColor : Color.secondary)

            SurfTextField(
                text: $text,
                placeholder: "Search or enter address",
                font: .systemFont(ofSize: 19, weight: .regular),
                focusToken: session.focusAddressToken,
                onSubmit: submit,
                onMove: { direction in
                    guard completions.isShowing else { return }
                    completions.moveHighlight(by: direction)
                },
                onCancel: { completions.dismiss() }
            )
            .frame(height: 26)
            .onChange(of: text) { _, value in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    completions.update(for: value, isFocused: true)
                }
            }
        }
        // Asymmetric, because the shape is. The tail end is blunt and needs
        // little; the nose runs out for the last third and is down to half
        // height by x=576 of 620, so text ending where a capsule's would end
        // would sit outside the board.
        .padding(.leading, 40)
        .padding(.trailing, 100)
        .padding(.vertical, 17)
        .frame(width: barWidth)
        .glassEffect(
            .regular
                .tint(text.isEmpty ? (isHovering ? Color.accentColor.opacity(0.08) : nil)
                                   : Color.accentColor.opacity(0.10))
                .interactive(),
            in: SurfboardShape()
        )
        .background { SurfboardShape().fill(.thickMaterial) }
        .overlay(alignment: .trailing) {
            // The stringer, kept to the nose run. Full length is what a board
            // actually has and it drew a line straight through the placeholder;
            // typed text can reach x=520 of 620, so this starts at 536 and
            // there is nothing for it to cross.
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(width: 48, height: 1.5)
                .padding(.trailing, 36)
                .allowsHitTesting(false)
        }
        .overlay {
            SurfboardShape()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.38), .white.opacity(0.06)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .contentShape(SurfboardShape())
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: text.isEmpty)
        .shadow(color: .black.opacity(isHovering ? 0.20 : 0.14), radius: isHovering ? 24 : 16, y: 8)
        .scaleEffect(isHovering ? 1.008 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovering)
        .onHover { isHovering = $0 }
    }

    private func submit() {
        if let entry = completions.highlightedEntry {
            navigate(to: entry)
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.submitFromPalette(text, creatingTab: false)
        completions.dismiss()
        text = ""
    }

    private func navigate(to entry: HistoryEntry) {
        session.submitFromPalette(entry.url, creatingTab: false)
        completions.dismiss()
        text = ""
    }
}
