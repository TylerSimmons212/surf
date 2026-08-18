import Foundation

/// What kind of thing was being fetched. Shown in the panel because "14
/// requests" says less than "scripts and a tracking pixel", and because it's
/// what tells a reader whether blocking something is likely to cost them
/// anything.
public enum ResourceKind: String, Sendable, Equatable, CaseIterable {
    case script
    case image
    case frame
    case stylesheet
    case fetch
    case beacon
    case media
    case font
    /// A window the page asked to open. Its own kind because it is the one a
    /// reader notices happening to them.
    case popup
    case other

    /// Maps what the page reports — Resource Timing's `initiatorType`, or the
    /// tag name of the element that asked — onto the set above.
    public init(reported: String) {
        switch reported.lowercased() {
        case "script": self = .script
        case "img", "image", "input": self = .image
        case "iframe", "frame", "embed", "object": self = .frame
        case "css", "link", "stylesheet": self = .stylesheet
        case "fetch", "xmlhttprequest", "xhr": self = .fetch
        case "beacon", "ping": self = .beacon
        case "popup", "window": self = .popup
        case "video", "audio", "source", "track": self = .media
        case "font": self = .font
        default: self = .other
        }
    }

    public var label: String {
        switch self {
        case .script: "scripts"
        case .image: "images"
        case .frame: "frames"
        case .stylesheet: "styles"
        case .fetch: "requests"
        case .beacon: "beacons"
        case .media: "media"
        case .font: "fonts"
        case .popup: "pop-ups"
        case .other: "resources"
        }
    }
}

/// Which rule caught a request. The panel says this because a blocked request
/// the user can't attribute is a blocked request they can't argue with.
public enum BlockSource: Equatable, Sendable {
    /// Matched a domain the shipped list blocks. Carries the domain the rule
    /// itself names, which is what the panel shows.
    case filterList(domain: String)
    /// A domain the user added from the panel.
    case userRule

    public var label: String {
        switch self {
        case .filterList: FilterList.displayName
        case .userRule: "Your rule"
        }
    }
}

/// One request the page tried to make, as the page reported it.
public struct RequestRecord: Equatable, Sendable {
    public let url: String
    public let kind: ResourceKind
    /// Whether it was seen to complete. Blocked requests never do, so this is
    /// the page's own corroboration of a verdict reached from the rules.
    public let didLoad: Bool

    public init(url: String, kind: ResourceKind, didLoad: Bool) {
        self.url = url
        self.kind = kind
        self.didLoad = didLoad
    }
}

/// Deciding what a request was, given the rules in force.
///
/// Holds the two domain sets and nothing else, so the verdict the panel shows
/// is reached by the same code in every context and can be tested without a web
/// view anywhere near it.
public struct BlockClassifier: Sendable {
    public var listedDomains: Set<String>
    public var userBlockedDomains: Set<String>

    public init(listedDomains: Set<String> = [], userBlockedDomains: Set<String> = []) {
        self.listedDomains = listedDomains
        self.userBlockedDomains = userBlockedDomains
    }

    public enum Verdict: Equatable, Sendable {
        case blocked(BlockSource)
        case allowed
        /// Same site as the page. Never shown: a site fetching its own assets
        /// isn't a party to anything.
        case firstParty
    }

    /// Both sets are matched by subdomain, because both sets' rules are.
    ///
    /// `||adnxs.com^` converts to a filter carrying the subdomain group, so it
    /// covers `ib.adnxs.com`, and the verdict here has to agree with it. It
    /// only earns that agreement by Surf converting the list itself: the
    /// publisher's own converted copy was host-exact, and this had to match
    /// exactly too, or the panel would have claimed credit for ads the reader
    /// could still see.
    public func verdict(forHost host: String, pageHost: String) -> Verdict {
        guard DomainName.isThirdParty(host, from: pageHost) else { return .firstParty }
        if DomainName.matches(host: host, in: userBlockedDomains) { return .blocked(.userRule) }
        if let domain = DomainName.coveringDomain(host: host, in: listedDomains) {
            return .blocked(.filterList(domain: domain))
        }
        return .allowed
    }

    /// Whether a window a page asked to open should be refused.
    ///
    /// Separate from `verdict` only to name what it is being asked. A window is
    /// the one refusal a reader *feels* — they clicked something and a tab
    /// didn't appear — so the standard is the same as for any other request and
    /// deliberately no looser: it points at a domain the lists name, or it
    /// opens. A site opening its own window is never refused, whatever else is
    /// true, because that is the site working.
    public func refusesWindow(to host: String, from pageHost: String) -> Bool {
        if case .blocked = verdict(forHost: host, pageHost: pageHost) { return true }
        return false
    }
}

/// One row of the panel: everything one domain did on this page.
public struct DomainActivity: Identifiable, Equatable, Sendable {
    public var domain: String
    public var count: Int
    public var kinds: Set<ResourceKind>
    public var source: BlockSource?

    public var id: String { domain }
    public var isBlocked: Bool { source != nil }

    /// "3 scripts", "1 image", "12 requests" — the dominant kind when there is
    /// one, and the neutral word when a domain did several things.
    public var summary: String {
        let noun = kinds.count == 1
            ? (kinds.first ?? .other).label
            : ResourceKind.fetch.label
        return count == 1 ? "1 \(singular(noun))" : "\(count) \(noun)"
    }

    private func singular(_ noun: String) -> String {
        noun.hasSuffix("s") ? String(noun.dropLast()) : noun
    }
}

/// What a tab has seen since its last navigation.
///
/// Per tab and reset on every page load, because the question the panel answers
/// is "what is *this page* doing", and a running total across a session is a
/// number nobody can act on.
public struct BlockLog: Equatable, Sendable {

    /// Distinct domains held per page. Reached only by pathological pages, and
    /// a panel with four hundred rows in it has stopped being readable long
    /// before it stops being cheap.
    public static let domainLimit = 300

    private var activity: [String: DomainActivity] = [:]

    public private(set) var blockedCount = 0

    public init() {}

    public var isEmpty: Bool { activity.isEmpty }

    /// Folds one request into the log. Returns false when nothing changed, so
    /// the caller can avoid publishing an observable update per request — a
    /// busy page reports hundreds.
    @discardableResult
    public mutating func record(
        _ record: RequestRecord,
        verdict: BlockClassifier.Verdict,
        host: String
    ) -> Bool {
        guard verdict != .firstParty else { return false }

        // A request seen to complete cannot have been blocked, whatever the
        // rules say. This is where the page's evidence overrules ours: a domain
        // on the list but reachable means the rule didn't fire — a cached
        // response, a request made before the list applied — and reporting it
        // as blocked would be a lie the user can check.
        let source: BlockSource? = {
            guard case let .blocked(source) = verdict, !record.didLoad else { return nil }
            return source
        }()

        // Blocked rows are keyed by the domain the *rule* names, not by the
        // site the host rolls up to. A rule against `imasdk.googleapis.com`
        // filed under `googleapis.com` would read as a claim to have blocked
        // Google's font and maps hosts, which it did not.
        let domain: String = {
            if case let .filterList(ruleDomain) = source { return ruleDomain }
            return DomainName.registrable(host)
        }()
        guard !domain.isEmpty else { return false }

        if activity[domain] == nil, activity.count >= Self.domainLimit { return false }

        var entry = activity[domain] ?? DomainActivity(
            domain: domain, count: 0, kinds: [], source: source
        )
        entry.count += 1
        entry.kinds.insert(record.kind)
        // A domain that is blocked in any of its requests is a blocked domain:
        // one stray cached hit shouldn't move a row out of the blocked list.
        entry.source = entry.source ?? source
        activity[domain] = entry

        if source != nil { blockedCount += 1 }
        return true
    }

    /// Blocked domains, heaviest first — the order that puts what a page is
    /// actually loaded down with at the top.
    public var blocked: [DomainActivity] {
        sorted(activity.values.filter(\.isBlocked))
    }

    /// Third parties that were contacted and weren't blocked. This is the half
    /// of the panel that can be acted on: everything here has a button that
    /// turns it into the half above.
    public var allowed: [DomainActivity] {
        sorted(activity.values.filter { !$0.isBlocked })
    }

    private func sorted(_ entries: [DomainActivity]) -> [DomainActivity] {
        entries.sorted {
            $0.count == $1.count ? $0.domain < $1.domain : $0.count > $1.count
        }
    }
}
