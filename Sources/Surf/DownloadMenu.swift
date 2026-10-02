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
        guard let view = anchor.view, view.window != nil else {
            // No menu to hang anywhere. Downloading is still the thing that was
            // asked for, so it happens rather than nothing happening.
            DownloadManager.shared.downloadMedia(from: tab)
            return
        }

        // Held across the whole of tracking. `popUp` runs its own event loop and
        // does not return until the menu closes, which is what makes the pair of
        // calls around it correct rather than hopeful — there is no window in
        // which the menu is up and the hold is not.
        hold.set(Self.holdReason, true)
        defer { hold.set(Self.holdReason, false) }

        menu(for: options, duration: duration).popUp(
            positioning: nil,
            // The view is unflipped, so zero is its bottom edge. A few points
            // below that leaves the gap a menu normally has from its button.
            at: NSPoint(x: 0, y: -5),
            in: view
        )
    }

    // MARK: - Building it

    private func menu(for options: [DownloadOption], duration: Double?) -> NSMenu {
        let videos = DownloadOptions.video(from: options)
        let sound = DownloadOptions.audio(from: options)
        let menu = NSMenu()

        // What a plain press used to do, named so it says what it will take
        // rather than leaving someone to find out from the finished file.
        let top = videos.first
        add(
            top.map { "Download Video — \($0.title) · \($0.detail(duration: duration))" }
                ?? "Download Video",
            to: menu
        ) { DownloadManager.shared.downloadMedia(from: tab) }

        // Only when there is something to choose between. One rendition and a
        // submenu offering to choose is a submenu that wastes a hover to tell
        // you there was never a decision.
        if videos.count > 1 {
            let choose = NSMenuItem(title: "Choose Quality", action: nil, keyEquivalent: "")
            let ladder = NSMenu()
            for option in videos {
                add("\(option.title) — \(option.detail(duration: duration))", to: ladder) {
                    DownloadManager.shared.downloadMedia(from: tab, choosing: option)
                }
            }
            choose.submenu = ladder
            menu.addItem(choose)
        }

        if let sound {
            menu.addItem(.separator())
            add("Audio Only — \(sound.detail(duration: duration))", to: menu) {
                DownloadManager.shared.downloadMedia(from: tab, choosing: sound)
            }
        }
        return menu
    }

    private func add(_ title: String, to menu: NSMenu, _ run: @escaping () -> Void) {
        let item = NSMenuItem(
            title: title, action: #selector(MenuAction.fire), keyEquivalent: ""
        )
        let action = MenuAction(run)
        item.target = action
        // `target` is weak, so the only thing keeping the closure alive is this.
        // Without it every item in the menu does nothing, which is a quiet
        // failure rather than a crash.
        item.representedObject = action
        menu.addItem(item)
    }
}

/// Carries a closure into `NSMenuItem`, which wants a target and a selector.
private final class MenuAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
        super.init()
    }

    @objc func fire() { run() }
}

/// A reference to the `NSView` a menu is positioned in.
@MainActor
private final class MenuAnchor {
    weak var view: NSView?
}

/// Puts a real view behind a SwiftUI button, because `NSMenu` is positioned in
/// one and SwiftUI does not hand its own out.
private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    /// Never takes a click. It sits over the same rectangle as the button, and
    /// an ordinary `NSView` hit-tests to itself, which would swallow every press
    /// the button exists for.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
