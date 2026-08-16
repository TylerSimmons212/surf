import SwiftUI

struct SearchView: View {
    let engine: BrowserEngine

    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground)

            VStack(spacing: 28) {
                Text("Glass")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.85))

                searchBar
                    .frame(maxWidth: 640)

                Text("Type a search or an address, then press Return.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(40)
        }
        .ignoresSafeArea()
        .onAppear { searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search or enter address", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($searchFocused)
                .onSubmit { submit() }

            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            searchFocused ? Color.accentColor.opacity(0.65)
                                          : Color.primary.opacity(0.12),
                            lineWidth: searchFocused ? 2 : 1
                        )
                }
                .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        }
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }

    private func submit() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        engine.submit(query)
    }
}
