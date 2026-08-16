import SwiftUI

/// Now-playing strip pinned to the bottom of the sidebar.
///
/// Shows whichever tab is making sound, not the selected one — the whole point
/// is to reach media in a tab you've navigated away from.
struct MediaPlayerBar: View {
    let tab: Tab
    let session: BrowserSession

    private var media: MediaState? { tab.media }

    var body: some View {
        if let media {
            VStack(spacing: 0) {
                Divider().opacity(0.5)

                HStack(spacing: 9) {
                    artwork

                    VStack(alignment: .leading, spacing: 1) {
                        Text(media.title.isEmpty ? tab.displayTitle : media.title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Text(media.artist)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    downloadControl(media)

                    if media.hasVideo {
                        IconButton(
                            systemName: PopOutController.shared.isPoppedOut(tab)
                                ? "arrow.down.right.and.arrow.up.left"
                                : "rectangle.on.rectangle",
                            size: 11,
                            width: 24,
                            height: 24,
                            cornerRadius: 12,
                            help: PopOutController.shared.isPoppedOut(tab)
                                ? "Bring Back" : "Pop Out Video"
                        ) {
                            PopOutController.shared.toggle(tab)
                        }
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
                // Clicking the strip jumps to whatever is playing.
                .contentShape(Rectangle())
                .onTapGesture { session.select(tab) }
                .help("Go to \(tab.displayTitle)")

                progress(media)
            }
            .background(.quaternary.opacity(0.25))
            .transition(.move(edge: .bottom).combined(with: .opacity))
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

    private var artwork: some View {
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
                Image(systemName: media?.hasVideo == true ? "film" : "music.note")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
