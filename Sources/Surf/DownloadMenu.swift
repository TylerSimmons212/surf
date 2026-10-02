import SurfCore
import SwiftUI

/// What to download, when there is more than one answer.
///
/// The engine picks for itself perfectly well — tallest wins, codec breaks a
/// tie — and for most of the web there is nothing to pick between. This exists
/// for the sites where the difference is large enough to be someone else's
/// decision: 4K AV1 is two and a half times the size of 1080p H.264 for the same
/// ten minutes, and on a metered connection or an older machine that is not
/// obviously the better answer.
///
/// Two pages rather than two popovers, the same arrangement `SiteToolsPopover`
/// uses and for the same reason: a popover that opens a second popover leaves the
/// first hanging behind it with nothing to say which a click belongs to.
struct DownloadMenu: View {
    let tab: Tab
    /// Dismisses the popover. Held rather than inferred, because every row here
    /// starts something and then wants to be gone.
    let close: () -> Void

    @State private var isChoosing = false
    @State private var options: [DownloadOption] = []
    @State private var duration: Double?
    @State private var isLoading = true

    private var videoOptions: [DownloadOption] { DownloadOptions.video(from: options) }
    private var audioOption: DownloadOption? { DownloadOptions.audio(from: options) }

    var body: some View {
        Group {
            if isChoosing {
                choosing
            } else {
                summary
            }
        }
        .frame(width: 228)
        .task {
            let found = await DownloadManager.shared.options(for: tab)
            options = found.options
            duration = found.duration
            isLoading = false
        }
    }

    // MARK: - What it opens on

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(
                title: "Download Video",
                detail: best.map { $0.title + " · " + $0.detail(duration: duration) },
                systemImage: "arrow.down.circle"
            ) {
                close()
                DownloadManager.shared.downloadMedia(from: tab)
            }

            // Only when there is something to choose between. One rendition and
            // a menu offering to choose is a menu that wastes a click to tell you
            // there was never a decision.
            if videoOptions.count > 1 {
                MenuRow(
                    title: "Choose Quality…",
                    detail: "\(videoOptions.count) sizes",
                    systemImage: "slider.horizontal.3"
                ) {
                    withAnimation(.easeOut(duration: 0.15)) { isChoosing = true }
                }
            }

            if let audioOption {
                MenuRow(
                    title: "Audio Only",
                    detail: audioOption.detail(duration: duration),
                    systemImage: "waveform"
                ) {
                    close()
                    DownloadManager.shared.downloadMedia(from: tab, choosing: audioOption)
                }
            }

            if isLoading {
                // Said rather than shown as an empty space. Working out what is
                // on offer can mean fetching a manifest, and a menu that silently
                // has fewer rows for a moment reads as a menu that is finished.
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Looking for other sizes…")
                        .font(Typeface.figtree(size: 11, weight: 500))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 5)
    }

    /// The one the plain download would take, so the first row can say what it
    /// is about to do rather than leaving someone to find out afterwards.
    private var best: DownloadOption? { videoOptions.first }

    // MARK: - The second page

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isChoosing = false }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("Download")
                        .font(Typeface.figtree(size: 12, weight: 600))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(videoOptions) { option in
                        MenuRow(
                            title: option.title,
                            detail: option.detail(duration: duration),
                            systemImage: nil
                        ) {
                            close()
                            DownloadManager.shared.downloadMedia(from: tab, choosing: option)
                        }
                    }
                }
                .padding(.vertical, 5)
            }
            // Tall enough for the five or six a site usually offers, and
            // scrolling past that rather than growing a popover off the screen.
            .frame(maxHeight: 260)
        }
    }
}

/// A row in either page.
///
/// Its own view rather than `SidebarMenuRow` because these carry a second line:
/// the choice being made here is between sizes, and a menu of resolutions with
/// no sizes beside them is asking someone to decide on the one fact it withheld.
private struct MenuRow: View {
    let title: String
    var detail: String?
    let systemImage: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Typeface.figtree(size: 12.5, weight: 500))
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(Typeface.figtree(size: 10.5, weight: 500))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .pointerStyle(.link)
    }
}
