import SwiftUI

/// A board seen from above, lying on its side: full through the middle, drawn
/// out to soft points at both ends.
///
/// The outline is a superellipse rather than a hand-placed set of curves, so
/// it stays symmetric at any size and the taper scales with the length instead
/// of being a fixed inset that looks wrong on a short field.
///
/// `fullness` is that superellipse's exponent, and it is the whole design. At 2
/// this is an ellipse — a lens, too pointed to type in. Climbing from there
/// squares the middle out while leaving the ends drawn: at 3.4 the field is
/// full height across the middle two thirds and only the last sixth tapers,
/// which reads as a board rather than as a damaged capsule.
struct SurfboardShape: InsettableShape {
    var fullness: CGFloat = 3.4
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }

        let halfHeight = r.height / 2
        let midY = r.midY
        // Half-height at a fraction along the length. The exponent gives a
        // vertical tangent at each tip, so they arrive rounded rather than as
        // the sharp corner an ellipse's ends would make against a stroke.
        func h(_ t: CGFloat) -> CGFloat {
            let u = min(max(t, 0), 1)
            let d = abs(2 * u - 1)
            return halfHeight * pow(max(0, 1 - pow(d, fullness)), 1 / fullness)
        }

        // Sampled and smoothed rather than solved: the curve has no exact Bézier
        // form, and enough samples to be under a pixel is cheaper than the
        // algebra. Cosine spacing puts them where the outline actually turns.
        let steps = 48
        let points: [CGPoint] = (0...steps).map { i in
            let t = (1 - cos(.pi * CGFloat(i) / CGFloat(steps))) / 2
            return CGPoint(x: r.minX + r.width * t, y: midY - h(t))
        }

        var path = Path()
        path.move(to: points[0])
        addSmooth(points, to: &path)                                  // top edge
        addSmooth(points.reversed().map { CGPoint(x: $0.x, y: 2 * midY - $0.y) }, to: &path)
        path.closeSubpath()
        return path
    }

    /// Catmull-Rom through the samples, expressed as the cubics `Path` takes.
    private func addSmooth(_ p: [CGPoint], to path: inout Path) {
        guard p.count > 1 else { return }
        if path.isEmpty { path.move(to: p[0]) } else { path.addLine(to: p[0]) }
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            )
        }
    }

    func inset(by amount: CGFloat) -> SurfboardShape {
        SurfboardShape(fullness: fullness, inset: inset + amount)
    }
}
