import CoreGraphics

/// Where the main window goes, and how big it is.
///
/// Two jobs: sizing a window that has never been opened before, and putting a
/// remembered one back somewhere it can actually be reached. Both are pure
/// arithmetic on the screen's usable rectangle, so the cases that are painful
/// to reproduce by hand — a frame saved on a monitor that has since been
/// unplugged, a window taller than the display it lands on — are settled in
/// tests rather than by plugging and unplugging monitors.
///
/// Every rectangle here is in AppKit's coordinates: origin bottom-left, and
/// `visible` is a screen's `visibleFrame`, which already excludes the menu bar
/// and the Dock.
public enum WindowPlacement {

    /// Below this the sidebar and the page are fighting over the same points.
    public static let minimumSize = CGSize(width: 720, height: 480)

    /// The widest a window opens by itself.
    ///
    /// A fresh window takes the full height of the display, because vertical
    /// space is what reading a page wants. Width is capped: a browser stretched
    /// across a 6K display puts the sidebar and the far edge of the page a head
    /// -turn apart, and line lengths go with it. Past this point the extra
    /// width is given back to the desktop rather than to the page.
    ///
    /// It only bites on large displays. A laptop or a 1440p monitor is narrower
    /// than this, so a fresh window there fills the screen edge to edge.
    public static let maximumWidth: CGFloat = 1800

    /// The frame for a window Surf has never opened before.
    ///
    /// Full height, capped width, centred horizontally.
    public static func opening(onVisible visible: CGRect) -> CGRect {
        let size = CGSize(
            width: min(visible.width, maximumWidth),
            height: visible.height
        )
        return centeredHorizontally(size, in: visible)
    }

    /// A remembered frame, made safe for the screen it is being restored onto.
    ///
    /// The size is clamped to what the display can hold, then the origin is
    /// slid until the whole window is on screen. Nothing here re-centres a
    /// window that already fits: a frame the user positioned is theirs, and
    /// tidying it up on every launch would be its own kind of wrong.
    public static func restoring(_ saved: CGRect, onVisible visible: CGRect) -> CGRect {
        guard saved.width > 0, saved.height > 0 else { return opening(onVisible: visible) }

        // The floor and the ceiling can contradict each other on a very small
        // display. The ceiling wins, because a window larger than the screen
        // has its title bar and its close button somewhere unreachable.
        let size = CGSize(
            width: min(max(saved.width, minimumSize.width), visible.width),
            height: min(max(saved.height, minimumSize.height), visible.height)
        )

        let x = min(max(saved.minX, visible.minX), visible.maxX - size.width)
        let y = min(max(saved.minY, visible.minY), visible.maxY - size.height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Which of these screens a remembered frame belongs to.
    ///
    /// The one it overlaps most, so a window straddling two displays goes back
    /// to the one it was mostly on. `nil` when it overlaps none of them, which
    /// is what unplugging the monitor it was left on looks like — the caller
    /// falls back to the main screen, and `restoring` drags it into view.
    public static func indexOfScreen(
        holding saved: CGRect, among visibleFrames: [CGRect]
    ) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, frame) in visibleFrames.enumerated() {
            let overlap = frame.intersection(saved)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            guard area > 0 else { continue }
            if best == nil || area > best!.area { best = (index, area) }
        }
        return best?.index
    }

    private static func centeredHorizontally(_ size: CGSize, in visible: CGRect) -> CGRect {
        CGRect(
            x: (visible.minX + (visible.width - size.width) / 2).rounded(),
            y: visible.minY.rounded(),
            width: size.width,
            height: size.height
        )
    }
}
