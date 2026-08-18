import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Toolbar button plus the downloads popover.
///
/// A popover rather than a permanent sidebar section: downloads are episodic,
/// and the sidebar's vertical space belongs to tabs. The button only exists
/// once there's something to show.
struct DownloadsButton: View {
    let session: BrowserSession
    /// Keeps the sidebar revealed while the list is up. The popover is its own
    /// window, so without this, moving the pointer toward Clear collapses the
    /// sidebar and takes the popover with it.
    let hold: SidebarHold

    private var isShowingList: Binding<Bool> { hold.binding(for: Self.holdReason) }

    private static let holdReason = "downloads"

    private var manager: DownloadManager { DownloadManager.shared }

    var body: some View {
        if !manager.items.isEmpty {
            ZStack {
                IconButton(
                    systemName: manager.activeCount > 0
                        ? "arrow.down"
                        : "arrow.down.circle",
                    help: manager.activeCount > 0
                        ? "\(manager.activeCount) downloading"
                        : "Downloads"
                ) {
                    isShowingList.wrappedValue.toggle()
                }

                // Same idiom as the reload button: the control carries its own
                // progress instead of needing a separate bar.
                if manager.activeCount > 0 {
                    Circle()
                        .trim(from: 0, to: max(0.04, manager.activeProgress))
                        .stroke(Color.accentColor,
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 20, height: 20)
                        .animation(.easeOut(duration: 0.25), value: manager.activeProgress)
                        .allowsHitTesting(false)
                }
            }
            .popover(isPresented: isShowingList, arrowEdge: .bottom) {
                DownloadsList(session: session)
            }
            // Clearing the last item removes this button, and a popover whose
            // anchor is gone never reports itself dismissed — the hold would be
            // stuck on and the sidebar stuck open.
            .onDisappear { hold.set(Self.holdReason, false) }
        }
    }
}

struct DownloadsList: View {
    let session: BrowserSession

    private var manager: DownloadManager { DownloadManager.shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if manager.items.contains(where: { !$0.isActive }) {
                    Button("Clear") { manager.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(manager.items) { item in
                        DownloadRow(item: item, session: session)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 330)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let session: BrowserSession

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            fileIcon
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename.isEmpty ? "Downloading…" : item.filename)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                subtitle

                if item.isActive {
                    ProgressView(value: max(0.01, item.fraction))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }

            Spacer(minLength: 0)

            actions
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Double-click opens it, matching the Finder behaviour people expect
        // from a downloads list.
        .onTapGesture(count: 2) { open() }
    }

    @ViewBuilder
    private var subtitle: some View {
        switch item.state {
        case .downloading:
            Text(item.sizeDescription.isEmpty ? "Starting…" : item.sizeDescription)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .finished:
            Text([item.sizeDescription, item.host].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: " — "))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .failed(let message):
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch item.state {
        case .downloading:
            IconButton(
                systemName: "xmark",
                size: 9, weight: .bold, width: 20, height: 20, cornerRadius: 10,
                help: "Cancel"
            ) {
                DownloadManager.shared.cancel(item)
            }

        case .finished:
            IconButton(
                systemName: "magnifyingglass",
                size: 10, width: 20, height: 20, cornerRadius: 10,
                help: "Show in Finder"
            ) {
                DownloadManager.shared.reveal(item)
            }

        case .failed:
            IconButton(
                systemName: "arrow.clockwise",
                size: 10, width: 20, height: 20, cornerRadius: 10,
                help: "Try Again"
            ) {
                DownloadManager.shared.retry(item, in: session.selectedTab)
            }
        }
    }

    /// The real document icon once the file exists, so the list looks like the
    /// Finder rather than a wall of identical glyphs.
    @ViewBuilder
    private var fileIcon: some View {
        if case let .finished(url) = item.state,
           FileManager.default.fileExists(atPath: url.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            let type = UTType(filenameExtension: (item.filename as NSString).pathExtension)
            Image(nsImage: NSWorkspace.shared.icon(for: type ?? .data))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(item.isActive ? 0.55 : 1)
        }
    }

    private func open() {
        guard case let .finished(url) = item.state else { return }
        NSWorkspace.shared.open(url)
    }
}
