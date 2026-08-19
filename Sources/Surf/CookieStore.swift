import Foundation
import SurfCore
import WebKit

/// Cookies and per-origin site data, read natively.
///
/// The two things here that page script cannot do at all:
///
/// * `WKHTTPCookieStore` returns **HttpOnly** cookies. `HttpOnly` means exactly
///   "script may not see this", so a cookie panel built out of page script is
///   blind to precisely the cookies that carry a session — the ones anyone
///   opening a cookie panel is usually looking for.
/// * `WKWebsiteDataStore` reports **per-origin, per-type** records. A page can
///   ask `navigator.storage.estimate()` for one blended number about itself; it
///   cannot enumerate other origins or say which type the bytes are in.
///
/// Everything here reads `tab.dataStore` rather than `tab.webView`'s
/// configuration. Both name the same store, but touching `webView` *builds*
/// one — so asking a sleeping tab what cookies it holds used to wake it and
/// spawn a web content process, which is exactly the trap `Tab` documents.
@MainActor
enum CookieStore {

    static func cookies(for tab: Tab) async -> [StorageCookie] {
        let store = tab.dataStore.httpCookieStore
        return await store.allCookies().map { cookie in
            StorageCookie(
                name: cookie.name,
                value: cookie.value,
                domain: cookie.domain,
                path: cookie.path,
                expiresAt: cookie.expiresDate,
                isSecure: cookie.isSecure,
                isHTTPOnly: cookie.isHTTPOnly,
                sameSite: sameSite(of: cookie)
            )
        }
    }

    /// Only the cookies that would actually travel with a request to this page,
    /// which is what someone asking "what cookies does this site have" means.
    static func cookies(for tab: Tab, matching urlString: String) async -> [StorageCookie] {
        let all = await cookies(for: tab)
        guard let host = URLComponents(string: urlString)?.host?.lowercased() else { return all }
        return all.filter { CookieMatching.domainMatches(host: host, cookieDomain: $0.domain) }
    }

    static func delete(_ cookie: StorageCookie, in tab: Tab) async {
        let store = tab.dataStore.httpCookieStore
        // Matched on the identifying triple, not the name: two cookies can
        // share a name and be different things, and deleting by name alone
        // would take the wrong one.
        for candidate in await store.allCookies()
        where candidate.name == cookie.name
            && candidate.domain == cookie.domain
            && candidate.path == cookie.path {
            await store.deleteCookie(candidate)
        }
    }

    static func deleteAll(_ cookies: [StorageCookie], in tab: Tab) async {
        for cookie in cookies { await delete(cookie, in: tab) }
    }

    /// Only what can actually be named.
    ///
    /// Foundation defines constants for Strict and Lax and nothing else, so a
    /// policy that is neither is a value we cannot identify. Labelling it
    /// "None" would assert that the cookie is sent on cross-site requests —
    /// a security property, and one the server never stated in the common case
    /// where it simply omitted the attribute. Better to show no badge than a
    /// confident wrong one.
    private static func sameSite(of cookie: HTTPCookie) -> String {
        switch cookie.sameSitePolicy {
        case .some(.sameSiteStrict): "Strict"
        case .some(.sameSiteLax): "Lax"
        default: ""
        }
    }

    // MARK: - Site data

    static func siteData(for tab: Tab) async -> [SiteDataRecord] {
        let store = tab.dataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)

        return records.map { record in
            SiteDataRecord(
                origin: record.displayName,
                types: record.dataTypes.map(readable).sorted(),
                // WebKit reports which types an origin holds but not how many
                // bytes. Inventing a number would be worse than admitting the
                // platform doesn't say.
                size: 0
            )
        }
    }

    static func clear(_ record: SiteDataRecord, in tab: Tab) async {
        let store = tab.dataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let all = await store.dataRecords(ofTypes: types)
        let matching = all.filter { $0.displayName == record.origin }
        guard !matching.isEmpty else { return }
        await store.removeData(ofTypes: types, for: matching)
    }

    private static func readable(_ type: String) -> String {
        switch type {
        case WKWebsiteDataTypeCookies: "Cookies"
        case WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache: "Cache"
        case WKWebsiteDataTypeLocalStorage: "Local storage"
        case WKWebsiteDataTypeSessionStorage: "Session storage"
        case WKWebsiteDataTypeIndexedDBDatabases: "IndexedDB"
        case WKWebsiteDataTypeServiceWorkerRegistrations: "Service workers"
        case WKWebsiteDataTypeOfflineWebApplicationCache: "App cache"
        case WKWebsiteDataTypeFetchCache: "Fetch cache"
        case WKWebsiteDataTypeWebSQLDatabases: "WebSQL"
        default: type
            .replacingOccurrences(of: "WKWebsiteDataType", with: "")
        }
    }
}
