import SwiftUI

/// Now-playing controls at the foot of the sidebar.
///
/// One row per tab holding media, drawn as a stack of cards. Collapsed, only
/// the active tab's row is legible and the others peek out behind it — enough
/// to say "there's more here" without spending vertical space on it. Hovering
/// fans them into full rows.
struct MediaPlayerStack: View {
    let session: BrowserSession

    @State private var isExpanded = false

    /// Fixed rather than measured: rows are positioned by offset, and reading
    /// back a dynamic height needs a geometry round-trip that lands a frame
    /// late and makes the fan-out jitter.
    private let rowHeight: CGFloat = 42
    private let rowSpacing: CGFloat = 2
    /// How far each collapsed card peeks above the one in front of it.
    private let peek: CGFloat = 4
    /// Past this, extra cards stack in place rather than peeking further.
    private let maxPeekingCards = 2

    private var tabs: [Tab] { session.mediaTabs }

    var body: some View {
        if let primary = tabs.first {
            let others = Array(tabs.dropFirst())

            VStack(spacing: 0) {
                Divider().opacity(0.5)

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

                    MediaRow(tab: primary, session: session, isPrimary: true)
                        .frame(height: rowHeight)
                        .zIndex(1)
                }
                .frame(height: stackHeight(otherCount: others.count), alignment: .bottom)
                // Room for the peeking edges so they aren't clipped by the divider.
                .padding(.top, others.isEmpty ? 0 : peek * CGFloat(min(others.count, maxPeekingCards)))
            }
            .background(.quaternary.opacity(0.25))
            .onHover { hovering in
                guard !others.isEmpty else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                    isExpanded = hovering
                }
            }
        }
    }

    /// Expanded, rows sit in a column above the front one. Collapsed, they tuck
    /// behind it with a few points showing.
    private func offset(forCardAt index: Int) -> CGFloat {
        if isExpanded {
            return -(rowHeight + rowSpacing) * CGFloat(index + 1)
        }
        return -peek * CGFloat(min(index + 1, maxPeekingCards))
    }

    /// Slightly narrower as they recede, which reads as depth.
    private func cardScale(_ index: Int) -> CGFloat {
        isExpanded ? 1 : 1 - 0.04 * CGFloat(min(index + 1, maxPeekingCards))
    }

    private func cardOpacity(_ index: Int) -> Double {
        guard !isExpanded else { return 1 }
        // Anything past the peek limit hides completely behind the stack.
        return index < maxPeekingCards ? 0.75 - 0.25 * Double(index) : 0
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
/// full controls are always one click away rather than crammed into 240 points.
struct MediaRow: View {
    let tab: Tab
    let session: BrowserSession
    let isPrimary: Bool

    @State private var isHovering = false

    private var media: MediaState? { tab.media }

    var body: some View {
        if let media {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    artwork(media)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(media.title.isEmpty ? tab.displayTitle : media.title)
                            .font(.system(size: 11, weight: isPrimary ? .medium : .regular))
                            .lineLimit(1)
                        Text(media.artist)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if isPrimary {
                        downloadControl(media)
                        popOutControl(media)
                    }

                    IconButton(
                        systemName: media.isPlaying ? "pause.fill" : "play.fill",
                        size: 11,
                        width: 24,
                        height: 24,
                        cornerRadius: 12,
                        help: media.isPlaying ? "Pause" : "Play"
                    ) {
                        tab.toggleMediaPlayback()
                    }
                    .animation(.easeOut(duration: 0.15), value: media.isPlaying)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                if isPrimary {
                    progress(media)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .background {
                // Stacked rows get their own plate so they read as separate
                // cards rather than one tall panel.
                RoundedRectangle(cornerRadius: isPrimary ? 0 : 8, style: .continuous)
                    .fill(isPrimary ? AnyShapeStyle(.clear) : AnyShapeStyle(.regularMaterial))
                    .overlay {
                        if !isPrimary {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
                        }
                    }
                    .shadow(color: .black.opacity(isPrimary ? 0 : 0.16), radius: 6, y: 2)
            }
            .padding(.horizontal, isPrimary ? 0 : 6)
            .contentShape(Rectangle())
            .onTapGesture { session.select(tab) }
            .onHover { isHovering = $0 }
            .help("Go to \(tab.displayTitle)")
        }
    }

    private func artwork(_ media: MediaState) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 26, height: 26)

            if let favicon = tab.favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 15, height: 15)
            } else {
                Image(systemName: media.hasVideo ? "film" : "music.note")
                    .font(.system(size: 11))
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
                size: 11,
                width: 24,
                height: 24,
                cornerRadius: 12,
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
                        .frame(width: 19, height: 19)
                        .animation(.easeOut(duration: 0.25), value: item.fraction)
                    Image(systemName: "square.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 24, height: 24)
                .help("Downloading \(Int(item.fraction * 100))%")

            case .finished:
                IconButton(
                    systemName: "checkmark.circle.fill",
                    size: 12, width: 24, height: 24, cornerRadius: 12,
                    tint: .green,
                    help: "Saved — click to show in Finder"
                ) {
                    DownloadManager.shared.reveal(item)
                }

            case .failed(let message):
                IconButton(
                    systemName: "exclamationmark.triangle.fill",
                    size: 11, width: 24, height: 24, cornerRadius: 12,
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
                size: 12, width: 24, height: 24, cornerRadius: 12,
                help: "Download Video"
            ) {
                DownloadManager.shared.downloadMedia(from: tab)
            }
        } else if media.isStreamed {
            // Disabled with a reason. A missing button reads as a bug; a dead
            // one reads worse.
            IconButton(
                systemName: "arrow.down.circle",
                size: 12, width: 24, height: 24, cornerRadius: 12,
                isEnabled: false,
                motion: .none,
                help: "This video is streamed in segments and can't be saved as a file"
            ) {}
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
