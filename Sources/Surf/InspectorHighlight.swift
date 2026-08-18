import AppKit
import SurfCore

/// The element highlight, drawn over the web view rather than inside the page.
///
/// Every other option is worse. An injected overlay `<div>` changes the
/// document you are inspecting: it shows up in the tree you are reading, it
/// answers `elementFromPoint`, it triggers the page's own `MutationObserver`,
/// and it inherits whatever the page did to `div`. This view is native, so the
/// page cannot see it at all — and it gets Core Animation smoothness and real
/// macOS typography for the size label for free.
final class InspectorHighlightView: NSView {

    /// Chrome's palette, near enough that it reads as familiar: blue content,
    /// green padding, orange margin.
    private enum Palette {
        static let content = NSColor(srgbRed: 0.45, green: 0.68, blue: 0.94, alpha: 0.55)
        static let padding = NSColor(srgbRed: 0.60, green: 0.83, blue: 0.53, alpha: 0.45)
        static let margin = NSColor(srgbRed: 0.96, green: 0.76, blue: 0.42, alpha: 0.40)
        static let outline = NSColor(srgbRed: 0.30, green: 0.55, blue: 0.90, alpha: 0.95)
    }

    private let marginLayer = CAShapeLayer()
    private let paddingLayer = CAShapeLayer()
    private let contentLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let labelLayer = CATextLayer()

    /// The page's height in CSS pixels, needed to flip from the web's
    /// top-left origin into AppKit's bottom-left one.
    var pageHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        for shape in [marginLayer, paddingLayer, contentLayer, outlineLayer] {
            shape.fillColor = nil
            shape.strokeColor = nil
            layer?.addSublayer(shape)
        }
        marginLayer.fillColor = Palette.margin.cgColor
        paddingLayer.fillColor = Palette.padding.cgColor
        contentLayer.fillColor = Palette.content.cgColor
        outlineLayer.strokeColor = Palette.outline.cgColor
        outlineLayer.lineWidth = 1

        labelLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        labelLayer.fontSize = 11
        labelLayer.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        labelLayer.foregroundColor = NSColor.white.cgColor
        labelLayer.backgroundColor = Palette.outline.cgColor
        labelLayer.cornerRadius = 3
        labelLayer.alignmentMode = .center
        labelLayer.isHidden = true
        layer?.addSublayer(labelLayer)

        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    /// Never takes a click — except while picking, when taking clicks is the
    /// entire job. Ordinary browsing must not notice this view exists.
    var isPicking = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isFlipped: Bool { false }

    func show(_ box: BoxModel) {
        // The web hands out top-left coordinates; AppKit draws from the bottom.
        func flip(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX,
                y: bounds.height - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        }

        let border = flip(box.frame)
        guard border.width > 0 || border.height > 0 else { clear(); return }

        CATransaction.begin()
        // The page can move an element every frame; an implicit animation on
        // each of these would smear the highlight across the screen.
        CATransaction.setDisableActions(true)

        marginLayer.path = CGPath(rect: flip(box.marginFrame), transform: nil)
        paddingLayer.path = CGPath(rect: flip(box.paddingFrame), transform: nil)
        contentLayer.path = CGPath(rect: flip(box.contentFrame), transform: nil)
        outlineLayer.path = CGPath(rect: border.insetBy(dx: -0.5, dy: -0.5), transform: nil)

        layoutLabel(for: box, at: border)

        CATransaction.commit()
        isHidden = false
    }

    private func layoutLabel(for box: BoxModel, at border: CGRect) {
        let text = "\(box.tagName)  \(box.sizeLabel)"
        labelLayer.string = text

        let size = (text as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        )
        let width = size.width + 12
        let height: CGFloat = 18

        // Above the element by preference, tucked inside when there's no room
        // — a label that runs off the top of the window tells you nothing.
        var y = border.maxY + 4
        if y + height > bounds.height { y = max(0, border.maxY - height - 4) }
        let x = min(max(0, border.minX), max(0, bounds.width - width))

        labelLayer.frame = CGRect(x: x, y: y, width: width, height: height)
        // CATextLayer draws from the top of its box; nudge for optical centre.
        labelLayer.contentsScale = window?.backingScaleFactor ?? 2
        labelLayer.isHidden = false
    }

    func clear() {
        isHidden = true
        labelLayer.isHidden = true
    }
}
