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
    static let hideAdContainers = "hideAdContainers"
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
            // On: an emptied ad container still occupies the page, and hiding
            // it is most of what makes a blocked page look unblocked.
            PreferenceKeys.hideAdContainers: true,
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

    /// Erases the given categories for every site.
    static func clear(_ categories: Set<BrowsingDataCategory>) async {
        guard !categories.isEmpty else { return }
        let types = Set(categories.map(\.webKitDataType))
        await WKWebsiteDataStore.default().removeData(
            ofTypes: types,
            modifiedSince: .distantPast
        )
    }

    /// How many sites currently have data stored. Used to show that the clear
    /// actually did something.
    static func storedSiteCount() async -> Int {
        let types = Set(BrowsingDataCategory.allCases.map(\.webKitDataType))
        return await WKWebsiteDataStore.default().dataRecords(ofTypes: types).count
    }
}
