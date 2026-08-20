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

    /// Tile edge. Six per row at the sidebar's 264pt minus insets.
    static let tileSize: CGFloat = 38

    /// The spring that presses a new sticker down. Named here because the
    /// *mutation* has to be wrapped in it — a `.animation(value:)` on the
    /// container doesn't reliably drive child transitions, which is exactly
    /// the bug this replaces.
    static let slap = Animation.spring(response: 0.45, dampingFraction: 0.62)
    static let peel = Animation.spring(response: 0.5, dampingFraction: 0.78)

    /// The in-flight reorder. `@State` rather than window-owned like the tab
    /// drag: a sticker only ever reorders within the shelf, so nothing outside
    /// it needs to watch.
    @State private var drag = StickerDragContext()

    var body: some View {
        let island = session.currentIsland
        // The proposed order while a drag is in flight, the real one otherwise.
        // Nothing is written back until the drag is actually dropped.
        let stickers = drag.preview ?? island.stickers
        let showing = session.showingStickerIDs

        // Always in the tree, even empty — `FlowLayout` collapses to zero
        // height with no children. Wrapping this in `if !stickers.isEmpty`
        // meant the first and last sticker never got their tile transition:
        // the whole shelf entered or left instead, as a plain fade.
        FlowLayout(spacing: 8, rowSpacing: 10) {
            ForEach(stickers) { sticker in
                StickerTile(
                    sticker: sticker,
                    isShowing: showing.contains(sticker.id),
                    isDragged: drag.draggedID == sticker.id,
                    onOpen: { session.open(sticker) },
                    onPeel: {
                        withAnimation(Self.peel) {
                            session.removeSticker(sticker, from: island)
                        }
                    }
                )
                .onDrag {
                    drag.begin(sticker.id, in: island.stickers) { order in
                        session.setStickerOrder(order, in: island)
                    }
                }
                // The reorder happens in `dropEntered`, not on release — the
                // gap slides through the shelf as the drag crosses tiles, so
                // the drop is letting go of an order already on screen.
                .onDrop(of: [.text], delegate: StickerReorderDropDelegate(
                    targetID: sticker.id,
                    drag: drag
                ))
                // A sticker arrives the way one goes on — pressed down — and
                // leaves the way one comes off: a corner lifts, the vinyl
                // curls, and it floats away.
                .transition(.asymmetric(insertion: .stickerSlapOn, removal: .stickerPeelOff))
            }

            // The end of the shelf, which otherwise has no tile to aim at.
            // Dropping *on* a tile takes that tile's slot, so without somewhere
            // past the last one the final position is the one place a drag
            // can't reach.
            if drag.isDragging {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                    .frame(width: Self.tileSize, height: Self.tileSize)
                    .onDrop(of: [.text], delegate: StickerReorderDropDelegate(
                        targetID: nil,
                        drag: drag
                    ))
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .animation(.snappy(duration: 0.2, extraBounce: 0), value: drag.isDragging)
        // Catches releases in the gaps between tiles, which are not targets of
        // their own. Without it, letting go a few points wide of a sticker
        // reads to the drag as "no drop" and throws the reorder away — the
        // same ending as Esc, from what felt like a perfectly good drop.
        .onDrop(of: [.text], delegate: StickerShelfDropDelegate(drag: drag))
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
    let isDragged: Bool
    let onOpen: () -> Void
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
            ZStack {
                backing(plate: press.plate.map(Color.init), wash: wash)
                art(icon)
            }
            .compositingGroup()
            // The peel. As `peelProgress` runs 0→1 the fold line sweeps from
            // the bottom-trailing corner across the whole sticker: the art is
            // cut away along the diagonal and the white adhesive underside
            // folds over it, its tail overhanging the tile's edge the way
            // half-peeled vinyl does. (After bsehovac's peel.)
            .mask { FoldCutout(fold: foldSize) }
            .overlay {
                FoldUnderside(fold: foldSize)
                    .fill(
                        LinearGradient(
                            colors: [Color.white, Color(white: 0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    // Thrown back onto the sticker, where the lifted corner
                    // would shade it.
                    .shadow(color: .black.opacity(0.3), radius: 1.5, x: -1, y: -1)
            }
            .frame(width: StickerShelf.tileSize, height: StickerShelf.tileSize)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PressedTile())
        // An empty slot while carried: same footprint, no content, so the
        // sticker appears once and the gap is where it lands. `opacity`, not
        // `hidden`, so the slot keeps taking drops.
        .opacity(isDragged ? 0 : 1)
        .background {
            if isDragged {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            }
        }
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

    /// How far the fold line has swept. Zero until "Peel Off" — the cutout's
    /// diagonal sits exactly on the corner, so nothing shows. The full sweep
    /// is both legs of the tile, which is when the last of the front is gone.
    private var foldSize: CGFloat { peelProgress * StickerShelf.tileSize * 2 }

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

// MARK: - Reordering

/// Tracks the in-flight sticker drag, and the order it is proposing.
///
/// The shelf itself is never reordered while a drag is in flight — this holds
/// the proposed order and the shelf draws from it, and only a real drop writes
/// it back. That is a correctness decision, not a tidiness one: a drag can end
/// with no notification at all, and reordering the model live means such an
/// ending leaves the change made with nothing left to undo it. Measured, on a
/// cancelled drag: `performDrop` never fires, and neither does the released
/// item provider that the tab list leans on to notice the same thing. Holding
/// the proposal here makes cancelling free — the preview is dropped and the
/// shelf is already right, whether or not anything told us it was over.
///
/// Deliberately separate from `TabDragContext`. Both carry a UUID as text, so a
/// tab dragged over the shelf would otherwise be read as a sticker being
/// reordered — two collections, two contexts, and each delegate sees nothing
/// being carried in the other's drag and does nothing.
@MainActor
@Observable
final class StickerDragContext {
    private(set) var draggedID: Sticker.ID?

    /// The order being proposed, which is what the shelf draws while a drag is
    /// in flight. Nil when nothing is being carried, and the shelf falls back
    /// to the real one.
    private(set) var preview: [Sticker]?

    var isDragging: Bool { draggedID != nil }

    @ObservationIgnored private var onCommit: (@MainActor ([Sticker]) -> Void)?
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    func begin(
        _ id: Sticker.ID,
        in order: [Sticker],
        onCommit: @escaping @MainActor ([Sticker]) -> Void
    ) -> NSItemProvider {
        draggedID = id
        preview = order
        self.onCommit = onCommit
        startWatchdog()
        return NSItemProvider(object: id.uuidString as NSString)
    }

    /// Proposes the dragged sticker into `targetID`'s slot.
    func move(before targetID: Sticker.ID) {
        guard let draggedID, let current = preview,
              let moved = Sticker.moving(draggedID, before: targetID, in: current)
        else { return }
        preview = moved
    }

    func moveToEnd() {
        guard let draggedID, let current = preview,
              let moved = Sticker.movingToEnd(draggedID, in: current)
        else { return }
        preview = moved
    }

    /// A real drop: the proposed order becomes the shelf's own.
    func drop() {
        let order = preview
        let commit = onCommit
        clear()
        if let order { commit?(order) }
    }

    /// No drop — Esc, or a release somewhere that isn't a target. The proposal
    /// is thrown away, and the shelf was never anything but correct underneath
    /// it.
    func cancel() {
        clear()
    }

    private func clear() {
        watchdog?.cancel()
        watchdog = nil
        draggedID = nil
        preview = nil
        onCommit = nil
    }

    /// Notices the drag ending when nothing reports it.
    ///
    /// The only reliable fact available is whether a mouse button is still
    /// down: SwiftUI does not call `performDrop` for a cancelled drag, and the
    /// item provider whose release is supposed to stand in for that was
    /// measured never being released at all. A drop, when there is one, lands
    /// on release too — so the button coming up is not by itself an answer, and
    /// this waits a moment afterwards to let one arrive before concluding that
    /// none will.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            // The button is down as the drag begins, but the closure can run
            // either side of that; a grace period stops the watchdog reading
            // its own start as an ending.
            try? await Task.sleep(for: .milliseconds(300))
            while !Task.isCancelled, NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(60))
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.isDragging else { return }
            withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
                self.cancel()
            }
        }
    }
}

/// Proposes a new order as a drag crosses the shelf's tiles.
///
/// One delegate per tile (`targetID` set) plus one on the slot past the last
/// (`targetID` nil, meaning "the end"). The moved sticker is tracked in
/// `StickerDragContext` rather than decoded from the item provider, because
/// `dropEntered` is synchronous and provider loading is not.
private struct StickerReorderDropDelegate: DropDelegate {
    /// The sticker whose slot the dragged one should take — nil for "the end".
    let targetID: Sticker.ID?
    let drag: StickerDragContext

    func dropEntered(info: DropInfo) {
        guard let draggedID = drag.draggedID, draggedID != targetID else { return }
        // Short and bounceless, matching the tab list: crossing tiles briskly
        // fires this once per tile, and a springy curve leaves each crossing
        // still settling as the next arrives.
        withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
            if let targetID {
                drag.move(before: targetID)
            } else {
                drag.moveToEnd()
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Move, not copy — no green plus badge on the cursor.
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(.snappy(duration: 0.2, extraBounce: 0)) { drag.drop() }
        return true
    }
}

/// Catches a release that lands on the shelf but not on any tile.
///
/// Only ends the drag — where the sticker goes was already decided by the tile
/// delegates as the drag crossed them, and this is the difference between a
/// drop that keeps that and a cancel that throws it away. Without it, letting
/// go a few points wide of a tile reads as no drop at all.
private struct StickerShelfDropDelegate: DropDelegate {
    let drag: StickerDragContext

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(.snappy(duration: 0.2, extraBounce: 0)) { drag.drop() }
        return true
    }
}
