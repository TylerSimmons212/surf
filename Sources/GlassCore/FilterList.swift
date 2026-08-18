import Foundation

/// A list Glass carries.
public struct FilterListSource: Sendable, Equatable, Identifiable {
    /// The name on disk, and the identifier its compiled rules are filed under.
    public let id: String
    /// What it's called where the user can see it.
    public let name: String
    public let url: URL

    public init(id: String, name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
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
        url: URL(string: "https://easylist.to/easylist/easylist.txt")!
    )

    /// The trackers. EasyList is about advertising, and a page can be free of
    /// ads and still be reporting everything you do on it to a dozen people.
    public static let easyprivacy = FilterListSource(
        id: "easyprivacy",
        name: "EasyPrivacy",
        url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!
    )

    public static let sources: [FilterListSource] = [easylist, easyprivacy]

    /// What the two are called together, in one phrase.
    public static var displayName: String {
        sources.map(\.name).joined(separator: " and ")
    }

    /// Below this, treat a download as a failure and keep what we already have.
    ///
    /// There is no checksum to verify against — the publisher issues none — so
    /// the guarantee has to come from what the payload *is*. It is filter
    /// syntax, never code: it is parsed into declarative rules that WebKit
    /// compiles and matches URLs against, and there is no execution path from it
    /// into Glass or into a page. What is left to guard is a truncated download
    /// or a captive portal's sign-in page arriving with a 200 and quietly
    /// replacing a working list with nothing, and converting it and counting
    /// what came out is what catches that. A list at full strength is tens of
    /// thousands of rules.
    public static let minimumRuleCount = 5_000

    /// WebKit's own ceiling on a single compiled list. Each source is compiled
    /// separately, which is what keeps both of them under it.
    public static let maximumRuleCount = 150_000
}
