import AppKit
import SwiftUI

/// Places the window's traffic lights on the sidebar's grid, and fades them
/// in and out with it.
///
/// The buttons belong to the window, not to the SwiftUI hierarchy — and their
/// position belongs to AppKit's titlebar tiling, which holds them in the stock
/// corner no matter who moves what: nudge a button and the next tiling pass
/// compensates it straight back; nudge the titlebar container and the buttons
/// are counter-shifted inside it. The one placement AppKit doesn't fight is
/// the buttons living somewhere else entirely — so they're adopted out of the
/// titlebar into a group view Surf owns and positions, and handed back for
/// full screen, where the auto-hiding titlebar must own them again.
///
/// Attached as a zero-size, click-through view purely to get at a window from
/// inside the view tree. `WindowGroup` can open more than one window, so
/// reaching for `NSApp.keyWindow` would let one window's reveal drive
/// another's buttons.
struct TrafficLights: NSViewRepresentable {
    let isRevealed: Bool
    /// Where the buttons' row begins, from the window's leading edge — chosen
    /// by the caller to sit on the sidebar's content grid rather than at
    /// AppKit's stock corner position.
    let leadingInset: CGFloat
    /// The vertical centre of the row they occupy, measured from the window's
    /// top edge, so the buttons centre in the strip the sidebar holds clear.
    let rowCenterFromTop: CGFloat

    func makeNSView(context: Context) -> NSView { TrafficLightHost() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? TrafficLightHost else { return }
        host.setPlacement(leadingInset: leadingInset, rowCenterFromTop: rowCenterFromTop)
        host.setRevealed(isRevealed)
    }
}

private final class TrafficLightHost: NSView {
    private var isRevealed = false
    private var leadingInset: CGFloat = 7
    private var rowCenterFromTop: CGFloat = 14

    /// Bumped on every change so a fade that's already in flight can't run its
    /// completion against a state that has since flipped — otherwise a quick
    /// out-and-back-in leaves the buttons visible but `isHidden`, i.e. gone.
    private var generation = 0
    private var observers: [any NSObjectProtocol] = []

    /// The view the buttons live in while Surf is placing them.
    private var group: LightsGroupView?
    /// Where each button came from and how it sat there, for handing back.
    private var homes: [(button: NSButton, superview: NSView, frame: NSRect)] = []

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
        // macOS reveals and conceals on its own. Managing them there fights
        // the system and can strand them invisible in a bar the user just
        // pulled down, so hand them back for the duration.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.returnHome()
                    self?.apply(animated: false)
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.adoptIfNeeded()
                    self?.apply(animated: false)
                }
            }
        )

        adoptIfNeeded()
        apply(animated: false)
    }

    func setPlacement(leadingInset: CGFloat, rowCenterFromTop: CGFloat) {
        guard leadingInset != self.leadingInset || rowCenterFromTop != self.rowCenterFromTop
        else { return }
        self.leadingInset = leadingInset
        self.rowCenterFromTop = rowCenterFromTop
        place()
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

    // MARK: - Adoption

    /// Lifts the buttons out of the titlebar into the group Surf places.
    private func adoptIfNeeded() {
        guard group == nil,
              let window,
              !window.styleMask.contains(.fullScreen),
              let frameView = window.contentView?.superview
        else { return }
        let buttons = buttons
        guard buttons.count == 3, buttons.allSatisfy({ $0.superview != nil }) else { return }

        // Stock metrics, read before anything moves.
        homes = buttons.map { ($0, $0.superview!, $0.frame) }

        let group = LightsGroupView()
        // Flexible bottom margin: glued to the window's top edge through
        // resizes, so there is nothing to re-apply and no one to fight.
        group.autoresizingMask = [.minYMargin]
        // Appended last — the top of the frame view's stack — and raised
        // above its siblings' layers besides. The buttons drew over all
        // content from the titlebar and must go on doing so from here; an
        // insertion relative to the content view turned out to sort *below*
        // the SwiftUI hierarchy, which showed as the lights simply missing.
        group.wantsLayer = true
        group.layer?.zPosition = 1000
        frameView.addSubview(group)

        // The buttons keep whatever frames they have — and whatever frames
        // AppKit's tiling gives them later. Tiling stamps their stock local
        // coordinates even in a foreign superview, and moving them back is a
        // war (each move triggers another tiling pass). So the buttons are
        // never touched: `place` positions the *group* to compensate, and a
        // frame the tiling changes is answered by re-placing the group, which
        // tiling doesn't care about. No cycle either way.
        for button in buttons {
            group.addSubview(button)
            button.postsFrameChangedNotifications = true
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: button, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                }
            )
        }

        self.group = group
        place()
    }

    /// Puts the buttons back exactly where the titlebar had them.
    private func returnHome() {
        guard group != nil else { return }
        for home in homes {
            home.superview.addSubview(home.button)
            home.button.frame = home.frame
        }
        group?.removeFromSuperview()
        group = nil
        homes = []
    }

    /// Positions the group so the close button lands `leadingInset` in from
    /// the window's leading edge, centred on `rowCenterFromTop`.
    ///
    /// Computed off the close button's *current* local frame rather than an
    /// assumed origin, because the buttons' local coordinates belong to
    /// AppKit's tiling — wherever it puts them inside the group, the group's
    /// origin absorbs the difference.
    private func place() {
        guard let group, let frameView = group.superview,
              let close = window?.standardWindowButton(.closeButton),
              close.superview === group
        else { return }

        // Sized to cover the buttons wherever they locally sit, so the hover
        // tracking area under them never has a hole.
        let union = group.subviews.reduce(NSRect.zero) { $0.union($1.frame) }
        group.setFrameSize(NSSize(width: union.maxX, height: union.maxY))

        group.setFrameOrigin(NSPoint(
            x: leadingInset - close.frame.minX,
            y: frameView.bounds.height - rowCenterFromTop - close.frame.midY
        ))
    }

    // MARK: - Fading

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

/// The buttons' new home, which also answers for their hover state.
///
/// The ×/−/+ glyphs only draw while AppKit believes the pointer is over the
/// button *group*, and it asks the buttons' superview — normally the titlebar
/// — via `_mouseInGroup:`. Out of the titlebar, that job comes with the
/// custody: track the pointer and answer the same question.
private final class LightsGroupView: NSView {
    private var isMouseInside = false

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        redrawButtons()
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        redrawButtons()
    }

    /// AppKit's own question, answered from our tracking. Private selector by
    /// name, but the shape is long-stable and the failure mode is only
    /// glyphless buttons — they stay clickable either way.
    @objc func _mouseInGroup(_ button: NSButton) -> Bool { isMouseInside }

    private func redrawButtons() {
        for view in subviews {
            view.needsDisplay = true
        }
    }
}
