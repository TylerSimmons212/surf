import AppKit
import SurfCore
import SwiftUI

/// The mini window's chrome: one bar across the top, above the page.
///
/// It used to be two clusters of round glass buttons floating *over* the page,
/// which is why the panel needed a separate invisible strip behind them to be
/// draggable, and why the clusters were mounted as two hosting views rather
/// than one — an AppKit view takes every click inside its frame, so a full
/// width bar would have deadened the page's whole top edge even where it drew
/// nothing. A real bar has no such problem: the page starts underneath it, so
/// there is no page up here to deaden.
///
/// No traffic lights. A mini window has one thing you can do to it that isn't
/// promoting it, and that is make it go away.
struct MiniWindowBar: View {
    @Bindable var tab: Tab
    let session: BrowserSession
    /// Where a plain click sends the page — the island it has been browsing in,
    /// which is not necessarily the one the main window is showing by now.
    let destination: Island
    let onClose: () -> Void
    let onCopyLink: () -> Void
    let onPromote: () -> Void
    let onPromoteInto: (Island) -> Void

    static let height: CGFloat = 46
    /// Every control in the bar, so nothing sits a point off its neighbour.
    fileprivate static let controlHeight: CGFloat = 30

    var body: some View {
        // No `GlassEffectContainer`. That coordinates `.glassEffect` modifiers
        // into one sampling pass, and these are `.buttonStyle(.glass)` buttons
        // — the system's own glass, which brings its own. Wrapping them in it
        // put the container in charge of a pass it had no controls to draw.
        Group {
            HStack(spacing: 8) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonBorderShape(.circle)
                .help("Close, and go back to the window this came from")
                .pointerStyle(.link)

                MiniWindowAddressField(tab: tab)

                CopyLinkButton(onCopy: onCopyLink)

                Button(hasChoice ? "Open in \(destination.name)" : "Open in Surf",
                       action: onPromote)
                    .buttonStyle(.glassProminent)
                    .help("Keep this page as a tab in \(destination.name)")
                    .pointerStyle(.link)

                if hasChoice { islandMenu }
            }
            // Every control in the row takes its size and its hover, focus and
            // press behaviour from the system. This was all hand-rolled —
            // `.onHover` into a `@State` flag into a tint on the glass — which
            // meant maintaining an impression of a button rather than having
            // one, and it drifted from the real thing in both directions: no
            // focus ring, no keyboard activation, and a hover tint no other
            // control in the app used.
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        // Behind the controls, so it takes the clicks they don't. This is the
        // whole drag affordance now — there is no title bar to grab, and
        // `isMovableByWindowBackground` is no use because the web view covers
        // the background and takes the drag first.
        .background { WindowDragArea() }
        .background {
            // `.behindWindow` blur, not a SwiftUI material: the panel is
            // transparent and the page stops at the bar's bottom edge, so
            // there is nothing behind this but the desktop.
            VisualEffectBackground(material: .headerView)
        }
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    /// With one island there is nothing to choose, so the button says which app
    /// this floating window belongs to instead — which is the more useful thing
    /// to know when it arrived from Slack. A caret offering a single
    /// destination would be a control that cannot do anything, sitting in a row
    /// of controls that can.
    private var hasChoice: Bool { session.islands.count > 1 }

    /// Somewhere else to put it. Its own shape beside the button rather than a
    /// split control: a `Menu` styles its own label, and glass is not something
    /// to hand to a style that has opinions about chrome.
    ///
    /// `.button` rather than `.borderlessButton` for the same reason the
    /// sidebar's screenshot menu takes it: it is the menu style that lets the
    /// row's `.buttonStyle` reach the label, so this wears the same glass and
    /// answers the pointer the same way as its neighbours.
    private var islandMenu: some View {
        Menu {
            ForEach(session.islands) { island in
                Button {
                    onPromoteInto(island)
                } label: {
                    // The one it would go to anyway is marked, so the menu says
                    // what the button already decided rather than presenting
                    // every island as equally likely.
                    if island === destination {
                        Label(island.name, systemImage: "checkmark")
                    } else {
                        Text(island.name)
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open in another island")
        .pointerStyle(.link)
    }
}

/// The address, and somewhere to type a new one.
///
/// A mini window opens on a link somebody sent, but it is a real `Tab` and
/// there is no reason a page you have followed two links into should still
/// claim to be at the address it arrived on. Bound straight to `addressText`,
/// which is the same property the main window's palette edits and the same one
/// navigation writes back to, so the field says where the page is without
/// anything having to keep the two in step.
///
/// An `NSTextField` by way of `SurfTextField`, and not SwiftUI's own
/// `TextField`, which was tried here and does not work: a `TextField` inside an
/// `NSHostingView` mounted as a *subview* of a borderless panel never takes
/// focus. Clicking it does nothing, `@FocusState` set by hand does nothing, and
/// typing goes wherever it was already going — proven by typing an address into
/// it and watching the page not navigate. `SurfTextField` makes itself first
/// responder explicitly, which is exactly the step the plain one is missing.
private struct MiniWindowAddressField: View {
    @Bindable var tab: Tab

    var body: some View {
        SurfTextField(
            text: $tab.addressText,
            placeholder: "Search or enter address",
            font: .systemFont(ofSize: 12, weight: .medium),
            // The address arrived from somewhere else and is the thing being
            // read, not something to be replaced on the first keystroke.
            selectsAllOnFocus: false,
            onSubmit: { tab.submit(tab.addressText) }
        )
        .padding(.horizontal, 12)
        .frame(height: MiniWindowBar.controlHeight)
        .frame(maxWidth: .infinity)
        // `.interactive()` is the glass answering the pointer itself, rather
        // than a tint swapped in behind a hover flag.
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(Capsule())
        // The capsule is bigger than the text in it; an I-beam over all of it
        // is what says the whole pill is the field.
        .pointerStyle(.horizontalText)
    }
}

/// Copy, and say so. The tick holds long enough to be read and then puts itself
/// away, so nothing has to be dismissed — a copy that says nothing looks like a
/// copy that failed.
private struct CopyLinkButton: View {
    let onCopy: () -> Void

    @State private var hasCopied = false

    var body: some View {
        Button {
            onCopy()
            hasCopied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                hasCopied = false
            }
        } label: {
            Image(systemName: hasCopied ? "checkmark" : "link")
                .foregroundStyle(hasCopied ? Color.green : Color.primary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonBorderShape(.circle)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: hasCopied)
        .help(hasCopied ? "Copied" : "Copy link")
        // A Mac button does not normally change the cursor, and in a row of
        // chrome floating over a web page that reads as nothing being there.
        // `.pointerStyle` is the system's own way to say otherwise.
        .pointerStyle(.link)
    }
}

/// A patch of window you can pick the window up by.
///
/// Mounted as the bar's background so SwiftUI's own controls sit above it and
/// keep their clicks; everything they don't take lands here.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> MiniWindowDragStrip { MiniWindowDragStrip() }
    func updateNSView(_ view: MiniWindowDragStrip, context: Context) {}
}

/// Drags the window it is in.
final class MiniWindowDragStrip: NSView {
    override func mouseDown(with event: NSEvent) {
        // Runs its own event loop until the mouse comes up, which is what makes
        // this a drag rather than a jump.
        window?.performDrag(with: event)
    }

    /// Nothing to draw — the bar's blur shows through.
    override var isOpaque: Bool { false }
}

/// Rounds the panel's corners and clips its contents to them. A borderless
/// window gets no rounding from AppKit, so this is where it comes from.
final class MiniWindowRootView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Borderless windows can't become key by default, which would leave the page
/// unable to take clicks or typing — and now the address field unable to take
/// any either.
final class MiniWindowPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    var onCancel: (() -> Void)?

    /// Escape dismisses. AppKit routes it here as the cancel action, which
    /// beats a key monitor: it arrives only while this panel is key.
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
