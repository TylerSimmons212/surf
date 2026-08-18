import Foundation

/// A list Glass carries.
public struct FilterListSource: Sendable, Equatable, Identifiable {
    /// The name on disk, and the identifier its compiled rules are filed under.
    public let id: String
    /// What it's called where the user can see it.
    public let name: String
    public let url: URL

    /// Below this, a download is treated as a failure and what's already
    /// installed is kept. Per list, because the lists are not the same size and
    /// one floor for all of them would either wave a truncated EasyList through
    /// or refuse a healthy small list outright.
    public let minimumRuleCount: Int

    public init(id: String, name: String, url: URL, minimumRuleCount: Int) {
        self.id = id
        self.name = name
        self.url = url
        self.minimumRuleCount = minimumRuleCount
    }
}

/// The filter lists Glass ships and keeps current.
///
/// Both are published in Adblock Plus filter syntax and converted here — see
/// `FilterConverter`. EasyList's publisher does build a WebKit version of that
/// one list, and Glass used it until the second list made it untenable:
/// EasyPrivacy is where the trackers are, it is published in filter syntax only,
/// and carrying one list through a converter and the other around it would mean
/// two sets of rules that behave differently for reasons no one could see.
public enum FilterList {

    public static let easylist = FilterListSource(
        id: "easylist",
        name: "EasyList",
        url: URL(string: "https://easylist.to/easylist/easylist.txt")!,
        minimumRuleCount: 40_000
    )

    /// The trackers. EasyList is about advertising, and a page can be free of
    /// ads and still be reporting everything you do on it to a dozen people.
    public static let easyprivacy = FilterListSource(
        id: "easyprivacy",
        name: "EasyPrivacy",
        url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
        minimumRuleCount: 30_000
    )

    /// The nag walls. A site that detects a blocker and demands you turn it off
    /// is a different problem from the ads themselves, and it has its own list —
    /// which removes the wall rather than hiding from the thing that raised it.
    /// Glass could only take this on once it converted lists itself: nobody
    /// publishes a WebKit build of it.
    public static let adblockWarnings = FilterListSource(
        id: "antiadblock",
        name: "Adblock Warning Removal",
        url: URL(string: "https://easylist-downloads.adblockplus.org/antiadblockfilters.txt")!,
        // A tenth the size of the others, and the floor has to know that.
        minimumRuleCount: 1_000
    )

    public static let sources: [FilterListSource] = [easylist, easyprivacy, adblockWarnings]

    /// What they're called together, in one phrase.
    public static var displayName: String {
        let names = sources.map(\.name)
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Why every list carries a floor at all.
    ///
    /// There is no checksum to verify one against — the publishers issue none —
    /// so the guarantee has to come from what the payload *is*. It is filter
    /// syntax, never code: it is parsed into declarative rules that WebKit
    /// compiles and matches URLs against, and there is no execution path from it
    /// into Glass or into a page. What is left to guard is a truncated download
    /// or a captive portal's sign-in page arriving with a 200 and quietly
    /// replacing a working list with nothing, and converting it and counting
    /// what came out is what catches that.

    /// WebKit's own ceiling on a single compiled list. Each source is compiled
    /// separately, which is what keeps both of them under it.
    public static let maximumRuleCount = 150_000
}
