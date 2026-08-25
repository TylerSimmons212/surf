import AppKit
import SwiftUI

/// One round glass button. Bigger than the pop-out's, because these float over
/// a page rather than over video the user is already looking at, and they are
/// the only chrome the window has.
///
/// `.regular` glass, not the `.clear` the pop-out uses: that one sits on moving
/// video, where frosting would fog the picture. This sits on a page, where what
/// is *on* the glass has to stay legible.
private struct GlassCircleButton: View {
    let symbol: String
    let help: String
    /// Swaps the glyph for a tick and tints it, for actions whose effect is
    /// invisible — a copy that says nothing looks like a copy that failed.
    var isConfirming = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isConfirming ? "checkmark" : symbol)
                .font(.system(size: 14, weight: .bold))
                // `.primary`, not white: this floats over whatever the page is,
                // and a white glyph vanishes on a light one.
                .foregroundStyle(isConfirming ? Color.green : Color.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                // Hover tints the glass; nothing moves. A `scaleEffect` here
                // transformed the label but not the glass shape — that is
                // drawn by the container's own pass — so the glyph slid around
                // inside its own circle instead of the button growing. Tint is
                // part of the glass's own configuration rather than a filter
                // laid over it, so it is the one lever that reaches the shape.
                .glassEffect(
                    isHovering
                        ? .regular.tint(.accentColor.opacity(0.38)).interactive()
                        : .regular.interactive(),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isConfirming)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// Copy, and say so. The tick holds long enough to be read and then puts itself
/// away, so nothing has to be dismissed.
private struct CopyLinkButton: View {
    let onCopy: () -> Void

    @State private var hasCopied = false

    var body: some View {
        GlassCircleButton(
            symbol: "link",
            help: hasCopied ? "Copied" : "Copy link",
            isConfirming: hasCopied
        ) {
            onCopy()
            hasCopied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                hasCopied = false
            }
        }
    }
}

/// Top-left: dismissing, where a window's close button belongs.
struct MiniWindowLeadingControls: View {
    let onClose: () -> Void

    var body: some View {
        GlassCircleButton(
            symbol: "xmark",
            help: "Close, and go back to the window this came from",
            action: onClose
        )
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        // Room for the shadow, which `fittingSize` would otherwise clip.
        .padding(8)
    }
}

/// Top-right: copy the link, or keep the page.
struct MiniWindowTrailingControls: View {
    let session: BrowserSession
    /// Where a plain click sends the page — the island it has been browsing in,
    /// which is not necessarily the one the main window is showing by now.
    let destination: Island
    let onCopyLink: () -> Void
    let onPromote: () -> Void
    let onPromoteInto: (Island) -> Void

    @State private var isHoveringPromote = false

    /// With one island there is nothing to choose, so the button says which app
    /// this floating window belongs to instead — which is the more useful thing
    /// to know when it arrived from Slack. A caret offering a single
    /// destination would be the pill mistake again: a control that cannot do
    /// anything, sitting in a row of controls that can.
    private var hasChoice: Bool { session.islands.count > 1 }

    var body: some View {
        // One container so neighbouring glass merges into a single sampling
        // pass instead of each shape carrying its own slab.
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                CopyLinkButton(onCopy: onCopyLink)

                Button(action: onPromote) {
                    Text(hasChoice ? "Open in \(destination.name)" : "Open in Surf")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        // Built from `.glassEffect` rather than
                        // `.buttonStyle(.glassProminent)`. The stock prominent
                        // style renders its fill in the glass pass, which no
                        // modifier layered afterwards can reach — brightness
                        // and scale both went nowhere. Tinting the glass
                        // itself is the only lever that touches the shape, and
                        // reaching for it means owning the shape.
                        .glassEffect(
                            .regular
                                .tint(.accentColor.opacity(isHoveringPromote ? 1 : 0.75))
                                .interactive(),
                            in: Capsule()
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .animation(.easeOut(duration: 0.16), value: isHoveringPromote)
                .onHover { isHoveringPromote = $0 }
                .help("Keep this page as a tab in \(destination.name)")

                if hasChoice {
                    islandMenu
                }
            }
        }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        .padding(8)
    }

    /// Somewhere else to put it. Its own shape beside the button rather than a
    /// split control: a `Menu` styles its own label, and glass is not something
    /// to hand to a style that has opinions about chrome.
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
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 36)
                .glassEffect(.regular.interactive(), in: Capsule())
                .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32, height: 36)
        .help("Open in another island")
    }
}

/// The strip along the top of the panel that drags the window.
///
/// A borderless panel has no title bar to grab, and
/// `isMovableByWindowBackground` is no use here because the web view covers the
/// whole background and takes the drag first. So the grab area is an explicit
/// view, mounted above the page and below the buttons.
///
/// It does cost the page its top strip: a real AppKit view takes every click
/// inside its frame, so the page no longer sees clicks up here. That is the
/// trade for being able to move the window, and it is the bargain every
/// titled window already makes.
final class MiniWindowDragStrip: NSView {
    override func mouseDown(with event: NSEvent) {
        // Runs its own event loop until the mouse comes up, which is what makes
        // this a drag rather than a jump.
        window?.performDrag(with: event)
    }

    /// Nothing to draw — the page shows through.
    override var isOpaque: Bool { false }
}

/// Rounds the panel's corners and clips the page to them.
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
/// unable to take clicks or typing.
final class MiniWindowPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    var onCancel: (() -> Void)?

    /// Escape dismisses. AppKit routes it here as the cancel action, which
    /// beats a key monitor: it arrives only while this panel is key.
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
