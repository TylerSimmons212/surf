import AppKit
import Observation
import SwiftUI

/// Hover state for the pop-out panel's controls, shared between the AppKit
/// tracking area that detects the pointer and the SwiftUI overlay that draws.
@Observable
@MainActor
final class PopOutChromeModel {
    var isHovering = false
    var title = ""
    var onClose: () -> Void = {}
    var onRestore: () -> Void = {}
}

/// The overlay drawn on top of the video: a scrim and a few controls that only
/// appear on hover, so at rest the panel is nothing but picture.
struct PopOutChrome: View {
    @Bindable var model: PopOutChromeModel

    static let barHeight: CGFloat = 34
    static let gripSize: CGFloat = 18

    var body: some View {
        ZStack(alignment: .top) {
            // Never intercepts: the page underneath keeps its own controls.
            Color.clear

            topBar
                .opacity(model.isHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.16), value: model.isHovering)
        }
    }

    private var topBar: some View {
        ZStack {
            // Darkens just enough to keep the glyphs legible over bright video.
            LinearGradient(
                colors: [.black.opacity(0.6), .black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: PopOutChrome.barHeight + 12)
            .allowsHitTesting(false)

            HStack(spacing: 4) {
                // Dragging the bar moves the window; the video below stays
                // clickable because this strip is the only interactive region.
                WindowDragHandle()
                    .overlay(alignment: .leading) {
                        Text(model.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .padding(.leading, 8)
                            .allowsHitTesting(false)
                    }

                chromeButton("arrow.down.right.and.arrow.up.left", help: "Back to Tab") {
                    model.onRestore()
                }
                chromeButton("xmark", help: "Close") {
                    model.onClose()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: PopOutChrome.barHeight)
        }
        .frame(height: PopOutChrome.barHeight + 12)
    }

    private func chromeButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background {
                    Circle().fill(.black.opacity(0.45))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Drags the whole window, the way a titlebar would.
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DragView: NSView {
    override func mouseDown(with event: NSEvent) {
        // performDrag hands the whole gesture to the window server, so the drag
        // keeps up with the pointer instead of being chased frame by frame.
        window?.performDrag(with: event)
    }
}

/// Passes clicks through to the web view except where the chrome actually has
/// controls.
///
/// A plain `NSHostingView` claims every point in its frame, which would swallow
/// clicks meant for the page's own player controls. Only the top strip — and
/// only while it's visible — should take events.
final class ChromeHostingView: NSHostingView<PopOutChrome> {
    /// Height of the interactive strip at the top, or zero for fully
    /// click-through.
    var interactiveTopHeight: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveTopHeight > 0 else { return nil }
        // AppKit's origin is bottom-left, so the top strip is the high-y band.
        guard point.y >= bounds.maxY - interactiveTopHeight else { return nil }
        return super.hitTest(point)
    }
}

/// The panel's root view: rounds the corners, and reports hover so the chrome
/// can fade in.
final class PopOutRootView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// Borderless windows can't become key by default, which would leave the web
/// view unable to take clicks properly.
final class PopOutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
