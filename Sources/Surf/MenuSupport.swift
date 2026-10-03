import AppKit
import SwiftUI

/// The AppKit menu plumbing SwiftUI does not hand out.
///
/// A short list of choices where you pick one is a menu, and macOS has a control
/// for that with keyboard navigation, submenus and edge flipping already in it.
/// Reaching for it from SwiftUI costs three small things every time: a real
/// `NSView` to position against, a closure where AppKit wants a target and a
/// selector, and — for anything the sidebar spawns — a hold so the panel cannot
/// collapse out from under the menu while it tracks.
///
/// All three lived inside `DownloadMenu.swift` while it was the only such menu.
/// They are here now because the island menu needs them too, and because the
/// hold has to be taken and released in exactly one way. Two hand-written copies
/// of that pair of calls is one copy too many of something that fails silently.

// MARK: - Items

/// An `NSMenuItem` that runs a closure.
///
/// AppKit wants a target and a selector; every call site wants a closure. The
/// item is its own target, which keeps the two ends of each menu entry on one
/// line instead of scattered across a switch on `sender.tag`.
///
/// Being its own target is also the only arrangement that cannot quietly break.
/// `NSMenuItem.target` is weak, so a separate target object has to be kept alive
/// by hanging it off `representedObject` — and forgetting that gives a menu
/// whose every row does nothing, with no crash and no warning to say why.
final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not from a nib") }

    @objc private func fire() { run() }
}

// MARK: - Building

extension NSMenu {

    /// A row that runs a closure.
    @discardableResult
    func addAction(_ title: String, _ run: @escaping () -> Void) -> ActionMenuItem {
        let item = ActionMenuItem(title, run)
        addItem(item)
        return item
    }

    /// A row that opens another menu on hover.
    ///
    /// The child is built by the closure rather than returned to the caller, so
    /// a submenu cannot be left unattached — which draws as a row that looks
    /// like it should expand and doesn't.
    @discardableResult
    func addSubmenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        build(submenu)
        item.submenu = submenu
        addItem(item)
        return item
    }

    /// A row that is only a view: a header, or anything else the menu shows
    /// rather than offers.
    ///
    /// Worth keeping rare. A view item draws its own everything, so it has no
    /// highlight, no keyboard focus and no accessibility unless it is given
    /// some — which is why nothing *actionable* in this app uses one. A header
    /// is never clicked, so none of that is a cost there.
    func addView(_ view: NSView) {
        let item = NSMenuItem()
        item.view = view
        addItem(item)
    }

    /// A line the menu states rather than offers.
    ///
    /// No action, which does two jobs at once: `autoenablesItems` dims anything
    /// it cannot find a target for, and keyboard navigation skips it. So a note
    /// needs no `isEnabled = false` and cannot be arrowed onto and pressed.
    ///
    /// Worth having because some of what a menu knows is an answer rather than a
    /// command. "No cookies in this island" is the whole reason somebody opened
    /// it, and a menu that can only offer actions has to either leave that
    /// unsaid or disable the row that would have said it.
    func addNote(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        addItem(item)
    }
}

extension NSMenuItem {

    /// The row's icon, in the column AppKit reserves for one.
    ///
    /// Returned rather than set in place so a row reads as one statement:
    /// `menu.addAction("Rename…") { … }.symbol("pencil")`. Icons are not
    /// decoration here — the popover these menus replaced had them, and a
    /// column of bare text is slower to scan than a column of shapes.
    @discardableResult
    func symbol(_ name: String) -> NSMenuItem {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            // A symbol name that does not resolve is a row that silently loses
            // its icon, which is exactly the kind of thing nobody notices until
            // the column looks wrong.
            debugLog("menu: no symbol named '\(name)'")
            return self
        }
        // Configured rather than resized. Assigning `size` to a symbol image
        // scales the box without telling the symbol what weight or point size
        // to render at, which is not the same thing as asking it to draw
        // smaller.
        self.image = image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        ) ?? image

        // Without this the image is set, correctly sized, and never drawn.
        //
        // macOS 26 put an icon on every menu item and was widely disliked for
        // it, so macOS 27 reversed it by hiding menu item *symbol* images by
        // default — ordinary images still show — and gave apps this property to
        // opt back in. `NSMenuItem.h`: "in macOS 27 and later, AppKit
        // determines the visibility of menu item images, and will typically
        // hide images."
        //
        // It binds on the SDK, not the running system, so building against 27
        // is what turns it on. Worth knowing before debugging this from the
        // image end, which is where every visible symptom points: the item
        // holds a perfectly good symbol and the row renders without it.
        preferredImageVisibility = .visible
        return self
    }

    /// A site's own icon at menu size, or nil when none is cached.
    ///
    /// Cache-only, which is what makes it safe to call while a menu is being
    /// built: `cachedIcon` never reaches the network, so a submenu of forty
    /// rows costs forty dictionary lookups rather than forty requests. The
    /// price is that a site nobody has visited this run has no icon, which is
    /// why every caller passes a fallback symbol.
    ///
    /// A favicon is cached under the host that served it, and the rest of the
    /// app asks with that host in hand. A cookie only names a registrable
    /// domain, so `github.com` has to find the icon fetched from
    /// `www.github.com` as well, or the one site anybody recognises is the one
    /// without a picture.
    @MainActor
    static func menuFavicon(host: String?) -> NSImage? {
        guard let host else { return nil }
        let store = FaviconStore.shared
        guard let cached = store.cachedIcon(forHost: host)
            ?? store.cachedIcon(forHost: "www.\(host)")
        else { return nil }
        // Copied before it is resized. The store hands back the instance it
        // keeps, so scaling that one would shrink the same icon everywhere
        // else it is drawn — the sidebar's rows included.
        let sized = (cached.copy() as? NSImage) ?? cached
        sized.size = NSSize(width: 15, height: 15)
        return sized
    }
}

// MARK: - Showing

extension NSMenu {

    /// Tracks under `anchor`, with the sidebar held open for the whole of it.
    ///
    /// `popUp` runs its own event loop and does not return until the menu
    /// closes, which is what makes the pair of calls around it correct rather
    /// than hopeful: there is no instant in which the menu is up and the hold is
    /// not, and no dismissal path that can skip the release the way a popover's
    /// can.
    ///
    /// The hold is needed even though an `NSMenu` lives in its own window and
    /// would survive the sidebar collapsing. The anchor is *in* the sidebar, so a
    /// panel that slides away underneath a tracking menu takes with it the thing
    /// the menu is positioned against.
    ///
    /// False when there is nowhere to hang the menu, so a caller with a
    /// reasonable fallback can take it instead of showing nothing.
    ///
    /// `@MainActor` throughout because `NSMenu` itself is not: AppKit's own
    /// annotations leave this extension nonisolated, and both the anchor and
    /// the hold are main-actor state.
    @discardableResult
    @MainActor
    func popUp(below anchor: MenuAnchor, holding hold: SidebarHold, reason: String) -> Bool {
        // The view is unflipped, so zero is its bottom edge. A few points below
        // that leaves the gap a menu normally has from its button.
        track(at: { _ in NSPoint(x: 0, y: -5) }, anchor, hold, reason)
    }

    /// Opens upward, clear of the button, rather than dropping from it.
    ///
    /// For a control at the foot of a window, where dropping down means
    /// spilling off the bottom — at which point AppKit rescues the menu by
    /// throwing it out to one side, and a menu that belongs to the button it
    /// came from ends up floating beside it instead.
    ///
    /// `popUp` always puts the menu's top-left corner at the point it is given
    /// and grows downward from there, so rising above the button means starting
    /// a whole menu-height higher. Reading `size` is what forces the layout
    /// that makes that height real.
    @discardableResult
    @MainActor
    func popUp(above anchor: MenuAnchor, holding hold: SidebarHold, reason: String) -> Bool {
        track(
            at: { [unowned self] view in
                NSPoint(x: 0, y: view.bounds.height + self.size.height + 5)
            },
            anchor, hold, reason
        )
    }

    /// Held across the whole of tracking.
    ///
    /// `popUp` runs its own event loop and does not return until the menu
    /// closes, which is what makes the pair of calls around it correct rather
    /// than hopeful: there is no instant in which the menu is up and the hold
    /// is not, and no dismissal path that can skip the release the way a
    /// popover's can.
    @MainActor
    private func track(
        at point: (NSView) -> NSPoint,
        _ anchor: MenuAnchor,
        _ hold: SidebarHold,
        _ reason: String
    ) -> Bool {
        guard let view = anchor.view, view.window != nil else { return false }

        hold.set(reason, true)
        defer { hold.set(reason, false) }

        popUp(positioning: nil, at: point(view), in: view)
        return true
    }
}

// MARK: - Anchoring

/// A reference to the `NSView` a menu is positioned in.
@MainActor
final class MenuAnchor {
    weak var view: NSView?
}

/// Puts a real view behind a SwiftUI button, because `NSMenu` is positioned in
/// one and SwiftUI does not hand its own out.
struct MenuAnchorView: NSViewRepresentable {
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

// MARK: - Rows that say what a click will do

/// A menu row that carries a leading icon, a title, and a trailing glyph naming
/// the action — shown only while the row is highlighted.
///
/// A standard `NSMenuItem` cannot do this. It has exactly one image slot and it
/// is on the leading edge; the only trailing affordance AppKit offers is
/// `NSMenuItemBadge`, which is text and is always visible. So a row that wants
/// to answer "what happens if I click this?" at the moment you are deciding has
/// to draw itself.
///
/// That is a real cost and it is paid here rather than skipped. A view item gets
/// no highlight, no keyboard selection and no accessibility for free. The first
/// of those comes from `enclosingMenuItem.isHighlighted` rather than from the
/// pointer, which is the detail that matters: AppKit sets it when you arrow onto
/// a row as well as when you point at it, so the keyboard keeps working and the
/// trailing glyph appears for it too.
@MainActor
final class MenuRowView: NSView {

    private let run: () -> Void
    private let title: NSTextField
    private let leading: NSImageView
    private let trailing: NSImageView

    /// Tracked here rather than read from `enclosingMenuItem.isHighlighted`.
    ///
    /// That property looks like the better answer, and it is why this was
    /// written that way first: AppKit sets it for keyboard selection as well as
    /// for the pointer, so a row would light up when arrowed onto. It is never
    /// set for a *view* item — AppKit hands highlighting to the view and stops
    /// keeping the flag — so reading it gave a row that never lit and a glyph
    /// that never appeared, which looks exactly like the view not being
    /// installed at all.
    ///
    /// The cost of owning it is the thing that made the other way attractive:
    /// arrowing through a submenu does not light these rows.
    private var isLit = false {
        didSet {
            guard isLit != oldValue else { return }
            title.textColor = isLit ? .selectedMenuItemTextColor : .labelColor
            leading.contentTintColor = isLit ? .selectedMenuItemTextColor : .labelColor
            // The whole point of the row: the action only names itself while
            // you are deciding whether to take it.
            trailing.isHidden = !isLit
            needsDisplay = true
        }
    }

    /// Matches a standard row closely enough to sit among them: the system's
    /// own menu font, and the inset AppKit leaves for an item's image.
    private static let height: CGFloat = 22
    private static let inset: CGFloat = 13
    private static let iconWidth: CGFloat = 15
    private static let gap: CGFloat = 8

    /// - Parameters:
    ///   - icon: the leading image, already sized.
    ///   - action: the symbol naming what a click does, on the trailing edge.
    init(
        title: String,
        icon: NSImage?,
        action: String,
        isChecked: Bool = false,
        width: CGFloat = 220,
        run: @escaping () -> Void
    ) {
        self.run = run
        self.title = NSTextField(labelWithString: title)
        self.leading = NSImageView()
        self.trailing = NSImageView()
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        // So the row fills the menu's width and the trailing glyph lands on the
        // true right edge rather than wherever this view happened to end.
        autoresizingMask = [.width]

        leading.image = icon
        leading.imageScaling = .scaleProportionallyUpOrDown
        addSubview(leading)

        self.title.font = .menuFont(ofSize: 0)
        self.title.textColor = .labelColor
        self.title.lineBreakMode = .byTruncatingTail
        addSubview(self.title)

        trailing.image = NSImage(systemSymbolName: action, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            )
        trailing.contentTintColor = .selectedMenuItemTextColor
        trailing.isHidden = true
        addSubview(trailing)

        if isChecked {
            // The selected tab, marked the way a menu marks one.
            self.title.stringValue = "✓ " + title
        }

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let middle = (Self.height - Self.iconWidth) / 2
        leading.frame = NSRect(
            x: Self.inset, y: middle, width: Self.iconWidth, height: Self.iconWidth
        )
        let textX = Self.inset + Self.iconWidth + Self.gap
        let trailingX = bounds.width - Self.inset - Self.iconWidth
        title.frame = NSRect(
            x: textX, y: 2, width: max(0, trailingX - textX - Self.gap), height: 18
        )
        trailing.frame = NSRect(
            x: trailingX, y: middle, width: Self.iconWidth, height: Self.iconWidth
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isLit else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5
        ).fill()
    }

    override func mouseEntered(with event: NSEvent) { isLit = true }
    override func mouseExited(with event: NSEvent) { isLit = false }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    private func press() {
        enclosingMenuItem?.menu?.cancelTracking()
        let run = self.run
        DispatchQueue.main.async { run() }
    }
}

extension NSMenu {

    /// A row that draws itself, so it can say on the trailing edge what
    /// clicking it does.
    @discardableResult
    @MainActor
    func addRow(
        _ title: String,
        icon: NSImage? = nil,
        symbol: String? = nil,
        action: String,
        isChecked: Bool = false,
        run: @escaping () -> Void
    ) -> MenuRowView {
        let resolved = icon ?? symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                )
        }
        let view = MenuRowView(
            title: title, icon: resolved, action: action, isChecked: isChecked, run: run
        )
        addView(view)
        return view
    }
}
