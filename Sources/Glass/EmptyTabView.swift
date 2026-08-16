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

    var body: some View {
        VStack(spacing: 18) {
            Text("Glass")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.5))

            Button(action: onOpenAddressBar) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                    Text("Search or enter address")
                        .font(.system(size: 13))
                    Text("⌘L")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(0.09))
                        }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background {
                    Capsule()
                        .fill(Color.primary.opacity(isHovering ? 0.09 : 0.05))
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .scaleEffect(isHovering ? 1.03 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isHovering)
            .onHover { isHovering = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
