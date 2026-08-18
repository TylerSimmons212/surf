import Foundation

/// The vendor table, and how to read a request as an event.
///
/// A pixel fire is a network request with the event encoded in it, and Surf
/// already records every request the page makes — including `<img>` fires and
/// beacons, which are the ones most tags use. So this needs no new capture at
/// all: it reads what the Network pane already holds and says what it means.
public enum TagDecoder {

    public static let signatures: [TagSignature] = [
        TagSignature(
            id: "ga4", name: "Google Analytics 4", category: .analytics,
            hosts: ["google-analytics.com", "analytics.google.com"],
            pathContains: "/collect",
            account: .query(["tid"]),
            eventParameters: ["en"], defaultEvent: "page_view",
            parameterPrefixes: ["ep.", "epn.", "up.", "upn."],
            globals: ["gtag", "dataLayer"]
        ),
        TagSignature(
            id: "google-ads", name: "Google Ads", category: .advertising,
            hosts: ["googleads.g.doubleclick.net", "google.com", "googleadservices.com"],
            pathContains: "conversion",
            account: .pathSegment(after: "viewthroughconversion"),
            eventParameters: ["label"], defaultEvent: "conversion",
            adLibrary: AdLibrary(
                name: "Google Ads Transparency Center",
                template: "https://adstransparency.google.com/?region=anywhere&domain={domain}",
                note: "searched by domain — Google's centre has no public API"
            ),
            globals: ["google_trackConversion"]
        ),
        TagSignature(
            id: "floodlight", name: "Campaign Manager (Floodlight)", category: .advertising,
            hosts: ["fls.doubleclick.net", "ad.doubleclick.net"],
            pathContains: "/activity",
            account: .query(["src"]),
            eventParameters: ["cat"], defaultEvent: "activity"
        ),
        TagSignature(
            id: "gtm", name: "Google Tag Manager", category: .tagManager,
            hosts: ["googletagmanager.com"],
            account: .query(["id"]),
            defaultEvent: "container load",
            globals: ["dataLayer", "google_tag_manager"]
        ),
        TagSignature(
            id: "meta", name: "Meta Pixel", category: .advertising,
            hosts: ["facebook.com", "connect.facebook.net"],
            pathContains: "/tr",
            account: .query(["id"]),
            eventParameters: ["ev"], defaultEvent: "PageView",
            parameterPrefixes: ["cd[", "cd."],
            adLibrary: AdLibrary(
                name: "Meta Ad Library",
                template: "https://www.facebook.com/ads/library/?active_status=all&ad_type=all&country=ALL&q={domain}",
                // Exact, when the site declares its Page: this returns that one
                // advertiser's ads rather than a name search.
                pageTemplate: "https://www.facebook.com/ads/library/?active_status=all&ad_type=all&country=ALL&view_all_page_id={id}",
                note: "the API is free but covers commercial ads only for EU and UK delivery"
            ),
            globals: ["fbq", "_fbq"]
        ),
        TagSignature(
            id: "tiktok", name: "TikTok Pixel", category: .advertising,
            hosts: ["analytics.tiktok.com"],
            account: .query(["sdkid", "pixel_code"]),
            eventParameters: ["event"], defaultEvent: "Pageview",
            adLibrary: AdLibrary(
                name: "TikTok Creative Center",
                template: "https://ads.tiktok.com/business/creativecenter/inspiration/topads/pc/en?query={domain}",
                note: "no public API"
            ),
            globals: ["ttq", "TiktokAnalyticsObject"]
        ),
        TagSignature(
            id: "linkedin", name: "LinkedIn Insight", category: .advertising,
            hosts: ["px.ads.linkedin.com", "snap.licdn.com"],
            account: .query(["pid"]),
            eventParameters: ["conversionId"], defaultEvent: "page view",
            adLibrary: AdLibrary(
                name: "LinkedIn Ad Library",
                template: "https://www.linkedin.com/ad-library/search?companyName={domain}",
                note: "no public API"
            ),
            globals: ["_linkedin_data_partner_ids", "lintrk"]
        ),
        TagSignature(
            id: "pinterest", name: "Pinterest Tag", category: .advertising,
            hosts: ["ct.pinterest.com"],
            account: .query(["tid"]),
            eventParameters: ["event"], defaultEvent: "pagevisit",
            parameterPrefixes: ["ed["],
            globals: ["pintrk"]
        ),
        TagSignature(
            id: "snap", name: "Snap Pixel", category: .advertising,
            hosts: ["tr.snapchat.com", "sc-static.net"],
            account: .query(["pid"]),
            eventParameters: ["ev"], defaultEvent: "PAGE_VIEW",
            globals: ["snaptr"]
        ),
        TagSignature(
            id: "reddit", name: "Reddit Pixel", category: .advertising,
            hosts: ["alb.reddit.com", "events.redditmedia.com"],
            account: .query(["id"]),
            eventParameters: ["event"], defaultEvent: "PageVisit",
            globals: ["rdt"]
        ),
        TagSignature(
            id: "twitter", name: "X (Twitter) Pixel", category: .advertising,
            hosts: ["analytics.twitter.com", "static.ads-twitter.com"],
            account: .query(["txn_id", "pid"]),
            eventParameters: ["events"], defaultEvent: "PageView",
            globals: ["twq"]
        ),
        TagSignature(
            id: "klaviyo", name: "Klaviyo", category: .email,
            hosts: ["a.klaviyo.com", "static.klaviyo.com"],
            account: .query(["company_id"]),
            eventParameters: ["event"], defaultEvent: "track",
            globals: ["klaviyo", "_learnq"]
        ),
        TagSignature(
            id: "hotjar", name: "Hotjar", category: .sessionReplay,
            hosts: ["hotjar.com", "hotjar.io"],
            account: .query(["site_id", "sv"]),
            defaultEvent: "session",
            globals: ["hj", "_hjSettings"]
        ),
        TagSignature(
            id: "clarity", name: "Microsoft Clarity", category: .sessionReplay,
            hosts: ["clarity.ms"],
            account: .query(["pid"]),
            defaultEvent: "session",
            globals: ["clarity"]
        ),
        TagSignature(
            id: "segment", name: "Segment", category: .analytics,
            hosts: ["api.segment.io", "cdn.segment.com"],
            account: .query(["writeKey"]),
            eventParameters: ["event"], defaultEvent: "track",
            globals: ["analytics"]
        ),
        TagSignature(
            id: "amplitude", name: "Amplitude", category: .analytics,
            hosts: ["amplitude.com", "api.amplitude.com"],
            account: .query(["api_key"]),
            defaultEvent: "event",
            globals: ["amplitude"]
        ),
        TagSignature(
            id: "mixpanel", name: "Mixpanel", category: .analytics,
            hosts: ["api-js.mixpanel.com", "api.mixpanel.com"],
            account: .query(["token"]),
            defaultEvent: "track",
            globals: ["mixpanel"]
        ),
    ]

    /// The vendor a request belongs to, if any.
    ///
    /// Host matching is suffix-with-a-boundary, never a plain `contains`: a
    /// plain substring test would attribute `evil-facebook.com.attacker.test`
    /// to Meta, and a tag debugger that misattributes traffic is worse than one
    /// that misses it.
    public static func signature(for url: String) -> TagSignature? {
        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased()
        else { return nil }
        let path = components.path.lowercased()

        return signatures.first { signature in
            let hostMatches = signature.hosts.contains { candidate in
                host == candidate || host.hasSuffix("." + candidate)
            }
            guard hostMatches else { return false }
            guard let required = signature.pathContains else { return true }
            return path.contains(required)
        }
    }

    /// Reads a request as an event, or returns nil if it isn't one.
    public static func decode(_ request: NetworkRequest, body: String? = nil) -> TagEvent? {
        guard let signature = signature(for: request.url) else { return nil }
        guard let components = URLComponents(string: request.url) else { return nil }

        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            parameters[item.name] = item.value ?? ""
        }
        // Some vendors POST their payload instead — TikTok and GA4 batch that
        // way — so the body is folded in where there is one.
        if let body, !body.isEmpty {
            for pair in decodeBody(body) { parameters[pair.key] = pair.value }
        }

        let accountId = account(for: signature, components: components, parameters: parameters)
        let name = signature.eventParameters
            .compactMap { parameters[$0] }
            .first { !$0.isEmpty } ?? signature.defaultEvent

        return TagEvent(
            id: request.id,
            vendorId: signature.id,
            vendorName: signature.name,
            category: signature.category,
            accountId: accountId,
            name: name,
            parameters: normalise(parameters, prefixes: signature.parameterPrefixes),
            at: request.startedAt,
            url: request.url
        )
    }

    private static func account(
        for signature: TagSignature,
        components: URLComponents,
        parameters: [String: String]
    ) -> String {
        switch signature.account {
        case .query(let names):
            return names.compactMap { parameters[$0] }.first { !$0.isEmpty } ?? ""
        case .pathSegment(let marker):
            let segments = components.path.split(separator: "/").map(String.init)
            guard let index = segments.firstIndex(of: marker),
                  segments.indices.contains(index + 1)
            else { return "" }
            return segments[index + 1]
        case .none:
            return ""
        }
    }

    /// Strips the vendor's custom-data prefix so `cd[value]` and `ep.value`
    /// both read as `value` — the parameter is the same fact either way, and
    /// the validation rules shouldn't need a spelling per vendor.
    static func normalise(
        _ parameters: [String: String], prefixes: [String]
    ) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in parameters {
            var name = key
            for prefix in prefixes where name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
                if name.hasSuffix("]") { name = String(name.dropLast()) }
                break
            }
            out[name] = value
        }
        return out
    }

    /// Form-encoded or JSON, whichever the body turns out to be.
    static func decodeBody(_ body: String) -> [String: String] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return flatten(object)
        }
        var out: [String: String] = [:]
        for pair in trimmed.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            out[parts[0].removingPercentEncoding ?? parts[0]] =
                parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[1]
        }
        return out
    }

    private static func flatten(_ object: [String: Any], prefix: String = "") -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in object {
            let name = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                // Nested objects are common — TikTok wraps everything in
                // `context` and `properties` — and the leaf is what matters.
                for (innerKey, innerValue) in flatten(nested) { out[innerKey] = innerValue }
                for (innerKey, innerValue) in flatten(nested, prefix: name) {
                    out[innerKey] = innerValue
                }
            } else if let array = value as? [Any] {
                out[name] = array.map { "\($0)" }.joined(separator: ",")
            } else {
                out[name] = "\(value)"
            }
        }
        return out
    }
}
