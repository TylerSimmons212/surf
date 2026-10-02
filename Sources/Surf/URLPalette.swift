import SurfCore
import SwiftUI

/// The floating address bar: a centered, focused input over a dimmed window.
///
/// Replaces the persistent toolbar. Nothing occupies the window until it's
/// asked for, which is the point — the page gets the whole surface.
///
/// The dimmed backdrop isn't drawn here. It belongs to the window, which fades
/// it on its own timing: when the two were one view, the backdrop scaled with
/// the card on the way in, and its edges could be seen creeping inward.
struct URLPalette: View {
    let session: BrowserSession
    let tab: Tab
    /// Whether submitting opens a new tab rather than navigating this one. The
    /// tab is created on submit, so dismissing costs nothing.
    let createsTab: Bool
    /// How the palette is leaving. The window decides what that looks like.
    let onClose: (PaletteClose) -> Void

    @State private var text: String
    @State private var completions = SuggestionController()

    init(
        session: BrowserSession,
        tab: Tab,
        createsTab: Bool,
        onClose: @escaping (PaletteClose) -> Void
    ) {
        self.session = session
        self.tab = tab
        self.createsTab = createsTab
        self.onClose = onClose
        // A new tab starts empty; editing an existing one starts from where it
        // already is. Set here rather than on appear, so the first frame
        // already has it: arriving a frame late, the clear button used to pop
        // in after everything else.
        _text = State(initialValue: (createsTab || tab.mode == .home) ? "" : tab.addressText)
    }

    var body: some View {
        VStack(spacing: 8) {
            field
            if completions.isShowing {
                SuggestionList(
                    suggestions: completions.suggestions,
                    highlighted: completions.highlighted,
                    onPick: navigate
                )
                .frame(width: 620)
                // Slides out from under the capsule, so the list reads as
                // coming *from* the field rather than appearing beside it.
                .transition(.asymmetric(
                    insertion: .modifier(
                        active: ListEmergence(isEmerging: true),
                        identity: ListEmergence(isEmerging: false)
                    ),
                    removal: .opacity.animation(.easeIn(duration: 0.12))
                ))
            }
            Spacer(minLength: 0)
        }
        // Sits above center — a centered box drifts downward as the
        // suggestion list grows beneath it.
        .padding(.top, 140)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Dark whatever the window's appearance, so the bar reads the same over
        // any page: light text on a dark capsule holds its contrast over a
        // white article and a black video alike, where a light capsule
        // washed out against the one and glared against the other. Set for
        // the whole palette so the suggestions beneath the bar match it.
        .environment(\.colorScheme, .dark)
    }

    // MARK: - The field

    private var field: some View {
        HStack(spacing: 12) {
            // The glyph says where this is going to land, since the page behind
            // the palette is the *current* tab either way.
            Image(systemName: createsTab ? "plus.magnifyingglass" : "magnifyingglass")
                .font(Typeface.figtree(size: 16, weight: 500))
                .foregroundStyle(createsTab ? Color.accentColor : Color.secondary)

            textField

            if !text.isEmpty {
                IconButton(
                    systemName: "xmark",
                    size: 11,
                    weight: .bold,
                    width: 22,
                    height: 22,
                    cornerRadius: 11,
                    help: "Clear"
                ) {
                    text = ""
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 620)
        // Drives the clear button's scale-in; the text binding itself isn't
        // animated, so the transition needs a scope to run in.
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: text.isEmpty)
        .background { capsule }
    }

    private var placeholder: String {
        createsTab ? "Search or enter address — opens a new tab" : "Search or enter address"
    }

    private var textField: some View {
        SurfTextField(
            text: $text,
            placeholder: placeholder,
            font: .systemFont(ofSize: 19, weight: .semibold),
            // An `NSTextField` doesn't take SwiftUI's colour scheme, so the ink
            // is said outright; the placeholder is derived from it.
            textColor: .white,
            onSubmit: submit,
            onMove: { direction in
                guard completions.isShowing else { return }
                completions.moveHighlight(by: direction)
            },
            onCancel: {
                // Escape closes the suggestions first, then the palette —
                // one dismissal per press, never both at once.
                if completions.isShowing {
                    completions.dismiss()
                } else {
                    dismiss()
                }
            }
        )
        .frame(height: 24)
        .onChange(of: text) { _, value in
            // Critically damped enough not to wobble: a list of rows that
            // overshoots its height on every keystroke reads as loose.
            withAnimation(.snappy(duration: 0.22)) {
                completions.update(for: value, isFocused: true)
            }
        }
    }

    private var capsule: some View {
        Color.clear
            // Liquid Glass rather than a flat material: this floats over the
            // page, which is exactly what the material is for. `interactive`
            // lets it respond to the pointer instead of sitting there like a
            // printed panel.
            //
            // A capsule, matching the bar on the new tab screen: this is meant
            // to read as that bar coming forward, and two different corner
            // radii give the game away.
            //
            // Tinted black, not with the accent. The accent tint came on with
            // any text in the field — which is always, since the palette opens
            // on the current address — so in practice the bar was simply pale
            // blue, and the white text on it had less to stand on.
            .glassEffect(.regular.tint(.black.opacity(0.35)).interactive(), in: Capsule())
            // Behind the glass, for the same reason as the sidebar: on its own
            // the glass is thin enough that a busy page competes with what you
            // type. Dark, from the palette's colour scheme.
            .background { Capsule().fill(.thickMaterial) }
            .overlay {
                // No focus ring. Nothing else on screen can take a keystroke
                // while this is up — the backdrop is dimmed and the page is
                // behind it — so an outline announcing "this is focused" is
                // answering a question nobody asked, and a coloured one fights
                // the glass.
                //
                // What replaces it is the edge real glass has: bright along the
                // top where light catches it, fading down the sides.
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.38), .white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
    }

    private func submit() {
        if let entry = completions.highlightedEntry {
            navigate(to: entry)
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.submitFromPalette(text, creatingTab: createsTab)
        close(.submit)
    }

    private func navigate(to entry: HistoryEntry) {
        session.submitFromPalette(entry.url, creatingTab: createsTab)
        close(.submit)
    }

    /// Dismissing is always harmless now: nothing was created on the way in.
    private func dismiss() {
        close(.dismiss)
    }

    private func close(_ reason: PaletteClose) {
        completions.dismiss()
        onClose(reason)
    }
}

/// Why the palette is going away, which decides how it goes.
enum PaletteClose: Equatable {
    /// Escape, or a click outside. Nothing happened, so it settles back and
    /// fades.
    case dismiss
    /// Something was submitted. It lifts toward the top of the window, where
    /// the loading border starts.
    case submit
}

/// The suggestion list's entrance: tucked up under the capsule, slightly
/// compressed, and clear.
private struct ListEmergence: ViewModifier {
    let isEmerging: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isEmerging ? 0 : 1)
            .scaleEffect(x: 1, y: isEmerging ? 0.9 : 1, anchor: .top)
            .offset(y: isEmerging ? -12 : 0)
    }
}
