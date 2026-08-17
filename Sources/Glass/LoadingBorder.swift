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

    var body: some View {
        ZStack {
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
