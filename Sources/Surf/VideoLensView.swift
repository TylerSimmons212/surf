import SurfCore
import SwiftUI

/// The video lens: theater mode's chrome.
///
/// The stage itself is the page's own `<video>`, promoted fullscreen in
/// place by `media.stage` — this view is deliberately transparent, because
/// covering the web view would cover the show. What it adds is Surf's
/// transport: one set of controls that looks the same on every site, driven
/// through the same agent methods the sidebar's now-playing strip uses.
struct VideoLensView: View {
    let tab: Tab

    /// The scrub in progress, so the slider follows the hand rather than
    /// the once-a-second report while dragging.
    @State private var scrubTarget: Double?
    /// Chrome fades when the pointer stops moving, like every theater.
    @State private var isChromeVisible = true
    @State private var chromeTimer: Task<Void, Never>?

    private var media: MediaState? { tab.media }

    var body: some View {
        ZStack {
            // A whisper of ground behind the letterbox edges while the page
            // promotes its element; never opaque — the video lives below.
            Color.black.opacity(media == nil ? 0.5 : 0)
                .allowsHitTesting(false)

            if media == nil {
                // The element was torn out — an SPA route, an ended embed.
                VStack(spacing: 12) {
                    Text("The video has gone away.")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white)
                    Button("Back to the Page") { tab.exitFocus() }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if isChromeVisible {
                exitControl
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if isChromeVisible, let media {
                transport(media)
                    .transition(.opacity)
            }
        }
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            revealChrome()
        }
        .animation(.easeOut(duration: 0.25), value: isChromeVisible)
        .onDisappear { chromeTimer?.cancel() }
    }

    /// Chrome shows on any pointer movement and takes itself away after a
    /// few still seconds — unless the video is paused, when there's nothing
    /// to get out of the way of.
    private func revealChrome() {
        isChromeVisible = true
        chromeTimer?.cancel()
        chromeTimer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            if media?.isPlaying == true, scrubTarget == nil {
                isChromeVisible = false
            }
        }
    }

    private var exitControl: some View {
        IconButton(
            systemName: "xmark",
            size: 11, weight: .bold, width: 26, height: 26, cornerRadius: 8,
            help: "Leave Focus (⇧⌘F)"
        ) { tab.exitFocus() }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .padding(.top, 14)
        .padding(.trailing, 14)
    }

    private func transport(_ media: MediaState) -> some View {
        VStack(spacing: 8) {
            if !media.title.isEmpty || !tab.displayTitle.isEmpty {
                Text(media.title.isEmpty ? tab.displayTitle : media.title)
                    .font(Typeface.figtree(size: 12, weight: 500))
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
                    systemName: media.isPlaying ? "pause.fill" : "play.fill",
                    size: 15, width: 32, height: 28, cornerRadius: 9,
                    help: media.isPlaying ? "Pause" : "Play"
                ) { tab.toggleMediaPlayback() }

                IconButton(
                    systemName: "goforward.10",
                    size: 13, width: 28, height: 26, cornerRadius: 8,
                    help: "Forward 10 Seconds"
                ) { tab.skipMedia(by: 10) }

                if media.duration > 0 {
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
                        // Seek once, on release: a seek per tick mid-drag
                        // makes streaming players stutter through the whole
                        // gesture.
                        if !editing, let target = scrubTarget {
                            tab.seekMedia(to: target)
                            scrubTarget = nil
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 260)

                    Text(timestamp(media.duration))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Divider().frame(height: 16)

                IconButton(
                    systemName: "rectangle.on.rectangle",
                    size: 12, width: 26, height: 24, cornerRadius: 8,
                    help: "Pop Out"
                ) {
                    // The pop-out is the stage's portable sibling; hand off
                    // cleanly rather than stacking one lens on another.
                    tab.exitFocus()
                    PopOutController.shared.popOut(tab)
                }
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

    private func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
