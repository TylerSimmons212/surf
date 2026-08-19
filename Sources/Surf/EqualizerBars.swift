import SwiftUI

/// The little dancing bars that mean "this is the thing making noise".
///
/// Replaces a coloured progress bar as the player's at-rest playing signal. A
/// filling bar is the web's universal shape for *waiting* — a page loading, a
/// file downloading — so using it for playback position made a playing tab read
/// as a stuck one. This says the one thing the bar was being asked to say, and
/// says it in the shape every music app already uses for it.
struct EqualizerBars: View {
    var isAnimating: Bool
    var color: Color = .accentColor

    /// Different periods per bar, none of them multiples of each other, so the
    /// bars never fall into step and start reading as a single blinking block.
    private let periods: [Double] = [0.62, 0.44, 0.78, 0.53]
    private let lowest: CGFloat = 0.28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isSwinging = false

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(periods.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2)
                    .scaleEffect(y: height(index), anchor: .center)
                    .animation(animation(index), value: isSwinging)
            }
        }
        .frame(height: 11)
        // Paused bars sit still rather than disappearing: the row keeps its
        // shape, so pausing doesn't shuffle the layout under the pointer.
        .opacity(isAnimating ? 1 : 0.35)
        .animation(.easeOut(duration: 0.2), value: isAnimating)
        .onAppear { isSwinging = true }
        .accessibilityHidden(true)
    }

    /// Bars are driven by one shared flag, so every animation starts from the
    /// same state change and the staggered periods do the rest.
    private func height(_ index: Int) -> CGFloat {
        guard isAnimating, !reduceMotion else { return staticHeight(index) }
        return isSwinging ? 1 : lowest
    }

    /// A fixed silhouette when there's nothing to animate — still legible as an
    /// equalizer rather than four identical ticks.
    private func staticHeight(_ index: Int) -> CGFloat {
        [0.5, 1, 0.7, 0.85][index % 4]
    }

    private func animation(_ index: Int) -> Animation? {
        guard isAnimating, !reduceMotion else { return .easeOut(duration: 0.2) }
        return .easeInOut(duration: periods[index]).repeatForever(autoreverses: true)
    }
}
