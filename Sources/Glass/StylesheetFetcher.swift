import Foundation
import GlassCore
import WebKit

/// Fetches a stylesheet the page itself is forbidden to read.
///
/// A cross-origin stylesheet served without `Access-Control-Allow-Origin`
/// throws `SecurityError` on `.cssRules`. That is a restriction on *page
/// script*, not on the browser — so every inspector built out of page script
/// shows nothing for those sheets, which looks exactly like the sheet having no
/// rules for the element you're looking at. `URLSession` is not bound by CORS
/// at all, so Glass can simply go and get it.
///
/// Sent with the tab's cookies, because a stylesheet behind a login is a
/// stylesheet, and fetching it anonymously would return the sign-in page and
/// then fail to parse as CSS.
@MainActor
enum StylesheetFetcher {

    enum FetchError: LocalizedError {
        case badURL
        case http(Int)
        case notStylesheet(String)
        case tooLarge(Int)
        case undecodable

        var errorDescription: String? {
            switch self {
            case .badURL: "not a fetchable URL"
            case .http(let status): "server returned \(status)"
            case .notStylesheet(let type): "served as \(type), not CSS"
            case .tooLarge(let bytes): "too large (\(NetworkRequest.formatBytes(bytes)))"
            case .undecodable: "not readable as text"
            }
        }
    }

    private static let cap = 4 * 1024 * 1024

    static func fetch(_ href: String, in tab: Tab) async -> Result<String, FetchError> {
        guard let url = URL(string: href), url.host != nil else { return .failure(.badURL) }

        var request = URLRequest(url: url)
        request.setValue("text/css,*/*;q=0.1", forHTTPHeaderField: "Accept")
        // Some CDNs vary on these, and a stylesheet fetched without them can
        // come back as something else entirely.
        // `currentURL`, which describes without building — see `pageURL`.
        if let page = tab.currentURL {
            request.setValue(page, forHTTPHeaderField: "Referer")
        }
        let cookies = CookieMatching.cookies(for: href, from: await RequestReplayer.jar(for: tab))
        if !cookies.isEmpty {
            request.setValue(CookieMatching.header(for: cookies), forHTTPHeaderField: "Cookie")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.http(http.statusCode))
            }
            guard data.count <= cap else { return .failure(.tooLarge(data.count)) }

            // A sign-in page returned with a 200 is the common failure here, and
            // parsing HTML as CSS yields a sheet with no rules — which would
            // look like a successful recovery of a stylesheet that does nothing.
            let mime = (response.mimeType ?? "").lowercased()
            if !mime.isEmpty, !mime.contains("css"), !mime.contains("text/plain"),
               !mime.contains("octet-stream") {
                return .failure(.notStylesheet(mime))
            }

            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
            else { return .failure(.undecodable) }
            return .success(text)
        } catch {
            return .failure(.http(0))
        }
    }
}
