import AppKit
import SurfCore

/// Remembers how big the main window was, and how big it should be the very
/// first time.
///
/// AppKit will do all of this for you — `setFrameAutosaveName` saves a frame on
/// every move and puts it back next launch — and Surf asked it to, for months,
/// with no effect. A `WindowGroup`'s window already belongs to SwiftUI, which
/// assigns an autosave name of its own a turn of the runloop after the hosting
/// view attaches, restores its own saved frame, and overwrites whatever anyone
/// else had set. The name it picks is built from the type of the scene's
/// content, so it reads in full as
/// `SwiftUI.WindowGroup<SwiftUI.ModifiedContent<Surf.ContentView, …>>-1-AppWindow-1`.
/// Add a modifier at the root of `ContentView` and that spelling changes, the
/// old key is orphaned, and the window forgets its size — silently, and with
/// nothing in the diff to suggest it.
///
/// So the frame is Surf's to keep. Three consequences worth stating:
///
/// - The key is stable and short, and survives refactoring the view tree.
/// - It is stored in `SurfDefaults.store`, which means a `SURF_STATE_DIR` run
///   no longer writes a window frame into your real preferences. AppKit's
///   autosave always writes to the standard domain, so this was the last piece
///   of the isolation that could not be closed without taking the job over.
/// - A window that has never been opened gets `WindowPlacement.opening`, which
///   is what makes Surf start at the size of the display instead of at a fixed
///   rectangle in the corner.
@MainActor
final class MainWindowFrame {
    static let shared = MainWindowFrame()

    private weak var window: NSWindow?
    private var observers: [any NSObjectProtocol] = []
    /// Shut between entering full screen and coming back out of it.
    private var isEnteringFullScreen = false

    private init() {}

    /// Takes over a window's frame. Idempotent for a window already held, so
    /// it is safe to call from a view that AppKit re-attaches.
    func adopt(_ window: NSWindow) {
        guard self.window !== window else { return }
        stopWatching()
        self.window = window

        // Now, so the window is never drawn at a size nobody asked for...
        place(window)

        // ...and again once SwiftUI has had its turn, because the assignment
        // described above lands between these two lines and undoes the first
        // one. This second placement is the one that sticks.
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            window.setFrameAutosaveName("")
            self.place(window)
            self.watch(window)

            // Clearing the name stops AppKit saving, but not SwiftUI, which
            // holds its own copy and writes the key about a tenth of a second
            // later regardless. So the sweep waits for that write rather than
            // racing it. Measured, not guessed: with the sweep run inline the
            // key is gone and then back within 100ms.
            try? await Task.sleep(for: .milliseconds(750))
            Self.sweepOrphanedFrames()
        }
    }

    /// Deletes the frame keys SwiftUI writes for the window.
    ///
    /// It writes one per launch, to the standard domain, which `SurfDefaults`
    /// has no way to redirect — so without this a `SURF_STATE_DIR` run leaves
    /// a mark in your real preferences, which is exactly the guarantee the
    /// scratch suite exists to make good on. Nothing reads these keys any
    /// more, so taking them back out costs nothing.
    ///
    /// The sweep is by prefix rather than by the one name just cleared,
    /// because the spelling changes with the scene's type and every previous
    /// spelling is still sitting there from whichever build wrote it. Surf has
    /// exactly one `WindowGroup`, and its frame is now this class's business,
    /// so every key of this shape is dead.
    private static func sweepOrphanedFrames() {
        let standard = UserDefaults.standard
        for key in standard.dictionaryRepresentation().keys
        where key.hasPrefix("NSWindow Frame SwiftUI.WindowGroup<") {
            standard.removeObject(forKey: key)
        }
    }

    // MARK: - Placing

    private func place(_ window: NSWindow) {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let fallback = NSScreen.main?.visibleFrame ?? screens.first else { return }

        let frame: CGRect
        if let saved = savedFrame() {
            // Back onto the display it was left on, when that display is still
            // attached. `NSScreen.main` is where the menu bar is, which is
            // rarely where the window was.
            let visible = WindowPlacement
                .indexOfScreen(holding: saved, among: screens)
                .map { screens[$0] } ?? fallback
            frame = WindowPlacement.restoring(saved, onVisible: visible)
        } else {
            frame = WindowPlacement.opening(onVisible: fallback)
        }

        debugLog("window: \(savedFrame() == nil ? "opening at" : "restoring to") \(frame)")
        guard frame != window.frame else { return }
        window.setFrame(frame, display: false)
    }

    // MARK: - Remembering

    private func savedFrame() -> CGRect? {
        guard let text = SurfDefaults.store.string(forKey: PreferenceKeys.mainWindowFrame)
        else { return nil }
        let rect = NSRectFromString(text)
        // `NSRectFromString` answers `.zero` for anything it cannot read, so a
        // corrupted value and an absent one are the same thing: open fresh.
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    private func save() {
        guard !isEnteringFullScreen, let window,
              !window.styleMask.contains(.fullScreen),
              !window.isMiniaturized
        else { return }
        SurfDefaults.store.set(
            NSStringFromRect(window.frame), forKey: PreferenceKeys.mainWindowFrame
        )
    }

    private func watch(_ window: NSWindow) {
        // Both, and not just the end of a live resize: a window can change
        // shape without a drag. Zooming it with the green button, or resizing
        // it from a script, produces no `didEndLiveResize` at all — and a
        // resize anchored at the top-left corner moves the origin too, so
        // neither notification implies the other. This does mean a write per
        // frame of a drag, which is affordable because a defaults write is a
        // dictionary set; the sweep below is not, and stays out of the path.
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.save() }
                }
            )
        }

        // Closing is the last chance to record the frame, and the last chance
        // to take SwiftUI's key back out. The sweep is here and not in `save`
        // because `save` runs on every frame of a resize drag, and reading the
        // whole defaults dictionary sixty times a second to delete a key that
        // is written once a launch is not a trade worth making.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.save()
                    Self.sweepOrphanedFrames()
                }
            }
        )

        // Full screen is a mode, not a size, and reopening a window filling the
        // display in the ordinary way is not what leaving it in full screen
        // asked for. The style mask says so once the transition finishes — but
        // the transition itself resizes the window to the whole display first,
        // and those notifications would overwrite the frame worth keeping
        // before the mask flips. So the door is shut on the way in.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isEnteringFullScreen = true }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isEnteringFullScreen = false }
            }
        )
    }

    private func stopWatching() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
