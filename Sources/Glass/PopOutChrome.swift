import AppKit
import Observation
import SwiftUI

/// State for the pop-out panel's controls, shared between the AppKit tracking
/// area that detects the pointer and the SwiftUI overlay that draws.
@Observable
@MainActor
final class PopOutChromeModel {
    var isHovering = false
    var isPlaying = false
    var title = ""
    var currentTime: Double = 0
    var duration: Double = 0
    var onClose: () -> Void = {}
    var onRestore: () -> Void = {}
    var onTogglePlay: () -> Void = {}
    var onSeek: (Double) -> Void = { _ in }
    var onSkip: (Double) -> Void = { _ in }
}

/// The overlay on top of the video: at rest nothing is drawn, on hover a scrim
/// and a few controls fade in.
///
/// The whole surface is an event sink. That's deliberate: the site's own player
/// controls appear on pointer activity and hide after a few seconds of quiet,
/// so denying the page any mouse events makes them fade out and stay out —
/// leaving exactly one set of controls, ours. It's also generic, where hiding
/// each site's control bar by selector would be an endless per-site chase.
struct PopOutChrome: View {
    @Bindable var model: PopOutChromeModel

    static let barHeight: CGFloat = 34
    private let gripSize: CGFloat = 20
    /// Matches the podcast convention, and the SF Symbols that exist for it.
    private let skipInterval: Double = 15

    /// Local while dragging so incoming time updates can't yank the knob out
    /// from under the pointer.
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    var body: some View {
        ZStack {
            // Fills the panel: swallows page input and drags the window.
            WindowDragHandle()

            if model.isHovering {
                topBar
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)

                transportControls
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))

                scrubBar
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)

                WindowResizeGrip()
                    .frame(width: gripSize, height: gripSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(4)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.isHovering)
    }

    private var topBar: some View {
        ZStack {
            // Darkens just enough to keep the glyphs legible over bright video.
            LinearGradient(
                colors: [.black.opacity(0.6), .black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: PopOutChrome.barHeight + 14)
            .allowsHitTesting(false)

            HStack(spacing: 4) {
                Text(model.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.leading, 8)
                    .allowsHitTesting(false)

                Spacer(minLength: 8)

                chromeButton("arrow.down.right.and.arrow.up.left", help: "Back to Tab") {
                    model.onRestore()
                }
                chromeButton("xmark", help: "Close") {
                    model.onClose()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: PopOutChrome.barHeight)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: PopOutChrome.barHeight + 14)
    }

    /// The page can't be clicked any more, so transport lives here.
    private var transportControls: some View {
        HStack(spacing: 18) {
            circleButton("gobackward.15", size: 15, diameter: 34,
                         help: "Back 15 Seconds") {
                model.onSkip(-skipInterval)
            }

            circleButton(model.isPlaying ? "pause.fill" : "play.fill",
                         size: 16, diameter: 44,
                         help: model.isPlaying ? "Pause" : "Play") {
                model.onTogglePlay()
            }

            circleButton("goforward.15", size: 15, diameter: 34,
                         help: "Forward 15 Seconds") {
                model.onSkip(skipInterval)
            }
        }
    }

    /// Elapsed, a draggable track, and remaining — the usual arrangement, kept
    /// clear of the resize grip in the corner.
    private var scrubBar: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 18)
            .allowsHitTesting(false)

            HStack(spacing: 8) {
                timeLabel(displayTime)
                track
                timeLabel(model.duration)
            }
            .padding(.leading, 10)
            // Room for the grip so the duration doesn't sit underneath it.
            .padding(.trailing, 28)
            .padding(.bottom, 8)
            .background {
                Color.black.opacity(0.65).allowsHitTesting(false)
            }
        }
    }

    private var displayFraction: Double {
        if isScrubbing { return scrubFraction }
        guard model.duration > 0 else { return 0 }
        return min(max(model.currentTime / model.duration, 0), 1)
    }

    private var displayTime: Double {
        isScrubbing ? scrubFraction * model.duration : model.currentTime
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(height: 3)

                Capsule()
                    .fill(.white)
                    .frame(width: width * displayFraction, height: 3)

                Circle()
                    .fill(.white)
                    .frame(width: isScrubbing ? 11 : 9, height: isScrubbing ? 11 : 9)
                    .offset(x: width * displayFraction - (isScrubbing ? 5.5 : 4.5))
            }
            .frame(maxHeight: .infinity)
            // Generous target: a 3pt line is impossible to grab otherwise.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        scrubFraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { value in
                        let fraction = min(max(value.location.x / width, 0), 1)
                        // Seek on release only: seeking per-frame while dragging
                        // makes streamed media rebuffer on every move.
                        model.onSeek(fraction * model.duration)
                        scrubFraction = fraction
                        isScrubbing = false
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isScrubbing)
        }
        .frame(height: 16)
    }

    private func timeLabel(_ seconds: Double) -> some View {
        Text(Self.formatted(seconds))
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .allowsHitTesting(false)
    }

    /// h:mm:ss only when there are hours; m:ss otherwise.
    static func formatted(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func circleButton(
        _ symbol: String,
        size: CGFloat,
        diameter: CGFloat,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background {
                    Circle().fill(.black.opacity(0.42))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
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

/// Drags the whole window, the way a titlebar would — and, by covering the
/// panel, keeps mouse events away from the page.
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

/// Bottom-right resize handle.
///
/// A borderless window has no frame to grab, and `.resizable` alone gives no
/// visible affordance, so the grip does the resizing itself.
private struct WindowResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ResizeGripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ResizeGripView: NSView {
    private var initialFrame: NSRect = .zero
    private var initialMouse: NSPoint = .zero

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Two short strokes, the usual grip idiom, light enough not to compete
        // with the video.
        let path = NSBezierPath()
        for inset in [CGFloat(4), CGFloat(9)] {
            path.move(to: NSPoint(x: bounds.maxX - inset, y: bounds.minY + 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + inset))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.75).setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialFrame = window.frame
        initialMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, initialFrame.height > 0 else { return }
        let delta = NSEvent.mouseLocation.x - initialMouse.x

        // Width drives the resize and height follows the aspect ratio; letting
        // both axes track the pointer would fight `contentAspectRatio` and
        // judder.
        let aspect = initialFrame.width / initialFrame.height
        let width = min(max(initialFrame.width + delta, 240), 1600)
        let height = width / aspect

        // Anchor the top-left so the panel grows down and right, rather than
        // sliding out from under the pointer.
        window.setFrame(
            NSRect(
                x: initialFrame.minX,
                y: initialFrame.maxY - height,
                width: width,
                height: height
            ),
            display: true
        )
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

/// Borderless windows can't become key by default, which would leave the panel
/// unable to take clicks properly.
final class PopOutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
