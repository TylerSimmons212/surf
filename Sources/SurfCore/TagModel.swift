import Foundation

public enum TagCategory: String, Sendable, CaseIterable, Identifiable {
    case advertising, analytics, tagManager, sessionReplay, email, consent, other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .advertising: "Advertising"
        case .analytics: "Analytics"
        case .tagManager: "Tag manager"
        case .sessionReplay: "Session"
        case .email: "Email"
        case .consent: "Consent"
        case .other: "Other"
        }
    }
}

/// Where a vendor keeps the account identifier in its requests.
public enum AccountLocation: Sendable, Equatable {
    /// One of these query parameters, first match wins.
    case query([String])
    /// The path segment following this one — Google Ads puts the conversion id
    /// in `/pagead/viewthroughconversion/<id>/`.
    case pathSegment(after: String)
    case none
}

/// How to recognise one vendor's traffic and read what it says.
///
/// Data rather than code, so the whole table is inspectable in one place and
/// every rule in it is testable without a browser.
public struct TagSignature: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var category: TagCategory
    /// Matched against the request's host as a suffix, so `facebook.com`
    /// catches `www.facebook.com` without catching `notfacebook.com`.
    public var hosts: [String]
    /// Required somewhere in the path, when the host alone is too broad.
    public var pathContains: String?
    public var account: AccountLocation
    /// Query parameters that carry the event name, first match wins.
    public var eventParameters: [String]
    /// What to call a fire that names no event.
    public var defaultEvent: String
    /// Custom data arrives prefixed: Meta uses `cd[...]`, GA4 uses `ep.`.
    public var parameterPrefixes: [String]
    /// The advertiser-facing library, for the ad-library links.
    public var adLibrary: AdLibrary?
    /// A page global that proves the tag is installed even before it fires.
    public var globals: [String]

    public init(
        id: String, name: String, category: TagCategory, hosts: [String],
        pathContains: String? = nil, account: AccountLocation = .none,
        eventParameters: [String] = [], defaultEvent: String = "hit",
        parameterPrefixes: [String] = [], adLibrary: AdLibrary? = nil,
        globals: [String] = []
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.hosts = hosts
        self.pathContains = pathContains
        self.account = account
        self.eventParameters = eventParameters
        self.defaultEvent = defaultEvent
        self.parameterPrefixes = parameterPrefixes
        self.adLibrary = adLibrary
        self.globals = globals
    }
}

/// Where to go to see what this advertiser is actually running.
///
/// Links rather than an API, and deliberately so. Meta's Ad Library API needs
/// an app token and identity verification and is really scoped to political
/// ads; Google's Ads Transparency Center, TikTok's Creative Center and
/// LinkedIn's Ad Library have no public API at all. Scraping them would be
/// fragile and against their terms, so Surf takes you there in one click with
/// the identifier already filled in rather than pretending to have data it
/// can't legitimately get.
public struct AdLibrary: Sendable, Equatable {
    public var name: String
    /// `{id}` is replaced with the account id, `{domain}` with the search term.
    public var template: String
    /// Used instead when an exact advertiser page id is known. A name search
    /// returns everyone who shares that name; a page lookup returns one
    /// advertiser, which is the difference between browsing and finding.
    public var pageTemplate: String?
    public var note: String

    public init(
        name: String, template: String, pageTemplate: String? = nil, note: String = ""
    ) {
        self.name = name
        self.template = template
        self.pageTemplate = pageTemplate
        self.note = note
    }

    public func url(id: String, domain: String) -> String {
        substitute(template, id: id, term: domain)
    }

    /// The most precise link available: an exact page lookup where the page is
    /// known, a name search otherwise.
    public func url(identity: SocialIdentity, accountId: String, term: String) -> String {
        if let pageTemplate, let pageId = identity.pageIds.first {
            return substitute(pageTemplate, id: pageId, term: term)
        }
        // A vanity name from a link beats a name guessed off the title.
        let best = identity.pageNames.first ?? identity.instagramHandles.first ?? term
        return substitute(template, id: accountId, term: best)
    }

    public var isExact: Bool { pageTemplate != nil }

    private func substitute(_ text: String, id: String, term: String) -> String {
        text
            .replacingOccurrences(of: "{id}", with: id.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed) ?? id)
            .replacingOccurrences(of: "{domain}", with: term.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed) ?? term)
    }
}

/// One decoded fire.
public struct TagEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var vendorId: String
    public var vendorName: String
    public var category: TagCategory
    public var accountId: String
    public var name: String
    public var parameters: [String: String]
    public var at: Double
    public var url: String

    public init(
        id: String, vendorId: String, vendorName: String, category: TagCategory,
        accountId: String, name: String, parameters: [String: String],
        at: Double, url: String
    ) {
        self.id = id
        self.vendorId = vendorId
        self.vendorName = vendorName
        self.category = category
        self.accountId = accountId
        self.name = name
        self.parameters = parameters
        self.at = at
        self.url = url
    }

    /// The parameters worth showing on the collapsed row.
    public var summary: String {
        let interesting = ["value", "currency", "transaction_id", "content_ids", "order_id"]
        let parts = interesting.compactMap { key -> String? in
            guard let value = parameters[key] else { return nil }
            return "\(key): \(value)"
        }
        return parts.joined(separator: " · ")
    }
}

/// A tag known to be present, whether or not it has fired.
public struct DetectedTag: Sendable, Equatable, Identifiable {
    public var vendorId: String
    public var name: String
    public var category: TagCategory
    public var accountIds: [String]
    /// What gave it away — a global, a script, a cookie, a fired request.
    public var evidence: [String]
    public var eventCount: Int

    public var id: String { vendorId }

    public init(
        vendorId: String, name: String, category: TagCategory,
        accountIds: [String] = [], evidence: [String] = [], eventCount: Int = 0
    ) {
        self.vendorId = vendorId
        self.name = name
        self.category = category
        self.accountIds = accountIds
        self.evidence = evidence
        self.eventCount = eventCount
    }

    /// Installed but silent, which is usually a bug rather than a choice.
    public var isSilent: Bool { eventCount == 0 }
}

public enum TagSeverity: String, Sendable, Equatable {
    case error, warning, info
}

/// Something worth telling the person debugging.
public struct TagFinding: Sendable, Equatable, Identifiable {
    public var id: String
    public var severity: TagSeverity
    public var title: String
    public var detail: String
    public var vendorName: String

    public init(
        id: String, severity: TagSeverity, title: String,
        detail: String, vendorName: String = ""
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.vendorName = vendorName
    }
}

/// The name to search an ad library for.
///
/// Not the domain, which is what a first pass reaches for and which those
/// libraries do not index by — searching `shop.example.com` in Meta's Ad
/// Library finds nothing. They are indexed by advertiser name, so the best
/// available guess is what the site calls itself, and it stays editable
/// because the guess is sometimes wrong and only the person looking knows.
public enum AdvertiserName {

    public static func guess(
        siteName: String, title: String, domain: String
    ) -> String {
        let trimmedSiteName = siteName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSiteName.isEmpty { return trimmedSiteName }

        // A title is usually "Product page — Brand" or "Brand | Tagline", and
        // the brand is the shortest distinctive part rather than the whole.
        let separators: [Character] = ["|", "—", "–", "·", "»"]
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            for separator in separators where trimmedTitle.contains(separator) {
                let parts = trimmedTitle.split(separator: separator)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                // The last segment is the brand far more often than the first,
                // which is usually the page.
                if let candidate = parts.last, candidate.count <= 40 { return candidate }
            }
            if trimmedTitle.count <= 40 { return trimmedTitle }
        }

        return apex(of: domain)
    }

    /// `shop.example.co.uk` → `example`.
    public static func apex(of domain: String) -> String {
        var host = domain.lowercased()
        for prefix in ["www.", "shop.", "store.", "m."] where host.hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 1 else { return host }
        // Two-part public suffixes are common enough to be worth handling.
        let compound: Set<String> = ["co", "com", "org", "net", "gov", "ac"]
        if labels.count > 2, compound.contains(labels[labels.count - 2]) {
            return labels[labels.count - 3]
        }
        return labels[labels.count - 2]
    }
}
