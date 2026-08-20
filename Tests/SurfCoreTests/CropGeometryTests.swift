import Foundation
import Testing

@testable import SurfCore

@Suite("Crop geometry")
struct CropGeometryTests {

    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let rect = CGRect(x: 100, y: 100, width: 200, height: 100)

    // MARK: - Handle hit testing

    @Test("Corners beat edges at their meeting point")
    func cornersWin() {
        #expect(CropGeometry.handle(at: CGPoint(x: 100, y: 100), in: rect) == .topLeft)
        #expect(CropGeometry.handle(at: CGPoint(x: 300, y: 200), in: rect) == .bottomRight)
    }

    @Test("Edges answer along their length")
    func edges() {
        #expect(CropGeometry.handle(at: CGPoint(x: 200, y: 100), in: rect) == .top)
        #expect(CropGeometry.handle(at: CGPoint(x: 100, y: 150), in: rect) == .left)
        #expect(CropGeometry.handle(at: CGPoint(x: 300, y: 150), in: rect) == .right)
        #expect(CropGeometry.handle(at: CGPoint(x: 200, y: 200), in: rect) == .bottom)
    }

    @Test("Inside is a move; outside is nothing")
    func insideOutside() {
        #expect(CropGeometry.handle(at: CGPoint(x: 200, y: 150), in: rect) == .move)
        #expect(CropGeometry.handle(at: CGPoint(x: 50, y: 50), in: rect) == nil)
    }

    // MARK: - Dragging

    @Test("An edge drag moves only its edge")
    func edgeDrag() {
        let out = CropGeometry.drag(rect, handle: .right, by: CGSize(width: 40, height: 99), in: bounds)
        #expect(out == CGRect(x: 100, y: 100, width: 240, height: 100))
    }

    @Test("A corner drag moves both its edges")
    func cornerDrag() {
        let out = CropGeometry.drag(rect, handle: .topLeft, by: CGSize(width: 20, height: 30), in: bounds)
        #expect(out == CGRect(x: 120, y: 130, width: 180, height: 70))
    }

    @Test("No drag can invert the rect — the minimum size holds")
    func minimumHolds() {
        let out = CropGeometry.drag(rect, handle: .left, by: CGSize(width: 500, height: 0), in: bounds)
        #expect(out.width == 24)
        #expect(out.maxX == rect.maxX)
    }

    @Test("No drag can leave the bounds")
    func boundsHold() {
        let out = CropGeometry.drag(rect, handle: .bottomRight, by: CGSize(width: 900, height: 900), in: bounds)
        #expect(out.maxX == 400)
        #expect(out.maxY == 300)
    }

    @Test("A move slides the whole rect and stops at the wall without shrinking")
    func moveClamps() {
        let out = CropGeometry.drag(rect, handle: .move, by: CGSize(width: 500, height: -500), in: bounds)
        #expect(out.size == rect.size)
        #expect(out.maxX == 400)
        #expect(out.minY == 0)
    }
}
