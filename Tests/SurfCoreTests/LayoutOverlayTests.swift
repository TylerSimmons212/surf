import Testing

@testable import SurfCore

@Suite("Layout overlay geometry")
struct LayoutOverlayTests {
    typealias Span = LayoutOverlay.Span

    @Test("n tracks produce n+1 lines, numbered from 1")
    func lineCount() {
        let lines = LayoutOverlayGeometry.lines(for: [
            Span(start: 0, end: 100), Span(start: 110, end: 210), Span(start: 220, end: 320),
        ])
        #expect(lines.count == 4)
        #expect(lines.map(\.number) == [1, 2, 3, 4])
    }

    @Test("Edge lines sit at the track edges")
    func edges() {
        let lines = LayoutOverlayGeometry.lines(for: [Span(start: 8, end: 100), Span(start: 110, end: 210)])
        #expect(lines.first?.position == 8)
        #expect(lines.last?.position == 210)
    }

    @Test("A line between tracks sits in the middle of the gap")
    func gapMiddle() {
        let lines = LayoutOverlayGeometry.lines(for: [Span(start: 0, end: 100), Span(start: 110, end: 210)])
        #expect(lines[1].position == 105)
    }

    @Test("Adjacent tracks with no gap put the line on the shared edge")
    func noGap() {
        let lines = LayoutOverlayGeometry.lines(for: [Span(start: 0, end: 100), Span(start: 100, end: 200)])
        #expect(lines[1].position == 100)
    }

    @Test("No tracks means no lines, not a crash")
    func empty() {
        #expect(LayoutOverlayGeometry.lines(for: []).isEmpty)
    }

    @Test("One track still gets both of its lines")
    func single() {
        let lines = LayoutOverlayGeometry.lines(for: [Span(start: 5, end: 50)])
        #expect(lines.map(\.position) == [5, 50])
        #expect(lines.map(\.number) == [1, 2])
    }

    @Test("Gaps are the spaces between tracks")
    func gaps() {
        let gaps = LayoutOverlayGeometry.gaps(in: [
            Span(start: 0, end: 100), Span(start: 110, end: 210), Span(start: 220, end: 320),
        ])
        #expect(gaps == [Span(start: 100, end: 110), Span(start: 210, end: 220)])
    }

    @Test("A zero-width gap is not worth shading")
    func zeroGap() {
        let gaps = LayoutOverlayGeometry.gaps(in: [Span(start: 0, end: 100), Span(start: 100, end: 200)])
        #expect(gaps.isEmpty)
    }
}
