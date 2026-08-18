import GlassCore
import SwiftUI

/// The shield and the list behind it.
///
/// A blocker that only ever shows a number is asking to be trusted. This shows
/// its working: what was blocked, on whose say-so, and — the half that makes it
/// worth opening twice — everything else the page reached out to, each with the
/// button that adds it.
struct BlockButton: View {
    let session: BrowserSession
    let hold: SidebarHold

    private static let holdReason = "blocking"

    private var isShowingList: Binding<Bool> { hold.binding(for: Self.holdReason) }

    private var blocker: ContentBlocker { ContentBlocker.shared }

    private var tab: Tab { session.selectedTab }

    private var isPaused: Bool {
        blocker.isPaused(on: tab.currentURL.flatMap { URL(string: $0)?.host })
    }

    var body: some View {
        if ContentBlocker.isEnabled, tab.mode == .browsing {
            IconButton(
                systemName: isPaused ? "shield.slash" : "shield.lefthalf.filled",
                tint: isPaused ? .secondary : nil,
                motion: .bounce,
                help: helpText
            ) {
                isShowingList.wrappedValue.toggle()
            }
            .overlay(alignment: .topTrailing) { badge }
            .popover(isPresented: isShowingList, arrowEdge: .bottom) {
                BlockList(session: session)
            }
            .onDisappear { hold.set(Self.holdReason, false) }
        }
    }

    private var helpText: String {
        if isPaused { return "Blocking paused on this site" }
        let count = tab.blockLog.blockedCount
        return count == 0 ? "Nothing blocked on this page" : "\(count) blocked"
    }

    /// The count, and only when there is one. A shield wearing a zero is a
    /// worse answer than a shield wearing nothing.
    @ViewBuilder
    private var badge: some View {
        let count = tab.blockLog.blockedCount
        if count > 0, !isPaused {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 8, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 13, minHeight: 11)
                .background { Capsule().fill(Color.accentColor) }
                .offset(x: 3, y: -1)
                .allowsHitTesting(false)
                .transition(.scale.combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: count)
        }
    }
}

struct BlockList: View {
    let session: BrowserSession

    private var blocker: ContentBlocker { ContentBlocker.shared }
    private var tab: Tab { session.selectedTab }
    private var pageHost: String? { tab.currentURL.flatMap { URL(string: $0)?.host } }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let blocked = tab.blockLog.blocked
                    let allowed = tab.blockLog.allowed

                    if blocked.isEmpty && allowed.isEmpty {
                        emptyState
                    }

                    if !blocked.isEmpty {
                        sectionTitle("Blocked")
                        ForEach(blocked) { domain in
                            DomainRow(activity: domain, session: session)
                        }
                    }

                    if !allowed.isEmpty {
                        sectionTitle("Also contacted")
                        ForEach(allowed) { domain in
                            DomainRow(activity: domain, session: session)
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                if let pageHost {
                    Text(DomainName.registrable(pageHost))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if let pageHost {
                // The escape hatch, in the one place someone looks when a site
                // has just broken under blocking.
                Toggle("", isOn: Binding(
                    get: { !blocker.isPaused(on: pageHost) },
                    set: { isOn in
                        blocker.setPaused(!isOn, on: pageHost)
                        tab.reload()
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(blocker.isPaused(on: pageHost)
                      ? "Resume blocking on this site"
                      : "Pause blocking on this site")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var headline: String {
        guard let pageHost, blocker.isPaused(on: pageHost) else {
            let count = tab.blockLog.blockedCount
            return count == 0 ? "Nothing blocked" : "\(count) blocked on this page"
        }
        return "Paused on this site"
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 3)
    }

    /// Two different silences, and they mean opposite things: a page that
    /// contacted nobody, and a panel that hasn't been told anything yet.
    private var emptyState: some View {
        Text(blocker.isPreparing
             ? "Preparing the filter list…"
             : "This page hasn't contacted anyone else.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
    }
}

private struct DomainRow: View {
    let activity: DomainActivity
    let session: BrowserSession

    @State private var isHovering = false

    private var blocker: ContentBlocker { ContentBlocker.shared }

    private var isUserRule: Bool { activity.source == .userRule }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: activity.isBlocked ? "shield.lefthalf.filled" : "arrow.up.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(activity.isBlocked ? Color.accentColor : .secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(activity.domain)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            action
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var subtitle: String {
        guard let source = activity.source else { return activity.summary }
        return "\(activity.summary) — \(source.label)"
    }

    /// Only what this row can actually do. A domain caught by the shipped list
    /// has no button: unblocking it individually would be a third kind of rule
    /// to explain, and the answer for a site that needs it is the pause switch
    /// in the header.
    @ViewBuilder
    private var action: some View {
        if isUserRule {
            IconButton(
                systemName: "minus",
                size: 9, weight: .bold, width: 20, height: 20, cornerRadius: 10,
                help: "Stop blocking \(activity.domain)"
            ) {
                blocker.unblock(domain: activity.domain)
                session.selectedTab.reload()
            }
        } else if !activity.isBlocked {
            IconButton(
                systemName: "nosign",
                size: 10, width: 20, height: 20, cornerRadius: 10,
                help: "Block \(activity.domain) everywhere"
            ) {
                blocker.block(domain: activity.domain)
                // The requests are already made. A reload is what turns the
                // rule into something visible, and clicking Block and seeing
                // nothing happen would read as a button that doesn't work.
                session.selectedTab.reload()
            }
        }
    }
}
