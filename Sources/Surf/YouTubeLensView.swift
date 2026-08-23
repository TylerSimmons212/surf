import SurfCore
import SwiftUI

/// The YouTube lens: three screens over a live YouTube.
///
/// A field, a grid, a stage — and nothing else. The web view stays mounted
/// underneath the whole time, because it is doing two jobs the lens cannot do
/// without it: it is where the data comes from, and it is the only thing that
/// can play the video. What it never does again is draw.
///
/// Opaque on the first two screens, for the same reason the reader is: the
/// page underneath is exactly what the lens exists to quiet down. Transparent
/// on the third, because there the page underneath *is* the show.
struct YouTubeLensView: View {
    let tab: Tab
    @Bindable var lens: YouTubeLens

    /// Hover is suppressed while the grid is moving. A scroll drags the
    /// pointer across every card it passes, and each crossing would other-
    /// wise start its own dim-and-glyph animation — a dozen of them running
    /// at once, during the one moment the frame budget is already spent.
    @State private var isScrolling = false

    var body: some View {
        ZStack {
            if lens.phase != .watching {
                Color(nsColor: .textBackgroundColor)
            }

            switch lens.phase {
            case .searching:
                openingScreen
            case .loading:
                loadingScreen
            case .results:
                resultsScreen
            case .watching:
                YouTubeStageChrome(tab: tab, lens: lens)
            case .failed(let message):
                failureScreen(message)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lens.phase)
    }

    // MARK: - The opening: one field, and nothing to scroll

    private var openingScreen: some View {
        VStack(spacing: 22) {
            YouTubeMark(size: 34)
            YouTubeSearchField(lens: lens, isLarge: true)
                .frame(maxWidth: 620)
            Text("Search YouTube")
                .font(Typeface.figtree(size: 12, weight: 500))
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { closeButton }
    }

    private var loadingScreen: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { searchBar }
        .overlay(alignment: .topTrailing) { closeButton }
    }

    private func failureScreen(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "questionmark.video")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.title3.weight(.medium))
            Button("Search Again") { lens.startOver() }
                .buttonStyle(.glassProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { searchBar }
        .overlay(alignment: .topTrailing) { closeButton }
    }

    // MARK: - The grid

    private var resultsScreen: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(minimum: 300, maximum: 420), spacing: 22
                )],
                spacing: 30
            ) {
                ForEach(lens.results) { result in
                    YouTubeResultCard(result: result, isScrolling: isScrolling) {
                        lens.play(result)
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 44)
            // Clear of the search bar floating above.
            .padding(.top, 96)
        }
        .onScrollPhaseChange { _, phase in
            isScrolling = phase != .idle
        }
        .overlay(alignment: .top) {
            // Over the scroll rather than above it, so the grid runs under
            // the glass instead of starting below a solid strip — with a
            // short fade so what runs under it dissolves rather than being
            // sliced off by the window edge.
            LinearGradient(
                colors: [
                    Color(nsColor: .textBackgroundColor),
                    Color(nsColor: .textBackgroundColor).opacity(0),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 104)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .top) { searchBar }
        .overlay(alignment: .topTrailing) { closeButton }
    }

    private var searchBar: some View {
        YouTubeSearchField(lens: lens, isLarge: false)
            .frame(maxWidth: 560)
            .padding(.top, 16)
    }

    private var closeButton: some View {
        IconButton(
            systemName: "xmark",
            size: 11, weight: .bold, width: 26, height: 26, cornerRadius: 8,
            help: "Leave Focus (\u{21E7}\u{2318}F)"
        ) { tab.exitFocus() }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .padding(.top, 16)
        .padding(.trailing, 16)
    }
}

// MARK: - The field

/// Surf's search field, standing in for YouTube's.
///
/// An `NSTextField` rather than SwiftUI's, for the reason `SurfTextField`
/// documents: the field editor never receives a SwiftUI text colour, so typed
/// text comes out dimmer than its own placeholder.
private struct YouTubeSearchField: View {
    @Bindable var lens: YouTubeLens
    let isLarge: Bool

    @State private var text = ""
    @State private var focusToken = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: isLarge ? 16 : 13, weight: .medium))
                .foregroundStyle(.secondary)

            SurfTextField(
                text: $text,
                placeholder: "Search YouTube",
                font: .systemFont(ofSize: isLarge ? 18 : 14, weight: .regular),
                focusToken: focusToken,
                onSubmit: { lens.search(text) }
            )
            .frame(height: isLarge ? 26 : 22)

            if !text.isEmpty {
                IconButton(
                    systemName: "xmark.circle.fill",
                    size: 13, width: 20, height: 20, cornerRadius: 10,
                    help: "Clear"
                ) {
                    text = ""
                    focusToken += 1
                }
            }
        }
        .padding(.horizontal, isLarge ? 20 : 16)
        .padding(.vertical, isLarge ? 15 : 11)
        .glassEffect(
            .regular.interactive(),
            in: Capsule(style: .continuous)
        )
        .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        // The field says what the grid is showing: a results page loaded from
        // anywhere — a restored tab, a link — fills it from the address.
        .onAppear { text = lens.query }
        .onChange(of: lens.query) { _, query in
            if query != text { text = query }
        }
    }
}

// MARK: - One result

private struct YouTubeResultCard: View {
    let result: YouTubeResult
    let isScrolling: Bool
    let play: () -> Void

    @State private var isHovering = false

    /// Hover state only counts when the grid is still.
    private var showsHover: Bool { isHovering && !isScrolling }

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 10) {
                thumbnail
                metadata
            }
        }
        .buttonStyle(.plain)
        // Scale only. The shadow is static: animating a shadow's radius
        // re-rasterises the whole layer every frame of the hover, which is
        // exactly the cost a grid of seventeen cards cannot afford.
        .scaleEffect(showsHover ? 1.02 : 1)
        .animation(.easeOut(duration: 0.16), value: showsHover)
        .onHover { isHovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(result.title)
                .font(Typeface.figtree(size: 14, weight: 600))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                // Two lines always, so cards with a short title and a long
                // one keep their metadata on the same baseline.
                .frame(height: 38, alignment: .topLeading)

            HStack(spacing: 4) {
                Text(result.channel)
                    .font(Typeface.figtree(size: 12, weight: 500))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if result.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(Typeface.figtree(size: 11, weight: 400))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Views and age on one line, and neither when the video has no history
    /// yet — an unaired premiere would otherwise render a lonely separator.
    private var subtitle: String {
        [result.viewText, result.publishedText]
            .filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ")
    }

    private var thumbnail: some View {
        ThumbnailImage(address: result.thumbnailURL)
            .aspectRatio(16 / 9, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .overlay {
                // The hover affordance: the picture dims and takes a play
                // glyph, so what a click will do is never in doubt.
                ZStack {
                    Color.black.opacity(showsHover ? 0.28 : 0)
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .opacity(showsHover ? 1 : 0)
                }
                .animation(.easeOut(duration: 0.16), value: showsHover)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) { chip }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(showsHover ? 0.24 : 0.10))
            }
            // One clip, and no shadow. A shadow on a rounded-clipped image
            // costs an offscreen pass per card, and seventeen offscreen
            // passes is a scroll that stutters — the border reads the edge
            // well enough without asking the GPU for a second buffer.
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The runtime, or the live marker — never both, because a live stream
    /// has no runtime to show.
    @ViewBuilder
    private var chip: some View {
        if result.isLive {
            label("LIVE", tint: Color(red: 0.8, green: 0.13, blue: 0.13))
        } else if let duration = result.durationText {
            label(duration, tint: .black.opacity(0.78))
        }
    }

    private func label(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(7)
    }
}

// MARK: - Surf's YouTube mark

/// Drawn rather than bundled. YouTube's logo is their trademark and shipping
/// it inside another application is their decision to give, not ours — so
/// this is the shape everyone reads as "video", in Surf's own hand and in
/// their red.
struct YouTubeMark: View {
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: "play.rectangle.fill")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Color(red: 0.87, green: 0.11, blue: 0.11))
    }
}
