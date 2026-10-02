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
/// Everything takes a `WKWebsiteDataStore`, and the `Tab` overloads are one
/// line each on top of it. It used to be the other way round, which could not
/// answer the question the island menu asks: an island owns a jar whether or
/// not it currently holds a single tab, and a background island is allowed to
/// be empty.
///
/// The guarantee that shape protected has moved up a level rather than away.
/// Nothing here can reach a web view at all now, where before the rule was
/// "read `tab.dataStore`, never `tab.webView`" — because `webView` *builds* one,
/// so asking a sleeping tab what cookies it holds used to wake it and spawn a
/// web content process. Both `Island.dataStore` and `Tab.dataStore` hand back
/// the memoised `IslandStores` instance, so every caller arrives with a store
/// that costs nothing to hold.
@MainActor
enum CookieStore {

    // MARK: - Reading

    static func cookies(in store: WKWebsiteDataStore) async -> [StorageCookie] {
        await store.httpCookieStore.allCookies().map { cookie in
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

    static func cookies(for tab: Tab) async -> [StorageCookie] {
        await cookies(in: tab.dataStore)
    }

    /// Only the cookies that would actually travel with a request to this page,
    /// which is what someone asking "what cookies does this site have" means.
    static func cookies(for tab: Tab, matching urlString: String) async -> [StorageCookie] {
        let all = await cookies(for: tab)
        guard let host = URLComponents(string: urlString)?.host?.lowercased() else { return all }
        return all.filter { CookieMatching.domainMatches(host: host, cookieDomain: $0.domain) }
    }

    // MARK: - Deleting

    /// Deletes a set of cookies with one pass over the jar.
    ///
    /// Matched on the identifying triple, not the name: two cookies can share a
    /// name and be entirely different things, and deleting by name alone would
    /// take the wrong one. `StorageCookie.identity` spells that key so both
    /// ends of the comparison use one copy of it.
    ///
    /// One `allCookies()` fetch for the whole set, which is the point. Deleting
    /// a site's worth of cookies one at a time meant one full fetch of the jar
    /// per cookie — thirty round trips to sign out of somewhere with thirty
    /// cookies, each one re-reading everything the previous had just read.
    static func delete(_ cookies: [StorageCookie], in store: WKWebsiteDataStore) async {
        guard !cookies.isEmpty else { return }
        let wanted = Set(cookies.map(\.id))
        let jar = store.httpCookieStore
        for candidate in await jar.allCookies()
        where wanted.contains(
            StorageCookie.identity(
                domain: candidate.domain, path: candidate.path, name: candidate.name
            )
        ) {
            await jar.deleteCookie(candidate)
        }
    }

    static func delete(_ cookie: StorageCookie, in tab: Tab) async {
        await delete([cookie], in: tab.dataStore)
    }

    static func deleteAll(_ cookies: [StorageCookie], in tab: Tab) async {
        await delete(cookies, in: tab.dataStore)
    }

    /// Signs this jar out of everywhere.
    ///
    /// Not an enumeration: one `removeData` call covering every origin at once,
    /// which also catches cookies no row could name.
    ///
    /// Cookies and nothing else, and that scope is the repo's own definition of
    /// signing out rather than a shortcut — `BrowsingDataCategory.browsingTraces`
    /// excludes cookies on the grounds that they are "the sign-in half", and
    /// the promise in Settings that clearing caches never signs you out is the
    /// same rule read from the other side. Widening this to local storage and
    /// IndexedDB would smuggle "and throw away this island's site settings"
    /// into a click that says it is about logins.
    static func deleteAllCookies(in store: WKWebsiteDataStore) async {
        await store.removeData(
            ofTypes: [BrowsingDataCategory.cookies.webKitDataType],
            modifiedSince: .distantPast
        )
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

    static func siteData(in store: WKWebsiteDataStore) async -> [SiteDataRecord] {
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

    static func siteData(for tab: Tab) async -> [SiteDataRecord] {
        await siteData(in: tab.dataStore)
    }

    static func clear(_ record: SiteDataRecord, in store: WKWebsiteDataStore) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let all = await store.dataRecords(ofTypes: types)
        let matching = all.filter { $0.displayName == record.origin }
        guard !matching.isEmpty else { return }
        await store.removeData(ofTypes: types, for: matching)
    }

    static func clear(_ record: SiteDataRecord, in tab: Tab) async {
        await clear(record, in: tab.dataStore)
    }

    private static func readable(_ type: String) -> String {
        switch type {
        case WKWebsiteDataTypeCookies: "Cookies"
        case WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache: "Cache"
        case WKWebsiteDataTypeLocalStorage: "Local storage"
        case WKWebsiteDataTypeSessionStorage: "Session storage"
        case WKWebsiteDataTypeIndexedDBDatabases: "IndexedDB"
        case WKWebsiteDataTypeServiceWorkerRegistrations: "Service workers"
        case WKWebsiteDataTypeFetchCache: "Fetch cache"
        case WKWebsiteDataTypeWebSQLDatabases: "WebSQL"
        default: type
            .replacingOccurrences(of: "WKWebsiteDataType", with: "")
        }
    }
}
