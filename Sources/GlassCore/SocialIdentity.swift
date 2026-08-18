import Foundation

/// The advertiser accounts a site declares about itself.
///
/// Worth extracting because a Meta Page id is a *far* better key for an ad
/// library than a guessed brand name — it addresses one advertiser exactly,
/// where a name search returns everyone who happens to share it. And a Page id
/// is not the same thing as the pixel id already recovered from the traffic:
/// they are unrelated identifiers, so having one says nothing about the other.
public struct SocialIdentity: Sendable, Equatable {
    /// Numeric Facebook Page ids, which address a page exactly.
    public var pageIds: [String]
    /// Vanity names from links — `facebook.com/acmestore` — which are good
    /// search terms but can't be used for an exact page lookup.
    public var pageNames: [String]
    public var instagramHandles: [String]
    public var linkedinCompanies: [String]
    public var tiktokHandles: [String]
    public var xHandles: [String]
    public var youtubeChannels: [String]

    public init(
        pageIds: [String] = [], pageNames: [String] = [], instagramHandles: [String] = [],
        linkedinCompanies: [String] = [], tiktokHandles: [String] = [],
        xHandles: [String] = [], youtubeChannels: [String] = []
    ) {
        self.pageIds = pageIds
        self.pageNames = pageNames
        self.instagramHandles = instagramHandles
        self.linkedinCompanies = linkedinCompanies
        self.tiktokHandles = tiktokHandles
        self.xHandles = xHandles
        self.youtubeChannels = youtubeChannels
    }

    public var isEmpty: Bool {
        pageIds.isEmpty && pageNames.isEmpty && instagramHandles.isEmpty
            && linkedinCompanies.isEmpty && tiktokHandles.isEmpty
            && xHandles.isEmpty && youtubeChannels.isEmpty
    }

    /// The best available way to identify this advertiser, most precise first.
    public var bestLabel: String? {
        pageIds.first ?? pageNames.first ?? instagramHandles.first
    }
}

public enum SocialDetection {

    /// `fb:pages` carries a comma-separated list; `fb:page_id` carries one.
    public static func pageIds(fromMeta content: String) -> [String] {
        content
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // Only digits: the tag is documented as numeric, and anything else
            // in it would produce a lookup for a page that doesn't exist.
            .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// Paths that are Facebook's own plumbing rather than a page.
    ///
    /// Share buttons and the pixel itself all live on `facebook.com`, and a
    /// naive reading of every link on a page turns `sharer.php` into an
    /// advertiser.
    private static let ignoredPaths: Set<String> = [
        "sharer.php", "sharer", "share.php", "share", "dialog", "plugins",
        "tr", "groups", "events", "help", "policies", "login", "watch",
        "ads", "business", "privacy", "legal", "settings", "search",
    ]

    /// The page a Facebook URL points at — an id where it gives one, otherwise
    /// the vanity name.
    public static func page(fromURL url: String) -> (id: String?, name: String?) {
        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased(),
              host == "facebook.com" || host.hasSuffix(".facebook.com")
        else { return (nil, nil) }

        // `profile.php?id=123` is the numeric form of a page link.
        if components.path.contains("profile.php"),
           let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
           id.allSatisfy(\.isNumber) {
            return (id, nil)
        }

        let segments = components.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let first = segments.first?.lowercased() else { return (nil, nil) }
        guard !ignoredPaths.contains(first) else { return (nil, nil) }

        // The legacy `/pages/Name/123456` form ends in the numeric id.
        if first == "pages", let last = segments.last, last.allSatisfy(\.isNumber) {
            return (last, segments.count > 2 ? segments[1] : nil)
        }
        // A bare numeric path is itself an id.
        if segments.count == 1, first.allSatisfy(\.isNumber) {
            return (segments[0], nil)
        }
        guard segments.count == 1 else { return (nil, nil) }
        return (nil, segments[0])
    }

    public static func instagramHandle(fromURL url: String) -> String? {
        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased(),
              host == "instagram.com" || host.hasSuffix(".instagram.com")
        else { return nil }
        let segments = components.path.split(separator: "/").map(String.init)
        guard let handle = segments.first, !handle.isEmpty,
              !["p", "reel", "explore", "accounts", "stories"].contains(handle.lowercased())
        else { return nil }
        return handle
    }

    /// A handle from a platform whose profile URL is `host/<prefix><handle>`.
    static func handle(
        fromURL url: String, hosts: [String], prefix: String = "",
        pathPrefix: String? = nil, ignoring: Set<String> = []
    ) -> String? {
        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased(),
              hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return nil }

        var segments = components.path.split(separator: "/").map(String.init)
        if let pathPrefix {
            guard segments.first?.lowercased() == pathPrefix else { return nil }
            segments.removeFirst()
        }
        guard var handle = segments.first, !handle.isEmpty else { return nil }
        if !prefix.isEmpty {
            guard handle.hasPrefix(prefix) else { return nil }
            handle = String(handle.dropFirst(prefix.count))
        }
        guard !handle.isEmpty, !ignoring.contains(handle.lowercased()) else { return nil }
        return handle
    }

    /// Everything a page says about itself, deduplicated and ordered.
    public static func identity(
        metaPages: [String], links: [String]
    ) -> SocialIdentity {
        var identity = SocialIdentity()

        func add(_ value: String?, to list: inout [String]) {
            guard let value, !list.contains(value) else { return }
            list.append(value)
        }

        for content in metaPages {
            for id in pageIds(fromMeta: content) { add(id, to: &identity.pageIds) }
        }
        for link in links {
            let page = page(fromURL: link)
            add(page.id, to: &identity.pageIds)
            add(page.name, to: &identity.pageNames)
            add(instagramHandle(fromURL: link), to: &identity.instagramHandles)
            add(
                handle(
                    fromURL: link, hosts: ["linkedin.com"], pathPrefix: "company",
                    ignoring: ["setup", "admin"]
                ),
                to: &identity.linkedinCompanies
            )
            add(
                handle(
                    fromURL: link, hosts: ["tiktok.com"], prefix: "@",
                    ignoring: ["explore", "foryou"]
                ),
                to: &identity.tiktokHandles
            )
            add(
                handle(
                    fromURL: link, hosts: ["x.com", "twitter.com"],
                    ignoring: ["share", "intent", "home", "i", "hashtag", "search"]
                ),
                to: &identity.xHandles
            )
            add(
                handle(
                    fromURL: link, hosts: ["youtube.com"], prefix: "@",
                    ignoring: ["watch", "embed", "results"]
                ),
                to: &identity.youtubeChannels
            )
        }
        return identity
    }
}

/// One account this site declares, and where to go to see it.
///
/// Links rather than fetched data, deliberately. Of these platforms exactly one
/// has an API a marketer could use — Meta's, free but covering commercial ads
/// only where they were delivered to the EU or UK — and TikTok's research API
/// explicitly excludes commercial users. Deep-linking to the advertiser needs
/// no token, no approval, and can't go stale.
public struct SocialProfile: Sendable, Equatable, Identifiable {
    public var platform: String
    public var handle: String
    /// True when the handle addresses one advertiser exactly rather than being
    /// a search term that might match several.
    public var isExact: Bool
    public var profileURL: String
    public var adLibraryURL: String?
    public var note: String

    public var id: String { "\(platform).\(handle)" }

    public init(
        platform: String, handle: String, isExact: Bool = false,
        profileURL: String, adLibraryURL: String? = nil, note: String = ""
    ) {
        self.platform = platform
        self.handle = handle
        self.isExact = isExact
        self.profileURL = profileURL
        self.adLibraryURL = adLibraryURL
        self.note = note
    }
}

extension SocialDetection {

    /// Deep links for every account the site declares.
    public static func profiles(
        for identity: SocialIdentity, fallbackTerm: String
    ) -> [SocialProfile] {
        var out: [SocialProfile] = []

        func encoded(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
        }

        if let pageId = identity.pageIds.first {
            out.append(SocialProfile(
                platform: "Facebook", handle: pageId, isExact: true,
                profileURL: "https://www.facebook.com/\(pageId)",
                // The exact form: this advertiser's ads, not a name search.
                adLibraryURL: "https://www.facebook.com/ads/library/?active_status=all"
                    + "&ad_type=all&country=ALL&view_all_page_id=\(pageId)",
                note: "exact page id"
            ))
        } else if let name = identity.pageNames.first {
            out.append(SocialProfile(
                platform: "Facebook", handle: name,
                profileURL: "https://www.facebook.com/\(name)",
                adLibraryURL: "https://www.facebook.com/ads/library/?active_status=all"
                    + "&ad_type=all&country=ALL&q=\(encoded(name))",
                note: "page name — the library searches by name, not id"
            ))
        }

        if let handle = identity.instagramHandles.first {
            out.append(SocialProfile(
                platform: "Instagram", handle: handle,
                profileURL: "https://www.instagram.com/\(handle)/",
                note: "Instagram ads appear under the linked Facebook page"
            ))
        }

        if let company = identity.linkedinCompanies.first {
            out.append(SocialProfile(
                platform: "LinkedIn", handle: company, isExact: true,
                profileURL: "https://www.linkedin.com/company/\(company)/",
                adLibraryURL: "https://www.linkedin.com/ad-library/search?companyName="
                    + encoded(company),
                note: "no public API"
            ))
        }

        if let handle = identity.tiktokHandles.first {
            out.append(SocialProfile(
                platform: "TikTok", handle: handle, isExact: true,
                profileURL: "https://www.tiktok.com/@\(handle)",
                adLibraryURL: "https://library.tiktok.com/ads?region=all&adv_name="
                    + encoded(handle),
                note: "the research API excludes commercial use"
            ))
        }

        if let handle = identity.xHandles.first {
            out.append(SocialProfile(
                platform: "X", handle: handle, isExact: true,
                profileURL: "https://x.com/\(handle)",
                note: "no per-advertiser ad library"
            ))
        }

        if let channel = identity.youtubeChannels.first {
            out.append(SocialProfile(
                platform: "YouTube", handle: channel, isExact: true,
                profileURL: "https://www.youtube.com/@\(channel)",
                adLibraryURL: "https://adstransparency.google.com/?region=anywhere&domain="
                    + encoded(fallbackTerm),
                note: "Google's centre searches by domain, not channel"
            ))
        }

        return out
    }
}
