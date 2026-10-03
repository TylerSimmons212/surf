import SurfCore
import SwiftUI

/// The home screen: the water, and the thing you type into.
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
            WaterBackground(surface: waterline, diveStartedAt: tab.diveStartedAt)
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
            // The field goes under as the water comes up — slipping below the
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

    /// Where the surface sits. The field is centred, so this is where the two
    /// meet — a fraction rather than a point, because the window resizes and a
    /// field floating above its own waterline is the one thing that would give
    /// the whole idea away.
    private let waterline = 0.5

    /// The glass's tint: the water's own deep, from the dive's underlayer in
    /// `WaterBackground`, so the pill reads as a darker patch of the same sea
    /// rather than a foreign grey. Deliberate, after a glass pane was rejected
    /// once for letting the water read straight through it: the tint is what
    /// keeps bold white text legible when a bright crest passes underneath.
    private static let glassTint = Color(red: 0.10, green: 0.30, blue: 0.56).opacity(0.38)

    private var field: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(Typeface.figtree(size: 17, weight: 600))
                .foregroundStyle(.white.opacity(0.85))

            SurfTextField(
                text: $text,
                placeholder: "Search or enter address",
                font: .systemFont(ofSize: 19, weight: .bold),
                // White on tinted glass over the sea, whatever the window's
                // appearance says; the placeholder is the same ink at 45%.
                textColor: .white,
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
                    completions.update(
                        for: value, isFocused: true, in: tab.islandID
                    )
                }
            }
            .onChange(of: session.focusAddressToken) { _, new in
                guard tab.id == session.selectedTabID else { return }
                focusToken = new
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 17)
        .frame(width: barWidth)
        // A glass pill on the water. Glass was tried here once and rejected
        // because the sea read straight through it; it is back by choice, and
        // the tint is what makes it sit *on* the wave rather than behind it.
        // Hover lives in the tint as well as the shadow: a brightness or scale
        // layered after `.glassEffect` never reaches the glass pass (see
        // MiniWindowChrome), so the material itself has to answer.
        .glassEffect(
            .regular
                .tint(Self.glassTint.opacity(isHovering ? 0.5 : 0.38))
                .interactive(),
            in: Capsule()
        )
        .contentShape(Capsule())
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: text.isEmpty)
        // The lift off the surface — and the dark halo that keeps the rim
        // readable where a crest would otherwise wash it out.
        .shadow(color: Color(red: 0.02, green: 0.10, blue: 0.20)
            .opacity(isHovering ? 0.42 : 0.32), radius: isHovering ? 26 : 18, y: 10)
        // On the whole field, glass and label together, so the two can't part.
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
        // Straight to the tab, not through the palette's router: this is the
        // one submission that comes from someone actually looking at the sea.
        tab.submit(text, diving: true)
        completions.dismiss()
        text = ""
    }

    private func navigate(to entry: HistoryEntry) {
        tab.submit(entry.url, diving: true)
        completions.dismiss()
        text = ""
    }
}
