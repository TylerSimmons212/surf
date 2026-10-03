import AppKit
import SurfCore
import SwiftUI

/// The download button, and the menu behind it.
///
/// A press opens a menu rather than downloading outright, because the engine's
/// pick and the right pick are not always the same thing: on YouTube that is the
/// difference between 712MB of 4K and 258MB of 1080p, and on a metered
/// connection or an older machine the bigger file is not obviously the better
/// answer.
///
/// It is a real `NSMenu`, and it was a SwiftUI popover first. Two things were
/// wrong with that. The sidebar closes when the pointer leaves it and a popover
/// lives in its own window, so reaching for a row read as leaving the sidebar:
/// it collapsed, took the anchor with it, and dismissed the menu before anything
/// could be clicked — which is the exact failure `SidebarHold` was written for,
/// and this was the one sidebar popover that never registered a hold. The second
/// is simpler: a short list of choices where you pick one is a menu, and macOS
/// has a control for that, with keyboard navigation, submenus and edge flipping
/// already in it.
///
/// Both are fixed here. The hold is taken for as long as the menu is tracking,
/// so the sidebar cannot collapse underneath it even though `NSMenu` would have
/// survived that on its own.
///
/// The anchor and that hold now live in `MenuSupport.swift`, because the island
/// menu wants the same three things and the hold has to be taken in exactly one
/// way. This is still the file that records why any of it exists.
struct DownloadMenuButton: View {
    let tab: Tab
    let hold: SidebarHold
    let systemName: String
    let help: String
    let isEnabled: Bool
    let bounces: Bool

    private static let holdReason = "download-menu"

    /// Somewhere for the menu to hang from, and a guard against a second press
    /// while the first is still finding out what is on offer.
    @State private var anchor = MenuAnchor()
    @State private var isAsking = false

    var body: some View {
        IconButton(
            systemName: systemName,
            size: 13, width: 26, height: 26, cornerRadius: 13,
            isEnabled: isEnabled,
            motion: bounces ? .bounce : .none,
            help: help
        ) {
            present()
        }
        .background(MenuAnchorView(anchor: anchor))
    }

    /// Finds out what is on offer, then shows the menu.
    ///
    /// In that order, and it costs a moment on a manifest because working out
    /// the renditions means fetching it. Deliberately not done when the card
    /// appears: that would fetch a manifest, with the tab's cookies, for every
    /// page with a video on it whether or not anyone ever means to save one.
    /// Paying for the menu when the menu is asked for is the right trade.
    private func present() {
        guard !isAsking else { return }
        isAsking = true
        Task { @MainActor in
            let found = await DownloadManager.shared.options(for: tab)
            isAsking = false
            show(found.options, duration: found.duration)
        }
    }

    private func show(_ options: [DownloadOption], duration: Double?) {
        let shown = menu(for: options, duration: duration)
            .popUp(below: anchor, holding: hold, reason: Self.holdReason)
        guard !shown else { return }
        // No menu to hang anywhere. Downloading is still the thing that was
        // asked for, so it happens rather than nothing happening.
        DownloadManager.shared.downloadMedia(from: tab)
    }

    // MARK: - Building it

    private func menu(for options: [DownloadOption], duration: Double?) -> NSMenu {
        let videos = DownloadOptions.video(from: options)
        let sound = DownloadOptions.audio(from: options)
        let menu = NSMenu()

        // Four words, and no account of what it is about to take.
        //
        // It read "Download Video — 2160p · AV1 · 712.4 MB" first, on the
        // reasoning that a button should say what it will do. The reasoning was
        // wrong about who is reading: picking the best available is the default
        // because it is the right answer, so stating the resolution, the codec
        // and the size is three facts offered to someone who has already
        // decided not to care. Anyone who does care is one row further down.
        menu.addAction("Download Video") {
            DownloadManager.shared.downloadMedia(from: tab)
        }

        // Only when there is something to choose between. One rendition and a
        // submenu offering to choose is a submenu that wastes a hover to tell
        // you there was never a decision.
        if videos.count > 1 {
            menu.addSubmenu("Choose Quality") { ladder in
                for option in videos {
                    // The height and the size, which are the two halves of the
                    // decision. Not the codec: it is the engine's problem, it
                    // has already guaranteed the result will play, and
                    // `avc1.64002a` was never a sentence anyone wanted to read.
                    ladder.addAction(option.rowTitle(duration: duration)) {
                        DownloadManager.shared.downloadMedia(from: tab, choosing: option)
                    }
                }
            }
        }

        if let sound {
            menu.addItem(.separator())
            // Bare, like the first row. There is only ever one soundtrack
            // offered — the best one, because sound is a fraction of a video's
            // size and there is nothing to save by taking less — so its size is
            // not a number anybody is comparing against anything.
            menu.addAction("Audio Only") {
                DownloadManager.shared.downloadMedia(from: tab, choosing: sound)
            }
        }
        return menu
    }
}
