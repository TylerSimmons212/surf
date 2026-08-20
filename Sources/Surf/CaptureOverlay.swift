import AppKit
import SurfCore

/// The element-pick veil: the page dims, the element under the pointer stays
/// at full brightness inside a stroked hole, with its size labelled.
///
/// Native, not injected, for the same reason as `InspectorHighlightView` —
/// an overlay `<div>` would answer `elementFromPoint` and poison the very
/// hovers it exists to show. Hit-testing stays transparent: the *page* takes
/// the clicks, and the agent suppresses them in the capture phase so picking
/// a link doesn't also follow it.
final class CaptureOverlayView: NSView {

    private let veilLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private let labelLayer = CATextLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        veilLayer.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        veilLayer.fillRule = .evenOdd
        strokeLayer.fillColor = nil
        strokeLayer.strokeColor = NSColor.systemBlue.cgColor
        strokeLayer.lineWidth = 1.5

        labelLayer.fontSize = 11
        labelLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        labelLayer.foregroundColor = NSColor.white.cgColor
        labelLayer.backgroundColor = NSColor.systemBlue.cgColor
        labelLayer.cornerRadius = 3
        labelLayer.alignmentMode = .center
        labelLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        labelLayer.isHidden = true

        layer?.addSublayer(veilLayer)
        layer?.addSublayer(strokeLayer)
        layer?.addSublayer(labelLayer)

        // Veil the whole page until the first hover arrives.
        show(nil)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Draws the hole at a viewport rect (CSS pixels, top-left origin), or
    /// a full veil when there's nothing under the pointer yet.
    func show(_ hover: CaptureEvent.Hover?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let full = CGPath(rect: bounds, transform: nil)
        guard let hover else {
            veilLayer.path = full
            strokeLayer.path = nil
            labelLayer.isHidden = true
            CATransaction.commit()
            return
        }

        let hole = CGRect(
            x: hover.x,
            y: bounds.height - hover.y - hover.height,
            width: hover.width,
            height: hover.height
        )

        let punched = CGMutablePath()
        punched.addPath(full)
        punched.addRect(hole)
        veilLayer.path = punched
        strokeLayer.path = CGPath(rect: hole.insetBy(dx: -0.75, dy: -0.75), transform: nil)

        let text = "\(Int(hover.width)) × \(Int(hover.height))"
        labelLayer.string = text
        let size = (text as NSString).size(
            withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]
        )
        var y = hole.maxY + 4
        if y + 18 > bounds.height { y = max(0, hole.maxY - 22) }
        labelLayer.frame = CGRect(
            x: min(max(0, hole.minX), max(0, bounds.width - size.width - 12)),
            y: y, width: size.width + 12, height: 18
        )
        labelLayer.contentsScale = window?.backingScaleFactor ?? 2
        labelLayer.isHidden = false

        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // A resize invalidates every cached path; redraw as a full veil and
        // let the next hover event rebuild the hole.
        show(nil)
    }
}
