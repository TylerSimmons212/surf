import Foundation
import SurfCore

/// Fetches segments with the tab's own session behind them.
///
/// The hard part of downloading a stream is not the fetching. It is arriving at
/// the CDN looking like the player that was just allowed to watch it, and
/// `RequestReplayer` already proved how: an ephemeral `URLSession` told to keep
/// no jar of its own, with the cookies matched per request from
/// `WKHTTPCookieStore` — which hands over the `HttpOnly` ones no script can see —
/// and no CORS to answer to. That file is a download engine with the bytes thrown
/// away. This is the same arrangement with the bytes kept.
///
/// Not an extension of `RequestReplayer`, deliberately. That type answers in
/// `NetworkRequest` and `NetworkBody` for a dev-tools panel and caps bodies at
/// 512KB. The six lines of session setup are worth duplicating rather than
/// abstracting over two callers with nothing else in common.
/// `Sendable` rather than `@MainActor`, so several hundred segment requests are
/// not built on the main thread. Only reading the tab's session needs the main
/// actor, and that happens once.
final class SegmentFetcher: Sendable {

    /// Where the request appears to come from.
    ///
    /// Collected once, at the start, rather than read per request. Two reasons:
    /// touching the tab for every one of several hundred segments is needless, and
    /// a download can outlive the tab that started it.
    struct Credentials: Sendable {
        var cookies: [ReplayCookie]
        var referer: String?
        var userAgent: String?
    }

    private let session: URLSession
    private let credentials: Credentials

    init(credentials: Credentials, parallelism: Int) {
        let configuration = URLSessionConfiguration.ephemeral
        // The only cookies on these requests are the ones matched below, from the
        // tab. A session accumulating its own would drift out of step with the
        // browser it is standing in for.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Raised from the default six, because the whole point is several
        // segments at once. Set explicitly rather than inherited so the number
        // the schedule hands out and the number the session will actually run are
        // the same.
        configuration.httpMaximumConnectionsPerHost = max(1, parallelism)
        configuration.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: configuration)
        self.credentials = credentials
    }

    deinit { session.invalidateAndCancel() }

    /// The tab's session, read once.
    @MainActor
    static func credentials(for tab: Tab?, page: URL?) async -> Credentials {
        guard let tab else {
            return Credentials(cookies: [], referer: page?.absoluteString, userAgent: nil)
        }
        return Credentials(
            cookies: await RequestReplayer.jar(for: tab),
            // Some CDNs refuse media that arrives without the page referrer, which
            // the direct download path already knew and works around the same way.
            referer: (page ?? tab.webView.url)?.absoluteString,
            userAgent: tab.webView.value(forKey: "customUserAgent") as? String
        )
    }

    enum Failure: Error, Equatable {
        /// The server said no. Carried rather than flattened because a 403 is the
        /// one status worth changing tactics over.
        case status(Int)
        case transport(String)
        /// A ranged request answered with the whole file, which would write the
        /// wrong bytes at the right offset.
        case rangeIgnored
    }

    /// One segment. Returns its bytes, which the caller writes in order.
    func fetch(_ segment: StreamSegment) async -> Result<Data, Failure> {
        var request = URLRequest(url: segment.url)
        if let referer = credentials.referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let userAgent = credentials.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        // Matched against this URL, every time. Never a header copied from an
        // earlier request: the manifest decides which hosts these go to, so the
        // scoping has to be re-derived per host rather than inherited.
        let cookies = CookieMatching.cookies(
            for: segment.url.absoluteString, from: credentials.cookies
        )
        if !cookies.isEmpty {
            request.setValue(CookieMatching.header(for: cookies), forHTTPHeaderField: "Cookie")
        }
        if let range = segment.byteRange {
            request.setValue(
                "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                forHTTPHeaderField: "Range"
            )
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .success(data)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.status(http.statusCode))
            }
            // A server that ignores `Range` answers 200 with everything. Writing
            // that at a segment's offset produces a file that is the right size
            // and wrong throughout, which is worse than failing.
            if let range = segment.byteRange,
               http.statusCode == 200, data.count != range.count {
                return .failure(.rangeIgnored)
            }
            return .success(data)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    /// What the server will say about a file before any of it is fetched.
    ///
    /// A one-byte ranged GET rather than a HEAD, for two reasons. Some CDNs refuse
    /// HEAD outright or answer it without the headers that matter, and a range
    /// request is the thing being tested anyway — a server that answers this with
    /// 206 and a `Content-Range` has demonstrated the capability rather than
    /// promised it.
    ///
    /// It doubles as the safety gate for taking a download away from WebKit. The
    /// existing path uses `WKWebView.startDownload` precisely so it inherits the
    /// session, and a comment there warns that a separate `URLSession` would be
    /// logged out and get a 403. This probe runs through exactly the session the
    /// parallel fetch would use, against exactly the URL it would use, so a
    /// success means the credentials work for this file. Anything else, and the
    /// download stays where it was.
    struct Probe: Sendable {
        var length: Int?
        var acceptsRanges: String?
    }

    func probe(_ url: URL) async -> Probe? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        if let referer = credentials.referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let userAgent = credentials.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        let cookies = CookieMatching.cookies(
            for: url.absoluteString, from: credentials.cookies
        )
        if !cookies.isEmpty {
            request.setValue(CookieMatching.header(for: cookies), forHTTPHeaderField: "Cookie")
        }

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 206
        else { return nil }

        // `Content-Range: bytes 0-0/304608906`. The total after the slash is the
        // only reliable length here: `Content-Length` on a 206 describes the one
        // byte that came back.
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        let total = contentRange?.components(separatedBy: "/").last.flatMap { Int($0) }
        return Probe(
            length: total,
            // A 206 is itself the promise, whatever the header says — but prefer
            // the header when it is there, since that is what the pure check reads.
            acceptsRanges: http.value(forHTTPHeaderField: "Accept-Ranges") ?? "bytes"
        )
    }

    /// One POST, for a protocol that asks rather than addresses.
    ///
    /// Separate from `fetch` because everything else here is a ranged GET of a
    /// segment whose URL says what it is. YouTube's streaming endpoint is the
    /// opposite: one URL, and what you get depends entirely on the body you send.
    ///
    /// Carries the same credentials as everything else — the tab's cookies
    /// matched per request, its referrer, its user agent — because the signed URL
    /// alone is not what makes the server answer.
    func post(_ body: Data, to url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        if let referer = credentials.referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let userAgent = credentials.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        let cookies = CookieMatching.cookies(
            for: url.absoluteString, from: credentials.cookies
        )
        if !cookies.isEmpty {
            request.setValue(CookieMatching.header(for: cookies), forHTTPHeaderField: "Cookie")
        }

        guard let (data, response) = try? await session.data(for: request) else { return nil }
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            // 403 here is the one worth recognising: it is what a request with no
            // proof-of-origin token gets, and it arrives with an empty body so
            // there is no error part inside to read.
            debugLog("sabr: POST refused — HTTP \(http.statusCode), \(data.count) bytes")
            return nil
        }
        return data
    }

    /// A whole manifest, as text.
    func text(at url: URL) async -> String? {
        guard case .success(let data) = await fetch(StreamSegment(url: url)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
