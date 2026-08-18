import Testing

@testable import GlassCore

@Suite("Appearance mode")
struct AppearanceModeTests {

    @Test("An unset preference follows the system rather than forcing a scheme")
    func unsetDefaultsToSystem() {
        // The failure this guards is silent: a key that has never been written
        // reads back nil, and anything that treats nil as `.light` ships a
        // browser that ignores the Mac's own dark mode until Settings is opened.
        #expect(AppearanceMode(stored: nil) == .system)
        #expect(AppearanceMode.default == .system)
    }

    @Test("A preference file edited by hand can't force an unknown scheme")
    func garbageDefaultsToSystem() {
        #expect(AppearanceMode(stored: "") == .system)
        #expect(AppearanceMode(stored: "Dark") == .system)  // case matters
        #expect(AppearanceMode(stored: "sepia") == .system)
    }

    @Test("Stored values round-trip", arguments: AppearanceMode.allCases)
    func roundTrip(mode: AppearanceMode) {
        #expect(AppearanceMode(stored: mode.rawValue) == mode)
    }

    @Test("Only an explicit choice overrides the system")
    func overrides() {
        #expect(!AppearanceMode.system.overridesSystem)
        #expect(AppearanceMode.light.overridesSystem)
        #expect(AppearanceMode.dark.overridesSystem)
    }

    @Test("System mode tracks the OS in both directions")
    func systemTracks() {
        #expect(AppearanceMode.system.resolved(systemIsDark: true) == .dark)
        #expect(AppearanceMode.system.resolved(systemIsDark: false) == .light)
    }

    @Test("An explicit choice ignores the OS")
    func explicitIgnoresSystem() {
        // The whole point of the override: sunset must not move a pinned window.
        for systemIsDark in [true, false] {
            #expect(AppearanceMode.light.resolved(systemIsDark: systemIsDark) == .light)
            #expect(AppearanceMode.dark.resolved(systemIsDark: systemIsDark) == .dark)
        }
    }

    @Test("Every mode resolves to something concrete", arguments: AppearanceMode.allCases)
    func alwaysResolves(mode: AppearanceMode) {
        // There is no third rendered state, so resolution is total by
        // construction — this pins that as the tree grows.
        let resolved = mode.resolved(systemIsDark: true)
        #expect(ColorSchemeTarget.allCases.contains(resolved))
    }

    @Test("Targets are opposites of each other")
    func opposites() {
        #expect(ColorSchemeTarget.dark.opposite == .light)
        #expect(ColorSchemeTarget.light.opposite == .dark)
        // Phase 2 leans on this being an involution when it runs the transform
        // in either direction.
        for target in ColorSchemeTarget.allCases {
            #expect(target.opposite.opposite == target)
        }
    }
}
