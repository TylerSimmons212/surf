import SwiftUI

/// A board seen from above, lying on its side: pointed nose on the right,
/// fuller tail on the left, widest just behind the middle.
///
/// The outline is a superellipse rather than a hand-placed set of curves, so it
/// scales with the field instead of being a fixed inset that looks wrong at a
/// different width. Each half gets its own exponent, which is what makes it a
/// board rather than a lens: a real one is not symmetric end to end, and drawing
/// it that way is exactly what made the first version read as a damaged capsule.
///
/// - `nose` is the right half, and lower means more pointed. Below about 2 it
///   stops being somewhere you can put text.
/// - `tail` is the left half, and higher means blunter — this end holds the
///   search glyph, so it stays close to full height.
/// - `peak` is where the widest point sits. Behind the middle, as on a board,
///   which is what gives the nose the longer run.
struct SurfboardShape: InsettableShape {
    var nose: CGFloat = 2.3
    var tail: CGFloat = 4.2
    var peak: CGFloat = 0.40
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
            // Each half is measured from the widest point outward, so the two
            // exponents meet there at full height and the join is smooth.
            let (d, n) = u < peak
                ? ((peak - u) / peak, tail)
                : ((u - peak) / (1 - peak), nose)
            return halfHeight * pow(max(0, 1 - pow(d, n)), 1 / n)
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
        SurfboardShape(nose: nose, tail: tail, peak: peak, inset: inset + amount)
    }
}
