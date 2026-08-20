import Foundation

/// Viewport emulation: the page laid out at a chosen CSS-pixel size inside
/// whatever the window happens to give it.
///
/// No scaling and no device chrome, deliberately. A scaled page lies about
/// text legibility and hit-target sizes — the two things being checked — and
/// a bezel drawing is decoration. The web view *is* the chosen size; media
/// queries, viewport units and layout all answer for that size because it is
/// genuinely the size.
public enum ViewportEmulation {

    public struct Preset: Sendable, Equatable, Identifiable {
        public var name: String
        public var size: CGSize

        public var id: String { name }

        public init(name: String, size: CGSize) {
            self.name = name
            self.size = size
        }

        public var label: String {
            "\(name) — \(Int(size.width)) × \(Int(size.height))"
        }
    }

    /// A short list of shapes, not a device catalogue. Each entry earns its
    /// place by being a breakpoint class someone actually designs for; the
    /// parade of near-identical phone models is what "custom" is for, later.
    public static let presets: [Preset] = [
        Preset(name: "Phone", size: CGSize(width: 390, height: 844)),
        Preset(name: "Phone small", size: CGSize(width: 375, height: 667)),
        Preset(name: "Tablet", size: CGSize(width: 820, height: 1180)),
        Preset(name: "Tablet landscape", size: CGSize(width: 1180, height: 820)),
        Preset(name: "Laptop", size: CGSize(width: 1280, height: 800)),
    ]

    /// Where the emulated page sits: centered, pinned to the top when it is
    /// taller than the container — the fold is at the top of a page, so the
    /// top is the end that must stay visible — and never scaled.
    ///
    /// AppKit coordinates (origin bottom-left), because the caller is an
    /// NSView's `layout()`.
    public static func frame(for target: CGSize, in bounds: CGSize) -> CGRect {
        let x = ((bounds.width - target.width) / 2).rounded()
        let y: CGFloat
        if target.height <= bounds.height {
            y = ((bounds.height - target.height) / 2).rounded()
        } else {
            // Flipped math: pinning the page's *top* edge means the frame's
            // bottom sits below the container's floor.
            y = bounds.height - target.height
        }
        return CGRect(x: x, y: y, width: target.width, height: target.height)
    }
}
