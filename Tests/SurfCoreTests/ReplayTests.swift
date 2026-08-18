import Foundation
import Testing

@testable import SurfCore

@Suite("Cookie matching")
struct CookieMatchingTests {

    private func cookie(
        _ name: String = "session", domain: String, path: String = "/",
        secure: Bool = false, expires: Date? = nil
    ) -> ReplayCookie {
        ReplayCookie(
            name: name, value: "v", domain: domain, path: path,
            isSecure: secure, expiresAt: expires
        )
    }

    /// The rule that makes this security-relevant rather than merely fiddly.
    /// A plain suffix check sends `example.com`'s session cookie to
    /// `notexample.com` — a session leak committed by a debugging tool.
    @Test("A domain cookie needs a label boundary, not just a suffix")
    func domainBoundary() {
        #expect(CookieMatching.domainMatches(host: "api.example.com", cookieDomain: ".example.com"))
        #expect(CookieMatching.domainMatches(host: "example.com", cookieDomain: "example.com"))
        #expect(CookieMatching.domainMatches(host: "example.com", cookieDomain: ".example.com"))

        #expect(!CookieMatching.domainMatches(host: "notexample.com", cookieDomain: "example.com"))
        #expect(!CookieMatching.domainMatches(host: "evilexample.com", cookieDomain: ".example.com"))
        // And never the other way around: a subdomain's cookie is not the
        // parent's.
        #expect(!CookieMatching.domainMatches(host: "example.com", cookieDomain: "api.example.com"))
    }

    @Test("Domain matching ignores case")
    func domainCase() {
        #expect(CookieMatching.domainMatches(host: "api.example.com", cookieDomain: ".EXAMPLE.com"))
    }

    /// `/api` covers `/api/users` but not `/apidocs` — the boundary is a
    /// slash, not a prefix.
    @Test("Path matching stops at a segment boundary")
    func pathBoundary() {
        #expect(CookieMatching.pathMatches(requestPath: "/api", cookiePath: "/api"))
        #expect(CookieMatching.pathMatches(requestPath: "/api/users", cookiePath: "/api"))
        #expect(CookieMatching.pathMatches(requestPath: "/api/users", cookiePath: "/api/"))
        #expect(CookieMatching.pathMatches(requestPath: "/anything", cookiePath: "/"))

        #expect(!CookieMatching.pathMatches(requestPath: "/apidocs", cookiePath: "/api"))
        #expect(!CookieMatching.pathMatches(requestPath: "/other", cookiePath: "/api"))
    }

    /// A Secure cookie over plain http is exactly the disclosure the flag
    /// exists to prevent.
    @Test("A Secure cookie never travels over http")
    func secureOnly() {
        let jar = [cookie(domain: "example.com", secure: true)]
        #expect(CookieMatching.cookies(for: "https://example.com/x", from: jar).count == 1)
        #expect(CookieMatching.cookies(for: "http://example.com/x", from: jar).isEmpty)
    }

    @Test("Expired cookies are left behind")
    func expiry() {
        let past = Date(timeIntervalSince1970: 1_000)
        let future = Date(timeIntervalSince1970: 4_000_000_000)
        let jar = [
            cookie("old", domain: "example.com", expires: past),
            cookie("live", domain: "example.com", expires: future),
            cookie("session", domain: "example.com"),
        ]
        let sent = CookieMatching.cookies(
            for: "https://example.com/", from: jar, now: Date(timeIntervalSince1970: 2_000)
        )
        #expect(sent.map(\.name).sorted() == ["live", "session"])
    }

    @Test("Matching combines domain, path, scheme and expiry")
    func combined() {
        let jar = [
            cookie("a", domain: ".example.com", path: "/api"),
            cookie("b", domain: "other.com"),
            cookie("c", domain: ".example.com", path: "/admin"),
            cookie("d", domain: ".example.com", secure: true),
        ]
        let sent = CookieMatching.cookies(for: "http://api.example.com/api/users", from: jar)
        #expect(sent.map(\.name) == ["a"])
    }

    @Test("The header is assembled the way a server expects it")
    func header() {
        let header = CookieMatching.header(for: [
            ReplayCookie(name: "a", value: "1", domain: "x"),
            ReplayCookie(name: "b", value: "2", domain: "x"),
        ])
        #expect(header == "a=1; b=2")
    }

    @Test("A URL with no host matches nothing rather than everything")
    func malformedURL() {
        let jar = [cookie(domain: "example.com")]
        #expect(CookieMatching.cookies(for: "not a url", from: jar).isEmpty)
        #expect(CookieMatching.cookies(for: "", from: jar).isEmpty)
    }
}

@Suite("Replay requests")
struct ReplayRequestTests {

    private func recorded(
        method: String = "POST",
        headers: [String: String] = ["Content-Type": "application/json", "X-Token": "abc"]
    ) -> NetworkRequest {
        NetworkRequest(
            id: "1", url: "https://example.com/api", method: method,
            status: 200, requestHeaders: headers, isDetailed: true
        )
    }

    /// Re-sending a stale Content-Length or a Cookie we're about to recompute
    /// produces a failure that reads like the server's fault.
    @Test("Headers the transport owns are dropped when building a replay")
    func excludesComputedHeaders() {
        let source = recorded(headers: [
            "Content-Type": "application/json",
            "Content-Length": "13",
            "Host": "example.com",
            "Cookie": "stale=1",
            "X-Token": "abc",
        ])
        let replay = ReplayRequest(from: source)
        #expect(replay.headers.map(\.name).sorted() == ["Content-Type", "X-Token"])
    }

    @Test("A replay starts as a faithful copy of what was observed")
    func copiesTheOriginal() {
        let replay = ReplayRequest(from: recorded(), body: #"{"a":1}"#)
        #expect(replay.method == "POST")
        #expect(replay.url == "https://example.com/api")
        #expect(replay.body == #"{"a":1}"#)
        #expect(replay.includesCookies)
    }

    /// Replaying a POST re-runs whatever it did the first time, so the UI has
    /// to be able to say so before sending.
    @Test("Non-idempotent methods are identifiable")
    func idempotence() {
        #expect(ReplayRequest(from: recorded(method: "GET")).isIdempotent)
        #expect(!ReplayRequest(from: recorded(method: "POST")).isIdempotent)
        #expect(!ReplayRequest(from: recorded(method: "DELETE")).isIdempotent)
    }

    @Test("Disabled and blank headers don't reach the wire")
    func headerDictionary() {
        var replay = ReplayRequest(from: recorded())
        replay.headers.append(ReplayHeader(name: "X-Off", value: "1", isEnabled: false))
        replay.headers.append(ReplayHeader(name: "  ", value: "ignored"))
        #expect(replay.headerDictionary.keys.sorted() == ["Content-Type", "X-Token"])
    }
}

@Suite("Replay comparison")
struct ReplayComparisonTests {

    private func response(
        status: Int, size: Int = 100, duration: Double = 10,
        headers: [String: String] = [:]
    ) -> NetworkRequest {
        NetworkRequest(
            id: "x", url: "https://example.com/api", status: status,
            transferSize: size, duration: duration, responseHeaders: headers
        )
    }

    @Test("An unchanged replay says so")
    func identical() {
        let comparison = ReplayComparison(
            original: response(status: 200), originalBody: "{}",
            replayed: response(status: 200), replayedBody: "{}"
        )
        #expect(comparison.isIdentical)
    }

    @Test("A changed status and a changed body are both reported")
    func changes() {
        let comparison = ReplayComparison(
            original: response(status: 200), originalBody: #"{"a":1}"#,
            replayed: response(status: 401), replayedBody: #"{"error":"nope"}"#
        )
        #expect(comparison.statusChanged)
        #expect(comparison.bodyChanged)
        #expect(!comparison.isIdentical)
    }

    /// Claiming a body changed when one side was never captured would be a
    /// guess dressed up as a finding.
    @Test("An uncaptured body is not reported as a difference")
    func missingBody() {
        let comparison = ReplayComparison(
            original: response(status: 200), originalBody: nil,
            replayed: response(status: 200), replayedBody: "{}"
        )
        #expect(!comparison.bodyChanged)
        #expect(comparison.isIdentical)
    }

    /// Every response carries a fresh Date. Reporting it as a difference would
    /// mean every replay looked changed, which is the same as reporting nothing.
    @Test("Headers that always differ are ignored")
    func ignoresNoiseHeaders() {
        let comparison = ReplayComparison(
            original: response(status: 200, headers: ["Date": "Mon", "ETag": "a"]),
            originalBody: nil,
            replayed: response(status: 200, headers: ["Date": "Tue", "ETag": "a"]),
            replayedBody: nil
        )
        #expect(comparison.changedHeaders.isEmpty)
    }

    @Test("A header that appears or changes is named")
    func namesChangedHeaders() {
        let comparison = ReplayComparison(
            original: response(status: 200, headers: ["ETag": "a"]), originalBody: nil,
            replayed: response(status: 200, headers: ["ETag": "b", "X-New": "1"]),
            replayedBody: nil
        )
        #expect(comparison.changedHeaders == ["etag", "x-new"])
    }

    @Test("Size and duration deltas are signed")
    func deltas() {
        let comparison = ReplayComparison(
            original: response(status: 200, size: 500, duration: 100), originalBody: nil,
            replayed: response(status: 200, size: 300, duration: 40), replayedBody: nil
        )
        #expect(comparison.sizeDelta == -200)
        #expect(comparison.durationDelta == -60)
    }
}
