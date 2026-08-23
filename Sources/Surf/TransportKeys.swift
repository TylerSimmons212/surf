import SwiftUI

/// Arrow-key scrubbing, for the lenses that put a video on a stage.
///
/// Five seconds each way. That is the web's own arrow-key convention —
/// YouTube, Vimeo and the stock HTML5 controls all agree on it — and a
/// transport that disagreed with the muscle memory would be worse than
/// having none.
///
/// The overlay has to hold keyboard focus for a key to arrive at all: the web
/// view is still mounted underneath and would otherwise take it. That is the
/// intended trade for a lens whose premise is one transport on every site,
/// and it is why focus is re-asserted on pointer movement — clicking the
/// video itself hands focus back to the page, and the arrows would quietly
/// stop working with nothing on screen to explain why.
struct TransportKeys: ViewModifier {
    /// Seconds, signed. Wired to whichever skip the lens drives its stage by.
    let skip: (Double) -> Void
    /// Called on a handled key, so the chrome can show what just moved.
    var reveal: () -> Void = {}

    /// The step the arrows take.
    static let step: Double = 5

    @FocusState private var hasKeyboardFocus: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            // No focus ring: this is a transparent overlay over a video, and
            // a blue rectangle around the whole screen is not a transport.
            .focusEffectDisabled()
            .focused($hasKeyboardFocus)
            .onAppear { hasKeyboardFocus = true }
            .onContinuousHover { phase in
                guard case .active = phase, !hasKeyboardFocus else { return }
                hasKeyboardFocus = true
            }
            .onKeyPress(.leftArrow) {
                skip(-Self.step)
                reveal()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                skip(Self.step)
                reveal()
                return .handled
            }
    }
}

extension View {
    /// - Parameters:
    ///   - skip: seconds to move, signed.
    ///   - reveal: shown chrome, so a keyed seek isn't invisible.
    func transportKeys(
        skip: @escaping (Double) -> Void,
        reveal: @escaping () -> Void = {}
    ) -> some View {
        modifier(TransportKeys(skip: skip, reveal: reveal))
    }
}
