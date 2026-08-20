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

    /// Firefox's grid purple and a flex teal, because those are the colours
    /// this feature's users already have burned in.
    private enum LayoutPalette {
        static let grid = NSColor(srgbRed: 0.58, green: 0.29, blue: 0.90, alpha: 1)
        static let flex = NSColor(srgbRed: 0.05, green: 0.55, blue: 0.55, alpha: 1)
    }

    private let marginLayer = CAShapeLayer()
    private let paddingLayer = CAShapeLayer()
    private let contentLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let labelLayer = CATextLayer()

    // The layout overlay draws independently of the element highlight: you
    // arm a grid and then go hover other nodes, and losing the grid every
    // time the highlight moved would defeat the point of arming it.
    private let layoutFrameLayer = CAShapeLayer()
    private let layoutLinesLayer = CAShapeLayer()
    private let layoutGapsLayer = CAShapeLayer()
    private var layoutNumberLayers: [CATextLayer] = []

    private var boxVisible = false
    private var layoutVisible = false

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

        layoutGapsLayer.fillColor = LayoutPalette.grid.withAlphaComponent(0.12).cgColor
        layoutGapsLayer.strokeColor = nil
        layoutLinesLayer.fillColor = nil
        layoutLinesLayer.lineWidth = 1
        layoutLinesLayer.lineDashPattern = [4, 3]
        layoutFrameLayer.fillColor = nil
        layoutFrameLayer.lineWidth = 1.5
        for shape in [layoutGapsLayer, layoutLinesLayer, layoutFrameLayer] {
            layer?.addSublayer(shape)
        }

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
        boxVisible = true
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
        boxVisible = false
        labelLayer.isHidden = true
        for shape in [marginLayer, paddingLayer, contentLayer, outlineLayer] {
            shape.path = nil
        }
        isHidden = !layoutVisible
    }

    // MARK: - Layout overlay

    func setLayout(_ overlay: LayoutOverlay?) {
        guard let overlay else {
            layoutVisible = false
            for shape in [layoutFrameLayer, layoutLinesLayer, layoutGapsLayer] {
                shape.path = nil
            }
            for label in layoutNumberLayers { label.isHidden = true }
            isHidden = !boxVisible
            return
        }

        func flip(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX, y: bounds.height - rect.maxY,
                width: rect.width, height: rect.height
            )
        }
        // A single y is flipped as a zero-height rect's edge.
        func flipY(_ y: Double) -> CGFloat { bounds.height - CGFloat(y) }

        let tint = overlay.kind == .grid ? LayoutPalette.grid : LayoutPalette.flex

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        layoutFrameLayer.strokeColor = tint.cgColor
        layoutLinesLayer.strokeColor = tint.withAlphaComponent(0.8).cgColor
        layoutGapsLayer.fillColor = tint.withAlphaComponent(0.12).cgColor

        let frame = flip(overlay.bounds)
        layoutFrameLayer.path = CGPath(rect: frame, transform: nil)

        let lines = CGMutablePath()
        let gaps = CGMutablePath()
        var numbers: [(text: String, at: CGPoint)] = []

        switch overlay.kind {
        case .grid:
            for line in LayoutOverlayGeometry.lines(for: overlay.columns) {
                let x = CGFloat(line.position)
                lines.move(to: CGPoint(x: x, y: frame.minY))
                lines.addLine(to: CGPoint(x: x, y: frame.maxY))
                numbers.append((
                    "\(line.number)", CGPoint(x: x, y: frame.maxY + 2)
                ))
            }
            for line in LayoutOverlayGeometry.lines(for: overlay.rows) {
                let y = flipY(line.position)
                lines.move(to: CGPoint(x: frame.minX, y: y))
                lines.addLine(to: CGPoint(x: frame.maxX, y: y))
                numbers.append((
                    "\(line.number)", CGPoint(x: frame.minX - 14, y: y - 7)
                ))
            }
            for gap in LayoutOverlayGeometry.gaps(in: overlay.columns) {
                gaps.addRect(CGRect(
                    x: gap.start, y: frame.minY,
                    width: gap.end - gap.start, height: frame.height
                ))
            }
            for gap in LayoutOverlayGeometry.gaps(in: overlay.rows) {
                gaps.addRect(CGRect(
                    x: frame.minX, y: flipY(gap.end),
                    width: frame.width, height: gap.end - gap.start
                ))
            }

        case .flex:
            for item in overlay.items {
                lines.addRect(flip(item))
            }
        }

        layoutLinesLayer.path = lines
        layoutGapsLayer.path = gaps
        placeNumbers(numbers, tint: tint)

        CATransaction.commit()
        layoutVisible = true
        isHidden = false
    }

    /// A pooled set of tiny labels — a 12-column grid is 13 numbers per axis,
    /// and building text layers per frame during a scroll would churn.
    private func placeNumbers(_ numbers: [(text: String, at: CGPoint)], tint: NSColor) {
        while layoutNumberLayers.count < numbers.count {
            let label = CATextLayer()
            label.fontSize = 9
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            label.foregroundColor = NSColor.white.cgColor
            label.cornerRadius = 2
            label.alignmentMode = .center
            label.contentsScale = window?.backingScaleFactor ?? 2
            layer?.addSublayer(label)
            layoutNumberLayers.append(label)
        }
        for (index, label) in layoutNumberLayers.enumerated() {
            guard index < numbers.count else { label.isHidden = true; continue }
            let (text, at) = numbers[index]
            label.backgroundColor = tint.withAlphaComponent(0.85).cgColor
            label.string = text
            label.frame = CGRect(x: at.x - 7, y: at.y, width: 14, height: 12)
            label.isHidden = false
        }
    }
}
