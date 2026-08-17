import GlassCore
import SwiftUI

/// The floating address bar: a centered, focused input over a dimmed window.
///
/// Replaces the persistent toolbar. Nothing occupies the window until it's
/// asked for, which is the point — the page gets the whole surface.
struct URLPalette: View {
    let session: BrowserSession
    let tab: Tab
    /// Whether submitting opens a new tab rather than navigating this one. The
    /// tab is created on submit, so dismissing costs nothing.
    let createsTab: Bool
    @Binding var isPresented: Bool

    @State private var text: String = ""
    @State private var completions = SuggestionController()
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // Dimmed backdrop; clicking anywhere outside dismisses.
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 8) {
                field
                if completions.isShowing {
                    SuggestionList(
                        suggestions: completions.suggestions,
                        highlighted: completions.highlighted,
                        onPick: navigate
                    )
                    .frame(width: 620)
                }
                Spacer(minLength: 0)
            }
            // Sits above center — a centered box drifts downward as the
            // suggestion list grows beneath it.
            .padding(.top, 140)
        }
        .onAppear {
            // A new tab starts empty; editing an existing one starts from where
            // it already is.
            text = (createsTab || tab.mode == .home) ? "" : tab.addressText
            focused = true
        }
    }

    private var field: some View {
        HStack(spacing: 12) {
            // The glyph says where this is going to land, since the page behind
            // the palette is the *current* tab either way.
            Image(systemName: createsTab ? "plus.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(createsTab ? Color.accentColor : Color.secondary)

            TextField(createsTab ? "Search or enter address — opens a new tab"
                                 : "Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($focused)
                .onSubmit(submit)
                .onChange(of: text) { _, value in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        completions.update(for: value, isFocused: true)
                    }
                }
                .onKeyPress(.downArrow) {
                    guard completions.isShowing else { return .ignored }
                    completions.moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard completions.isShowing else { return .ignored }
                    completions.moveHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    // Escape closes the suggestions first, then the palette —
                    // one dismissal per press, never both at once.
                    if completions.isShowing {
                        completions.dismiss()
                    } else {
                        dismiss()
                    }
                    return .handled
                }

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
                    focused = true
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
        // Liquid Glass rather than a flat material: this floats over the page,
        // which is exactly what the material is for. `interactive` lets it
        // respond to the pointer instead of sitting there like a printed panel.
        //
        // A capsule, matching the bar on the new tab screen: this is meant to
        // read as that bar coming forward, and two different corner radii give
        // the game away.
        .glassEffect(.regular.interactive(), in: Capsule())
        .overlay {
            // Thinner than before: glass draws its own edge, so the focus ring
            // only has to tint it rather than outline the whole shape.
            Capsule()
                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1.5)
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
        dismiss()
    }

    private func navigate(to entry: HistoryEntry) {
        session.submitFromPalette(entry.url, creatingTab: createsTab)
        dismiss()
    }

    /// Dismissing is always harmless now: nothing was created on the way in.
    private func dismiss() {
        completions.dismiss()
        focused = false
        isPresented = false
    }
}
