import Foundation
import Testing
@testable import SurfCore

@Suite("Privacy policy")
struct PrivacyPolicyTests {

    // MARK: - The central guarantee

    @Test("Clearing traces never clears cookies")
    func tracesNeverTakeCookies() {
        // The whole proposition: forget where you went, stay signed in.
        let settings = PrivacySettings(keepSignedIn: true, clearTracesOnQuit: true)
        let categories = PrivacyPolicy.categoriesToClearOnQuit(settings)
        #expect(!categories.contains(.cookies))
        #expect(categories.contains(.diskCache))
        #expect(categories.contains(.localStorage))
    }

    @Test("Cookies are cleared when sign-in isn't wanted, even if traces are kept")
    func cookiesClearedIndependently() {
        let settings = PrivacySettings(keepSignedIn: false, clearTracesOnQuit: false)
        let categories = PrivacyPolicy.categoriesToClearOnQuit(settings)
        #expect(categories == [.cookies])
    }

    @Test("Both switches off clears nothing")
    func clearNothing() {
        let settings = PrivacySettings(keepSignedIn: true, clearTracesOnQuit: false)
        #expect(PrivacyPolicy.categoriesToClearOnQuit(settings).isEmpty)
    }

    @Test("Both switches on clears everything")
    func clearEverything() {
        let settings = PrivacySettings(keepSignedIn: false, clearTracesOnQuit: true)
        let categories = PrivacyPolicy.categoriesToClearOnQuit(settings)
        #expect(categories == Set(BrowsingDataCategory.allCases))
    }

    @Test("Service workers and IndexedDB count as traces — they're the sneaky ones")
    func sneakyTraces() {
        let categories = PrivacyPolicy.categoriesToClearOnQuit(PrivacySettings.default)
        #expect(categories.contains(.serviceWorkers))
        #expect(categories.contains(.indexedDB))
        #expect(categories.contains(.fetchCache))
    }

    // MARK: - Defaults

    @Test("Ships private by default, but signed in")
    func shippedDefaults() {
        let settings = PrivacySettings.default
        #expect(settings.rememberHistory == false)
        #expect(settings.keepSignedIn == true)
        #expect(settings.clearTracesOnQuit == true)
        #expect(settings.restoreTabs == true)
    }

    // MARK: - Session redaction

    @Test("History off strips the back/forward blob but keeps the tab")
    func redactsHistory() {
        let tab = PersistedTab(
            url: "https://example.com",
            title: "Example",
            interactionState: Data([1, 2, 3])
        )
        let redacted = PrivacyPolicy.redact(tab, for: PrivacySettings(rememberHistory: false))
        #expect(redacted.interactionState == nil)
        // Still restorable — that's the point of redacting rather than dropping.
        #expect(redacted.url == "https://example.com")
        #expect(redacted.title == "Example")
        #expect(redacted.isRestorable)
    }

    @Test("History on keeps the blob untouched")
    func keepsHistoryWhenEnabled() {
        let tab = PersistedTab(url: "https://a.com", title: "A", interactionState: Data([9]))
        let kept = PrivacyPolicy.redact(tab, for: PrivacySettings(rememberHistory: true))
        #expect(kept == tab)
    }

    @Test("Redaction applies across a whole session, preserving selection")
    func redactsWholeSession() {
        let session = PersistedSession(
            tabs: [
                PersistedTab(url: "https://a.com", title: "A", interactionState: Data([1])),
                PersistedTab(url: "https://b.com", title: "B", interactionState: Data([2])),
            ],
            selectedIndex: 1
        )
        let redacted = PrivacyPolicy.redact(session, for: PrivacySettings(rememberHistory: false))
        #expect(redacted.tabs.allSatisfy { $0.interactionState == nil })
        #expect(redacted.selectedIndex == 1)
        #expect(redacted.tabs.count == 2)
    }

    @Test("Session is only persisted when tab restore is wanted")
    func persistenceGate() {
        #expect(PrivacyPolicy.shouldPersistSession(PrivacySettings(restoreTabs: true)))
        #expect(!PrivacyPolicy.shouldPersistSession(PrivacySettings(restoreTabs: false)))
    }
}
