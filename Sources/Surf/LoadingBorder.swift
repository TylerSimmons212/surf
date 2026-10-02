import SurfCore
import SwiftUI

/// Page load progress drawn around the window's edge.
///
/// Surf has no address bar to put a progress bar in, and the reload button's
/// ring lives in a sidebar that's hidden most of the time — so a loading page
/// looked identical to a finished one. The window frame is the one surface
/// that's always visible and never in the way.
///
/// Two crests leave twelve o'clock together, one each way round, and meet at
/// six. Mirrored rather than one crest lapping the window, because each only
/// has half the distance to cover, both top corners move as soon as anything
/// does, and the finish has a place: the point where they meet, which is where
/// the ripple starts.
///
/// How a load *ends* decides most of how this feels, and the rules for it are
/// `LoadProgress.ending(shownFor:failed:)`: a load inside the grace period
/// draws nothing, a successful one closes the lap, washes out in foam and ripples into the page, and
/// a failed one fades where it stopped. What to draw along the way is
/// `LoadProgress`; this only draws it.
struct LoadingBorder: View {
    let tab: Tab

    @State private var progress = LoadProgress()
    @State private var phase: Phase = .idle
    /// Bumped whenever a load is abandoned or restarted. Every delayed step
    /// captures it and checks it on waking, so a sleep that outlives its load
    /// can't act on the next one.
    @State private var generation = 0
    @State private var isShown = false
    @State private var startedAt: ContinuousClock.Instant?
    @State private var shownAt: ContinuousClock.Instant?
    /// `tab.failedLoads` when this load began; any change means it failed.
    @State private var failuresAtStart = 0
    /// 0 while loading, 1 once the lap has closed and the line has turned to
    /// foam.
    @State private var wash: CGFloat = 0
    /// When the last finished load set off its ripple. Kept apart from the
    /// rest of the state on purpose: the ripple outlives the border, and a new
    /// load starting mid-ripple resets the border without cutting it short.
    @State private var rippleStart: Date?
    @State private var trickle: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase {
        case idle
        case loading
        /// The engine has finished and the lap is about to close.
        case closing
        /// Washing or fading out; nothing left to decide.
        case ending
    }

    private let lineWidth: CGFloat = 2
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

    /// Clockwise first, then its mirror image.
    private static let directions = [false, true]

    /// How far along its own path each crest has got. Each covers half the
    /// perimeter, so a full load is one half-lap apiece.
    private var reach: CGFloat { CGFloat(progress.value) / 2 }

    var body: some View {
        ZStack {
            border
                .opacity(isShown ? 1 : 0)
            // Outside the border's fade: the rings carry on into the page after
            // the line has gone, like the water settling after the wave.
            if let rippleStart {
                MeetingRipple(start: rippleStart, cornerRadius: windowRadius - inset)
            }
        }
        .padding(inset)
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .onAppear { sync(isLoading: tab.isLoading) }
        .onChange(of: tab.isLoading) { _, loading in sync(isLoading: loading) }
        .onChange(of: tab.progress) { _, reported in
            guard phase == .loading else { return }
            withAnimation(.smooth(duration: 0.45)) { _ = progress.report(reported) }
        }
        // WebKit doesn't promise to report a failure before it reports that
        // loading stopped. One that lands while the lap is waiting to close
        // still turns the ending into a fade.
        .onChange(of: tab.failedLoads) { _, _ in
            if phase == .closing { fadeOut() }
        }
        // Switching tabs mid-load must not carry the old tab's arc across.
        .onChange(of: tab.id) { _, _ in
            reset()
            sync(isLoading: tab.isLoading)
        }
        .onDisappear { reset() }
    }

    /// The line, the glow and the crests — everything that fades together.
    private var border: some View {
        ZStack {
            if phase != .idle {
                ForEach(Self.directions, id: \.self) { mirrored in
                    crestGlow(shape(mirrored))
                }

                // The traced arc is one flat colour; the crests are the only
                // place the palette appears. Flat body, loud tip: the tip is
                // the thing that's actually moving.
                ZStack {
                    ForEach(Self.directions, id: \.self) { mirrored in
                        trace(shape(mirrored))
                    }
                }
                .shadow(color: OceanTide.shallow.opacity(0.5), radius: 5)

                ZStack {
                    if reach > 0.002 {
                        ForEach(Self.directions, id: \.self) { mirrored in
                            CrestHead(
                                shape: shape(mirrored),
                                reach: reach,
                                lineWidth: lineWidth,
                                flows: !reduceMotion
                            )
                        }
                    }
                }
                // Once the lap closes the crests have nowhere left to go; they
                // dissolve into the foam rather than sitting on the finish.
                .opacity(1 - wash)
                // The glow belongs to the crests, not the whole border — it's
                // what makes the tip read as lit from inside rather than
                // painted. Applied once over both, so two crests cost the same
                // two shadow passes one did.
                .shadow(color: OceanTide.shallow.opacity(0.85), radius: 7)
                .shadow(color: OceanTide.surf.opacity(0.5), radius: 14)
            }
        }
    }

    // MARK: - Drawing

    private func shape(_ mirrored: Bool) -> WindowPerimeter {
        WindowPerimeter(cornerRadius: windowRadius - inset, mirrored: mirrored)
    }

    /// The arc travelled so far, with a foam copy on top that the wash fades
    /// in. A second stroke rather than an animated colour, so the line can
    /// also thicken as it brightens.
    private func trace(_ shape: WindowPerimeter) -> some View {
        ZStack {
            shape
                .trim(from: 0, to: reach)
                .stroke(OceanTide.shallow, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            shape
                .trim(from: 0, to: reach)
                .stroke(OceanTide.foam, style: StrokeStyle(lineWidth: lineWidth + 1.2, lineCap: .round))
                .opacity(wash)
        }
    }

    /// Light bleeding inward from just behind the crest.
    ///
    /// Only behind the crest. Lighting the whole traced arc put a blurred
    /// 26-point band around most of the window on every load, which made the
    /// page look tinted rather than the edge look lit. Clipped to the perimeter
    /// so the glow only ever falls *into* the page.
    private func crestGlow(_ shape: WindowPerimeter) -> some View {
        shape
            .trim(from: max(0, reach - 0.07), to: reach)
            .stroke(OceanTide.shallow.opacity(0.32), style: StrokeStyle(lineWidth: 14, lineCap: .round))
            .blur(radius: 9)
            .clipShape(shape)
            .opacity(1 - wash)
    }

    // MARK: - Sequencing

    private func sync(isLoading: Bool) {
        isLoading ? begin() : finish()
    }

    private func begin() {
        // Loading again before the lap closed — a redirect, or a page that
        // stops and restarts. The arc on screen is still telling the truth,
        // so it carries on rather than vanishing and returning after another
        // grace period.
        if phase == .closing {
            generation += 1
            phase = .loading
            failuresAtStart = tab.failedLoads
            startCreeping()
            return
        }

        reset()
        phase = .loading
        startedAt = .now
        failuresAtStart = tab.failedLoads
        progress.begin()
        progress.report(tab.progress)

        let generation = generation
        trickle = Task { @MainActor in
            try? await Task.sleep(for: LoadProgress.grace)
            guard !Task.isCancelled, self.generation == generation, phase == .loading else { return }
            shownAt = .now
            debugLog("border: shown")
            withAnimation(.easeOut(duration: 0.15)) { isShown = true }
            startCreeping()
        }
    }

    /// Keeps the arc alive through the silences WebKit leaves between
    /// updates — a bar frozen for four seconds reads as a hung page.
    private func startCreeping() {
        trickle?.cancel()
        guard !reduceMotion else { return }
        let generation = generation
        trickle = Task { @MainActor in
            while !Task.isCancelled, self.generation == generation, phase == .loading {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, self.generation == generation, phase == .loading else { return }
                // A spring rather than a curve: a new tick arriving mid-move
                // picks up the arc's speed instead of restarting from rest.
                withAnimation(.smooth(duration: 0.45)) { _ = progress.creep() }
            }
        }
    }

    private func finish() {
        guard phase == .loading else { return }
        trickle?.cancel()

        let shownFor = shownAt.map { ContinuousClock.now - $0 }
        let failed = tab.failedLoads != failuresAtStart
        let ending = LoadProgress.ending(shownFor: shownFor, failed: failed)
        let took = startedAt.map { ContinuousClock.now - $0 } ?? .zero
        debugLog("border: load took \(took.formatted(.units(allowed: [.milliseconds]))), ending \(ending)")
        switch ending {
        case .unseen:
            reset()
        case .fade:
            fadeOut()
        case .closeLap(let delay):
            phase = .closing
            let generation = generation
            Task { @MainActor in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard self.generation == generation, phase == .closing else { return }
                withAnimation(.snappy(duration: 0.3), completionCriteria: .logicallyComplete) {
                    progress.complete()
                } completion: {
                    guard self.generation == generation, phase == .closing else { return }
                    washOut()
                }
            }
        }
    }

    /// The finish: the line brightens to foam, the crests dissolve, rings
    /// spread from where they met, and the line fades while the rings carry on.
    private func washOut() {
        phase = .ending
        let generation = generation
        debugLog("border: washed out")
        withAnimation(.easeOut(duration: 0.12)) { wash = 1 }
        if !reduceMotion { ripple() }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard self.generation == generation else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                isShown = false
            } completion: {
                if self.generation == generation { reset() }
            }
        }
    }

    /// A failed load: no wash and no closing lap, just the arc fading from
    /// wherever it stopped. That stub reads as "didn't make it", which is the
    /// truth.
    private func fadeOut() {
        debugLog("border: faded out")
        phase = .ending
        trickle?.cancel()
        let generation = generation
        withAnimation(.easeOut(duration: 0.3)) {
            isShown = false
        } completion: {
            if self.generation == generation { reset() }
        }
    }

    /// Sets the rings going, and takes the ripple down once its last ring has
    /// spread out, so its timeline stops asking for frames.
    private func ripple() {
        let start = Date.now
        rippleStart = start
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(MeetingRipple.duration))
            // A later load may have set off its own ripple meanwhile.
            if rippleStart == start { rippleStart = nil }
        }
    }

    /// Back to nothing, at once. Invalidates every pending step.
    private func reset() {
        generation += 1
        trickle?.cancel()
        trickle = nil
        startedAt = nil
        shownAt = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            phase = .idle
            isShown = false
            wash = 0
            progress.clear()
        }
    }
}

// MARK: - The ripple

/// Rings spreading into the page from six o'clock, where the two crests meet.
///
/// A `Canvas` on a `TimelineView`, rather than a view per ring: each frame is
/// three arcs and a splash drawn into one layer, with no views to insert,
/// diff or remove. The timeline only exists while the ripple does — the border
/// takes it down when the last ring is done — so nothing ticks between loads.
///
/// Drawn the way water does it. Each ring decelerates as it spreads, because a
/// real ripple loses speed as its energy spreads over a longer front; thins and
/// fades as it goes for the same reason; and trails the one before it, smaller
/// and dimmer, because the first ring carries most of the energy. The first is
/// foam and the rest are shallow water. The centre flashes once at the moment
/// of impact — the splash — and is gone before the first ring has gone far.
private struct MeetingRipple: View {
    let start: Date
    let cornerRadius: CGFloat

    /// From impact to the last ring fading out, in seconds.
    static let duration: Double = ringLife + Double(ringCount - 1) * ringGap

    private static let ringCount = 3
    /// The delay between one ring and the next.
    private static let ringGap: Double = 0.09
    /// How long one ring takes to spread and fade.
    private static let ringLife: Double = 0.75
    private static let splashLife: Double = 0.28

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                // The point on the bottom edge where the crests met. Rings
                // centred on it are half below the window and clipped away, so
                // what's seen are arcs spreading up into the page.
                let centre = CGPoint(x: size.width / 2, y: size.height)
                let reach = min(size.width, size.height) * 0.42

                context.clip(
                    to: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .path(in: CGRect(origin: .zero, size: size))
                )

                drawSplash(in: &context, at: centre, elapsed: elapsed)
                for ring in 0..<Self.ringCount {
                    drawRing(ring, in: &context, at: centre, reach: reach, elapsed: elapsed)
                }
            }
        }
    }

    private func drawSplash(in context: inout GraphicsContext, at centre: CGPoint, elapsed: Double) {
        let life = elapsed / Self.splashLife
        guard life < 1 else { return }
        let radius = 10 + 22 * easeOut(life)
        let disc = Path(ellipseIn: CGRect(
            x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2
        ))
        context.fill(
            disc,
            with: .radialGradient(
                Gradient(colors: [
                    OceanTide.foam.opacity(0.9 * (1 - life)),
                    OceanTide.shallow.opacity(0),
                ]),
                center: centre,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    private func drawRing(
        _ ring: Int,
        in context: inout GraphicsContext,
        at centre: CGPoint,
        reach: CGFloat,
        elapsed: Double
    ) {
        let life = (elapsed - Double(ring) * Self.ringGap) / Self.ringLife
        guard life > 0, life < 1 else { return }

        // Each ring a little shorter-reaching and dimmer than the one ahead.
        let falloff = 1 - CGFloat(ring) * 0.14
        let radius = 6 + easeOut(life) * reach * falloff
        let fade = (1 - life) * (ring == 0 ? 0.95 : 0.6)
        let width = 0.6 + 2.2 * (1 - life)
        let circle = Path(ellipseIn: CGRect(
            x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2
        ))

        // The glow first, underneath: a wide, soft band of the same ring, so
        // the line reads as lit water rather than a drawn stroke.
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 6))
            glow.stroke(
                circle,
                with: .color(OceanTide.shallow.opacity(fade * 0.55)),
                lineWidth: width * 4
            )
        }
        context.stroke(
            circle,
            with: .color((ring == 0 ? OceanTide.foam : OceanTide.shallow).opacity(fade)),
            lineWidth: width
        )
    }

    /// Cubic ease-out: quick off the mark, settling as it spreads.
    private func easeOut(_ t: Double) -> CGFloat {
        CGFloat(1 - pow(1 - min(max(t, 0), 1), 3))
    }
}

// MARK: - The crest

/// The breaking crest at the leading edge of one arc.
///
/// Its own view so that its animation state is its own. The colour flow is a
/// repeating animation started by flipping a flag on appear; when that flag
/// lived on the border, it was flipped on the first load and never flipped
/// back, so every later load drew a crest that had nothing to animate. A
/// crest is inserted fresh with each load, so it starts fresh with each load.
///
/// Built as a short band at the tip rather than as a gradient along the whole
/// arc, because a wave is a local event: the water behind it is just water.
/// Three things stack up over the same few points of arc —
///
/// - the **curl**, a wide soft band of deep water gathering behind the crest,
///   which is what gives the tip somewhere to break *from*;
/// - the **flow**, the mixed ocean ramp streaming through the tip, drawn as a
///   rotating angular gradient masked to the band so the colours travel
///   through it instead of sitting still on it;
/// - the **spray**, a short foam cap right at the leading point.
private struct CrestHead: View {
    let shape: WindowPerimeter
    let reach: CGFloat
    let lineWidth: CGFloat
    /// False under Reduce Motion: the crest is drawn, but holds still.
    let flows: Bool

    @State private var isFlowing = false

    /// How much arc each part of the crest covers, as a fraction of the
    /// perimeter. Deliberately small: a crest that spans a whole side of the
    /// window stops being a crest and becomes a gradient again.
    private let curlSpan: CGFloat = 0.055
    private let flowSpan: CGFloat = 0.038
    private let spraySpan: CGFloat = 0.012
    /// One turn of the colours, in seconds. Slow enough to read as a swell
    /// rather than something spinning.
    private let wavePeriod: TimeInterval = 2.6

    var body: some View {
        ZStack {
            band(span: curlSpan, width: lineWidth * 2.6, blur: 5)
                .foregroundStyle(OceanTide.ocean.opacity(0.5))

            flow

            band(span: spraySpan, width: lineWidth, blur: 0.7)
                .foregroundStyle(OceanTide.foam)
        }
        .onAppear { isFlowing = flows }
    }

    /// One band of the crest — the arc from `span` behind the leading edge up
    /// to it, stroked and softened. Untinted here so callers style it.
    private func band(span: CGFloat, width: CGFloat, blur: CGFloat) -> some View {
        shape
            .trim(from: max(0, reach - span), to: reach)
            .stroke(.foreground, style: StrokeStyle(lineWidth: width, lineCap: .round))
            .blur(radius: blur)
    }

    /// The palette streaming through the crest.
    ///
    /// The colours rotate rather than the geometry: one pre-drawn angular
    /// gradient spun about the window's centre is a transform, so this body is
    /// evaluated once per progress change instead of once per frame. Masked to
    /// the crest band, which is what turns a spinning wheel of colour into
    /// water moving through one point.
    private var flow: some View {
        AngularGradient(
            gradient: Gradient(colors: [
                OceanTide.surf, OceanTide.shallow, OceanTide.foam,
                OceanTide.shallow, OceanTide.ocean, OceanTide.surf,
            ]),
            center: .center
        )
        .scaleEffect(1.5)
        .rotationEffect(.degrees(isFlowing ? 360 : 0))
        .animation(
            isFlowing ? .linear(duration: wavePeriod).repeatForever(autoreverses: false) : nil,
            value: isFlowing
        )
        .mask { band(span: flowSpan, width: lineWidth * 1.5, blur: 1.4) }
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
///
/// **Mirrored**, it runs counter-clockwise from the same point. A rounded
/// rectangle is symmetric about its vertical centre line, so flipping the
/// clockwise path across that line gives exactly the counter-clockwise one —
/// same start, same corners, same length — without building a second path.
struct WindowPerimeter: Shape {
    var cornerRadius: CGFloat
    var mirrored = false

    /// Where twelve o'clock falls in `RoundedRectangle`'s own parameterization.
    private static let topCentre: CGFloat = 0.75

    func path(in rect: CGRect) -> Path {
        let full = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .path(in: rect)
        var path = full.trimmedPath(from: Self.topCentre, to: 1)
        path.addPath(full.trimmedPath(from: 0, to: Self.topCentre))
        guard mirrored else { return path }
        return path.applying(
            CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0)
        )
    }
}
