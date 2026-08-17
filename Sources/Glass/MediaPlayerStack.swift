import SwiftUI

/// Now-playing controls at the foot of the sidebar.
///
/// One row per tab holding media, drawn as a stack of cards. Collapsed, only
/// the active tab's row is visible — the rest sit hidden directly behind it,
/// announced by a count chip. Hovering fans them into full rows.
struct MediaPlayerStack: View {
    let session: BrowserSession

    @State private var isExpanded = false

    /// Fixed rather than measured: rows are positioned by offset, and reading
    /// back a dynamic height needs a geometry round-trip that lands a frame
    /// late and makes the fan-out jitter.
    private let rowHeight: CGFloat = 54
    private let rowSpacing: CGFloat = 4

    private var tabs: [Tab] { session.mediaTabs }

    var body: some View {
        if let primary = tabs.first {
            let others = Array(tabs.dropFirst())

            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    // Reversed so the nearest card draws last and lands on top.
                    ForEach(Array(others.enumerated()).reversed(), id: \.element.id) { index, tab in
                        MediaRow(tab: tab, session: session, isPrimary: false)
                            .frame(height: rowHeight)
                            .offset(y: offset(forCardAt: index))
                            .scaleEffect(cardScale(index), anchor: .bottom)
                            .opacity(cardOpacity(index))
                            // Collapsed cards are decoration; only the front row
                            // should take clicks.
                            .allowsHitTesting(isExpanded)
                            .zIndex(-Double(index))
                    }

                    MediaRow(
                        tab: primary,
                        session: session,
                        isPrimary: true,
                        stackedCount: isExpanded ? 0 : others.count
                    )
                    .frame(height: rowHeight)
                    .zIndex(1)
                }
                .frame(height: stackHeight(otherCount: others.count), alignment: .bottom)
            }
            .padding(.bottom, 8)
            .onHover { hovering in
                guard !others.isEmpty else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                    isExpanded = hovering
                }
            }
        }
    }

    /// Expanded, rows sit in a column above the front one. Collapsed, they sit
    /// exactly behind it — see `cardOpacity` for why they're hidden outright.
    private func offset(forCardAt index: Int) -> CGFloat {
        isExpanded ? -(rowHeight + rowSpacing) * CGFloat(index + 1) : 0
    }

    /// Slightly narrower on the way in, so the fan-out reads as cards springing
    /// forward rather than rows appearing from nowhere.
    private func cardScale(_ index: Int) -> CGFloat {
        isExpanded ? 1 : 0.94
    }

    /// Fully hidden when collapsed rather than dimmed.
    ///
    /// Materials are translucent to their own siblings, so a partly-visible
    /// card still smudges through the row in front no matter what background
    /// sits between them. Zero opacity is the only way to be certain nothing
    /// shows through; the count chip carries the affordance instead.
    private func cardOpacity(_ index: Int) -> Double {
        isExpanded ? 1 : 0
    }

    private func stackHeight(otherCount: Int) -> CGFloat {
        guard isExpanded, otherCount > 0 else { return rowHeight }
        return rowHeight * CGFloat(otherCount + 1) + rowSpacing * CGFloat(otherCount)
    }
}

/// A single tab's media controls.
///
/// The front row carries the full set; stacked rows carry play/pause only.
/// Clicking any row selects that tab, which promotes it to the front — so the
/// full controls are always one click away rather than crammed into a column
/// that's only a few hundred points wide.
struct MediaRow: View {
    let tab: Tab
    let session: BrowserSession
    let isPrimary: Bool
    /// How many other tabs are holding media, shown as a chip on the front row
    /// so the hidden stack is still discoverable. Zero hides the chip.
    var stackedCount: Int = 0

    @State private var isHovering = false

    private var media: MediaState? { tab.media }

    /// Same corner as a tab row, so the player reads as part of the column
    /// rather than a panel underneath it.
    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
    }

    var body: some View {
        if let media {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    // Only this part selects the tab. The card used to carry
                    // the tap itself, which put one gesture over the whole
                    // surface and left every control arguing with it for the
                    // same click — the card won, so the buttons did nothing but
                    // switch tabs. Two regions that don't overlap can't argue.
                    HStack(spacing: 10) {
                        artwork(media)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(media.title.isEmpty ? tab.displayTitle : media.title)
                                .font(.system(size: 13, weight: isPrimary ? .medium : .regular))
                                .lineLimit(1)
                            Text(media.artist)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { session.select(tab) }
                    .help("Go to \(tab.displayTitle)")

                    if stackedCount > 0 {
                        stackChip
                    }

                    if isPrimary {
                        downloadControl(media)
                        popOutControl(media)
                    }

                    IconButton(
                        systemName: media.isPlaying ? "pause.fill" : "play.fill",
                        size: 12,
                        width: 26,
                        height: 26,
                        cornerRadius: 13,
                        help: media.isPlaying ? "Pause" : "Play"
                    ) {
                        tab.toggleMediaPlayback()
                    }
                    .animation(.easeOut(duration: 0.15), value: media.isPlaying)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 9)

                if isPrimary {
                    progress(media)
                } else {
                    Spacer(minLength: 0)
                }
            }
            // Clipped, not just backed: the progress bar runs to the card's
            // bottom edge and would otherwise square off its corners.
            .background(.regularMaterial, in: cardShape)
            .clipShape(cardShape)
            .overlay {
                cardShape.fill(Color.primary.opacity(isHovering ? 0.07 : 0))
            }
            .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
            .padding(.horizontal, 8)
            .onHover { isHovering = $0 }
        }
    }

    /// Signals the collapsed stack, since the cards themselves are invisible.
    private var stackChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.stack.fill")
                .font(.system(size: 9))
            Text("\(stackedCount + 1)")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(Color.primary.opacity(0.09))
        }
        .help("\(stackedCount + 1) tabs playing — hover to show all")
    }

    private func artwork(_ media: MediaState) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 32, height: 32)

            if let favicon = tab.favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: media.hasVideo ? "film" : "music.note")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func popOutControl(_ media: MediaState) -> some View {
        if media.hasVideo {
            IconButton(
                systemName: PopOutController.shared.isPoppedOut(tab)
                    ? "arrow.down.right.and.arrow.up.left"
                    : "rectangle.on.rectangle",
                size: 12,
                width: 26,
                height: 26,
                cornerRadius: 13,
                help: PopOutController.shared.isPoppedOut(tab) ? "Bring Back" : "Pop Out Video"
            ) {
                PopOutController.shared.toggle(tab)
            }
        }
    }

    /// Three states, deliberately distinct: downloading shows progress,
    /// finished offers Finder, and streamed media is shown disabled with an
    /// explanation rather than a button that does nothing.
    @ViewBuilder
    private func downloadControl(_ media: MediaState) -> some View {
        if let item = DownloadManager.shared.activeItem(for: tab) {
            switch item.state {
            case .downloading:
                ZStack {
                    Circle()
                        .trim(from: 0, to: max(0.04, item.fraction))
                        .stroke(Color.accentColor,
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 21, height: 21)
                        .animation(.easeOut(duration: 0.25), value: item.fraction)
                    Image(systemName: "square.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 26, height: 26)
                .help("Downloading \(Int(item.fraction * 100))%")

            case .finished:
                IconButton(
                    systemName: "checkmark.circle.fill",
                    size: 13, width: 26, height: 26, cornerRadius: 13,
                    tint: .green,
                    help: "Saved — click to show in Finder"
                ) {
                    DownloadManager.shared.reveal(item)
                }

            case .failed(let message):
                IconButton(
                    systemName: "exclamationmark.triangle.fill",
                    size: 12, width: 26, height: 26, cornerRadius: 13,
                    tint: .orange,
                    motion: .wiggle,
                    help: "Download failed: \(message)"
                ) {
                    DownloadManager.shared.downloadMedia(from: tab)
                }
            }
        } else if media.isDownloadable {
            IconButton(
                systemName: "arrow.down.circle",
                size: 13, width: 26, height: 26, cornerRadius: 13,
                help: "Download Video"
            ) {
                DownloadManager.shared.downloadMedia(from: tab)
            }
        } else if media.needsExtraction {
            // Segmented media has no URL to fetch and is reassembled from the
            // page instead. A different glyph because it's a slower,
            // best-effort job rather than a straight file copy — but the
            // machinery behind it is never named. As far as anyone using Glass
            // is concerned this is just what downloading a stream looks like.
            let isReady = MediaExtractor.shared.isAvailable
            IconButton(
                systemName: "arrow.down.circle.dotted",
                size: 13, width: 26, height: 26, cornerRadius: 13,
                isEnabled: isReady,
                motion: isReady ? .bounce : .none,
                help: isReady
                    ? "Download Video — reassembled from the stream"
                    : "This video is streamed in segments and can't be saved as a file"
            ) {
                DownloadManager.shared.downloadMedia(from: tab)
            }
        }
    }

    /// Only drawn for media with a known duration — live streams report zero,
    /// and a bar stuck at 0% reads as broken.
    @ViewBuilder
    private func progress(_ media: MediaState) -> some View {
        if media.duration > 0 {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: geometry.size.width * media.progress)
                    .animation(.linear(duration: 0.9), value: media.progress)
            }
            .frame(height: 2)
        }
    }
}

