import AppKit
import SwiftUI

/// Fades the window's traffic lights in and out.
///
/// The buttons belong to the window, not to the SwiftUI hierarchy, and they
/// render *above* it — which is exactly why they can be overlaid on the page
/// with no strip reserved for them, and also why hiding them can't be done by
/// simply not drawing something.
///
/// Attached as a zero-size, click-through view purely to get at a window from
/// inside the view tree. `WindowGroup` can open more than one window, so
/// reaching for `NSApp.keyWindow` would let one window's reveal drive another's
/// buttons.
struct TrafficLights: NSViewRepresentable {
    let isRevealed: Bool

    func makeNSView(context: Context) -> NSView { TrafficLightHost() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrafficLightHost)?.setRevealed(isRevealed)
    }
}

private final class TrafficLightHost: NSView {
    private var isRevealed = false
    /// Bumped on every change so a fade that's already in flight can't run its
    /// completion against a state that has since flipped — otherwise a quick
    /// out-and-back-in leaves the buttons visible but `isHidden`, i.e. gone.
    private var generation = 0
    private var observers: [any NSObjectProtocol] = []

    /// Sensing and styling only — never in the way of a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Cleared before the guard, so this doubles as teardown: AppKit calls
        // this with a nil window when the view leaves the hierarchy, which is
        // the only unsubscribe hook available — a `deinit` can't touch
        // main-actor state.
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }

        // In full screen the buttons live in the auto-hiding titlebar, which
        // macOS reveals and conceals on its own. Managing them there fights the
        // system and can strand them invisible in a bar the user just pulled
        // down, so hand them back for the duration.
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply(animated: false) }
                }
            )
        }

        apply(animated: false)
    }


    func setRevealed(_ revealed: Bool) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        apply(animated: true)
    }

    private var buttons: [NSButton] {
        guard let window else { return [] }
        return [.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap(window.standardWindowButton)
    }

    private func apply(animated: Bool) {
        let buttons = buttons
        guard !buttons.isEmpty else { return }

        let shouldShow = isRevealed || window?.styleMask.contains(.fullScreen) == true

        generation += 1
        let token = generation

        // Un-hide before fading in: an `isHidden` view won't animate, and alpha
        // alone isn't enough to hide them — a fully transparent AppKit view
        // still hit-tests, so an invisible close button would still be clickable.
        if shouldShow {
            for button in buttons {
                button.isHidden = false
            }
        }

        guard animated else {
            for button in buttons {
                button.alphaValue = shouldShow ? 1 : 0
                button.isHidden = !shouldShow
            }
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = shouldShow ? 0.16 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for button in buttons {
                button.animator().alphaValue = shouldShow ? 1 : 0
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, !shouldShow else { return }
                for button in buttons {
                    button.isHidden = true
                }
            }
        }
    }
}
