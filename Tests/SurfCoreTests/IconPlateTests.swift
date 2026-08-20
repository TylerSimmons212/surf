import Testing
@testable import SurfCore

@Suite("Icon plate detection")
struct IconPlateTests {

    private let side = 16

    /// Builds a square RGBA buffer from a per-pixel closure.
    private func buffer(
        side: Int,
        _ pixel: (_ row: Int, _ column: Int) -> (r: Double, g: Double, b: Double, a: Double)
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(side * side * 4)
        for row in 0..<side {
            for column in 0..<side {
                let p = pixel(row, column)
                bytes.append(UInt8((p.r * 255).rounded()))
                bytes.append(UInt8((p.g * 255).rounded()))
                bytes.append(UInt8((p.b * 255).rounded()))
                bytes.append(UInt8((p.a * 255).rounded()))
            }
        }
        return bytes
    }

    private func isClose(_ lhs: SRGB, _ rhs: SRGB, tolerance: Double = 0.02) -> Bool {
        abs(lhs.r - rhs.r) <= tolerance
            && abs(lhs.g - rhs.g) <= tolerance
            && abs(lhs.b - rhs.b) <= tolerance
    }

    // MARK: - Plated icons

    @Test("A solid colour square is its own plate")
    func solidFill() {
        let bytes = buffer(side: side) { _, _ in (0.2, 0.4, 0.9, 1) }
        let plate = IconPlate.detect(rgba: bytes, side: side)
        #expect(plate.map { isClose($0, SRGB(r: 0.2, g: 0.4, b: 0.9)) } == true)
    }

    @Test("A mark on a plate reports the plate, not the mark")
    func markOnPlate() {
        // A white glyph filling the middle of a red plate.
        let bytes = buffer(side: side) { row, column in
            let inner = (4..<12).contains(row) && (4..<12).contains(column)
            return inner ? (1, 1, 1, 1) : (0.85, 0.15, 0.15, 1)
        }
        let plate = IconPlate.detect(rgba: bytes, side: side)
        #expect(plate.map { isClose($0, SRGB(r: 0.85, g: 0.15, b: 0.15)) } == true)
    }

    @Test("Rounded corners don't disqualify a plate")
    func roundedCorners() {
        // A genuine rounded rectangle — quarter-circle corners, the way an
        // app-style favicon is drawn. Generously rounded on purpose: a radius
        // of 4 on a 16px sample is about as far as the house style goes, and
        // it still costs only ~5% of the icon.
        let radius = 4.0
        let bytes = buffer(side: side) { row, column in
            let x = Double(column) + 0.5, y = Double(row) + 0.5
            let edge = Double(side)
            // Distance past the corner arc, in whichever corner this pixel is
            // nearest; negative everywhere else.
            let dx = max(radius - x, x - (edge - radius), 0)
            let dy = max(radius - y, y - (edge - radius), 0)
            let outside = dx > 0 && dy > 0 && (dx * dx + dy * dy) > radius * radius
            return outside ? (0, 0, 0, 0) : (0.1, 0.6, 0.3, 1)
        }
        let verdict = ImageAnalysis.verdict(rgba: bytes)
        // The fixture has to be honest about what rounding actually costs, or
        // it isn't testing the threshold it claims to.
        #expect((verdict?.transparentFraction ?? 1) < IconPlate.maximumTransparency)

        let plate = IconPlate.detect(rgba: bytes, side: side)
        #expect(plate.map { isClose($0, SRGB(r: 0.1, g: 0.6, b: 0.3)) } == true)
    }

    @Test("A white plate is still a plate")
    func whitePlate() {
        let bytes = buffer(side: side) { row, column in
            let inner = (5..<11).contains(row) && (5..<11).contains(column)
            return inner ? (0, 0, 0, 1) : (1, 1, 1, 1)
        }
        let plate = IconPlate.detect(rgba: bytes, side: side)
        #expect(plate.map { isClose($0, SRGB(r: 1, g: 1, b: 1)) } == true)
    }

    @Test("A mark bleeding off its plate doesn't drag the colour")
    func markBleedingOffPlate() {
        // A dark bar running out to the trailing edge on a light plate.
        let bytes = buffer(side: side) { row, _ in
            (7..<9).contains(row) ? (0, 0, 0, 1) : (0.9, 0.9, 0.2, 1)
        }
        let plate = IconPlate.detect(rgba: bytes, side: side)
        #expect(plate.map { isClose($0, SRGB(r: 0.9, g: 0.9, b: 0.2)) } == true)
    }

    // MARK: - Unplated icons

    @Test("A mark floating on transparency has no plate")
    func transparentIcon() {
        let bytes = buffer(side: side) { row, column in
            let inner = (5..<11).contains(row) && (5..<11).contains(column)
            return inner ? (0.1, 0.1, 0.1, 1) : (0, 0, 0, 0)
        }
        #expect(IconPlate.detect(rgba: bytes, side: side) == nil)
    }

    @Test("A stroke running to the edge isn't enough to call it plated")
    func strokeTouchingEdge() {
        // One column of ink on an otherwise empty canvas.
        let bytes = buffer(side: side) { _, column in
            column == 8 ? (0, 0, 0, 1) : (0, 0, 0, 0)
        }
        #expect(IconPlate.detect(rgba: bytes, side: side) == nil)
    }

    @Test("A black mark reaching every edge is not a black plate")
    func markTouchingAllEdges() {
        // The real regression: a black logo on transparency whose strokes run
        // out to all four sides. Its border ring is opaque, flat and black —
        // indistinguishable from a plate read at the edges alone — but the
        // icon is nearly half transparent, and no plate is. Calling it a plate
        // painted the vinyl the same black as the mark and the icon vanished.
        let bytes = buffer(side: side) { row, column in
            let hollow = (4..<12).contains(row) && (4..<12).contains(column)
            return hollow ? (0, 0, 0, 0) : (0, 0, 0, 1)
        }
        let verdict = ImageAnalysis.verdict(rgba: bytes)
        #expect(verdict?.hasTransparency == true)
        #expect(IconPlate.detect(rgba: bytes, side: side) == nil)
    }

    @Test("A gradient border is opaque but not flat, so it isn't a plate")
    func gradientBorder() {
        let bytes = buffer(side: side) { row, _ in
            let t = Double(row) / Double(side - 1)
            return (t, 0.2, 1 - t, 1)
        }
        #expect(IconPlate.detect(rgba: bytes, side: side) == nil)
    }

    @Test("Half-transparent border pixels are not plate")
    func semiTransparentBorder() {
        let bytes = buffer(side: side) { _, _ in (0.5, 0.5, 0.5, 0.5) }
        #expect(IconPlate.detect(rgba: bytes, side: side) == nil)
    }

    // MARK: - Guards

    @Test("A malformed or tiny buffer reports no plate rather than guessing")
    func malformed() {
        #expect(IconPlate.detect(rgba: [], side: 16) == nil)
        #expect(IconPlate.detect(rgba: [255, 255, 255, 255], side: 1) == nil)
        // Length disagreeing with the stated side.
        #expect(IconPlate.detect(rgba: [UInt8](repeating: 255, count: 64), side: 16) == nil)
    }
}
