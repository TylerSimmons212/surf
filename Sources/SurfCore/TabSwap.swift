import Foundation

/// A page that opens itself in a new tab and sends the old tab somewhere else.
///
/// The reader clicks a thumbnail. The page opens the video they wanted in a new
/// tab, which passes every check, because it is the page's own site, and then
/// navigates the tab they clicked in to an ad. Each half is innocent alone. A
/// window to your own site is what a "open in new tab" button does, and a
/// script moving its own tab is what half the web's redirects are. Together,
/// moments apart, they are a swap: the reader ends up looking at the tab they
/// asked for and comes back to find the one they left has become an ad.
///
/// So the second half is refused, and only when it follows the first. The tab
/// that opened stays open and holds what the reader wanted. The tab they
/// clicked in stays where it was.
public struct TabSwap: Sendable {
    /// How long after the window the redirect counts as its other half. The
    /// scripts do both in the same handler, so this only has to cover a
    /// redirect that waits for the new tab to be on screen.
    public static let window: TimeInterval = 2

    private var openedOwnSite: (pageHost: String, at: Date)?

    public init() {}

    /// The page opened a window. Only a window to the page's own site starts a
    /// swap. One aimed elsewhere is a pop-under, which the window rules judge.
    public mutating func pageOpenedWindow(to host: String, from pageHost: String, at time: Date) {
        guard !DomainName.isThirdParty(host, from: pageHost) else { return }
        openedOwnSite = (pageHost, time)
    }

    /// Whether a navigation of this tab that the page started, rather than the
    /// reader, is the second half of a swap.
    ///
    /// Not cleared by a refusal. A page that was refused tries again, often
    /// with `location.replace`, and each attempt is the same swap.
    public func refuses(to host: String, from pageHost: String, at time: Date) -> Bool {
        guard let opened = openedOwnSite,
              time.timeIntervalSince(opened.at) <= Self.window,
              !DomainName.isThirdParty(pageHost, from: opened.pageHost)
        else { return false }
        return DomainName.isThirdParty(host, from: pageHost)
    }

    /// The reader went somewhere: typed an address, picked a bookmark. Whatever
    /// the page set up before that is no longer about this tab.
    public mutating func readerNavigated() {
        openedOwnSite = nil
    }
}
