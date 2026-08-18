import AppKit
import SwiftUI

/// An invisible region that reports mouse enter/exit **without intercepting
/// clicks**.
///
/// SwiftUI's `.onHover` requires hit testing, so a hover strip along the window
/// edge would swallow clicks meant for the page underneath. `NSTrackingArea`
/// delivers enter/exit based on the window's mouse tracking, independent of hit
/// testing — so `hitTest` can return nil and let every click through.
struct HoverZone: NSViewRepresentable {
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = HoverTrackingView()
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HoverTrackingView)?.onHoverChange = onHoverChange
    }
}

private final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    /// Click-through: this view is for sensing the pointer only.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                // .inVisibleRect keeps the area correct as the window resizes;
                // .activeAlways so the reveal works before the window is focused.
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}
