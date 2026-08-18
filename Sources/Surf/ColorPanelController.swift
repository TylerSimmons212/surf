import AppKit
import SurfCore

extension ResolvedColor {
    /// Whatever space the panel hands back, converted to the one CSS means.
    ///
    /// The picker will happily return Display P3, and writing those components
    /// out as `rgb()` would produce a colour that isn't the one on screen.
    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: Int((srgb.redComponent * 255).rounded()),
            green: Int((srgb.greenComponent * 255).rounded()),
            blue: Int((srgb.blueComponent * 255).rounded()),
            alpha: Int((srgb.alphaComponent * 255).rounded())
        )
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            alpha: opacity
        )
    }
}

/// Drives the system colour picker on behalf of whichever swatch was clicked.
///
/// `NSColorPanel` is a single shared window with one target — which is the
/// right shape for this anyway, since two colour pickers open at once would be
/// a question about which one the page is following. The whole reason to use it
/// rather than draw our own is that it's the picker with the eyedropper, the
/// system palettes, and every colour space, and it already works the way anyone
/// on this machine expects.
@MainActor
final class ColorPanelController: NSObject {
    static let shared = ColorPanelController()

    private var onChange: ((ResolvedColor) -> Void)?
    private var onFinish: (() -> Void)?
    private var closeObserver: NSObjectProtocol?

    /// The latest colour, forwarded on a trailing throttle.
    ///
    /// Dragging in the wheel fires continuously, and each one is a write into
    /// the page. At full rate that's hundreds of round trips for one gesture;
    /// at a frame's cadence it still looks live and costs almost nothing.
    private var pending: ResolvedColor?
    private var throttle: Task<Void, Never>?

    func present(
        startingAt color: ResolvedColor,
        onChange: @escaping (ResolvedColor) -> Void,
        onFinish: @escaping () -> Void
    ) {
        finishIfNeeded()

        self.onChange = onChange
        self.onFinish = onFinish

        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.color = color.nsColor
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ColorPanelController.shared.finishIfNeeded() }
        }
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let color = ResolvedColor(sender.color) else { return }
        pending = color
        guard throttle == nil else { return }

        throttle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            throttle = nil
            guard let latest = pending else { return }
            pending = nil
            onChange?(latest)
        }
    }

    /// Stops following, and lets the caller settle up — the page has been
    /// written to many times by now, but only one of those is worth a reload.
    private func finishIfNeeded() {
        throttle?.cancel()
        throttle = nil

        // A colour still in the throttle window would otherwise be lost, and
        // the page would keep whatever the previous tick wrote.
        if let latest = pending {
            pending = nil
            onChange?(latest)
        }

        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        // Always cleared: the panel is shared, and leaving a stale target on it
        // means a later picker somewhere else in the app drives our callback.
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)

        let finish = onFinish
        onChange = nil
        onFinish = nil
        finish?()
    }
}
