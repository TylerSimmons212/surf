import CoreGraphics
import Testing

@testable import GlassCore

@Suite("Developer tools layout")
struct DevToolsLayoutTests {

    /// A divider dragged to the edge would otherwise erase a pane outright, and
    /// there'd be no grab handle left to drag it back with.
    @Test("Neither side of the split can be squeezed away")
    func splitKeepsBothPanes() {
        let total: CGFloat = 800
        let hardLeft = DevToolsLayout.stylesWidth(inTotal: total, requested: 0)
        let hardRight = DevToolsLayout.stylesWidth(inTotal: total, requested: total)

        #expect(hardLeft == DevToolsLayout.minimumPaneWidth)
        #expect(hardRight == total - DevToolsLayout.minimumPaneWidth)
    }

    @Test("An untouched divider is left where it was asked for")
    func splitHonoursRequest() {
        #expect(DevToolsLayout.stylesWidth(inTotal: 800, requested: 340) == 340)
    }

    /// Below twice the minimum the two constraints contradict each other. Half
    /// each is the least-bad answer: both panes stay on screen, which beats one
    /// pane taking everything.
    @Test("A window too narrow for both minimums splits down the middle")
    func splitDegradesGracefully() {
        let total = DevToolsLayout.minimumPaneWidth * 1.5
        #expect(DevToolsLayout.stylesWidth(inTotal: total, requested: 10) == total / 2)
    }

    /// Opening dev tools on a second tab must not drop an identical window
    /// exactly on top of the first — it reads as nothing having happened.
    @Test("Consecutive panels do not land on the same spot")
    func panelsCascade() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let size = DevToolsLayout.defaultSize
        let first = DevToolsLayout.cascadedOrigin(index: 0, size: size, on: screen)
        let second = DevToolsLayout.cascadedOrigin(index: 1, size: size, on: screen)

        #expect(first != second)
        #expect(second.x > first.x)
        // AppKit's origin is bottom-left, so cascading down the screen lowers y.
        #expect(second.y < first.y)
    }

    /// A panel whose title bar is off-screen cannot be dragged back, which is
    /// an unrecoverable state rather than a cosmetic one.
    @Test("A cascaded panel always stays on screen", arguments: 0..<20)
    func cascadeStaysOnScreen(_ index: Int) {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = DevToolsLayout.defaultSize
        let origin = DevToolsLayout.cascadedOrigin(index: index, size: size, on: screen)

        #expect(origin.x >= screen.minX)
        #expect(origin.y >= screen.minY)
        #expect(origin.x + size.width <= screen.maxX + 0.5)
    }

    /// Guards the constants against a careless edit: a "minimum" larger than
    /// the default would make every panel open already too small.
    @Test("The default panel is larger than the minimum")
    func defaultExceedsMinimum() {
        #expect(DevToolsLayout.defaultSize.width > DevToolsLayout.minimumSize.width)
        #expect(DevToolsLayout.defaultSize.height > DevToolsLayout.minimumSize.height)
        #expect(DevToolsLayout.minimumSize.width > DevToolsLayout.minimumPaneWidth * 2)
    }
}
