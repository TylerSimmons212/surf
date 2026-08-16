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
