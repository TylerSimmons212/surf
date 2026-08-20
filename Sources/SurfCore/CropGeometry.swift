import Foundation

/// The crop rectangle's drag algebra: which handle a point means, and where
/// the rect goes when that handle moves.
///
/// Pure and tested because nine handles × two axes × two clamps (a minimum
/// size, the image's bounds) is a bug farm when written inline in a gesture
/// handler — an edge that crosses its opposite edge, a corner that escapes
/// the image, a rect that inverts when dragged past minimum. Every rule
/// lives here; the view only forwards translations.
public enum CropGeometry {

    public enum Handle: CaseIterable, Sendable, Equatable {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
        /// Anywhere inside: the whole rect rides the drag.
        case move
    }

    /// Which handle a touch at `point` addresses, or nil when the point is
    /// outside the rect's reach entirely. Edges win over the interior, and
    /// corners over edges — the corner *is* two edges, and must be grabbable
    /// at their meeting.
    public static func handle(
        at point: CGPoint, in rect: CGRect, tolerance: CGFloat = 10
    ) -> Handle? {
        let nearLeft = abs(point.x - rect.minX) <= tolerance
        let nearRight = abs(point.x - rect.maxX) <= tolerance
        let nearTop = abs(point.y - rect.minY) <= tolerance
        let nearBottom = abs(point.y - rect.maxY) <= tolerance
        let insideX = point.x >= rect.minX - tolerance && point.x <= rect.maxX + tolerance
        let insideY = point.y >= rect.minY - tolerance && point.y <= rect.maxY + tolerance

        guard insideX, insideY else { return nil }

        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default:
            return rect.contains(point) ? .move : nil
        }
    }

    /// The rect after dragging `handle` by `delta`, clamped to `bounds` and
    /// never smaller than `minSize`. Top-left origin, matching both SwiftUI
    /// views and image rows.
    public static func drag(
        _ rect: CGRect,
        handle: Handle,
        by delta: CGSize,
        in bounds: CGRect,
        minSize: CGFloat = 24
    ) -> CGRect {
        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY

        func movesLeft() { minX = min(max(bounds.minX, minX + delta.width), maxX - minSize) }
        func movesRight() { maxX = max(min(bounds.maxX, maxX + delta.width), minX + minSize) }
        func movesTop() { minY = min(max(bounds.minY, minY + delta.height), maxY - minSize) }
        func movesBottom() { maxY = max(min(bounds.maxY, maxY + delta.height), minY + minSize) }

        switch handle {
        case .topLeft: movesLeft(); movesTop()
        case .top: movesTop()
        case .topRight: movesRight(); movesTop()
        case .left: movesLeft()
        case .right: movesRight()
        case .bottomLeft: movesLeft(); movesBottom()
        case .bottom: movesBottom()
        case .bottomRight: movesRight(); movesBottom()
        case .move:
            // Translation clamps by sliding, never by shrinking.
            let dx = min(max(delta.width, bounds.minX - minX), bounds.maxX - maxX)
            let dy = min(max(delta.height, bounds.minY - minY), bounds.maxY - maxY)
            minX += dx; maxX += dx
            minY += dy; maxY += dy
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
