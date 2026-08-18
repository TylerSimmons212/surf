import Foundation

/// Byte counts, formatted once so every pane says it the same way.
public enum ByteSize {
    public static func format(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kilobytes = Double(bytes) / 1024
        if kilobytes < 1024 { return String(format: "%.1f kB", kilobytes) }
        let megabytes = kilobytes / 1024
        if megabytes < 1024 { return String(format: "%.2f MB", megabytes) }
        return String(format: "%.2f GB", megabytes / 1024)
    }
}

public enum StorageArea: String, Sendable, CaseIterable, Identifiable {
    case cookies
    case local
    case session
    case caches
    case databases
    case siteData

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cookies: "Cookies"
        case .local: "Local"
        case .session: "Session"
        case .caches: "Caches"
        case .databases: "IndexedDB"
        case .siteData: "Site data"
        }
    }

    public var symbol: String {
        switch self {
        case .cookies: "birthday.cake"
        case .local: "internaldrive"
        case .session: "clock.arrow.circlepath"
        case .caches: "shippingbox"
        case .databases: "cylinder.split.1x2"
        case .siteData: "externaldrive"
        }
    }

    /// Whether values in this area can be edited in place.
    public var isEditable: Bool { self == .local || self == .session }
}

/// One cookie, as the native store describes it.
///
/// Read through `WKHTTPCookieStore`, which is why this can exist at all: it
/// hands over `HttpOnly` cookies, and `HttpOnly` means precisely that page
/// script may not see them. Chrome's and Safari's own panels manage it through
/// privileged internals; anything built on page script simply cannot.
public struct StorageCookie: Sendable, Equatable, Identifiable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expiresAt: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public var sameSite: String

    /// Domain, path and name together — the triple that actually identifies a
    /// cookie. Two cookies can share a name and be entirely different things.
    public var id: String { "\(domain)\(path)|\(name)" }

    public init(
        name: String, value: String, domain: String, path: String = "/",
        expiresAt: Date? = nil, isSecure: Bool = false, isHTTPOnly: Bool = false,
        sameSite: String = ""
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
    }

    public var size: Int { name.utf8.count + value.utf8.count }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// What the expiry column says.
    ///
    /// A session cookie has no date at all, which is a different thing from one
    /// expiring soon — and rendering both as a blank cell loses the distinction
    /// that decides whether closing the browser logs you out.
    public func expiryLabel(now: Date = Date()) -> String {
        guard let expiresAt else { return "Session" }
        let seconds = expiresAt.timeIntervalSince(now)
        if seconds <= 0 { return "Expired" }
        if seconds < 3600 { return "in \(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "in \(Int(seconds / 3600)) h" }
        let days = Int(seconds / 86_400)
        if days < 365 { return "in \(days) d" }
        return "in \(days / 365) y"
    }
}

/// A key/value pair from `localStorage`, `sessionStorage`, or a listing of
/// caches and databases where only the name is meaningful.
public struct StorageItem: Sendable, Equatable, Identifiable {
    public var key: String
    public var value: String
    /// Set for listings where the value column is a count rather than content.
    public var detail: String

    public var id: String { key }

    public init(key: String, value: String = "", detail: String = "") {
        self.key = key
        self.value = value
        self.detail = detail
    }

    public var size: Int { key.utf8.count + value.utf8.count }

    /// Values are frequently a whole serialised object; the table shows a line.
    public var preview: String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return flattened.count > 200 ? String(flattened.prefix(200)) + "…" : flattened
    }

    public var looksLikeJSON: Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return false }
        return trimmed.count > 1
    }
}

/// What one origin is actually holding on disk.
///
/// From `WKWebsiteDataStore`, which reports per-origin, per-type records. A
/// page can ask `navigator.storage.estimate()` for one blended number about
/// itself; it cannot enumerate other origins or break the total down by type.
public struct SiteDataRecord: Sendable, Equatable, Identifiable {
    public var origin: String
    public var types: [String]
    public var size: Int

    public var id: String { origin }

    public init(origin: String, types: [String], size: Int = 0) {
        self.origin = origin
        self.types = types
        self.size = size
    }
}

public enum StorageFilter {

    public static func cookies(
        _ cookies: [StorageCookie], query: String
    ) -> [StorageCookie] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty
            ? cookies
            : cookies.filter {
                $0.name.lowercased().contains(needle)
                    || $0.value.lowercased().contains(needle)
                    || $0.domain.lowercased().contains(needle)
            }
        return matching.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func items(_ items: [StorageItem], query: String) -> [StorageItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty
            ? items
            : items.filter {
                $0.key.lowercased().contains(needle) || $0.value.lowercased().contains(needle)
            }
        return matching.sorted {
            $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
        }
    }

    public static func siteData(
        _ records: [SiteDataRecord], query: String
    ) -> [SiteDataRecord] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty
            ? records
            : records.filter { $0.origin.lowercased().contains(needle) }
        // Biggest first: the reason to open this list is to find what's large.
        return matching.sorted {
            $0.size == $1.size
                ? $0.origin.localizedCaseInsensitiveCompare($1.origin) == .orderedAscending
                : $0.size > $1.size
        }
    }
}
