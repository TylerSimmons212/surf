import SwiftUI
import AppKit

/// A translucent backdrop that blurs whatever is *behind* the window.
///
/// SwiftUI's `.ultraThinMaterial` blends within the window only, so it can never
/// show the desktop through. `NSVisualEffectView` with `.behindWindow` blending
/// can — but only if the hosting window is itself non-opaque with a clear
/// background. This one only draws; `WindowGround` is the one that arranges for
/// that to be true.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
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

/// The main window's ground: the blur above, plus the window configuration that
/// makes a blur of what is *behind* the window possible at all.
///
/// Split from `VisualEffectBackground` because it does something that view's
/// name does not admit to — it reaches out and reconfigures whatever window it
/// lands in, down to taking over the frame. That is exactly right for the one
/// window it is meant for and wrong everywhere else: dropping it into the mini
/// window's chrome would have handed a floating panel's frame to
/// `MainWindowFrame` and let it overwrite the main window's remembered size.
/// Anything that just wants a blur wants the other one.
struct WindowGround: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = TransparentHostView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
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

        // Size and position across launches, which SwiftUI cannot be left to
        // do — see MainWindowFrame for what it does instead and why.
        MainWindowFrame.shared.adopt(window)
    }
}
