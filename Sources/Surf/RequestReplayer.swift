import Foundation
import SurfCore
import WebKit

/// Sends a request again, natively.
///
/// This is the reason the Network pane was worth building here rather than
/// cloning. A page-side re-fetch is bound by CORS and cannot read the session
/// it is authenticated with — `HttpOnly` exists precisely to keep script away
/// from it. `WKHTTPCookieStore` hands those cookies over, and `URLSession` is
/// not subject to CORS at all, so a replay from here carries the real session
/// to any origin. No JS-based inspector can do that, which is why Chrome's
/// "copy as cURL" exists: it is the workaround for not being able to.
///
/// Metrics come from `URLSessionTaskMetrics`, which reports DNS, connect, TLS
/// and response phases even cross-origin — better than Resource Timing manages
/// for a third-party host that withholds `Timing-Allow-Origin`.
@MainActor
enum RequestReplayer {

    struct Result: Sendable {
        var request: NetworkRequest
        var body: NetworkBody?
    }

    enum ReplayError: LocalizedError {
        case badURL

        var errorDescription: String? {
            switch self {
            case .badURL: "That isn't a URL this can send."
            }
        }
    }

    static func send(
        _ replay: ReplayRequest,
        replacing original: NetworkRequest?,
        in tab: Tab,
        startingAt timelineOffset: Double
    ) async -> Result {
        let id = "replay:\(UUID().uuidString.prefix(8))"

        guard let url = URL(string: replay.url), url.host != nil else {
            return Result(
                request: NetworkRequest(
                    id: id, url: replay.url, method: replay.method,
                    kind: original?.kind ?? .fetch,
                    failure: ReplayError.badURL.errorDescription,
                    startedAt: timelineOffset, duration: 0,
                    isDetailed: true, replayOf: original?.id
                ),
                body: nil
            )
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = replay.method.uppercased()
        for (name, value) in replay.headerDictionary {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if !replay.body.isEmpty, !["GET", "HEAD"].contains(urlRequest.httpMethod ?? "") {
            urlRequest.httpBody = Data(replay.body.utf8)
        }

        var sentCookies: [ReplayCookie] = []
        if replay.includesCookies {
            sentCookies = CookieMatching.cookies(for: replay.url, from: await jar(for: tab))
            if !sentCookies.isEmpty {
                urlRequest.setValue(
                    CookieMatching.header(for: sentCookies), forHTTPHeaderField: "Cookie"
                )
            }
        }

        let collector = MetricsCollector()
        // Ephemeral, and told not to keep or send a jar of its own: the only
        // cookies on this request are the ones matched above, from the tab. A
        // session that quietly accumulated its own would drift out of step with
        // the browser it is supposed to be impersonating.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration, delegate: collector, delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let started = Date()
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let elapsed = Date().timeIntervalSince(started) * 1000
            let http = response as? HTTPURLResponse

            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                headers["\(key)"] = "\(value)"
            }
            let contentType = headers
                .first { $0.key.lowercased() == "content-type" }?.value ?? ""

            var request = NetworkRequest(
                id: id,
                url: replay.url,
                method: replay.method.uppercased(),
                kind: original?.kind ?? .fetch,
                status: http?.statusCode,
                statusText: http.map {
                    HTTPURLResponse.localizedString(forStatusCode: $0.statusCode)
                } ?? "",
                transferSize: collector.transferred ?? data.count,
                bodySize: data.count,
                startedAt: timelineOffset,
                duration: collector.duration ?? elapsed,
                protocolName: collector.networkProtocol ?? "",
                initiator: "replay",
                requestHeaders: replay.headerDictionary.merging(
                    // Shown so it is never a mystery which session was used —
                    // and HttpOnly cookies are marked, since carrying those is
                    // the whole point.
                    sentCookies.isEmpty ? [:] : ["Cookie": CookieMatching.header(for: sentCookies)]
                ) { current, _ in current },
                responseHeaders: headers,
                isDetailed: true,
                hasResponseBody: !data.isEmpty,
                replayOf: original?.id
            )
            request.hasRequestBody = !replay.body.isEmpty

            return Result(request: request, body: body(from: data, contentType: contentType))
        } catch {
            return Result(
                request: NetworkRequest(
                    id: id, url: replay.url, method: replay.method.uppercased(),
                    kind: original?.kind ?? .fetch,
                    failure: error.localizedDescription,
                    startedAt: timelineOffset,
                    duration: Date().timeIntervalSince(started) * 1000,
                    initiator: "replay", requestHeaders: replay.headerDictionary,
                    isDetailed: true, replayOf: original?.id
                ),
                body: nil
            )
        }
    }

    /// The tab's cookies, including the `HttpOnly` ones no script can read.
    static func jar(for tab: Tab) async -> [ReplayCookie] {
        let store = tab.dataStore.httpCookieStore
        let cookies = await store.allCookies()
        return cookies.map {
            ReplayCookie(
                name: $0.name, value: $0.value, domain: $0.domain,
                path: $0.path, isSecure: $0.isSecure, isHTTPOnly: $0.isHTTPOnly,
                expiresAt: $0.expiresDate
            )
        }
    }

    private static func body(from data: Data, contentType: String) -> NetworkBody {
        guard !data.isEmpty else { return NetworkBody(omission: .empty) }
        guard BodyFormat.from(contentType: contentType) != .binary else {
            return NetworkBody(byteCount: data.count, contentType: contentType, omission: .binary)
        }
        let cap = 512 * 1024
        let slice = data.count > cap ? data.prefix(cap) : data
        guard let text = String(data: slice, encoding: .utf8) else {
            return NetworkBody(byteCount: data.count, contentType: contentType, omission: .binary)
        }
        return NetworkBody(
            text: text, byteCount: data.count,
            isTruncated: data.count > cap, contentType: contentType
        )
    }
}

/// Real phase timings, which `URLSession` reports even for hosts that withhold
/// `Timing-Allow-Origin` from the page.
private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private(set) var duration: Double?
    private(set) var transferred: Int?
    private(set) var networkProtocol: String?

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        duration = metrics.taskInterval.duration * 1000
        guard let transaction = metrics.transactionMetrics.last else { return }
        networkProtocol = transaction.networkProtocolName
        let received = transaction.countOfResponseHeaderBytesReceived
            + transaction.countOfResponseBodyBytesReceived
        if received > 0 { transferred = Int(received) }
    }
}
