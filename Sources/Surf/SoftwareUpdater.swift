import Sparkle
import SwiftUI

/// Surf keeping itself current.
///
/// The one dependency in the project, and the reasoning is the same one that
/// keeps the extractor hand-rolled: write it yourself unless the thing being
/// written is genuinely hard. Swapping a running, signed application for a
/// newer one is genuinely hard — verify the download, stage it beside the
/// original, replace a bundle whose code is currently executing, relaunch,
/// and leave nothing broken if the power fails in the middle. Sparkle is the
/// implementation the rest of the Mac already trusts with that.
///
/// What it does *not* do here is talk about the user. System profiling is off
/// (`SUEnableSystemProfiling` in the bundle, and `sendsSystemProfile` below),
/// so a check is a plain GET for one XML file with no query string. That is
/// the whole of Surf's update conversation, and it keeps the promise the rest
/// of the app makes: nothing about you leaves the machine.
@MainActor
@Observable
final class SoftwareUpdater {
    static let shared = SoftwareUpdater()

    /// False while a check is already running, so the menu item can dim
    /// rather than start a second one.
    private(set) var canCheck = false

    /// Whether Surf looks for updates on its own. Read from and written
    /// straight through to Sparkle, which persists it — a mirrored
    /// `@AppStorage` would be a second source of truth that could disagree.
    var checksAutomatically: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    /// Nil in a bare `swift run`. Sparkle needs a real bundle to read its feed
    /// and its public key from, and to have something to replace at the end —
    /// starting it against a loose binary is an error with no useful outcome.
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private var updater: SPUUpdater? { controller?.updater }

    /// Whether updating is possible at all here, so the interface can explain
    /// itself instead of showing a button that cannot work.
    var isAvailable: Bool { controller != nil }

    private init() {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        // Belt and braces with the bundle key: this is the flag that would
        // attach a hardware and OS profile to the feed request as a query
        // string, and it is the one thing in this file worth being sure of.
        controller.updater.sendsSystemProfile = false
        observation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheck = updater.canCheckForUpdates
            }
        }
    }

    /// The menu item. Shows Sparkle's own progress and release notes.
    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// When Surf last looked, for Settings to show instead of a claim.
    var lastCheck: Date? { updater?.lastUpdateCheckDate }
}
