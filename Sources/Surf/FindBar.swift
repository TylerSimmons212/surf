import SurfCore
import SwiftUI

/// Find in page.
///
/// A small floating bar rather than a strip that pushes the page down: the
/// window is nothing but page, and shoving the content around to search it
/// loses your place at the exact moment you're trying to find something.
struct FindBar: View {
    let tab: Tab
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var matches = 0
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Find in page", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .tint(Color.accentColor)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { step(forward: true) }
                .onChange(of: query) { _, value in search(value) }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }

            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(hasResults ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .frame(minWidth: 66, alignment: .trailing)
            }

            Divider().frame(height: 16)

            IconButton(
                systemName: "chevron.up",
                size: 10, weight: .semibold, width: 22, height: 22, cornerRadius: 6,
                isEnabled: hasResults,
                help: "Previous Match (⇧⌘G)"
            ) { step(forward: false) }

            IconButton(
                systemName: "chevron.down",
                size: 10, weight: .semibold, width: 22, height: 22, cornerRadius: 6,
                isEnabled: hasResults,
                help: "Next Match (⌘G)"
            ) { step(forward: true) }

            IconButton(
                systemName: "xmark",
                size: 10, weight: .bold, width: 22, height: 22, cornerRadius: 6,
                help: "Done (esc)"
            ) { dismiss() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .shadow(color: .black.opacity(0.22), radius: 16, y: 5)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .surfFindStep)) { note in
            step(forward: note.object as? Bool ?? true)
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var status: String {
        FindStatus.summary(query: query, matches: matches)
    }

    private var hasResults: Bool {
        FindStatus.hasResults(query: query, matches: matches)
    }

    func step(forward: Bool) {
        guard !query.isEmpty else { return }
        Task { @MainActor in
            await tab.findInPage(query, forward: forward)
        }
    }

    /// Debounced: typing "swift" would otherwise run five searches and five
    /// counts, and the count walks the whole page's text.
    private func search(_ value: String) {
        searchTask?.cancel()
        guard !value.isEmpty else {
            matches = 0
            tab.clearFindSelection()
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            let count = await tab.countMatches(of: value)
            guard !Task.isCancelled else { return }
            matches = count
            // Search from the top on each edit, so refining a query doesn't
            // leave you somewhere further down the page than you expect.
            await tab.findInPage(value, forward: true)
        }
    }

    private func dismiss() {
        searchTask?.cancel()
        tab.clearFindSelection()
        isPresented = false
    }
}


extension Notification.Name {
    /// ⌘G / ⇧⌘G, delivered to whichever find bar is on screen.
    static let surfFindStep = Notification.Name("surf.find.step")
}
