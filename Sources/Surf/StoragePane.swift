import SurfCore
import SwiftUI

/// What the site is keeping.
///
/// Two things here are impossible for an inspector built out of page script,
/// and they're the reason this pane is worth having rather than a `localStorage`
/// dump in the console. `HttpOnly` cookies — the ones that carry a session, and
/// the ones anyone opening a cookie panel is looking for — are hidden from
/// script by definition, and come from `WKHTTPCookieStore`. And per-origin site
/// data comes from `WKWebsiteDataStore`, where a page can only ever ask about
/// itself.
struct StoragePane: View {
    @Bindable var session: DevToolsSession

    var body: some View {
        VStack(spacing: 0) {
            areaPicker
            Divider()
            toolbar
            Divider()
            content
            Divider()
            footer
        }
        .task { await session.loadStorage() }
    }

    /// The stock segmented control, deliberately — same reasoning as the
    /// panel's old pane switcher: built against the macOS 26 SDK it adopts
    /// Liquid Glass on its own, and supplies the interaction, the metrics and
    /// "tab, 2 of 6" for VoiceOver. The hand-rolled chip row this replaces
    /// re-implemented all of that at 80% fidelity for zero gain.
    private var areaPicker: some View {
        HStack {
            Picker("Area", selection: $session.storageArea) {
                ForEach(StorageArea.allCases) { area in
                    Text(area.label).tag(area)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, 5)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if session.storageArea == .cookies {
                Toggle("All origins", isOn: $session.showsAllCookies)
                    .toggleStyle(.checkbox)
                    .font(DevToolsTheme.chrome)
                    .help("Show cookies for every site, not just this one")
            }

            if session.storageArea == .cookies || session.storageArea.isEditable {
                Button("Clear") {
                    Task { @MainActor in await session.clearStorageArea() }
                }
                .buttonStyle(.borderless)
                .font(DevToolsTheme.chrome)
                .help("Remove everything shown here")
            }

            Button {
                Task { @MainActor in await session.loadStorage() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Refresh")

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $session.storageQuery)
                    .textFieldStyle(.plain)
                    .font(DevToolsTheme.chrome)
                    .frame(width: 130)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                    .fill(DevToolsTheme.inputFill)
            }
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, DevToolsTheme.barVertical)
    }

    @ViewBuilder
    private var content: some View {
        if let error = session.storageError {
            DevToolsPlaceholder(
                symbol: "lock",
                title: "Storage is unavailable here",
                detail: error
            )
        } else {
            switch session.storageArea {
            case .cookies: cookieTable
            case .siteData: siteDataTable
            case .local, .session, .caches, .databases: itemTable
            }
        }
    }

    // MARK: - Cookies

    private var cookieTable: some View {
        Group {
            if session.visibleCookies.isEmpty {
                empty("No cookies", "This site hasn't set any.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.visibleCookies) { cookie in
                            CookieRow(cookie: cookie) {
                                Task { @MainActor in await session.deleteCookie(cookie) }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Key/value areas

    private var itemTable: some View {
        Group {
            if session.visibleItems.isEmpty {
                empty(
                    "Nothing stored",
                    session.storageArea == .caches
                        ? "No cache storage for this origin."
                        : "This origin has no \(session.storageArea.label.lowercased()) entries."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.visibleItems) { item in
                            ItemRow(
                                item: item,
                                isEditable: session.storageArea.isEditable,
                                onCommit: { value in
                                    Task { @MainActor in
                                        await session.setStorageValue(value, for: item.key)
                                    }
                                },
                                onDelete: {
                                    Task { @MainActor in
                                        await session.removeStorageItem(item.key)
                                    }
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Site data

    private var siteDataTable: some View {
        Group {
            if session.visibleSiteData.isEmpty {
                empty("No stored site data", "Nothing is being kept for any origin.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.visibleSiteData) { record in
                            SiteDataRow(record: record) {
                                Task { @MainActor in await session.clearSiteData(record) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        DevToolsPlaceholder(symbol: session.storageArea.symbol, title: title, detail: detail)
            .frame(maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            switch session.storageArea {
            case .cookies:
                let httpOnly = session.visibleCookies.filter(\.isHTTPOnly).count
                Text("\(session.visibleCookies.count) cookies")
                if httpOnly > 0 {
                    // Called out because it is the capability: these are the
                    // ones no page script can see.
                    Label("\(httpOnly) HttpOnly", systemImage: "lock.fill")
                        .foregroundStyle(Color.accentColor)
                        .help("Hidden from page scripts — readable only natively")
                }
            case .siteData:
                Text("\(session.visibleSiteData.count) origins")
            default:
                let bytes = session.visibleItems.reduce(0) { $0 + $1.size }
                Text("\(session.visibleItems.count) entries · \(ByteSize.format(bytes))")
            }

            Spacer(minLength: 8)

            if let usage = session.storageUsage {
                Text("\(ByteSize.format(usage.used)) of \(ByteSize.format(usage.quota)) used")
                    .help("Reported by the page's storage estimate")
            }
        }
        .font(DevToolsTheme.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, 5)
    }
}

private struct CookieRow: View {
    let cookie: StorageCookie
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(cookie.name)
                    .font(DevToolsTheme.mono)
                    .foregroundStyle(ElementsStyle.attributeColor)
                    .lineLimit(1)

                Text(cookie.value)
                    .font(DevToolsTheme.mono)
                    .foregroundStyle(ElementsStyle.valueColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if cookie.isHTTPOnly {
                    Badge(text: "HttpOnly", tint: .accentColor)
                        .help("Page scripts can't read this — Surf reads it natively")
                }
                if cookie.isSecure { Badge(text: "Secure", tint: .green) }
                if !cookie.sameSite.isEmpty { Badge(text: cookie.sameSite, tint: .secondary) }

                Text(cookie.expiryLabel())
                    .font(DevToolsTheme.caption)
                    .foregroundStyle(cookie.isExpired() ? .orange : .secondary)
                    .frame(width: 62, alignment: .trailing)

                if isHovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .help("Delete this cookie")
                }
            }

            if isExpanded {
                HStack(spacing: 8) {
                    Text(cookie.domain + cookie.path)
                        .font(DevToolsTheme.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    Text("\(ByteSize.format(cookie.size))")
                        .font(DevToolsTheme.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 2)
                }
                Text(cookie.value)
                    .font(DevToolsTheme.mono)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            Button("Copy Value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cookie.value, forType: .string)
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint.opacity(0.14))
            }
    }
}

private struct ItemRow: View {
    let item: StorageItem
    let isEditable: Bool
    let onCommit: (String) -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.key)
                    .font(DevToolsTheme.mono)
                    .foregroundStyle(ElementsStyle.attributeColor)
                    .frame(width: 150, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isEditing {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(DevToolsTheme.mono)
                        .onSubmit {
                            isEditing = false
                            onCommit(draft)
                        }
                        .onExitCommand { isEditing = false }
                } else if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(DevToolsTheme.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(item.preview)
                        .font(DevToolsTheme.mono)
                        .foregroundStyle(ElementsStyle.valueColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                if isHovering, isEditable {
                    Button(action: onDelete) {
                        Image(systemName: "trash").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .help("Remove this entry")
                }
            }
        }
        .padding(.horizontal, DevToolsTheme.rowInset)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? DevToolsTheme.hoverFill : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEditable else { return }
            draft = item.value
            isEditing = true
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.value, forType: .string)
            }
            if item.looksLikeJSON {
                Button("Copy Formatted") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(JSONPretty.format(item.value), forType: .string)
                }
            }
            if isEditable {
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }
}

private struct SiteDataRow: View {
    let record: SiteDataRecord
    let onClear: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(record.origin)
                .font(DevToolsTheme.mono)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 190, alignment: .leading)

            Text(record.types.joined(separator: ", "))
                .font(DevToolsTheme.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if isHovering {
                Button("Clear", action: onClear)
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                    .help("Remove everything this origin has stored")
            }
        }
        .padding(.horizontal, DevToolsTheme.rowInset)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? DevToolsTheme.hoverFill : .clear)
        .onHover { isHovering = $0 }
    }
}
