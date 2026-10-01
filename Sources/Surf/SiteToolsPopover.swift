import AppKit
import SurfCore
import SwiftUI

/// Everything that acts on the page in front of you, in one place.
///
/// These four used to be four separate squares in the sidebar's top strip,
/// where they sat beside Back, Forward and the pin without anything saying
/// they were a different kind of thing. They are: the window's row is about
/// the window, and these are about whatever page happens to be open in it.
///
/// Two pages, not two popovers. The blocking summary opens the full list in
/// place, because a popover that spawns a second popover leaves the first one
/// hanging behind it with no way to say which one a click belongs to.
struct SiteToolsPopover: View {
    let session: BrowserSession

    @State private var isShowingBlockDetail = false

    private var tab: Tab { session.selectedTab }

    var body: some View {
        Group {
            if isShowingBlockDetail {
                VStack(spacing: 0) {
                    backRow
                    Divider()
                    BlockList(session: session)
                }
            } else {
                tools
            }
        }
        .frame(width: 320)
    }

    private var backRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isShowingBlockDetail = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                Text("Page tools")
                    .font(Typeface.figtree(size: 12, weight: 600))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZoomRow(tab: tab)

            Divider().padding(.vertical, 6)

            CopyLinkRow(tab: tab)

            ScreenshotRows(tab: tab)

            if ContentBlocker.isEnabled, tab.mode == .browsing {
                Divider().padding(.vertical, 6)
                BlockingRow(session: session) {
                    withAnimation(.easeOut(duration: 0.15)) { isShowingBlockDetail = true }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// Zoom, with the level spelled out.
///
/// The level is the reason this is a row rather than two menu items. A page
/// stuck at 125% with nothing saying so reads as a rendering bug, and the old
/// answer was a pill that appeared in the sidebar's top strip only while
/// zoomed — a control that moved its neighbours around every time somebody hit
/// ⌘+. Here it has a fixed home and can say the number all the time.
private struct ZoomRow: View {
    let tab: Tab

    var body: some View {
        HStack(spacing: 8) {
            Label("Zoom", systemImage: "textformat.size")
                .font(Typeface.figtree(size: 13, weight: 500))
                .labelStyle(SiteToolsLabelStyle())

            Spacer(minLength: 8)

            if tab.isZoomed {
                Button("Reset") { tab.resetZoom() }
                    .font(Typeface.figtree(size: 11, weight: 500))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .pointerStyle(.link)
                    .help("Back to 100% (⌘0)")
            }

            HStack(spacing: 0) {
                step("minus", isEnabled: tab.zoomLevel > ZoomSteps.levels.first!) {
                    tab.zoomOut()
                }

                Text(tab.zoomLabel)
                    .font(Typeface.figtree(size: 12, weight: 600).monospacedDigit())
                    .frame(minWidth: 42)

                step("plus", isEnabled: tab.zoomLevel < ZoomSteps.levels.last!) {
                    tab.zoomIn()
                }
            }
            .padding(.horizontal, 2)
            .frame(height: 26)
            .glassEffect(.regular, in: Capsule())
        }
        .padding(.horizontal, 12)
        .disabled(tab.mode != .browsing)
    }

    private func step(
        _ symbol: String, isEnabled: Bool, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!isEnabled)
        .pointerStyle(.link)
        .accessibilityLabel(symbol == "minus" ? "Zoom out" : "Zoom in")
    }
}

/// Copy, and say so: a copy that says nothing looks like a copy that failed.
private struct CopyLinkRow: View {
    let tab: Tab

    @State private var didCopy = false

    var body: some View {
        SiteToolsRow(
            title: didCopy ? "Copied" : "Copy link",
            systemImage: didCopy ? "checkmark" : "link",
            tint: didCopy ? .green : nil,
            isEnabled: tab.mode == .browsing
        ) {
            copyURL()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: didCopy)
    }

    private func copyURL() {
        let url = tab.currentURL ?? tab.addressText
        guard !url.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)

        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            didCopy = false
        }
    }
}

/// The three captures, spelled out rather than nested in a submenu.
///
/// A submenu would hide two of them behind a hover, and there are only three.
private struct ScreenshotRows: View {
    let tab: Tab

    var body: some View {
        Group {
            SiteToolsRow(
                title: "Select Area", systemImage: "selection.pin.in.out",
                isEnabled: tab.mode == .browsing
            ) {
                tab.beginAreaCapture()
            }
            SiteToolsRow(
                title: "Capture Visible Area", systemImage: "camera",
                isEnabled: tab.mode == .browsing
            ) {
                capture { await tab.captureVisibleArea() }
            }
            SiteToolsRow(
                title: "Capture Full Page", systemImage: "doc.text.image",
                isEnabled: tab.mode == .browsing
            ) {
                capture { await tab.captureFullPage() }
            }
        }
    }

    private func capture(_ take: @escaping () async -> NSImage?) {
        Task { @MainActor in
            guard let image = await take() else { return }
            ScreenshotPreviewController.shared.show(image, title: tab.displayTitle)
        }
    }
}

/// Blocking, for this site, with the way into the detail.
///
/// The toggle is per-host and not global, because the moment anybody reaches
/// for it is the moment a site has just broken under blocking — and the fix
/// for one broken site is never "turn the whole thing off".
private struct BlockingRow: View {
    let session: BrowserSession
    let onShowDetail: () -> Void

    private var blocker: ContentBlocker { ContentBlocker.shared }
    private var tab: Tab { session.selectedTab }
    private var host: String? { tab.currentURL.flatMap { URL(string: $0)?.host } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("Block ads and trackers", systemImage: "shield.lefthalf.filled")
                    .font(Typeface.figtree(size: 13, weight: 500))
                    .labelStyle(SiteToolsLabelStyle())

                Spacer(minLength: 8)

                if let host {
                    Toggle("", isOn: Binding(
                        get: { !blocker.isPaused(on: host) },
                        set: { blocker.setPaused(!$0, on: host) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
            .padding(.horizontal, 12)

            // The count is a button, because the only interesting thing about
            // a number like this is what it is made of.
            Button(action: onShowDetail) {
                HStack(spacing: 4) {
                    Text(summary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Spacer(minLength: 0)
                }
                .font(Typeface.figtree(size: 11, weight: 400))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
        }
    }

    private var summary: String {
        if let host, blocker.isPaused(on: host) { return "Paused on this site" }
        let count = tab.blockLog.blockedCount
        // A shield wearing a zero is a worse answer than one wearing nothing,
        // and the same is true of this line.
        return count == 0 ? "Nothing blocked here yet" : "\(count) blocked on this page"
    }
}

// MARK: - Shared pieces

/// One tappable line in the popover.
private struct SiteToolsRow: View {
    let title: String
    let systemImage: String
    var tint: Color?
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Typeface.figtree(size: 13, weight: 500))
                .labelStyle(SiteToolsLabelStyle(tint: tint))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isHovering && isEnabled ? 0.08 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .padding(.horizontal, 4)
        .onHover { isHovering = $0 && isEnabled }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .pointerStyle(.link)
    }
}

/// Icons on one column, so the titles line up however wide a glyph is.
private struct SiteToolsLabelStyle: LabelStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.icon
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 17, alignment: .center)
            configuration.title
        }
    }
}
