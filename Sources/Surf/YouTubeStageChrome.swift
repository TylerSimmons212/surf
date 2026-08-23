import SurfCore
import SwiftUI

/// The player screen: Surf's chrome over YouTube's own pinned player.
///
/// Transparent, deliberately — the stage below is the show. What this adds is
/// the transport, and the three things a generic theater cannot offer because
/// only YouTube knows them: the chapter list with its exact starts, the
/// subtitle tracks, and the speeds this player will actually accept.
///
/// Playback itself goes through the media bridge rather than the site: the
/// `<video>` is the thing that plays, `Tab` already drives it for the
/// now-playing strip, and one transport for every site is the point.
struct YouTubeStageChrome: View {
    let tab: Tab
    @Bindable var lens: YouTubeLens

    @State private var scrubTarget: Double?
    @State private var isChromeVisible = true
    @State private var showsChapters = false
    @State private var chromeTimer: Task<Void, Never>?

    private var media: MediaState? { tab.media }

    var body: some View {
        ZStack {
            // Never opaque: the video lives below. A whisper of ground only
            // while the stage is still going up.
            Color.black.opacity(media == nil ? 0.5 : 0)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if isChromeVisible { heading.transition(.opacity) }
        }
        .overlay(alignment: .topTrailing) {
            if isChromeVisible { corner.transition(.opacity) }
        }
        .overlay(alignment: .bottom) {
            if isChromeVisible { transport.transition(.opacity) }
        }
        .overlay(alignment: .trailing) {
            if showsChapters, !lens.chapters.isEmpty {
                chapterPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            revealChrome()
        }
        .transportKeys(skip: { tab.skipMedia(by: $0) }, reveal: revealChrome)
        .animation(.easeOut(duration: 0.22), value: isChromeVisible)
        .animation(.easeOut(duration: 0.24), value: showsChapters)
        .onDisappear { chromeTimer?.cancel() }
    }

    /// Chrome shows on any pointer movement and takes itself away after a few
    /// still seconds — unless the video is paused, or a panel is open, when
    /// there is nothing to get out of the way of.
    private func revealChrome() {
        isChromeVisible = true
        chromeTimer?.cancel()
        chromeTimer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            if media?.isPlaying == true, scrubTarget == nil, !showsChapters {
                isChromeVisible = false
            }
        }
    }

    // MARK: - What is playing

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(lens.video?.title ?? tab.displayTitle)
                .font(Typeface.figtree(size: 14, weight: 600))
                .foregroundStyle(.white)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let channel = lens.video?.channel, !channel.isEmpty {
                    Text(channel)
                        .font(Typeface.figtree(size: 12, weight: 500))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if let views = lens.video?.viewText, !views.isEmpty {
                    Text(views)
                        .font(Typeface.figtree(size: 12, weight: 400))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .padding(.top, 14)
        .padding(.leading, 14)
    }

    private var corner: some View {
        HStack(spacing: 6) {
            IconButton(
                systemName: "square.grid.2x2",
                size: 12, width: 26, height: 26, cornerRadius: 8,
                help: "Back to Results"
            ) { lens.showResults() }

            IconButton(
                systemName: "xmark",
                size: 11, weight: .bold, width: 26, height: 26, cornerRadius: 8,
                help: "Leave Focus (\u{21E7}\u{2318}F)"
            ) { tab.exitFocus() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .padding(.top, 14)
        .padding(.trailing, 14)
    }

    // MARK: - The transport

    private var transport: some View {
        VStack(spacing: 7) {
            // The chapter being played, named. The one line of the transport
            // that a generic theater has no way to fill.
            if let chapter = lens.currentChapter {
                Text(chapter.title)
                    .font(Typeface.figtree(size: 11, weight: 500))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                IconButton(
                    systemName: "gobackward.10",
                    size: 13, width: 28, height: 26, cornerRadius: 8,
                    help: "Back 10 Seconds"
                ) { tab.skipMedia(by: -10) }

                IconButton(
                    systemName: media?.isPlaying == true ? "pause.fill" : "play.fill",
                    size: 15, width: 32, height: 28, cornerRadius: 9,
                    help: media?.isPlaying == true ? "Pause" : "Play"
                ) { tab.toggleMediaPlayback() }

                IconButton(
                    systemName: "goforward.10",
                    size: 13, width: 28, height: 26, cornerRadius: 8,
                    help: "Forward 10 Seconds"
                ) { tab.skipMedia(by: 10) }

                scrubber

                Divider().frame(height: 16)

                if !lens.chapters.isEmpty {
                    IconButton(
                        systemName: "list.bullet",
                        size: 12, width: 26, height: 24, cornerRadius: 8,
                        tint: showsChapters ? .accentColor : nil,
                        help: "Chapters"
                    ) { showsChapters.toggle() }
                }

                if !lens.captionTracks.isEmpty { captionsMenu }
                speedMenu
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .shadow(color: .black.opacity(0.3), radius: 16, y: 5)
        .padding(.bottom, 18)
    }

    /// Hidden for a live stream, which has no length to scrub through.
    @ViewBuilder
    private var scrubber: some View {
        if let media, media.duration > 0 {
            Text(timestamp(scrubTarget ?? media.currentTime))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { scrubTarget ?? media.currentTime },
                    set: { scrubTarget = $0 }
                ),
                in: 0...media.duration
            ) { editing in
                // Seek once, on release: a seek per tick mid-drag makes
                // streaming players stutter through the whole gesture.
                if !editing, let target = scrubTarget {
                    tab.seekMedia(to: target)
                    scrubTarget = nil
                }
            }
            .controlSize(.small)
            .frame(width: 240)

            Text(timestamp(media.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        } else if lens.video?.isLive == true {
            Text("LIVE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(red: 0.87, green: 0.11, blue: 0.11))
                .padding(.horizontal, 6)
        }
    }

    private var captionsMenu: some View {
        Menu {
            Button("Off") { lens.setCaptionLanguage("") }
            Divider()
            ForEach(lens.captionTracks) { track in
                Button {
                    lens.setCaptionLanguage(track.languageCode)
                } label: {
                    // An auto-generated track says so: the two read very
                    // differently and the choice matters to anyone relying
                    // on them.
                    Text(track.isAutomatic ? "\(track.label) (auto)" : track.label)
                }
            }
        } label: {
            Image(systemName: lens.captionLanguage.isEmpty
                ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26)
        .help("Subtitles")
    }

    private var speedMenu: some View {
        Menu {
            ForEach(lens.rates, id: \.self) { rate in
                Button {
                    lens.setRate(rate)
                } label: {
                    Text(rate == 1 ? "Normal" : "\(speedLabel(rate))\u{00D7}")
                }
            }
        } label: {
            Text(lens.rate == 1 ? "1\u{00D7}" : "\(speedLabel(lens.rate))\u{00D7}")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34)
        .help("Playback Speed")
    }

    // MARK: - Chapters

    private var chapterPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lens.chapters) { chapter in
                    let isCurrent = lens.currentChapter == chapter
                    Button {
                        lens.seek(to: chapter)
                    } label: {
                        HStack(spacing: 10) {
                            Text(chapter.startText)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(isCurrent ? .primary : .secondary)
                                .frame(width: 54, alignment: .leading)
                            Text(chapter.title)
                                .font(Typeface.figtree(
                                    size: 12, weight: isCurrent ? 600 : 400
                                ))
                                .foregroundStyle(isCurrent ? .primary : .secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background {
                            if isCurrent {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.16))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .frame(width: 290)
        .frame(maxHeight: 420)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
        .padding(.trailing, 16)
        // Clear of the transport below and the heading above.
        .padding(.bottom, 96)
        .padding(.top, 80)
    }

    // MARK: - Formatting

    private func timestamp(_ seconds: Double) -> String {
        YouTubeFormat.clock(Int(seconds.rounded()))
    }

    /// "1.25" rather than "1.25000001", and "2" rather than "2.0".
    private func speedLabel(_ rate: Double) -> String {
        rate == rate.rounded()
            ? String(Int(rate))
            : String(format: "%g", rate)
    }
}
