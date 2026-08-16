import Foundation
import GlassCore
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
