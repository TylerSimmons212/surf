import SurfCore
import SwiftUI

/// Page load progress drawn around the window's edge.
///
/// Surf has no address bar to put a progress bar in, and the reload button's
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
    /// Flipped once on appear; both the sweep and the breath hang off it, so a
    /// single state change starts every repeating animation.
    @State private var isSweeping = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lineWidth: CGFloat = 3
    /// Keeps the stroke clear of the window's own rounded mask, which would
    /// otherwise shave the outer half off along the corners.
    private let inset: CGFloat = 2.5
    /// macOS's window corner radius.
    ///
    /// Measured, not eyeballed: the window server rounds the frame itself, so
    /// there's no layer to read and no public API for it — but `NSWindow` does
    /// carry the number internally, and on this OS it is 16. It was 14 here
    /// before, guessed, and the two-point deficit plus a plain-arc corner was
    /// enough to make the border visibly cut inside the window it traces.
    ///
    /// If a future macOS changes it, this is the one number to change.
    private let windowRadius: CGFloat = 16
    /// How far the glow reaches into the page.
    private let glowWidth: CGFloat = 26
    /// One lap of the crest, in seconds. Slow enough to read as a swell rather
    /// than something spinning.
    private let wavePeriod: TimeInterval = 2.6
    private let breathPeriod: TimeInterval = 3.4

    var body: some View {
        ZStack {
            innerGlow

            // The traced arc is one flat colour. Running the whole ramp along
            // it made every part of the border a different blue, which read as
            // decoration rather than as a measurement — and the eye had nothing
            // to fix on, because there was no one place the colour was going.
            // Flat body, loud tip: the tip is the thing that's actually moving.
            shape
                .trim(from: 0, to: progress.value)
                .stroke(OceanTide.shallow, style: strokeStyle)
                .shadow(color: OceanTide.shallow.opacity(0.5), radius: 5)

            waveHead
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

    // MARK: - The wave

    /// The breaking crest at the leading edge, and the only place the full
    /// palette appears.
    ///
    /// Built as a short band at the tip rather than as a gradient along the
    /// whole arc, because a wave is a local event: the water behind it is just
    /// water. Three things stack up over the same few points of arc —
    ///
    /// - the **curl**, a wide soft band of deep water gathering behind the
    ///   crest, which is what gives the tip somewhere to break *from*;
    /// - the **flow**, the mixed ocean ramp streaming through the tip, drawn as
    ///   a rotating angular gradient masked to the band so the colours travel
    ///   through it instead of sitting still on it;
    /// - the **spray**, a short foam cap right at the leading point.
    @ViewBuilder
    private var waveHead: some View {
        if progress.value > 0.004 {
            ZStack {
                band(span: curlSpan, width: lineWidth * 2.6, blur: 5)
                    .foregroundStyle(OceanTide.ocean.opacity(0.5))

                flow

                band(span: spraySpan, width: lineWidth, blur: 0.7)
                    .foregroundStyle(OceanTide.foam)
            }
            // The glow belongs to the crest, not to the whole border — it's
            // what makes the tip read as lit from inside rather than painted.
            .shadow(color: OceanTide.shallow.opacity(0.85), radius: 7)
            .shadow(color: OceanTide.surf.opacity(0.5), radius: 14)
            .opacity(isSweeping && !reduceMotion ? 1 : 0.85)
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: breathPeriod / 2).repeatForever(autoreverses: true),
                value: isSweeping
            )
            .onAppear { isSweeping = true }
        }
    }

    /// How much arc each part of the crest covers, as a fraction of the
    /// perimeter. Deliberately small: a crest that spans a whole side of the
    /// window stops being a crest and becomes a gradient again.
    private let curlSpan: CGFloat = 0.055
    private let flowSpan: CGFloat = 0.038
    private let spraySpan: CGFloat = 0.012

    /// One band of the crest — the arc from `span` behind the leading edge up
    /// to it, stroked and softened.
    ///
    /// Untinted here so callers style it; the shape work is identical for all
    /// three and only the paint differs.
    private func band(span: CGFloat, width: CGFloat, blur: CGFloat) -> some View {
        shape
            .trim(from: max(0, progress.value - span), to: progress.value)
            .stroke(.foreground, style: StrokeStyle(lineWidth: width, lineCap: .round))
            .blur(radius: blur)
    }

    /// The palette streaming through the crest.
    ///
    /// The colours rotate rather than the geometry: one pre-drawn angular
    /// gradient spun about the window's centre is a transform, so Core
    /// Animation runs it on the render thread and this body is evaluated once
    /// per progress change instead of once per frame. Masked to the crest band,
    /// which is what turns a spinning wheel of colour into water moving through
    /// one point.
    private var flow: some View {
        AngularGradient(
            gradient: Gradient(colors: [
                OceanTide.surf, OceanTide.shallow, OceanTide.foam,
                OceanTide.shallow, OceanTide.ocean, OceanTide.surf,
            ]),
            center: .center
        )
        .scaleEffect(1.5)
        .rotationEffect(.degrees(isSweeping && !reduceMotion ? 360 : 0))
        .animation(
            reduceMotion
                ? nil
                : .linear(duration: wavePeriod).repeatForever(autoreverses: false),
            value: isSweeping
        )
        .mask { band(span: flowSpan, width: lineWidth * 1.5, blur: 1.4) }
    }

    // MARK: - Inner glow

    /// Light bleeding inward from the traced edge.
    ///
    /// Clipped to the perimeter so the glow only ever falls *into* the page —
    /// spilling outward would just be a fatter border. One flat colour, for the
    /// same reason the stroke is: this is the water, and the wave above is the
    /// only thing with colours in it.
    @ViewBuilder
    private var innerGlow: some View {
        // Removed outright when nothing is drawn, which also stops the
        // animation rather than leaving it running against a hidden view.
        if progress.value > 0 {
            shape
                .trim(from: 0, to: progress.value)
                .stroke(
                    OceanTide.shallow.opacity(0.34),
                    style: StrokeStyle(lineWidth: glowWidth, lineCap: .round)
                )
                .blur(radius: glowWidth * 0.55)
                .clipShape(shape)
                .opacity(isSweeping && !reduceMotion ? 0.62 : 1)
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: breathPeriod).repeatForever(autoreverses: true),
                    value: isSweeping
                )
                .onAppear { isSweeping = true }
        }
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
/// Two things have to be true at once, and neither comes for free.
///
/// **The corners have to be the window's corners.** macOS rounds windows with
/// continuous curvature — a squircle, not a circular arc — and the difference
/// is not subtle at this radius: the squircle starts bending about 1.53× the
/// radius out from the corner, so against a plain arc the two part company for
/// a third of the way along each edge. Hand-rolling that curve means copying
/// Apple's coefficients and hoping; `RoundedRectangle(style: .continuous)`
/// already *is* the curve, exactly, so this borrows it rather than imitating it.
///
/// **The sweep has to start at twelve o'clock.** `RoundedRectangle` begins its
/// path halfway down the right edge, which would put the start and the finish
/// line of a progress arc at the side of the window — arbitrary-looking, and
/// nowhere the eye goes first.
///
/// So the path is re-cut: take the last quarter, then append the first three.
/// The 0.75 is exact rather than approximate, and holds for any width, height
/// or radius — a rounded rectangle is symmetric enough that right-centre to
/// top-centre going clockwise is three quarters of the perimeter, the same as
/// it would be on a circle. `trimmedPath` measures by arc length, so the two
/// pieces meet with no seam and `.trim(from:to:)` on the result runs from the
/// top exactly as a caller would expect.
struct WindowPerimeter: Shape {
    var cornerRadius: CGFloat

    /// Where twelve o'clock falls in `RoundedRectangle`'s own parameterization.
    private static let topCentre: CGFloat = 0.75

    func path(in rect: CGRect) -> Path {
        let full = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .path(in: rect)
        var path = full.trimmedPath(from: Self.topCentre, to: 1)
        path.addPath(full.trimmedPath(from: 0, to: Self.topCentre))
        return path
    }
}
