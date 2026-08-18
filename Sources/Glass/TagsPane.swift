import GlassCore
import SwiftUI

/// Marketing tags: what's installed, what it's actually sending, and what's
/// wrong with it.
///
/// The events need no capture of their own — a pixel fire is a network request,
/// including the `<img>` and beacon ones most tags use, and those are already
/// recorded. What was missing was anyone reading them: `facebook.com/tr/?id=…&
/// ev=Purchase&cd[value]=49.99` is in the buffer either way, and the difference
/// between a network row and "Meta Pixel · Purchase · $49.99" is a decoder.
///
/// Today this takes Meta's Pixel Helper, Google's Tag Assistant and GA4's
/// DebugView, each showing one vendor and none of them noticing that the other
/// fired the same event a moment earlier.
struct TagsPane: View {
    @Bindable var session: DevToolsSession

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !session.tagFindings.isEmpty { findings }
            sections
            Divider()
            content
        }
        .task { await session.loadTags() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                Task { @MainActor in await session.loadTags() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Read the tags again")

            if session.isLoadingTags {
                ProgressView().controlSize(.small)
            }

            if !session.consentManagers.isEmpty {
                Label(session.consentManagers.joined(separator: ", "), systemImage: "checkmark.shield")
                    .font(DevToolsTheme.caption)
                    .foregroundStyle(.secondary)
                    .help("Consent manager detected")
            }

            Spacer(minLength: 8)

            Text("\(session.detectedTags.count) tools · \(session.tagEvents.count) events")
                .font(DevToolsTheme.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, DevToolsTheme.barVertical)
    }

    /// Above the section switcher rather than inside a tab: a double-fired
    /// Purchase is the reason to have opened this, and it shouldn't be
    /// somewhere you have to go and look.
    private var findings: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(session.tagFindings) { finding in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: symbol(finding.severity))
                        .font(.system(size: 10))
                        .foregroundStyle(color(finding.severity))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(finding.title)
                            .font(DevToolsTheme.chrome.weight(.medium))
                        Text(finding.detail)
                            .font(DevToolsTheme.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 2)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .fill(worstColor.opacity(0.10))
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.bottom, 6)
    }

    private var worstColor: Color {
        if session.tagFindings.contains(where: { $0.severity == .error }) { return NetworkStyle.error }
        if session.tagFindings.contains(where: { $0.severity == .warning }) { return .orange }
        return .secondary
    }

    private func symbol(_ severity: TagSeverity) -> String {
        switch severity {
        case .error: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    private func color(_ severity: TagSeverity) -> Color {
        switch severity {
        case .error: NetworkStyle.error
        case .warning: .orange
        case .info: .secondary
        }
    }

    private var sections: some View {
        Picker("Section", selection: $session.tagSection) {
            ForEach(DevToolsSession.TagSection.allCases) { section in
                Text(section.label).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .fixedSize()
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch session.tagSection {
        case .detected: detectedList
        case .events: eventList
        case .libraries: libraryList
        }
    }

    // MARK: - Detected

    private var detectedList: some View {
        Group {
            if session.detectedTags.isEmpty {
                DevToolsPlaceholder(
                    symbol: "tag",
                    title: "No tags found",
                    detail: "Nothing recognisable is installed on this page."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(TagCategory.allCases) { category in
                            let inCategory = session.detectedTags.filter { $0.category == category }
                            if !inCategory.isEmpty {
                                Text(category.label)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, DevToolsTheme.rowInset)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                                ForEach(inCategory) { tag in DetectedRow(tag: tag) }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - Events

    private var eventList: some View {
        Group {
            if session.tagEvents.isEmpty {
                DevToolsPlaceholder(
                    symbol: "bolt",
                    title: "No events yet",
                    detail: "Interact with the page, or reload it, to see tags fire."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.tagEvents) { event in EventRow(event: event) }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - Ad libraries

    private var libraryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // The honest shape of this, said plainly. Of these platforms
                // exactly one has an API a marketer could use — Meta's, free
                // but covering commercial ads only where they were delivered to
                // the EU or UK — and TikTok's research API bars commercial use
                // outright. Deep links need no token and can't go stale.
                Text(
                    "Glass links out rather than fetching. Only Meta has an ad API a "
                    + "marketer can use, and only for EU and UK delivery; TikTok's research "
                    + "API excludes commercial use, and Google's and LinkedIn's libraries "
                    + "are browser-only."
                )
                .font(DevToolsTheme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if session.socialProfiles.isEmpty {
                    Text(
                        "No accounts declared on this page. Sites usually link theirs in "
                        + "the footer, or declare a Facebook page with an fb:pages tag."
                    )
                    .font(DevToolsTheme.chrome)
                    .foregroundStyle(.tertiary)
                } else {
                    ForEach(session.socialProfiles) { profile in
                        ProfileRow(profile: profile)
                    }
                }

                // Domain-keyed, since Google's centre indexes that way and no
                // account on the page improves on it.
                if let google = TagDecoder.signatures
                    .first(where: { $0.id == "google-ads" })?.adLibrary,
                   session.detectedTags.contains(where: { $0.vendorId == "google-ads" }) {
                    ProfileRow(profile: SocialProfile(
                        platform: "Google Ads", handle: session.siteDomain,
                        profileURL: "https://\(session.siteDomain)",
                        adLibraryURL: google.url(id: "", domain: session.siteDomain),
                        note: "searched by domain — no public API"
                    ))
                }
            }
            .padding(DevToolsTheme.barInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DetectedRow: View {
    let tag: DetectedTag
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(tag.name)
                .font(DevToolsTheme.chrome.weight(.medium))
                .frame(width: 168, alignment: .leading)
                .lineLimit(1)

            if tag.accountIds.isEmpty {
                Text("no id seen")
                    .font(DevToolsTheme.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(tag.accountIds.joined(separator: ", "))
                    .font(DevToolsTheme.mono)
                    .foregroundStyle(ElementsStyle.valueColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if tag.isSilent {
                // Installed and silent is usually a tag that threw, which looks
                // identical to working from the outside.
                Text("no events")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            } else {
                Text("\(tag.eventCount)")
                    .font(DevToolsTheme.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DevToolsTheme.rowInset)
        .padding(.vertical, 3)
        .background(isHovering ? DevToolsTheme.hoverFill : .clear)
        .onHover { isHovering = $0 }
        .help(tag.evidence.joined(separator: ", "))
    }
}

private struct EventRow: View {
    let event: TagEvent
    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(event.vendorName)
                    .font(DevToolsTheme.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 116, alignment: .leading)
                    .lineLimit(1)

                Text(event.name)
                    .font(DevToolsTheme.mono)
                    .foregroundStyle(ElementsStyle.attributeColor)

                Text(event.summary)
                    .font(DevToolsTheme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(Int(event.at.rounded())) ms")
                    .font(DevToolsTheme.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(event.parameters.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(key)
                                .font(DevToolsTheme.mono)
                                .foregroundStyle(ElementsStyle.attributeColor)
                                .frame(width: 130, alignment: .leading)
                                .lineLimit(1)
                            Text(event.parameters[key] ?? "")
                                .font(DevToolsTheme.mono)
                                .foregroundStyle(ElementsStyle.valueColor)
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Spacer(minLength: 2)
                        }
                    }
                }
                .padding(.leading, 122)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, DevToolsTheme.rowInset)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? DevToolsTheme.hoverFill : .clear)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() } }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Request URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(event.url, forType: .string)
            }
        }
    }
}

private struct ProfileRow: View {
    let profile: SocialProfile

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(profile.platform)
                        .font(DevToolsTheme.chrome.weight(.medium))
                    Text(profile.handle)
                        .font(DevToolsTheme.caption.monospaced())
                        .foregroundStyle(ElementsStyle.valueColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if profile.isExact {
                        // Worth marking: an exact id returns one advertiser,
                        // where a name search returns everyone who shares it.
                        Text("exact")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(NetworkStyle.success)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(NetworkStyle.success.opacity(0.15))
                            }
                    }
                }
                Text(profile.note)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if let library = profile.adLibraryURL, let url = URL(string: library) {
                Link("Their ads", destination: url)
                    .font(DevToolsTheme.chrome)
            }
            if let url = URL(string: profile.profileURL) {
                Link("Profile", destination: url)
                    .font(DevToolsTheme.chrome)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .fill(DevToolsTheme.inputFill)
        }
    }
}
