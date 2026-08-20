import Foundation

/// The kinds of data WebKit persists on a user's behalf.
///
/// Modelled here rather than using WebKit's string constants directly so the
/// policy below can be reasoned about and tested without importing WebKit.
public enum BrowsingDataCategory: String, CaseIterable, Sendable, Comparable {
    case diskCache
    case memoryCache
    case fetchCache
    case localStorage
    case sessionStorage
    case indexedDB
    case serviceWorkers
    case cookies

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Everything that records *where you went* without keeping you signed in.
    /// Cookies are deliberately excluded — they're the sign-in half.
    public static var browsingTraces: Set<BrowsingDataCategory> {
        [.diskCache, .memoryCache, .fetchCache, .localStorage, .sessionStorage,
         .indexedDB, .serviceWorkers]
    }
}

public struct PrivacySettings: Equatable, Sendable {
    public var rememberHistory: Bool
    public var keepSignedIn: Bool
    public var restoreTabs: Bool
    public var clearTracesOnQuit: Bool

    public init(
        rememberHistory: Bool = false,
        keepSignedIn: Bool = true,
        restoreTabs: Bool = true,
        clearTracesOnQuit: Bool = true
    ) {
        self.rememberHistory = rememberHistory
        self.keepSignedIn = keepSignedIn
        self.restoreTabs = restoreTabs
        self.clearTracesOnQuit = clearTracesOnQuit
    }

    /// The shipped defaults: private by default, but still signed in.
    public static let `default` = PrivacySettings()
}

/// Turns settings into concrete decisions. Each rule is one function so the
/// behaviour is stated once and tested directly, rather than being scattered
/// across `if` statements at the call sites.
public enum PrivacyPolicy {

    /// What to erase at quit.
    ///
    /// The two switches are independent on purpose: caches are about *where you
    /// went*, cookies are about *who you are*. Clearing traces must never take
    /// logins with it, or the whole proposition collapses.
    public static func categoriesToClearOnQuit(
        _ settings: PrivacySettings
    ) -> Set<BrowsingDataCategory> {
        var categories: Set<BrowsingDataCategory> = []
        if settings.clearTracesOnQuit {
            categories.formUnion(BrowsingDataCategory.browsingTraces)
        }
        if !settings.keepSignedIn {
            categories.insert(.cookies)
        }
        return categories
    }

    /// Whether the session file should be written at all.
    public static func shouldPersistSession(_ settings: PrivacySettings) -> Bool {
        settings.restoreTabs
    }

    /// Strips what a tab shouldn't be storing.
    ///
    /// `interactionState` holds the tab's full back/forward list — that *is*
    /// history on disk. With history off we keep only the current URL and
    /// title, which is the minimum that still restores a tab.
    public static func redact(_ tab: PersistedTab, for settings: PrivacySettings) -> PersistedTab {
        guard !settings.rememberHistory else { return tab }
        var redacted = tab
        redacted.interactionState = nil
        return redacted
    }

    public static func redact(
        _ session: PersistedSession,
        for settings: PrivacySettings
    ) -> PersistedSession {
        // Every island, not just the legacy mirror. A back/forward blob that
        // survives in an island the redaction didn't walk is the whole trail
        // the user asked not to keep, filed one level deeper.
        PersistedSession(
            tabs: session.tabs.map { redact($0, for: settings) },
            selectedIndex: session.selectedIndex,
            islands: session.islands.map { islands in
                islands.map { island in
                    var island = island
                    island.tabs = island.tabs.map { redact($0, for: settings) }
                    return island
                }
            },
            selectedIslandIndex: session.selectedIslandIndex,
            schemaVersion: session.schemaVersion
        )
    }
}
