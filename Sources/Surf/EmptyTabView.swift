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

    /// The session's address-focus token, but only advanced while this tab is
    /// the focused one.
    ///
    /// Two home tabs can be on screen at once now, and the field focuses on any
    /// *change* to the token it's given — so handing both panes the session's
    /// token directly made one ⌘L put the caret in both, with the loser of the
    /// race keeping it. Latching here means an unfocused pane sees a value that
    /// never moves, and focus changes alone don't count as a request either.
    @State private var focusToken = 0

    /// The palette's width, still — the two are different presentations of one
    /// control, and a different measure would say otherwise.
    private let barWidth: CGFloat = 620

    var body: some View {
        ZStack {
            // Over the mark, so the water washes across its bottom half.
            // The mark lives inside the water's canvas, not behind it: the
            // layers are translucent, so anything merely behind them ghosts
            // through. The water erases the mark with its own wave shapes
            // instead, and the letters' bottom edge becomes the crest line.
            WaterBackground(surface: waterline, diveStartedAt: tab.diveStartedAt,
                            mark: Self.markPath)
                .ignoresSafeArea()

            // On the water, at its own surface.
            VStack(spacing: 8) {
                field
                if completions.isShowing && !tab.isDiving {
                    SuggestionList(
                        suggestions: completions.suggestions,
                        highlighted: completions.highlighted,
                        onPick: navigate
                    )
                    .frame(width: barWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            // The board goes under as the water comes up — slipping below the
            // rising surface rather than blinking out, which is the one wrong
            // note a disappearing control could hit here.
            .offset(y: tab.isDiving ? 130 : 0)
            .opacity(tab.isDiving ? 0 : 1)
            .animation(.easeIn(duration: 0.55), value: tab.isDiving)
            .allowsHitTesting(!tab.isDiving)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The reveal. Time answers for the rise; the tab answers for the page.
        // Both have to be true: fading out while the water is still climbing
        // would show the page through a half-risen sea.
        .task(id: tab.isDiving) {
            guard tab.isDiving else { return }
            let minimumRise: TimeInterval = 1.9
            while !Task.isCancelled && tab.isDiving {
                if let start = tab.diveStartedAt,
                   Date().timeIntervalSince(start) >= minimumRise,
                   !tab.isLoading {
                    tab.completeDive()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Where the surface sits. The board is centred, so this is where the two
    /// meet — a fraction rather than a point, because the window resizes and a
    /// board floating above its own waterline is the one thing that would give
    /// the whole idea away.
    private let waterline = 0.5

    /// The mark, placed for a given window size — cached, because the water
    /// asks thirty times a second and the outlines only change when the window
    /// does. An outline face rather than a stroked one: stroking Outfit works
    /// until the line is heavy enough to see across a room, and then the R and
    /// the F run into each other. Sunk so its last fifth starts below the
    /// waterline, where the waves now decide what shows.
    private static let mark = GlyphOutline(text: "SURF", family: "Bungee Outline", tracking: 2)
    private static let markAspect = mark.aspect()
    private static var markCache: (size: CGSize, path: Path)?

    private static func markPath(for size: CGSize) -> Path {
        if let cached = markCache, cached.size == size { return cached.path }
        let width = size.width - 60
        let height = width / max(markAspect, 0.001)
        let centerY = size.height * 0.5 + size.height * 0.06 - height / 2
        let path = mark.path(in: CGRect(
            x: (size.width - width) / 2, y: centerY - height / 2,
            width: width, height: height
        ))
        markCache = (size, path)
        return path
    }

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
                focusToken: focusToken,
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
            .onChange(of: session.focusAddressToken) { _, new in
                guard tab.id == session.selectedTabID else { return }
                focusToken = new
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
