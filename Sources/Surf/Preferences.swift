import Foundation
import SurfCore
import WebKit

/// Defaults keys, named once. `@AppStorage` in views and plain `UserDefaults`
/// reads in the app delegate must agree, and string literals scattered across
/// both is how they stop agreeing.
enum PreferenceKeys {
    static let rememberHistory = "rememberHistory"
    static let keepSignedIn = "keepSignedIn"
    static let restoreTabs = "restoreTabs"
    static let clearTracesOnQuit = "clearTracesOnQuit"
    static let sidebarPinned = "sidebarPinned"
    static let autoPopOutVideo = "autoPopOutVideo"
    static let appearanceMode = "appearanceMode"
    static let synthesizeTheme = "synthesizeTheme"
    static let blockAds = "blockAds"
    /// When the filter list was last checked. Not a setting either, and here
    /// for the same reason as the one below it.
    static let lastFilterListCheck = "lastFilterListCheck"
    /// When the helper binaries were last checked for updates. Not a setting —
    /// there is no UI for it — but it lives here so the key isn't a literal
    /// buried in `UpdateManager`.
    static let lastComponentCheck = "lastComponentCheck"
}

extension PrivacySettings {

    /// Registers the shipped defaults. Must run before anything reads them, or
    /// unset keys read as `false` and quietly invert the intent — "keep me
    /// signed in" would default to off.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            PreferenceKeys.rememberHistory: PrivacySettings.default.rememberHistory,
            PreferenceKeys.keepSignedIn: PrivacySettings.default.keepSignedIn,
            PreferenceKeys.restoreTabs: PrivacySettings.default.restoreTabs,
            PreferenceKeys.clearTracesOnQuit: PrivacySettings.default.clearTracesOnQuit,
            PreferenceKeys.autoPopOutVideo: true,
            PreferenceKeys.appearanceMode: AppearanceMode.default.rawValue,
            // Off by default while it's new: restyling a site is a far bigger
            // intervention than telling it which scheme we want.
            PreferenceKeys.synthesizeTheme: false,
            // On, unlike the theme switch above it. Blocking removes requests
            // the user never asked to make; restyling redraws a page its
            // authors did draw. Only one of those needs asking first.
            PreferenceKeys.blockAds: true,
        ])
    }

    static var current: PrivacySettings {
        let defaults = UserDefaults.standard
        return PrivacySettings(
            rememberHistory: defaults.bool(forKey: PreferenceKeys.rememberHistory),
            keepSignedIn: defaults.bool(forKey: PreferenceKeys.keepSignedIn),
            restoreTabs: defaults.bool(forKey: PreferenceKeys.restoreTabs),
            clearTracesOnQuit: defaults.bool(forKey: PreferenceKeys.clearTracesOnQuit)
        )
    }
}

enum MediaPreferences {
    /// Whether leaving a tab that's playing video should pop it out.
    static var autoPopOut: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKeys.autoPopOutVideo)
    }
}

extension BrowsingDataCategory {
    /// Maps the abstract category onto WebKit's string constant.
    var webKitDataType: String {
        switch self {
        case .diskCache: WKWebsiteDataTypeDiskCache
        case .memoryCache: WKWebsiteDataTypeMemoryCache
        case .fetchCache: WKWebsiteDataTypeFetchCache
        case .localStorage: WKWebsiteDataTypeLocalStorage
        case .sessionStorage: WKWebsiteDataTypeSessionStorage
        case .indexedDB: WKWebsiteDataTypeIndexedDBDatabases
        case .serviceWorkers: WKWebsiteDataTypeServiceWorkerRegistrations
        case .cookies: WKWebsiteDataTypeCookies
        }
    }
}

@MainActor
enum BrowsingDataCleaner {

    /// Erases the given categories for every site, in every island.
    ///
    /// Every island, emphatically. Clearing only the default store would leave
    /// the promise in Settings true for the browsing you did in the island you
    /// happened to be in and false for all the rest — and the user would have
    /// no way to tell, because nothing in the UI distinguishes them.
    ///
    /// Concurrently, because this runs on the way out: `applicationShouldTerminate`
    /// is holding the app open waiting for it, and six islands cleared one
    /// after another is six round trips the user spends staring at a window
    /// that won't close.
    static func clear(_ categories: Set<BrowsingDataCategory>) async {
        guard !categories.isEmpty else { return }
        let types = Set(categories.map(\.webKitDataType))
        let stores = await IslandStores.shared.allStores()

        // Started together, awaited afterwards. A task group would be the
        // obvious spelling and doesn't compile here: the isolation checker
        // can't reason about handing a main-actor store into a group.
        let clears = stores.map { store in
            Task { @MainActor in
                await store.removeData(ofTypes: types, modifiedSince: .distantPast)
            }
        }
        for clear in clears { await clear.value }
    }

    /// How many sites currently have data stored, across every island. Used to
    /// show that the clear actually did something.
    ///
    /// A sum rather than a distinct count: an origin with data in two islands
    /// is two piles of data, and reporting it once would make clearing look
    /// like it had done less than it did.
    static func storedSiteCount() async -> Int {
        let types = Set(BrowsingDataCategory.allCases.map(\.webKitDataType))
        let stores = await IslandStores.shared.allStores()
        var total = 0
        for store in stores {
            total += await store.dataRecords(ofTypes: types).count
        }
        return total
    }
}
