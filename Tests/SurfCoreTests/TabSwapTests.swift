import Foundation
import Testing
@testable import SurfCore

@Suite("Tab swap")
struct TabSwapTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("A page that opens itself and then sends this tab elsewhere is refused the second half")
    func swapRefused() {
        var swap = TabSwap()
        swap.pageOpenedWindow(to: "internetchicks.com", from: "internetchicks.com", at: start)
        #expect(swap.refuses(to: "impeccablewriter.com", from: "internetchicks.com",
                             at: start.addingTimeInterval(0.3)))
    }

    @Test("Its own subdomains count as itself")
    func subdomainIsOwnSite() {
        var swap = TabSwap()
        swap.pageOpenedWindow(to: "video.example.com", from: "www.example.com", at: start)
        #expect(swap.refuses(to: "ads.example.net", from: "www.example.com",
                             at: start.addingTimeInterval(0.3)))
    }

    @Test("Without a window to its own site first, a page may navigate anywhere")
    func noWindowNoRefusal() {
        var swap = TabSwap()
        #expect(!swap.refuses(to: "elsewhere.com", from: "example.com", at: start))
    }

    @Test("A window to another site is a pop-under, not a swap, and is someone else's rule")
    func windowElsewhereIsNotASwap() {
        var swap = TabSwap()
        swap.pageOpenedWindow(to: "ads.net", from: "example.com", at: start)
        #expect(!swap.refuses(to: "elsewhere.com", from: "example.com",
                              at: start.addingTimeInterval(0.3)))
    }

    @Test("Moving within its own site after opening a window is just navigation")
    func sameSiteNavigationAllowed() {
        var swap = TabSwap()
        swap.pageOpenedWindow(to: "example.com", from: "example.com", at: start)
        #expect(!swap.refuses(to: "cdn.example.com", from: "example.com",
                              at: start.addingTimeInterval(0.3)))
    }

    @Test("The link between the two halves expires")
    func expires() {
        var swap = TabSwap()
        swap.pageOpenedWindow(to: "example.com", from: "example.com", at: start)
        #expect(!swap.refuses(to: "elsewhere.com", from: "example.com",
                              at: start.addingTimeInterval(TabSwap.window + 0.1)))
    }

    @Test("It keeps refusing for the whole window, because a refused page tries again")
    func retriesRefused() {
        var swap = TabSwap()
        swap.pageOpenedWindow(to: "example.com", from: "example.com", at: start)
        #expect(swap.refuses(to: "a.com", from: "example.com", at: start.addingTimeInterval(0.2)))
        #expect(swap.refuses(to: "b.com", from: "example.com", at: start.addingTimeInterval(0.6)))
    }

    @Test("Going somewhere yourself ends it")
    func readerNavigationClears() {
        var swap = TabSwap()
        swap.pageOpenedWindow(to: "example.com", from: "example.com", at: start)
        swap.readerNavigated()
        #expect(!swap.refuses(to: "elsewhere.com", from: "example.com",
                              at: start.addingTimeInterval(0.3)))
    }
}
