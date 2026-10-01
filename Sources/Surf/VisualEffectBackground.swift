import SwiftUI
import AppKit

/// A translucent backdrop that blurs whatever is *behind* the window.
///
/// SwiftUI's `.ultraThinMaterial` blends within the window only, so it can never
/// show the desktop through. `NSVisualEffectView` with `.behindWindow` blending
/// can — but only if the hosting window is itself non-opaque with a clear
/// background, which is configured here as soon as the view is attached.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = TransparentHostView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        // Without this the effect view paints an opaque fill on first draw.
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Configures the window the moment the view is attached to one. Doing this in
/// `applicationDidFinishLaunching` is unreliable — the window may not exist yet.
private final class TransparentHostView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        // Guarded, and the guard is the point. Assigning `styleMask` rebuilds
        // the window's theme frame even when the value is unchanged, and a
        // rebuilt titlebar repossesses the traffic lights — which Surf has
        // moved into the sidebar. Writing it only when it is actually wrong
        // keeps that rebuild to the one time it is needed.
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        // With no titlebar to grab, dragging the background moves the window.
        window.isMovableByWindowBackground = true

        // Restores size and position across launches. Assigning the name also
        // applies any saved frame immediately.
        window.setFrameAutosaveName("SurfMainWindow")
    }
}
