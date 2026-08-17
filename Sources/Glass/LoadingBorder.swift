import GlassCore
import SwiftUI

/// Page load progress drawn around the window's edge.
///
/// Glass has no address bar to put a progress bar in, and the reload button's
/// ring lives in a sidebar that's hidden most of the time — so a loading page
/// looked identical to a finished one. The window frame is the one surface
/// that's always visible and never in the way: the stroke traces the perimeter
/// clockwise from top centre, completes a full lap, then fades.
///
/// What to draw is `LoadProgress`; this only draws it.
struct LoadingBorder: View {
    let tab: Tab

    @State private var progress = LoadProgress()
    @State private var trickle: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lineWidth: CGFloat = 3
    /// Keeps the stroke clear of the window's own rounded mask, which would
    /// otherwise shave the outer half off along the corners.
    private let inset: CGFloat = 2.5
    /// macOS's window corner radius. The mask belongs to the system and isn't
    /// published anywhere, so this is matched by eye.
    private let windowRadius: CGFloat = 14
    /// How far the glow reaches into the page.
    private let glowWidth: CGFloat = 26
    /// One lap of the crest, in seconds. Slow enough to read as a swell rather
    /// than something spinning.
    private let wavePeriod: TimeInterval = 2.6
    private let breathPeriod: TimeInterval = 3.4

    var body: some View {
        ZStack {
            innerGlow

            shape
                .trim(from: 0, to: progress.value)
                .stroke(Color.accentColor, style: strokeStyle)
                // The glow is what makes it read as light rather than as a
                // border the window suddenly grew.
                .shadow(color: Color.accentColor.opacity(0.55), radius: 5)

            // A brighter head just ahead of the fill, so the eye follows the
            // leading edge rather than the whole arc at once.
            if !reduceMotion, progress.value > 0.04 {
                shape
                    .trim(from: max(0, progress.value - 0.05), to: progress.value)
                    .stroke(Color.white.opacity(0.9), style: strokeStyle)
                    .blur(radius: 2.5)
            }
        }
        .padding(inset)
        .opacity(progress.isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: progress.value)
        .animation(.easeOut(duration: 0.3), value: progress.isVisible)
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .onAppear { sync(isLoading: tab.isLoading) }
        .onChange(of: tab.isLoading) { _, loading in sync(isLoading: loading) }
        .onChange(of: tab.progress) { _, reported in progress.report(reported) }
        // Switching tabs mid-load must not carry the old tab's arc across.
        .onChange(of: tab.id) { _, _ in
            trickle?.cancel()
            progress.clear()
            sync(isLoading: tab.isLoading)
        }
        .onDisappear { trickle?.cancel() }
    }

    // MARK: - Inner glow

    /// Light bleeding inward from the traced edge, with a crest that keeps
    /// travelling along it.
    ///
    /// Clipped to the perimeter so the glow only ever falls *into* the page —
    /// spilling outward would just be a fatter border. The whole thing is
    /// driven off a clock rather than SwiftUI animations: the crest's position
    /// depends on the progress value, which is itself animating, and two
    /// animation systems driving one number fight each other.
    @ViewBuilder
    private var innerGlow: some View {
        // No timeline while nothing is drawn — this would otherwise tick at
        // display rate for the entire life of the window.
        if progress.value > 0 {
            if reduceMotion {
                wash(intensity: 0.7).clipShape(shape)
            } else {
                TimelineView(.animation) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        wash(intensity: breath(at: time))
                        crest(at: crestPosition(at: time))
                    }
                    .clipShape(shape)
                }
            }
        }
    }

    /// A broad, soft band under everything traced so far.
    private func wash(intensity: Double) -> some View {
        shape
            .trim(from: 0, to: progress.value)
            .stroke(
                Color.accentColor.opacity(0.42 * intensity),
                style: StrokeStyle(lineWidth: glowWidth, lineCap: .round)
            )
            .blur(radius: glowWidth * 0.55)
    }

    /// The wave itself: three stacked segments of decreasing length and rising
    /// opacity, which gives the crest a tail that falls off behind it. A real
    /// gradient along a path isn't available, and three bands are enough once
    /// they're blurred into each other.
    private func crest(at head: Double) -> some View {
        ZStack {
            crestBand(head: head, length: 0.26, opacity: 0.16, blur: 22)
            crestBand(head: head, length: 0.15, opacity: 0.22, blur: 16)
            crestBand(head: head, length: 0.07, opacity: 0.30, blur: 11)
        }
    }

    private func crestBand(
        head: Double,
        length: Double,
        opacity: Double,
        blur: CGFloat
    ) -> some View {
        shape
            .trim(from: max(0, head - length), to: head)
            .stroke(
                Color.accentColor.opacity(opacity),
                style: StrokeStyle(lineWidth: glowWidth * 1.3, lineCap: .round)
            )
            .blur(radius: blur)
    }

    /// The crest sweeps the lit portion of the perimeter, so it stays inside
    /// what's actually been traced and never runs ahead of the progress.
    ///
    /// Kept off the seam at top centre deliberately: `trim` draws nothing when
    /// `from` is greater than `to`, so a crest that wrapped past the finish
    /// line would blink out rather than continue around.
    private func crestPosition(at time: TimeInterval) -> Double {
        let phase = (time / wavePeriod).truncatingRemainder(dividingBy: 1)
        return phase * progress.value
    }

    /// Slow swell in the wash, so the glow is alive even while the crest is on
    /// the far side of the window.
    private func breath(at time: TimeInterval) -> Double {
        let phase = sin(time * 2 * .pi / breathPeriod)
        return 0.62 + 0.38 * (phase + 1) / 2
    }

    private var shape: some Shape {
        WindowPerimeter(cornerRadius: windowRadius - inset)
    }

    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round)
    }

    private func sync(isLoading: Bool) {
        isLoading ? begin() : finish()
    }

    private func begin() {
        trickle?.cancel()
        progress.begin()
        progress.report(tab.progress)

        guard !reduceMotion else { return }
        // Keeps the arc alive through the silences WebKit leaves between
        // updates — a bar frozen for four seconds reads as a hung page.
        trickle = Task { @MainActor in
            while !Task.isCancelled, tab.isLoading {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, tab.isLoading else { return }
                progress.creep()
            }
        }
    }

    private func finish() {
        trickle?.cancel()
        guard progress.isVisible else { return }
        progress.complete()

        Task { @MainActor in
            // Long enough for the closing lap to be seen before it goes.
            try? await Task.sleep(for: .milliseconds(280))
            guard !tab.isLoading else { return }
            progress.hide()
            // Rewound only once the fade is over, so the arc never appears to
            // retreat on its way out.
            try? await Task.sleep(for: .milliseconds(340))
            guard !tab.isLoading else { return }
            progress.clear()
        }
    }
}

/// A rounded rectangle whose path *starts at top centre* and runs clockwise.
///
/// `RoundedRectangle` starts halfway down the right edge, so trimming it would
/// begin the sweep at the side of the window — arbitrary-looking, and it puts
/// the finish line there too. Twelve o'clock is where an indicator is read from.
///
/// The corners are plain arcs rather than the squircle `.continuous` uses. At a
/// 12-point radius on a window-sized rectangle the difference isn't visible,
/// and a hand-built path is the only way to choose where it starts.
struct WindowPerimeter: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        var path = Path()

        // Path coordinates are y-down, which is why every arc below sweeps with
        // `clockwise: false` to come out visually clockwise.
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))

        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
            radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0),
            clockwise: false
        )

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius, startAngle: .degrees(0), endAngle: .degrees(90),
            clockwise: false
        )

        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius, startAngle: .degrees(90), endAngle: .degrees(180),
            clockwise: false
        )

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius, startAngle: .degrees(180), endAngle: .degrees(270),
            clockwise: false
        )

        // Closes along the top edge, back to where the sweep began.
        path.closeSubpath()
        return path
    }
}
