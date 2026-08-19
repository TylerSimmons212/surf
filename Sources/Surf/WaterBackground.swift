import SwiftUI

/// The bottom of the home screen, as water for the board to sit on.
///
/// A port of the "Simple CSS Waves" pen, kept faithful to its geometry because
/// the geometry is the reason it works. Four copies of one curve, offset
/// slightly in depth and each drifting at its own speed — the layers slide past
/// one another and the combination never lines up the same way twice, which is
/// what reads as water. Summed sine waves were the first attempt here and read
/// as a moving squiggle: one period, plainly visible, doing the same thing
/// forever.
///
/// The original's units are kept rather than converted to points. It is drawn
/// in a 150 x 28 box stretched to fill, so the wave is always the same shape
/// relative to the window instead of getting choppy on a wide one.
struct WaterBackground: View {

    /// Depth offset, seconds for one pass, start offset, and how solid.
    ///
    /// The four periods share no common factor worth the name, so the layers
    /// take about seven minutes to return to the same arrangement.
    private static let layers: [(depth: CGFloat, period: Double, delay: Double, opacity: Double)] = [
        (0, 7, -2, 0.70),
        (3, 10, -3, 0.50),
        (5, 13, -4, 0.30),
        (7, 20, -5, 1.00),
    ]

    /// One wavelength, in the original's units — and the distance each layer
    /// travels per pass is 175 of them. Not a coincidence and not quite equal:
    /// a pass that covers one wavelength lands on a curve identical to the one
    /// it started on, so the jump back is invisible.
    private static let wavelength: CGFloat = 176
    private static let travel: CGFloat = 175
    private static let start: CGFloat = -90

    /// Where the surface sits, as a fraction of the height.
    var surface: Double = 0.5

    /// The water's own colour at the surface, fading out below.
    var tint = Color(red: 0.44, green: 0.78, blue: 0.98)

    var body: some View {
        // 30fps rather than the display's rate: this is a backdrop running
        // behind whatever the browser is actually doing.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let band = min(max(size.height * 0.17, 90), 155)

                // Body under the waves. Without it the layers fade out around
                // two thirds down and the bottom of the window is just page
                // again — waves floating in the dark rather than the surface of
                // something. Starts below the lowest trough, so it never shows
                // as an edge above the water.
                let bodyTop = size.height * surface
                context.fill(
                    Path(CGRect(x: 0, y: bodyTop, width: size.width,
                                height: size.height - bodyTop)),
                    with: .linearGradient(
                        // Ramped in rather than starting solid: a flat top on
                        // this rectangle draws a hard line straight across the
                        // window wherever the waves above it have gone
                        // transparent.
                        Gradient(stops: [
                            .init(color: tint.opacity(0), location: 0),
                            .init(color: tint.opacity(0.26), location: 0.30),
                            .init(color: .clear, location: 1),
                        ]),
                        startPoint: CGPoint(x: 0, y: bodyTop),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )

                for layer in Self.layers {
                    let progress = ((t - layer.delay) / layer.period).truncatingRemainder(dividingBy: 1)
                    let shift = Self.start + Self.travel * CGFloat(progress < 0 ? progress + 1 : progress)
                    context.fill(
                        Self.wave(size: size, surface: surface, band: band,
                                  depth: layer.depth, shift: shift),
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: tint.opacity(0.46 * layer.opacity), location: 0),
                                .init(color: tint.opacity(0.30 * layer.opacity), location: 0.45),
                                .init(color: .clear, location: 1),
                            ]),
                            startPoint: CGPoint(x: 0, y: size.height * surface),
                            endPoint: CGPoint(x: 0, y: size.height)
                        )
                    )
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// One layer's surface, closed down to the bottom edge so it can be filled.
    ///
    /// The curve is the pen's: a half-period is 88 units wide and 18 deep, with
    /// its handles at 30 and 58 across. Alternating the sign of the depth is
    /// what the original's chain of smooth curves works out to, and stating it
    /// directly means every segment is the same four numbers.
    static func wave(
        size: CGSize, surface: Double, band: CGFloat, depth: CGFloat, shift: CGFloat
    ) -> Path {
        let xScale = size.width / 150
        let yScale = band / 28
        // The curve crests at 26 and troughs at 44, so its mean is 35 — and it
        // is the mean that has to land on the waterline. Hanging the box's top
        // edge there instead put the whole sea about a hundred points low, and
        // the board rode above it with a gap you could see.
        let top = size.height * surface - 11 * yScale
        func px(_ ux: CGFloat) -> CGFloat { (ux + shift) * xScale }
        func py(_ uy: CGFloat) -> CGFloat { top + (uy + depth - 24) * yScale }

        // Wide enough that the drift never pulls an end into view.
        let first: CGFloat = -352, last: CGFloat = 528
        var path = Path()
        var x = first
        var y: CGFloat = 44
        var rising = true
        path.move(to: CGPoint(x: px(x), y: py(y)))
        while x < last {
            let dy: CGFloat = rising ? -18 : 18
            path.addCurve(
                to: CGPoint(x: px(x + 88), y: py(y + dy)),
                control1: CGPoint(x: px(x + 30), y: py(y)),
                control2: CGPoint(x: px(x + 58), y: py(y + dy))
            )
            x += 88
            y += dy
            rising.toggle()
        }
        path.addLine(to: CGPoint(x: px(last), y: size.height))
        path.addLine(to: CGPoint(x: px(first), y: size.height))
        path.closeSubpath()
        return path
    }
}
