import Foundation

/// A request about to be sent again, after any editing.
public struct ReplayRequest: Sendable, Equatable {
    public var method: String
    public var url: String
    /// Authored order isn't recoverable from a dictionary, and header order
    /// occasionally matters to a server, so these stay a list.
    public var headers: [ReplayHeader]
    public var body: String
    /// Whether to attach the tab's cookies. On by default — replaying an
    /// authenticated call without them just returns 401, which looks like the
    /// endpoint is broken rather than like the request was incomplete.
    public var includesCookies: Bool

    public init(
        method: String = "GET",
        url: String = "",
        headers: [ReplayHeader] = [],
        body: String = "",
        includesCookies: Bool = true
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.includesCookies = includesCookies
    }

    /// Built from something already observed.
    public init(from request: NetworkRequest, body: String = "") {
        self.init(
            method: request.method,
            url: request.url,
            // Hop-by-hop and computed headers are dropped: re-sending a stale
            // Content-Length or an Accept-Encoding we won't honour produces a
            // failure that looks like the server's fault.
            headers: request.requestHeaders
                .filter { !ReplayRequest.excluded.contains($0.key.lowercased()) }
                .sorted { $0.key < $1.key }
                .map { ReplayHeader(name: $0.key, value: $0.value) },
            body: body
        )
    }

    static let excluded: Set<String> = [
        "content-length", "host", "connection", "keep-alive",
        "transfer-encoding", "upgrade", "accept-encoding", "cookie",
    ]

    public var isIdempotent: Bool {
        ["GET", "HEAD", "OPTIONS", "TRACE"].contains(method.uppercased())
    }

    public var headerDictionary: [String: String] {
        headers.reduce(into: [:]) { result, header in
            let name = header.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, header.isEnabled else { return }
            result[name] = header.value
        }
    }
}

public struct ReplayHeader: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var value: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, value: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.value = value
        self.isEnabled = isEnabled
    }
}

/// A cookie as the cookie store described it, reduced to what matching needs.
public struct ReplayCookie: Sendable, Equatable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public var expiresAt: Date?

    public init(
        name: String, value: String, domain: String, path: String = "/",
        isSecure: Bool = false, isHTTPOnly: Bool = false, expiresAt: Date? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.expiresAt = expiresAt
    }
}

/// Decides which cookies a replayed request may carry.
///
/// The capability this exists to deliver is real and unusual: `WKHTTPCookieStore`
/// hands over **HttpOnly** cookies, which page script is forbidden to read — so
/// a replay from here carries the session that a page-side re-fetch simply
/// cannot. That is also exactly why the matching has to be right. Sending a
/// session cookie to a host it wasn't issued for would be a security bug
/// committed by a debugging tool, so every rule here is the spec's rule and is
/// pinned by a test.
public enum CookieMatching {

    public static func cookies(
        for urlString: String, from jar: [ReplayCookie], now: Date = Date()
    ) -> [ReplayCookie] {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased()
        else { return [] }

        let isSecureScheme = (components.scheme ?? "").lowercased() == "https"
        let path = components.path.isEmpty ? "/" : components.path

        return jar.filter { cookie in
            if let expiry = cookie.expiresAt, expiry <= now { return false }
            if cookie.isSecure, !isSecureScheme { return false }
            guard domainMatches(host: host, cookieDomain: cookie.domain) else { return false }
            return pathMatches(requestPath: path, cookiePath: cookie.path)
        }
    }

    /// RFC 6265 §5.1.3.
    ///
    /// The subtlety that matters: a domain cookie for `example.com` is sent to
    /// `api.example.com`, but must *never* go to `notexample.com` — a plain
    /// suffix check would send it to both, which is how a debugging tool leaks
    /// a session to an attacker's host.
    public static func domainMatches(host: String, cookieDomain: String) -> Bool {
        let domain = cookieDomain.hasPrefix(".")
            ? String(cookieDomain.dropFirst()).lowercased()
            : cookieDomain.lowercased()
        guard !domain.isEmpty else { return false }
        if host == domain { return true }
        // The dot is the whole point: it forces a label boundary.
        return host.hasSuffix("." + domain)
    }

    /// RFC 6265 §5.1.4. `/api` covers `/api` and `/api/users`, but not
    /// `/apidocs` — the boundary has to be a slash, not a prefix.
    public static func pathMatches(requestPath: String, cookiePath: String) -> Bool {
        let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
        if cookiePath == "/" { return true }
        if requestPath == cookiePath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if cookiePath.hasSuffix("/") { return true }
        return requestPath.dropFirst(cookiePath.count).hasPrefix("/")
    }

    /// `a=1; b=2` — the header value itself.
    public static func header(for cookies: [ReplayCookie]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

/// What changed between the original response and the one just replayed.
///
/// The reason to bother: a replay you can't compare against the original only
/// tells you the endpoint still answers. What people are actually asking is
/// "is it different now" — after a deploy, a token refresh, a header tweak.
public struct ReplayComparison: Sendable, Equatable {
    public var statusChanged: Bool
    public var originalStatus: Int?
    public var replayedStatus: Int?
    public var bodyChanged: Bool
    public var sizeDelta: Int
    public var durationDelta: Double
    public var changedHeaders: [String]

    public init(
        original: NetworkRequest,
        originalBody: String?,
        replayed: NetworkRequest,
        replayedBody: String?
    ) {
        originalStatus = original.status
        replayedStatus = replayed.status
        statusChanged = original.status != replayed.status
        // Unknown on either side means unknown overall — claiming a body
        // changed when one of them was never captured would be a guess.
        bodyChanged = {
            guard let originalBody, let replayedBody else { return false }
            return originalBody != replayedBody
        }()
        sizeDelta = (replayed.transferSize ?? 0) - (original.transferSize ?? 0)
        durationDelta = (replayed.duration ?? 0) - (original.duration ?? 0)

        let interesting = Set(
            original.responseHeaders.keys.map { $0.lowercased() }
        ).union(replayed.responseHeaders.keys.map { $0.lowercased() })

        changedHeaders = interesting.filter { key in
            let before = original.responseHeaders
                .first { $0.key.lowercased() == key }?.value
            let after = replayed.responseHeaders
                .first { $0.key.lowercased() == key }?.value
            // Dates differ on every response and say nothing.
            guard !["date", "age", "expires"].contains(key) else { return false }
            return before != after
        }.sorted()
    }

    public var isIdentical: Bool {
        !statusChanged && !bodyChanged && changedHeaders.isEmpty
    }
}
