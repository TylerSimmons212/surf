import AppKit
import SurfCore
import SwiftUI

/// The grid of pinned-site stickers at the top of the sidebar.
///
/// Its own `View` struct, per the rule at the top of `Sidebar`: this reads the
/// current island's sticker list and the selection, so a tab loading,
/// retitling, or reporting progress never redraws the shelf. The selection is
/// unavoidable — a sticker is a tab, so it has to show when it is the one on
/// screen — but `showingStickerIDs` is built to answer that without touching
/// the tab array.
struct StickerShelf: View {
    let session: BrowserSession

    /// Tile edge. Six per row at the sidebar's width minus insets — still six
    /// at 292pt, since a seventh would need 314.
    static let tileSize: CGFloat = 38

    /// The spring that presses a new sticker down. Named here because the
    /// *mutation* has to be wrapped in it — a `.animation(value:)` on the
    /// container doesn't reliably drive child transitions, which is exactly
    /// the bug this replaces.
    static let slap = Animation.spring(response: 0.45, dampingFraction: 0.62)
    static let peel = Animation.spring(response: 0.5, dampingFraction: 0.78)

    var body: some View {
        let island = session.currentIsland
        let stickers = island.stickers
        let showing = session.showingStickerIDs

        // Always in the tree, even empty — `FlowLayout` collapses to zero
        // height with no children. Wrapping this in `if !stickers.isEmpty`
        // meant the first and last sticker never got their tile transition:
        // the whole shelf entered or left instead, as a plain fade.
        return FlowLayout(spacing: 8, rowSpacing: 10) {
            ForEach(stickers) { sticker in
                StickerTile(
                    sticker: sticker,
                    isShowing: showing.contains(sticker.id),
                    onOpen: { session.open(sticker) },
                    onOpenInNewTab: { session.openInNewTab(sticker) },
                    onOpenInSplit: { session.openInSplit(sticker) },
                    onPeel: {
                        withAnimation(Self.peel) {
                            session.removeSticker(sticker, from: island)
                        }
                    }
                )
                // A sticker arrives the way one goes on — pressed down — and
                // leaves the way one comes off: a corner lifts, the vinyl
                // curls, and it floats away.
                .transition(.asymmetric(insertion: .stickerSlapOn, removal: .stickerPeelOff))
            }
            // The drag, the gap opening ahead of it, the empty slot behind it
            // and the drop are all the system's now.
            //
            // What this replaces was not incidental: an observable context
            // holding a proposed order, a delegate per tile reordering it in
            // `dropEntered`, a second delegate catching releases in the gaps
            // between tiles, a dashed placeholder past the last sticker because
            // dropping *on* a tile takes that tile's slot and the final
            // position was otherwise unreachable, and a watchdog, because a
            // cancelled drag can end with no notification at all.
            .reorderable()
        }
        // The only part left that is ours: where the order actually lives.
        .reorderContainer(for: Sticker.self) { difference in
            guard let order = difference.reordering(stickers.map(\.id)) else { return }
            session.setStickerOrder(
                ListOrder.resequencing(stickers, into: order), in: island
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, stickers.isEmpty ? 0 : 2)
        .padding(.bottom, stickers.isEmpty ? 0 : 10)
    }
}

// MARK: - Transitions

/// The removal's second act. By the time this runs the tile has already
/// folded over itself (see `StickerTile.peel()`), so this is just the folded
/// wad being flicked away — up, back, and gone.
private struct PeelEffect: ViewModifier {
    /// 0 = laying flat (identity), 1 = fully peeled (gone).
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.3 * progress)
            .rotationEffect(.degrees(-14 * progress))
            .offset(x: -8 * progress, y: -34 * progress)
            .opacity(1 - progress)
    }
}

/// The insertion: the sticker is slapped on. It starts big, loose, and soft —
/// still in the air — and the container's bouncy spring presses it down into
/// its resting tilt.
private struct SlapEffect: ViewModifier {
    /// 0 = stuck down (identity), 1 = still airborne.
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 + 0.65 * progress)
            .rotationEffect(.degrees(-10 * progress))
            .blur(radius: 2.5 * progress)
            .opacity(1 - progress)
    }
}

extension AnyTransition {
    fileprivate static var stickerPeelOff: AnyTransition {
        .modifier(active: PeelEffect(progress: 1), identity: PeelEffect(progress: 0))
    }

    fileprivate static var stickerSlapOn: AnyTransition {
        .modifier(active: SlapEffect(progress: 1), identity: SlapEffect(progress: 0))
    }
}

// MARK: - Tile

/// One pinned site, drawn as a die-cut sticker: a white vinyl backing with a
/// soft edge shadow, the site's favicon printed on it, and a slight lean that
/// is the sticker's own (deterministic per sticker, so nothing shuffles between
/// launches). Hovering straightens and lifts it, like a thumb testing a corner.
private struct StickerTile: View {
    let sticker: Sticker
    /// Whether this sticker's tab is the page on screen. A sticker is a tab,
    /// so it needs the same "you are here" the tab rows get.
    let isShowing: Bool
    /// Whether this tile is the one being carried, in which case it draws as
    /// the gap it will drop into.
    let onOpen: () -> Void
    let onOpenInNewTab: () -> Void
    let onOpenInSplit: () -> Void
    let onPeel: () -> Void

    @State private var isHovering = false
    /// 0 = stuck down flat; 1 = fully folded over itself, ready to be flicked
    /// away. Driven only by "Peel Off" — hovering never starts a peel, so the
    /// animation stays the reward for actually removing one.
    @State private var peelProgress: CGFloat = 0
    /// Set when a fetch for a never-visited host lands, since `FaviconStore`'s
    /// cache is not observable — the state change is what redraws the tile.
    @State private var fetchedIcon: NSImage?
    /// What the icon turned out to be made of: a solid plate to match, or just
    /// ink to wash the vinyl with.
    @State private var press = StickerPrint()

    var body: some View {
        let icon = fetchedIcon ?? FaviconStore.shared.cachedIcon(forHost: sticker.host)

        // The colour printed across the vinyl, when the icon isn't bringing its
        // own background: the icon's ink when it has any; the host's stable hue
        // while no icon exists (so the monogram tile is the same object, just
        // awaiting its art); nothing for an achromatic mark, which gets clean
        // white — a colour invented for a black wordmark would be one the site
        // never chose.
        let wash: Color? = press.plate == nil
            ? press.ink.map(Color.init) ?? (icon == nil
                ? Color(hue: sticker.fallbackHue, saturation: 0.5, brightness: 0.8)
                : nil)
            : nil

        Button(action: onOpen) {
            // The peel. As `peelProgress` runs 0→1 the fold line sweeps from
            // the bottom-trailing corner across the whole sticker, and the
            // vinyl curls back over itself along it. (After bsehovac's peel.)
            PeelingSticker(progress: peelProgress, size: StickerShelf.tileSize) {
                ZStack {
                    backing(plate: press.plate.map(Color.init), wash: wash)
                    art(icon)
                }
                .compositingGroup()
            }
            .frame(width: StickerShelf.tileSize, height: StickerShelf.tileSize)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PressedTile())
        // Rounds the floating snapshot to match the sticker it left.
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            if isShowing {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    // Held off the edge, so the ring reads against a plate of
                    // any colour instead of blending into a dark one.
                    .padding(-3)
                    .transition(.opacity.combined(with: .scale(scale: 0.86)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isShowing)
        .rotationEffect(.degrees(isHovering ? 0 : sticker.tiltDegrees))
        .scaleEffect(isHovering ? 1.1 : 1)
        // A lifted sticker throws a longer, softer shadow than one laying flat.
        .shadow(
            color: .black.opacity(isHovering ? 0.26 : 0.16),
            radius: isHovering ? 6 : 2.5,
            y: isHovering ? 4 : 1.5
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: isHovering)
        // The icon blooming in and its ink soaking outward share one motion,
        // so the print arrives as a single event rather than two.
        .animation(.spring(response: 0.5, dampingFraction: 0.72), value: fetchedIcon)
        .animation(.easeOut(duration: 0.6), value: press)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open in New Tab", action: onOpenInNewTab)
            Button("Open in Split", action: onOpenInSplit)

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sticker.url, forType: .string)
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            Divider()
            Button(role: .destructive, action: peel) {
                Label("Peel Off", systemImage: "xmark.circle")
            }
        }
        // A half-peeled sticker isn't a button any more.
        .allowsHitTesting(peelProgress == 0)
        .help(sticker.title.isEmpty ? sticker.host : sticker.title)
        .task(id: sticker.host) { await load() }
    }

    /// The whole peel, in order: fold the sticker over itself, then hand the
    /// model the removal — whose transition flicks the folded wad away.
    private func peel() {
        withAnimation(.easeIn(duration: 0.5)) { peelProgress = 1 }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.52))
            onPeel()
        }
    }

    /// The vinyl, with the icon's ink printed right across it — one surface,
    /// not a card with a chip resting on top.
    ///
    /// The wash runs corner to corner so the icon's colour *is* the sticker's
    /// colour. When the ink is unknown (or the mark is achromatic and has no
    /// colour worth borrowing), the vinyl falls back to the host's stable hue
    /// for the monogram case, or clean white for a colourless logo.
    private func backing(plate: Color?, wash: Color?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return shape
            // A plated icon brings its own background, so the vinyl becomes
            // that colour and the icon's edges have nothing to sit against —
            // the seam that made the art look stuck onto the sticker rather
            // than printed on it simply isn't there any more.
            .fill(plate ?? Color.white)
            .overlay {
                // The vinyl's sheen, as light rather than as white, so the
                // same top-lit fall-off reads on a plate of any colour.
                shape.fill(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .black.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.softLight)
            }
            .overlay {
                // The print. Deeper at the top-left where the vinyl catches
                // light, thinning toward the far corner — the same direction
                // as the vinyl's own sheen, so wash and backing read as one
                // material.
                if let wash {
                    shape.fill(
                        LinearGradient(
                            colors: [wash.opacity(0.42), wash.opacity(0.14)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .transition(.opacity)
                }
            }
            .overlay {
                // A hairline so the white edge doesn't dissolve into a light
                // sidebar.
                shape.strokeBorder(Color.black.opacity(0.09), lineWidth: 0.5)
            }
    }

    /// The printed art: the favicon large on the vinyl, or a lettered monogram
    /// printed the same way while none exists.
    @ViewBuilder
    private func art(_ icon: NSImage?) -> some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                // Most of the tile, so the icon is the sticker rather than a
                // decoration on one. No clip shape: favicons carry their own
                // silhouettes, and cropping them re-introduces the pasted-on
                // look this replaces.
                .frame(width: 24, height: 24)
                // Blooms in like ink soaking into the vinyl, rather than
                // popping over the monogram it replaces.
                .transition(
                    .scale(scale: 0.4)
                        .combined(with: .opacity)
                        .combined(with: .modifier(
                            active: BlurEffect(radius: 5),
                            identity: BlurEffect(radius: 0)
                        ))
                )
        } else {
            // The monogram is printed like the icon would be — a letter in the
            // host's ink, straight on the vinyl — so a sticker doesn't change
            // material when its icon arrives.
            Text(sticker.fallbackInitial)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    Color(
                        hue: sticker.fallbackHue,
                        saturation: 0.6,
                        brightness: 0.52
                    )
                )
                .transition(.opacity)
        }
    }

    /// Fetches an icon for a host with nothing cached — the pinned-but-never-
    /// visited case, which `FaviconStore` otherwise only fills from a live
    /// page — then samples whichever icon we ended up with for its ink.
    private func load() async {
        let store = FaviconStore.shared
        var icon = store.cachedIcon(forHost: sticker.host)

        if icon == nil,
           store.shouldFetch(forHost: sticker.host),
           let origin = sticker.origin,
           let href = FaviconPicker.best(from: [], origin: origin) {
            icon = await store.fetchIcon(from: href, host: sticker.host)
            fetchedIcon = icon
        }

        if let icon, press == StickerPrint() {
            press = StickerPress.print(of: icon, host: sticker.host)
        }
    }
}

// MARK: - Ink sampling

/// What a favicon is made of, as far as the vinyl underneath it cares.
///
/// The two are exclusive by construction. A plated icon needs no wash — the
/// vinyl is already wearing the icon's own background — and an unplated one
/// has no plate to match.
private struct StickerPrint: Equatable {
    /// The solid background the icon is drawn on, when it has one. The vinyl
    /// takes this colour exactly, so the icon's edges disappear into it.
    var plate: SRGB?
    /// The icon's own colour, for an icon that floats on transparency and so
    /// has no background to match. Nil for an achromatic mark, which has no
    /// colour worth borrowing.
    var ink: SRGB?

    /// How strongly the ink wash is laid on at its deepest corner.
    static let washAlpha = 0.42

    /// Roughly how light the vinyl ends up, for deciding how the gloss has to
    /// be drawn to be seen on it.
    func vinylLuminance(hasIcon: Bool, fallbackHue: Double) -> Double {
        if let plate { return Contrast.relativeLuminance(plate) }
        if let ink {
            // Averaged over the wash's fall-off rather than its deepest point.
            let representative = ink.composited(over: SRGB(r: 1, g: 1, b: 1), alpha: 0.28)
            return Contrast.relativeLuminance(representative)
        }
        // The monogram tile wears a light pastel by construction; anything else
        // is clean white vinyl.
        return hasIcon ? 1 : 0.55
    }
}

/// Reads a favicon for the colour its sticker should be.
///
/// Reuses `IconPlate` and `ImageAnalysis` — the same judgements the rest of the
/// app makes about images — rather than a bare pixel average, because the
/// average of a multi-coloured logo is mud, an achromatic mark has no colour
/// worth borrowing, and a plate is a question about the edges rather than the
/// mean.
@MainActor
private enum StickerPress {
    /// Sampled once per host and remembered: the icons are tiny, but view
    /// bodies are hot and CGContext work doesn't belong in them.
    private static var cache: [String: StickerPrint] = [:]

    static func print(of image: NSImage, host: String) -> StickerPrint {
        if let known = cache[host] { return known }
        let sampled = sample(image)
        cache[host] = sampled
        return sampled
    }

    private static func sample(_ image: NSImage) -> StickerPrint {
        let side = 16
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return StickerPrint() }

        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return StickerPrint()
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: rect)

        guard let data = context.data else { return StickerPrint() }
        var bytes = [UInt8](
            UnsafeRawBufferPointer(start: data, count: side * side * 4)
        )

        // A bitmap context can only hand back premultiplied components, and
        // both analyses are specified on unpremultiplied ones. Left as drawn,
        // the anti-aliased edge of a mark on transparency arrives darkened
        // toward black — and `ImageAnalysis` then weights by alpha a second
        // time, pulling the sampled colour toward black twice over.
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Double(bytes[pixel + 3]) / 255
            guard alpha > 0, alpha < 1 else { continue }
            for channel in 0..<3 {
                let value = Double(bytes[pixel + channel]) / 255 / alpha
                bytes[pixel + channel] = UInt8((min(1, value) * 255).rounded())
            }
        }

        if let plate = IconPlate.detect(rgba: bytes, side: side) {
            return StickerPrint(plate: plate, ink: nil)
        }

        guard let verdict = ImageAnalysis.verdict(rgba: bytes), !verdict.isAchromatic else {
            return StickerPrint()
        }
        return StickerPrint(plate: nil, ink: verdict.artwork)
    }
}

extension Color {
    fileprivate init(_ srgb: SRGB) {
        self.init(red: srgb.r, green: srgb.g, blue: srgb.b)
    }
}

// MARK: - Corner fold

/// A sticker that can be peeled: flat views at rest, a `Canvas` while it peels.
///
/// The peel used to be a mask and a flat triangle — the face cut away along
/// the crease and a gradient-filled shape laid over it — which read as paper
/// folding rather than vinyl curling. Drawing it lets the lifted part be shaded
/// like a curl: dark deep in the bend, a highlight where the curve catches the
/// light, then the flat back easing off toward the tip. The flap is
/// foreshortened mid-peel, as though bending up out of the surface, and it
/// throws a shadow across what's still stuck down.
///
/// Animatable, so the body is asked for again at every step of the peel with
/// the progress so far, and can be plain views at zero. The shelf holds a dozen
/// stickers and only one is ever peeling; the rest shouldn't be canvases.
private struct PeelingSticker<Face: View>: View, Animatable {
    /// 0 = stuck down flat; 1 = fully folded over itself.
    var progress: CGFloat
    let size: CGFloat
    let face: Face

    init(progress: CGFloat, size: CGFloat, @ViewBuilder face: () -> Face) {
        self.progress = progress
        self.size = size
        self.face = face()
    }

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        if progress <= 0 {
            face.frame(width: size, height: size)
        } else {
            // Three tiles across, the sticker in the middle: past halfway the
            // folded part overhangs the tile's top-leading edge, and a canvas
            // only draws inside its own bounds. The outer frame keeps the
            // sticker's own size for layout, so the shelf doesn't move.
            Canvas { context, canvasSize in
                draw(in: &context, canvas: canvasSize)
            } symbols: {
                face.frame(width: size, height: size).tag(0)
            }
            .frame(width: size * 3, height: size * 3)
            .frame(width: size, height: size)
        }
    }

    private func draw(in context: inout GraphicsContext, canvas: CGSize) {
        let tile = CGRect(x: size, y: size, width: size, height: size)
        // How far the crease has swept: the full sweep is both legs of the
        // tile, which is when the last of the front is gone.
        let fold = progress * size * 2
        // The crease is x + y = crease in the canvas's coordinates; `n` is the
        // unit normal pointing from it toward the bottom-trailing corner.
        let crease = creaseConstant(fold: fold, in: tile) + tile.minX + tile.minY
        let n = CGVector(dx: 1 / 2.squareRoot(), dy: 1 / 2.squareRoot())
        let onCrease = CGPoint(x: crease / 2, y: crease / 2)
        // Lifted highest in the middle of the peel, flat again once it has
        // folded right over.
        let lift = sin(.pi * min(progress, 1))

        // What's still stuck down.
        let stuck = FoldCutout(fold: fold).path(in: tile)
        if let symbol = context.resolveSymbol(id: 0) {
            var face = context
            face.clip(to: stuck)
            face.draw(symbol, in: tile)
        }

        // The crease's own shadow, on the stuck side: the curl blocks the light
        // there, darkest right at the bend.
        var creaseShade = context
        creaseShade.clip(to: stuck)
        let shadeDepth = 3 + 5 * lift
        creaseShade.fill(
            Path(CGRect(origin: .zero, size: canvas)),
            with: .linearGradient(
                Gradient(colors: [.black.opacity(0.28 * lift + 0.08), .black.opacity(0)]),
                startPoint: onCrease,
                endPoint: CGPoint(x: onCrease.x - n.dx * shadeDepth, y: onCrease.y - n.dy * shadeDepth)
            )
        )

        // The flap: what's peeled, folded back over the sticker — squashed
        // toward the crease mid-peel, since the part nearest the bend is
        // standing up off the surface and is seen end-on.
        let squash = 1 - 0.22 * lift
        let a = (1 - squash) / 2
        let foreshorten = CGAffineTransform(
            a: 1 - a, b: -a, c: -a, d: 1 - a,
            tx: a * crease, ty: a * crease
        )
        let flap = FoldUnderside(fold: fold).path(in: tile).applying(foreshorten)
        guard !flap.isEmpty else { return }

        // Raised off the sticker, so it shades what's under it. Thrown toward
        // the crease, away from a light up and to the left.
        context.drawLayer { shadow in
            shadow.addFilter(.blur(radius: 1.5 + 2.5 * lift))
            shadow.translateBy(x: 1 + 2 * lift, y: 1.5 + 2.5 * lift)
            shadow.fill(flap, with: .color(.black.opacity(0.22 + 0.12 * lift)))
        }

        // The adhesive back, shaded across the curl. Measured from the crease
        // out to the flap's far tip.
        let depth = max(1, fold / 2.squareRoot() * squash)
        context.fill(
            flap,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(white: 0.6), location: 0),
                    .init(color: .white, location: 0.14),
                    .init(color: Color(white: 0.97), location: 0.4),
                    .init(color: Color(white: 0.8), location: 1),
                ]),
                startPoint: onCrease,
                endPoint: CGPoint(x: onCrease.x - n.dx * depth, y: onCrease.y - n.dy * depth)
            )
        )
        // The vinyl's cut edge, catching the light along the flap's rim.
        context.stroke(flap, with: .color(.white.opacity(0.6)), lineWidth: 0.5)
    }
}

/// The fold line is `x + y = c` in the tile's local coordinates, sweeping from
/// the bottom-trailing corner (`c = w + h`, fold = 0) up across the whole
/// sticker (`c = 0`, fully folded). Shared by the mask and the underside so the
/// two can never disagree about where the crease is.
private func creaseConstant(fold: CGFloat, in rect: CGRect) -> CGFloat {
    rect.width + rect.height - fold
}

/// What's still stuck down: the part of the tile on the near side of the
/// crease. At zero fold the crease sits exactly on the corner and the mask
/// passes everything.
private struct FoldCutout: Shape {
    var fold: CGFloat

    var animatableData: CGFloat {
        get { fold }
        set { fold = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let c = creaseConstant(fold: fold, in: rect)
        guard c > 0 else { return Path() }
        let w = rect.width, h = rect.height
        var path = Path()

        if c >= w && c >= h {
            // Crease crosses the trailing and bottom edges: a clipped corner.
            path.move(to: local(0, 0, rect))
            path.addLine(to: local(w, 0, rect))
            path.addLine(to: local(w, c - w, rect))
            path.addLine(to: local(c - h, h, rect))
            path.addLine(to: local(0, h, rect))
        } else {
            // Crease crosses the top and leading edges: only a corner remains.
            path.move(to: local(0, 0, rect))
            path.addLine(to: local(min(c, w), 0, rect))
            path.addLine(to: local(0, min(c, h), rect))
        }
        path.closeSubpath()
        return path
    }
}

/// The adhesive underside: the peeled part folded back over the sticker — the
/// mirror of the cut-away region across the crease. Past halfway its tail
/// overhangs the tile's top-leading edge, the way half-peeled vinyl does.
private struct FoldUnderside: Shape {
    var fold: CGFloat

    var animatableData: CGFloat {
        get { fold }
        set { fold = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard fold > 0.5 else { return Path() }
        let c = creaseConstant(fold: fold, in: rect)
        let w = rect.width, h = rect.height
        var path = Path()

        // Reflection across x + y = c maps (x, y) to (c - y, c - x).
        if c >= w && c >= h {
            // The peeled triangle, folded over.
            path.move(to: local(w, c - w, rect))
            path.addLine(to: local(c - h, h, rect))
            path.addLine(to: local(c - h, c - w, rect))
        } else {
            // Past halfway: the folded part is a pentagon whose far corners
            // hang off the tile.
            path.move(to: local(min(c, w), 0, rect))
            path.addLine(to: local(c, c - w, rect))
            path.addLine(to: local(c - h, c - w, rect))
            path.addLine(to: local(c - h, c, rect))
            path.addLine(to: local(0, min(c, h), rect))
        }
        path.closeSubpath()
        return path
    }
}

private func local(_ x: CGFloat, _ y: CGFloat, _ rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + x, y: rect.minY + y)
}

/// Blur as a transition modifier, which SwiftUI doesn't ship.
private struct BlurEffect: ViewModifier {
    let radius: Double
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

/// The squish when a sticker is pressed.
///
/// A `ButtonStyle` rather than a simultaneous `DragGesture`, which is how this
/// read the press before the shelf could be reordered. A zero-distance drag
/// gesture competes with the drag-and-drop one for the same movement, and the
/// press state has no reliable end when the drag wins — leaving a sticker stuck
/// looking pressed for as long as it was carried. The style is told by SwiftUI
/// instead, and cannot disagree with the gesture that actually happened.
private struct PressedTile: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(
                .spring(response: 0.2, dampingFraction: 0.55),
                value: configuration.isPressed
            )
    }
}
