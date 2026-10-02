import Foundation
import SurfCore

/// What every site lens owes the tab it lives in.
///
/// Three methods, because three is all `Tab` ever calls. It exists so that
/// adding a site is adding a case rather than adding a stored property, a nil
/// assignment in `resetFocus`, two delegate calls, a teardown and a check in
/// the view — six places, five of which are easy to miss and none of which
/// the compiler would complain about.
///
/// The factory below is the part that actually enforces it: `makeLens` must
/// be exhaustive over `SiteFocusSite`, so a new case in that enum cannot
/// compile until it has a lens of its own. Before this existed,
/// `enterSiteFocus` built a `YouTubeLens` unconditionally — adding `.amazon`
/// would have compiled cleanly and put YouTube's lens on amazon.com.
@MainActor
protocol SiteLens: AnyObject {
    /// A new document is on its way; whatever is being read is stale.
    func documentWillChange()
    /// A document finished loading. What to show next is the lens's call.
    func documentDidLoad()
    /// The lens is closing and the page has to be handed back as it was.
    func tearDown()
}

@MainActor
extension SiteFocusSite {
    /// The lens for this site. Exhaustive on purpose — see above.
    func makeLens(tab: Tab) -> any SiteLens {
        switch self {
        case .youtube: return YouTubeLens(tab: tab)
        case .amazon: return AmazonLens(tab: tab)
        }
    }
}

extension YouTubeLens: SiteLens {}
extension AmazonLens: SiteLens {}
