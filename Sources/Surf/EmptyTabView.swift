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
            // Backmost, and an outline face rather than a stroked one. Stroking
            // Outfit works until the line is heavy enough to see from across the
            // room, and then the R and the F run into each other — the outline
            // is drawn around each letter independently and nothing stops two
            // of them meeting. Bungee Outline is drawn as an outline, so the
            // counters and the spacing already account for it.
            GeometryReader { geo in
                let mark = GlyphOutline(text: "SURF", family: "Bungee Outline", tracking: 2)
                let width = geo.size.width - 60
                let height = width / max(mark.aspect(), 0.001)
                mark
                    .fill(.primary.opacity(0.16))
                    .frame(width: width, height: height)
                    // Sunk to the waterline: the last fifth of the letters goes
                    // under, where the water is densest and hides it. Left to
                    // centre itself the word sat far lower, and the whole
                    // bottom half of it showed through the water as a ghost.
                    .position(
                        x: geo.size.width / 2,
                        y: geo.size.height * waterline + geo.size.height * 0.06 - height / 2
                    )
            }
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
                .foregroundStyle(Color(red: 0.10, green: 0.22, blue: 0.34).opacity(0.55))

            SurfTextField(
                text: $text,
                placeholder: "Search or enter address",
                font: .systemFont(ofSize: 19, weight: .regular),
                // The board sets its own surface, so the ink is chosen against
                // that rather than against the window's appearance.
                textColor: NSColor(red: 0.06, green: 0.15, blue: 0.24, alpha: 1),
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
        // A real board, not a pane of glass: white, opaque, catching a little
        // more light along the top than the bottom. Glass let the water read
        // straight through it, which put the thing meant to be riding the wave
        // somewhere behind it.
        .background {
            SurfboardShape()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.99), Color(white: 0.90)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
        .overlay(alignment: .trailing) {
            // The stringer, kept to the nose run. Full length is what a board
            // actually has and it drew a line straight through the placeholder;
            // typed text can reach x=520 of 620, so this starts at 536 and
            // there is nothing for it to cross.
            Capsule()
                .fill(Color(red: 0.10, green: 0.22, blue: 0.34).opacity(0.18))
                .frame(width: 48, height: 1.5)
                .padding(.trailing, 36)
                .allowsHitTesting(false)
        }
        .overlay {
            SurfboardShape()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white, Color(red: 0.55, green: 0.68, blue: 0.78)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .contentShape(SurfboardShape())
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: text.isEmpty)
        .shadow(color: Color(red: 0.02, green: 0.10, blue: 0.20)
            .opacity(isHovering ? 0.42 : 0.32), radius: isHovering ? 26 : 18, y: 10)
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
