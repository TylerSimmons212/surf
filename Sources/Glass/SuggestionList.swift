import GlassCore
import SwiftUI

/// The autocomplete dropdown. Rendered by both the toolbar address field and
/// the home search bar, so the keyboard behaviour stays identical in each.
struct SuggestionList: View {
    let suggestions: [HistoryEntry]
    let highlighted: Int
    let onPick: (HistoryEntry) -> Void

    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, entry in
                row(entry, isHighlighted: index == highlighted)
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        }
    }

    private func row(_ entry: HistoryEntry, isHighlighted: Bool) -> some View {
        // Keyboard highlight and mouse hover share one visual state; the
        // keyboard wins so arrowing down isn't fought by a resting cursor.
        let isActive = isHighlighted || (hovered == entry.id && highlighted < 0)

        return HStack(spacing: 8) {
            icon(for: entry)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? entry.displayURL : entry.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(entry.displayURL)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(isActive ? 0.85 : 0))
        }
        .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(Rectangle())
        .onTapGesture { onPick(entry) }
        .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
    }

    @ViewBuilder
    private func icon(for entry: HistoryEntry) -> some View {
        let host = URL(string: entry.url)?.host
        if let host, let favicon = FaviconStore.shared.cachedIcon(forHost: host) {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
    }
}

/// Keyboard and query state for an autocompleting text field.
///
/// Kept as one observable object rather than loose `@State` so the toolbar and
/// the home screen can't drift apart in behaviour.
@Observable
@MainActor
final class SuggestionController {
    private(set) var suggestions: [HistoryEntry] = []
    /// -1 means "nothing selected": Return submits exactly what was typed.
    private(set) var highlighted: Int = -1

    var isShowing: Bool { !suggestions.isEmpty }

    var highlightedEntry: HistoryEntry? {
        guard highlighted >= 0, highlighted < suggestions.count else { return nil }
        return suggestions[highlighted]
    }

    func update(for query: String, isFocused: Bool) {
        guard isFocused, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            dismiss()
            return
        }
        suggestions = HistoryStore.shared.suggestions(for: query)
        // Typing invalidates the previous selection — otherwise Return could
        // navigate somewhere the list no longer even shows.
        highlighted = -1
    }

    func dismiss() {
        suggestions = []
        highlighted = -1
    }

    /// Moves the selection, stopping at "nothing selected" above the first row
    /// so the user can always get back to their literal input.
    func moveHighlight(by offset: Int) {
        guard isShowing else { return }
        let next = highlighted + offset
        highlighted = max(-1, min(next, suggestions.count - 1))
    }
}
