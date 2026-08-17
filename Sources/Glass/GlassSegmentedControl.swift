import SwiftUI

/// A segmented control built from Liquid Glass rather than AppKit's.
///
/// The stock `.segmented` picker draws an opaque, bevelled control that reads
/// as a system dialog dropped into the window — precisely the look the rest of
/// Glass avoids. Here the selection is a glass capsule that slides between
/// segments, so switching panes is one object moving rather than two controls
/// swapping state.
struct GlassSegmentedControl<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    let symbol: (Value) -> String

    @Namespace private var glass
    @State private var hovered: Value?

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    segment(option)
                }
            }
            .padding(2)
        }
        .background {
            Capsule().fill(DevToolsTheme.inputFill)
        }
        .clipShape(Capsule())
    }

    private func segment(_ option: Value) -> some View {
        let isSelected = option == selection

        return Button {
            // The capsule glides to the new segment rather than cutting, which
            // is what makes it read as one object moving.
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                selection = option
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol(option))
                    .font(.system(size: 10, weight: .medium))
                Text(label(option))
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        // Ties the two capsules together so SwiftUI animates
                        // one moving instead of cross-fading two.
                        .glassEffectID("selection", in: glass)
                } else if hovered == option {
                    Capsule().fill(DevToolsTheme.hoverFill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? option : (hovered == option ? nil : hovered) }
    }
}
