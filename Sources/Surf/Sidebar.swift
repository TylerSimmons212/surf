import AppKit
import SurfCore
import SwiftUI
import UniformTypeIdentifiers

/// The vertical tab list plus the navigation controls.
///
/// Everything that used to sit in a toolbar lives here, so the window itself is
/// nothing but page.
///
/// Every part below is a `View` struct rather than a method or computed
/// property on this one, and that is a performance decision rather than a
/// stylistic one. Under `@Observable`, a dependency read while a body runs is
/// attributed to *that body* — so a helper method returning a row makes the
/// whole sidebar depend on the row's tab. Written that way, one tab reporting
/// load progress re-evaluated the navigation bar, every visible row, both
/// buttons in each of them, and the new-tab button. Split like this, each piece
/// depends only on what it actually reads.
struct Sidebar: View {
    let session: BrowserSession
    @Binding var isPinned: Bool
    /// Floating mode draws its own material panel; pinned sits on the window's
    /// glass. Also shifts the top inset: the floating panel already starts
    /// below the traffic lights' row, so it has less of it left to clear.
    let isFloating: Bool
    /// Whether the traffic lights are currently overlaying the window's corner
    /// — which is this panel's corner too, whenever it's pinned.
    let lightsRevealed: Bool
    /// Lets the sidebar's own transient UI keep it on screen.
    let hold: SidebarHold
    /// The in-flight tab drag, owned by the window: a drag that starts on a row
    /// can end on the page, so the drop zones over the content area have to be
    /// watching the same object the rows write to.
    let dragContext: TabDragContext

    @State private var isHoveringNewTab = false

    /// Wide enough that the roomier rows don't buy their height back out of
    /// the title: taller rows with the same width would just truncate sooner.
    static let width: CGFloat = 264
    /// Two 21pt controls and the gap between them.
    static let actionsWidth: CGFloat = 44

    /// How far the floating panel is held off the top of the window.
    static let floatingTopPadding: CGFloat = 4

    /// Steps out of the traffic lights' way — but only while they're actually
    /// there.
    ///
    /// Holding this space permanently rebuilds, inside the sidebar, exactly the
    /// dead strip that removing the title bar was meant to reclaim: the lights
    /// are hidden almost all of the time, so almost all of the time it reserved
    /// room for nothing.
    ///
    /// A pinned panel is the case that needs it, since it's on screen no matter
    /// what the pointer is doing and the lights can appear right on top of its
    /// back and forward buttons. A floating panel is nearly always spared by
    /// arbitration — it holds the corner while the pointer is inside it, so the
    /// lights don't reveal — and this only covers the moment one is animating
    /// out as the other fades in.
    ///
    /// Measured from the window's top edge, so the floating panel subtracts the
    /// gap it's already sitting below.
    private var topInset: CGFloat {
        guard lightsRevealed else { return 0 }
        return ChromeReveal.lightsRowHeight - (isFloating ? Sidebar.floatingTopPadding : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarNavigationBar(session: session, isPinned: $isPinned, hold: hold)
            StickerShelf(session: session)
            tabList
            SidebarMediaSection(session: session)
            IslandStrip(session: session, hold: hold)
        }
        .padding(.top, topInset)
        // Matched to the lights' own fade, so the room appears as they do
        // rather than as a separate jolt just after them.
        .animation(.easeOut(duration: 0.18), value: topInset)
        .frame(width: Sidebar.width)
    }

    // MARK: - Tabs

    private var tabList: some View {
        // The geometry is for the stack's `minHeight` below — a scroll view
        // sizes its content to the content, so without it the list is only as
        // tall as its rows and the empty space beneath them belongs to nothing.
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(sections) { section in
                        if let group = section.group {
                            GroupHeaderRow(
                                session: session,
                                dragContext: dragContext,
                                group: group,
                                tabCount: section.tabCount,
                                holdsSelection: section.holdsSelection
                            )
                            if !group.isCollapsed {
                                ForEach(section.entries) { entry in
                                    content(for: entry)
                                        // Indented, and over a rule that runs the
                                        // height of the section: the header alone
                                        // says where a section starts but nothing
                                        // says where it ends, and two sections in a
                                        // row read as one long list otherwise.
                                        .padding(.leading, 12)
                                        .background(alignment: .leading) {
                                            Rectangle()
                                                .fill(Color.primary.opacity(0.10))
                                                .frame(width: 1)
                                                .padding(.leading, 4)
                                        }
                                }
                            }
                        } else {
                            ForEach(section.entries) { entry in
                                content(for: entry)
                            }
                        }
                    }
                    newTabButton
                        // Dropping below the last row — on the New Tab button —
                        // files the tab at the end rather than dead-ending the drag.
                        .onDrop(of: [.text], delegate: TabReorderDropDelegate(
                            targetID: nil,
                            drag: dragContext,
                            session: session
                        ))
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .animation(.snappy(duration: 0.26, extraBounce: 0), value: session.split)
                // Right-clicking past the last row is the one place in the
                // sidebar with no tab under the pointer, so it's where "start a
                // section from scratch" belongs. `minHeight` is what makes that
                // space part of the list rather than bare scroll view — and it
                // is a floor, not a size, so a list longer than the panel still
                // scrolls.
                .frame(minHeight: proxy.size.height, alignment: .top)
                .contentShape(Rectangle())
                .contextMenu {
                    // A section has to contain something — an empty one has no
                    // position in the list and nothing to draw — so this makes
                    // the tab as well.
                    Button("New Group") { session.createGroupWithNewTab() }
                }
            }
        }
    }

    @ViewBuilder
    private func content(for entry: SidebarEntry) -> some View {
        switch entry {
        case .single(let tab):
            row(for: tab)
        case .pair(let anchor, let leading, let trailing):
            SplitPairRow(
                session: session,
                dragContext: dragContext,
                leading: leading,
                trailing: trailing
            )
            // The pair is one row as far as the list is concerned, so a tab
            // dropped on it lands where the group sits rather than between its
            // halves.
            .onDrop(of: [.text], delegate: TabReorderDropDelegate(
                targetID: anchor,
                drag: dragContext,
                session: session
            ))
        }
    }

    /// The list as sections: runs of consecutive tabs sharing a group, and runs
    /// of ungrouped ones.
    ///
    /// Sections come from the tab order rather than from a list held on each
    /// group, so there is nothing to keep in step — where a section sits *is*
    /// where its tabs sit.
    private var sections: [SidebarSection] {
        var sections: [SidebarSection] = []
        for entry in entries {
            let groupID = entry.groupID
            let selected = entry.holds(session.selectedTabID)
            if var last = sections.last, last.group?.id == groupID {
                last.entries.append(entry)
                last.holdsSelection = last.holdsSelection || selected
                sections[sections.count - 1] = last
            } else {
                sections.append(SidebarSection(
                    group: groupID.flatMap { session.group($0) },
                    entries: [entry],
                    holdsSelection: selected
                ))
            }
        }
        // A group whose tabs somehow aren't consecutive would draw as two
        // sections wearing the same name. `Island.normalizeGroups` is what
        // prevents it; this is only the reader.
        return sections
    }

    /// The list as rows: tabs on their own, plus the split pair drawn as a
    /// single side-by-side row.
    ///
    /// The pair takes the slot of whichever of its tabs comes first, so pairing
    /// never makes the group jump to somewhere else in the list.
    ///
    /// While one of the two is being dragged they come apart and show as
    /// ordinary rows. Pulling a tab out of the group is how a split is ended,
    /// and that only reads as pulling it out if the group actually opens as you
    /// pull — held together, the dragged row would have nowhere to move to and
    /// the drag would look broken.
    private var entries: [SidebarEntry] {
        let tabs = session.tabs
        let isPullingApart = !dragContext.isDraggingPair
            && dragContext.settledDragID.map { id in
                session.split?.contains(id) == true
            } ?? false

        guard !isPullingApart,
              let split = session.split,
              let leading = tabs.first(where: { $0.id == split.leading }),
              let trailing = tabs.first(where: { $0.id == split.trailing })
        else { return tabs.map(SidebarEntry.single) }

        var entries: [SidebarEntry] = []
        var placed = false
        for tab in tabs {
            guard split.contains(tab.id) else {
                entries.append(.single(tab))
                continue
            }
            guard !placed else { continue }
            placed = true
            entries.append(.pair(anchor: tab.id, leading: leading, trailing: trailing))
        }
        return entries
    }

    private func row(for tab: Tab) -> some View {
        let isDragged = dragContext.draggedID == tab.id

        return TabRow(
            tab: tab,
            isSelected: tab.id == session.selectedTabID,
            onSelect: { session.select(tab) },
            onClose: { session.close(tab) }
        )
        // While a tab rides the cursor as the drag preview, its row becomes an
        // empty slot: same footprint, no content — the tab appears once, and
        // the slot is where it lands. `opacity`, not `hidden`, so the slot
        // keeps taking drops.
        .opacity(isDragged ? 0 : 1)
        .background {
            if isDragged {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        // Rounds the floating snapshot to match the row it left.
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onDrag {
            dragContext.begin(tab.id) { session.commitTabReorder() }
        }
        // The reorder happens in `dropEntered`, not on release — the slot
        // slides through the list as the drag crosses rows, so the drop is
        // letting go of an order already shown.
        .onDrop(of: [.text], delegate: TabReorderDropDelegate(
            targetID: tab.id,
            drag: dragContext,
            session: session
        ))
        // One menu for the row, and it has to be this one: a `contextMenu` on
        // `TabRow` itself would be the inner of two nested menus and win
        // outright, leaving everything below unreachable by right-click.
        .contextMenu {
            TabRowMenu(
                session: session,
                tab: tab,
                // Wrapped at the mutation, because that is what drives the
                // new tile's slap-on transition.
                onPin: {
                    withAnimation(StickerShelf.slap) {
                        session.pinSticker(for: tab)
                    }
                }
            )
        }
    }

    private var newTabButton: some View {
        Button {
            // A new tab is a request to go somewhere, so ask where immediately
            // rather than presenting a screen that asks the same thing.
            session.openNewTabAndPrompt()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(isHoveringNewTab ? 90 : 0))
                    .scaleEffect(isHoveringNewTab ? 1.15 : 1)
                Text("New Tab")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(isHoveringNewTab ? 0.07 : 0))
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.65), value: isHoveringNewTab)
        .onHover { isHoveringNewTab = $0 }
        .help("New Tab (⌘T)")
    }
}

// MARK: - Sections

/// One run of the list: a named section, or the ungrouped rows between two.
@MainActor
private struct SidebarSection: Identifiable {
    var group: TabGroup?
    var entries: [SidebarEntry]
    /// Whether the tab on screen is in here. Passed in rather than derived,
    /// because only the caller knows what's selected.
    var holdsSelection = false

    /// Group ids and tab ids are both UUIDs from disjoint sets, so either
    /// serves as identity and a section never collides with a loose run.
    ///
    /// `nonisolated` because `Identifiable` is: both sources are `let`
    /// constants that never move off the main actor's word, so the conformance
    /// doesn't have to hop onto it to read them.
    nonisolated var id: UUID { group?.id ?? entries[0].id }

    /// Tabs, not rows — a split pair is one row holding two.
    var tabCount: Int {
        entries.reduce(0) { count, entry in
            switch entry {
            case .single: count + 1
            case .pair: count + 2
            }
        }
    }

}

/// A section's header: its name, how many tabs are in it, and the control that
/// folds it away.
///
/// Also the handle for the section as a whole — dragging it moves every tab
/// under it at once, the way the split pair's spine moves both its halves.
private struct GroupHeaderRow: View {
    let session: BrowserSession
    let dragContext: TabDragContext
    let group: TabGroup
    let tabCount: Int
    /// Whether the tab on screen is inside this section. Only interesting while
    /// it's collapsed, when the row that would have shown it is folded away.
    let holdsSelection: Bool

    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    private var isCarried: Bool { dragContext.draggedGroupID == group.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                .animation(.snappy(duration: 0.22, extraBounce: 0), value: group.isCollapsed)

            if isRenaming {
                // SwiftUI's own field, and `@FocusState` rather than the
                // app's `SurfTextField`. That one asks AppKit for first
                // responder directly, which is the right answer when it opens a
                // screen — and the wrong one here, where it appears mid-click
                // inside a scroll view: SwiftUI's focus system put the window
                // back as first responder on the way out of the gesture, so the
                // editor opened with the caret nowhere and typing went to the
                // window. Asking through `@FocusState` is asking the system
                // that was overruling it.
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .focused($isFieldFocused)
                    .onSubmit(commitRename)
                    // Escape abandons the edit. Without it the only way out is
                    // to commit, so a rename begun by accident has to be undone
                    // by hand.
                    .onExitCommand { isRenaming = false }
                    // Clicking elsewhere in the sidebar doesn't move first
                    // responder — a text field keeps it until something else
                    // asks, which is ordinary AppKit and not worth fighting.
                    // What can't be allowed is an editor left open behind the
                    // user's back, so the two ways out that don't involve a key
                    // are handled directly. Both save rather than discard: the
                    // editor is a label you type into, and a label edit that
                    // evaporates when you look away loses work for no reason.
                    .onChange(of: isFieldFocused) { _, focused in
                        if !focused { commitRename() }
                    }
                    // Selecting a tab is the usual way of clicking away.
                    .onChange(of: session.selectedTabID) { _, _ in commitRename() }
            } else {
                Text(group.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Says what's folded away. Shown expanded too, because a section's
            // size is worth knowing before you decide to collapse it.
            Text("\(tabCount)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background { Capsule().fill(Color.primary.opacity(0.07)) }

            // The page you're looking at is in here somewhere. Collapsing a
            // section that holds the current tab is allowed — you may well want
            // it out of the way — but the sidebar can't then be showing nothing
            // selected at all.
            if group.isCollapsed, holdsSelection {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
                .animation(.easeOut(duration: 0.16), value: isHovered)
        }
        .opacity(isCarried ? 0 : 1)
        .onHover { isHovered = $0 }
        // Declared before the single tap, which is what makes a double click
        // reach it: with both on one view SwiftUI gives the first-declared
        // gesture the chance to claim the sequence, so the fold waits out the
        // double-click interval rather than firing on the way to a rename.
        .onTapGesture(count: 2) {
            guard !isRenaming else { return }
            beginRename()
        }
        // A single click folds; the whole header is the target, because a
        // chevron alone is a 9pt hit area on a row that has room to spare.
        .onTapGesture {
            guard !isRenaming else { return }
            withAnimation(.snappy(duration: 0.26, extraBounce: 0)) {
                session.toggleGroup(group.id)
            }
        }
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onDrag {
            beginGroupDrag()
        } preview: {
            dragPreview
        }
        .onDrop(of: [.text], delegate: GroupHeaderDropDelegate(
            group: group,
            drag: dragContext,
            session: session
        ))
        // A floating sidebar hides the moment the pointer leaves it, taking a
        // half-finished rename with it — and the field would be sitting there
        // still open the next time the panel came back.
        .onDisappear { commitRename() }
        .contextMenu {
            Button(group.isCollapsed ? "Expand" : "Collapse") {
                session.toggleGroup(group.id)
            }
            Button("Rename…") { beginRename() }
            Divider()
            Button("Ungroup") { session.ungroup(group.id) }
            Button("Close \(tabCount) Tabs") { session.closeGroup(group.id) }
        }
    }

    private func beginRename() {
        draft = group.name
        isRenaming = true
        // After the field exists to receive it.
        Task { @MainActor in isFieldFocused = true }
    }

    /// Saving is the same on Enter and on clicking away.
    ///
    /// Guarded because both can arrive for one edit — committing with Enter
    /// takes the field down, which ends editing, which reports it again.
    /// Escape clears the flag first, so an abandoned edit passes through here
    /// without saving anything.
    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        session.renameGroup(group.id, to: draft)
    }

    private func beginGroupDrag() -> NSItemProvider {
        // Not while the name is being edited: a drag starting inside the field
        // is someone selecting text, not moving a section.
        guard !isRenaming else { return NSItemProvider() }
        // The section stands in for itself by its first tab, which is also the
        // slot the reorder moves.
        guard let first = session.tabs(in: group.id).first else {
            return NSItemProvider(object: group.id.uuidString as NSString)
        }
        return dragContext.beginGroup(group.id, firstID: first.id) {
            session.commitTabReorder()
        }
    }

    /// Named rather than snapshotted: the header is a thin strip, and dragging
    /// it should look like carrying a section, not a caption.
    private var dragPreview: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder")
                .font(.system(size: 11))
            Text(group.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Text("\(tabCount)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: Sidebar.width - 16, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.12))
        }
    }
}

/// Dropping onto a section's header files the tab at the end of that section.
///
/// The header is the one part of a section that stays put when it's collapsed,
/// which makes it the only way to put a tab into a section you've folded away.
private struct GroupHeaderDropDelegate: DropDelegate {
    let group: TabGroup
    let drag: TabDragContext
    let session: BrowserSession

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let dragged = drag.draggedID
        let carriedGroup = drag.draggedGroupID
        defer { drag.end() }

        guard let dragged else { return false }

        withAnimation(.snappy(duration: 0.26, extraBounce: 0)) {
            if let carriedGroup, carriedGroup != group.id {
                // Section onto section: go ahead of it, since they don't nest.
                if let first = session.tabs(in: group.id).first {
                    session.moveGroup(carriedGroup, before: first.id)
                    session.commitTabReorder()
                }
            } else if carriedGroup == nil, let tab = session.tabs.first(where: { $0.id == dragged }) {
                session.addTab(tab, to: group.id)
            }
        }
        return true
    }
}

/// What right-clicking a tab offers, beyond what its own buttons already do.
private struct TabRowMenu: View {
    let session: BrowserSession
    let tab: Tab
    let onPin: () -> Void

    var body: some View {
        // A home tab has no page to pin or copy, so both items would only ever
        // silently do nothing there.
        if tab.mode == .browsing {
            Button(action: onPin) {
                Label("Add Sticker", systemImage: "star.square.on.square")
            }
            Button(action: copyURL) {
                Label("Copy Link", systemImage: "link")
            }
            Divider()
        }

        Button("New Group with This Tab") { session.createGroup(with: tab) }

        // Only worth offering when there is somewhere else to put it.
        let others = session.groups.filter { $0.id != tab.groupID }
        if !others.isEmpty {
            Menu("Add to Group") {
                ForEach(others) { group in
                    Button(group.name) { session.addTab(tab, to: group.id) }
                }
            }
        }

        if tab.groupID != nil {
            Button("Remove from Group") { session.removeFromGroup(tab) }
        }

        Divider()

        Button(role: .destructive) { session.close(tab) } label: {
            Label("Close Tab", systemImage: "xmark")
        }
    }

    private func copyURL() {
        let url = tab.currentURL ?? tab.addressText
        guard !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}

// MARK: - Split pair

/// One line of the tab list.
@MainActor
private enum SidebarEntry: Identifiable {
    case single(Tab)
    /// The two tabs on screen together, drawn as one row. `anchor` is the tab
    /// whose slot the group occupies — the earlier of the two in the list.
    case pair(anchor: Tab.ID, leading: Tab, trailing: Tab)

    nonisolated var id: Tab.ID {
        switch self {
        case .single(let tab): tab.id
        case .pair(let anchor, _, _): anchor
        }
    }

    /// Which section this row sits in. A split's two halves are always filed
    /// together — `setSplit` sees to that — so the leading one answers for both.
    var groupID: UUID? {
        switch self {
        case .single(let tab): tab.groupID
        case .pair(_, let leading, _): leading.groupID
        }
    }

    func holds(_ id: Tab.ID) -> Bool {
        switch self {
        case .single(let tab): tab.id == id
        case .pair(_, let leading, let trailing): leading.id == id || trailing.id == id
        }
    }
}

/// The split pair as one row: both tabs side by side, in the same order as the
/// panes they stand for.
///
/// Grouping them is what makes a split legible from the list. Left as two
/// ordinary rows, a split showed up as one highlighted row and one that looked
/// like any other — nothing said the two pages were on screen together, and
/// nothing said which was on which side. Here the row is a small picture of the
/// window.
private struct SplitPairRow: View {
    let session: BrowserSession
    let dragContext: TabDragContext
    let leading: Tab
    let trailing: Tab

    @State private var isHoveringSeam = false
    @State private var isHoveringGrip = false

    private var isCarried: Bool { dragContext.draggedID == leading.id && dragContext.isDraggingPair }

    var body: some View {
        HStack(spacing: 0) {
            grip
            half(leading)
            seam
            half(trailing)
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
                }
        }
        // Carried as one thing, so it empties as one thing — the same slot the
        // single rows leave behind.
        .opacity(isCarried ? 0 : 1)
        .background {
            if isCarried {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
    }

    /// The handle for the group as a whole.
    ///
    /// Without it the pair could only be taken apart, never moved: every other
    /// drag on this row is a drag of one half, and one half leaving is what ends
    /// the split. Repositioning a split in the list would have meant breaking
    /// it, moving two tabs, and building it again.
    ///
    /// A spine rather than a button-sized control — it reads as the thing that
    /// binds the two rows together, which is exactly what you take hold of to
    /// move both.
    private var grip: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color.accentColor.opacity(isHoveringGrip ? 0.9 : 0.45))
            .frame(width: 3)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 5)
            .frame(width: 11)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringGrip = hovering
                // Balanced by the `else`, and by `onDisappear` for the case the
                // row is rebuilt from under the pointer — an unmatched push
                // leaves the whole app wearing an open hand.
                if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if isHoveringGrip {
                    isHoveringGrip = false
                    NSCursor.pop()
                }
            }
            .animation(.easeOut(duration: 0.14), value: isHoveringGrip)
            .onDrag {
                dragContext.beginPair(leading.id) { session.commitTabReorder() }
            } preview: {
                dragPreview
            }
            .help("Drag to move both tabs")
    }

    /// What rides the cursor during a pair drag.
    ///
    /// Spelled out rather than letting the drag take a snapshot of the grip: the
    /// preview defaults to the view the gesture is attached to, and a 3pt spine
    /// floating across the screen says nothing about what is being moved.
    private var dragPreview: some View {
        HStack(spacing: 7) {
            StatusIcon(tab: leading)
            Text(leading.displayTitle)
                .lineLimit(1)
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            StatusIcon(tab: trailing)
            Text(trailing.displayTitle)
                .lineLimit(1)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: Sidebar.width - 16)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                }
        }
    }

    private func half(_ tab: Tab) -> some View {
        CompactTabRow(
            tab: tab,
            isSelected: tab.id == session.selectedTabID,
            isDragged: dragContext.draggedID == tab.id,
            onSelect: { session.select(tab) },
            onClose: { session.close(tab) }
        )
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onDrag {
            dragContext.begin(tab.id) { session.commitTabReorder() }
        }
        .onDrop(of: [.text], delegate: PaneSlotDropDelegate(
            targetID: tab.id,
            drag: dragContext,
            session: session
        ))
    }

    /// The seam between the halves, which is also the way out: it stands for
    /// the divider in the window, so clicking it to close the split is the same
    /// gesture as pulling the two pages apart.
    private var seam: some View {
        Button {
            withAnimation(.snappy(duration: 0.26, extraBounce: 0)) {
                session.closeSplit()
            }
        } label: {
            ZStack {
                Capsule()
                    .fill(Color.primary.opacity(isHoveringSeam ? 0.22 : 0.10))
                    .frame(width: 2)
                if isHoveringSeam {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background { Circle().fill(.regularMaterial) }
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .frame(width: 15)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringSeam = $0 }
        .animation(.easeOut(duration: 0.14), value: isHoveringSeam)
        .help("Close Split (\u{2318}\u{21E7}D)")
    }
}

/// Half of a split pair.
///
/// The copy-link button the full row carries is dropped rather than shrunk: at
/// half width there is barely room for a title, and two controls over it would
/// leave the name showing three characters.
private struct CompactTabRow: View {
    let tab: Tab
    let isSelected: Bool
    let isDragged: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            StatusIcon(tab: tab)

            Text(tab.displayTitle)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(tab.isAwaitingRestore ? 0.55 : 1)

            Spacer(minLength: 0)
        }
        .mask { titleFade }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .overlay(alignment: .trailing) { closeButton }
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.16 : (isHovered ? 0.07 : 0)))
                .animation(.easeOut(duration: 0.16), value: isHovered)
                .animation(.easeOut(duration: 0.2), value: isSelected)
        }
        // Same empty-slot treatment as a full row, so pulling a pane out of the
        // group looks like the one gesture it is.
        .opacity(isDragged ? 0 : 1)
        .onHover { isHovered = $0 }
        .help(tab.displayTitle)
    }

    private var closeButton: some View {
        IconButton(
            systemName: "xmark",
            size: 9,
            weight: .bold,
            width: 18,
            height: 18,
            cornerRadius: 5,
            help: "Close Tab (\u{2318}W)"
        ) {
            onClose()
        }
        .opacity(isHovered ? 1 : 0)
        .scaleEffect(isHovered ? 1 : 0.7, anchor: .trailing)
        .allowsHitTesting(isHovered)
        .animation(.spring(response: 0.26, dampingFraction: 0.7), value: isHovered)
    }

    private var titleFade: some View {
        HStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: isHovered ? 12 : 0)
            Color.clear
                .frame(width: isHovered ? 18 : 0)
        }
        .animation(.easeOut(duration: 0.2), value: isHovered)
    }
}

/// Drops onto one half of the pair, where the half stands for the pane.
///
/// Two meanings, both the obvious reading of the gesture: the other half means
/// swap the sides, and any other tab means put that page in this pane.
private struct PaneSlotDropDelegate: DropDelegate {
    let targetID: Tab.ID
    let drag: TabDragContext
    let session: BrowserSession

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let dragged = drag.draggedID
        defer { drag.end() }

        guard let dragged, dragged != targetID, !drag.isDraggingPair, !drag.isDraggingGroup,
              let split = session.split,
              let side = split.side(of: targetID)
        else { return false }

        withAnimation(.snappy(duration: 0.26, extraBounce: 0)) {
            if split.contains(dragged) {
                session.swapSplitSides()
            } else if let tab = session.tabs.first(where: { $0.id == dragged }) {
                session.openSplit(with: tab, on: side)
            }
        }
        return true
    }
}

// MARK: - Reordering

/// Tracks the in-flight reorder drag.
///
/// An `@Observable` object rather than plain sidebar `@State`, because ending
/// a drag is not something SwiftUI always reports: a drop outside every target
/// — on the page, on another app, or an Esc cancel — ends the session with no
/// `performDrop`. With the dragged row hidden behind an empty slot, missing
/// that end would leave an invisible tab in the list. The item provider is the
/// one object whose lifetime exactly matches the drag session, so a sentinel
/// rides on it and clears this state from its deinit however the drag ends.
@MainActor
@Observable
final class TabDragContext {
    private(set) var draggedID: Tab.ID?

    /// The same tab, but published a turn later.
    ///
    /// The sidebar takes the split pair apart while one of its halves is being
    /// dragged — which removes the very row the drag started from. Doing that
    /// from inside the `onDrag` closure, before it has even returned its item
    /// provider, tears the gesture's own view out from under it and the drag
    /// never starts: the pointer moves, nothing follows it, and letting go does
    /// nothing. Anything that *restructures the list* keys off this instead, so
    /// the drag session is underway before its source row can be rebuilt.
    ///
    /// Anything that only restyles a row in place — the empty slot — can and
    /// should use `draggedID`, which lands immediately.
    private(set) var settledDragID: Tab.ID?

    /// Whether this drag has actually relocated the tab yet.
    ///
    /// The obvious test for "was it dropped somewhere else" — comparing the
    /// drop target against the dragged tab — is wrong, and silently so. Rows
    /// reorder live, so by the time the pointer is released the slot underneath
    /// it *is* the dragged tab's own: the comparison says "dropped on itself"
    /// for every successful drag in the list. What the split needs to know is
    /// whether the tab moved at all, which only the reorder itself can say.
    @ObservationIgnored private(set) var didMove = false

    func noteMoved() { didMove = true }

    /// The group being dragged by its header, if that's what this drag is.
    @ObservationIgnored private(set) var draggedGroupID: UUID?

    var isDraggingGroup: Bool { draggedGroupID != nil }

    /// Whether the split pair is being dragged as one, rather than a single tab.
    ///
    /// `draggedID` still names the leading half, so the empty slot and the
    /// reorder both have something to key off — but everything that asks "which
    /// tab is being moved" has to know the answer is "both of them".
    @ObservationIgnored private(set) var isDraggingPair = false

    /// Whether a tab is currently being carried.
    var isDragging: Bool { draggedID != nil }

    /// Whether a *single* tab is being carried. The split drop zones over the
    /// page only mean anything for one: dropping a pair on the page would be
    /// asking to split a tab against its own partner.
    var isDraggingLoneTab: Bool { isDragging && !isDraggingPair && !isDraggingGroup }

    /// Stamps each drag so a stale sentinel — drag N's provider released after
    /// drag N+1 already began — can't clear the wrong session.
    private var generation = 0

    /// Run once the drag is over, however it ended. Reordering happens live as
    /// the drag crosses rows, so by this point the model has already changed
    /// and needs persisting — a cancelled drag included, since "cancelled"
    /// only means the pointer let go somewhere unhelpful, not that the rows
    /// went back.
    @ObservationIgnored private var onEnd: (@MainActor () -> Void)?

    /// Starts a drag of a whole section. `firstID` — its first tab — stands in
    /// for it, so the empty slot and the reorder have something to key off.
    func beginGroup(
        _ groupID: UUID,
        firstID: Tab.ID,
        onEnd: @escaping @MainActor () -> Void
    ) -> NSItemProvider {
        let provider = begin(firstID, onEnd: onEnd)
        draggedGroupID = groupID
        return provider
    }

    /// Starts a drag of the whole split pair. `leadingID` stands in for it.
    func beginPair(_ leadingID: Tab.ID, onEnd: @escaping @MainActor () -> Void) -> NSItemProvider {
        let provider = begin(leadingID, onEnd: onEnd)
        isDraggingPair = true
        return provider
    }

    func begin(_ id: Tab.ID, onEnd: @escaping @MainActor () -> Void) -> NSItemProvider {
        draggedID = id
        didMove = false
        isDraggingPair = false
        draggedGroupID = nil
        self.onEnd = onEnd
        generation += 1
        let gen = generation
        let provider = SentinelItemProvider(object: id.uuidString as NSString)
        provider.onDeinit = { [weak self] in
            // Deinit happens on whatever thread lets go last.
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.finish()
            }
        }
        // Deliberately after this closure returns. See `settledDragID`.
        Task { @MainActor [weak self] in
            guard let self, self.generation == gen else { return }
            self.settledDragID = id
        }
        return provider
    }

    /// Ends the drag now, rather than waiting for the provider to be released.
    /// A completed drop knows it's over; the sentinel is only there for the
    /// endings SwiftUI doesn't report.
    func end() {
        generation += 1
        finish()
    }

    private func finish() {
        guard draggedID != nil || onEnd != nil else { return }
        draggedID = nil
        settledDragID = nil
        isDraggingPair = false
        draggedGroupID = nil
        let onEnd = self.onEnd
        self.onEnd = nil
        onEnd?()
    }
}

/// An item provider that reports its own release — the only reliable signal
/// that a drag session is over, completed or cancelled.
private final class SentinelItemProvider: NSItemProvider {
    var onDeinit: (@Sendable () -> Void)?
    deinit { onDeinit?() }
}

/// Reorders tabs live as a drag crosses their rows.
///
/// One delegate per row (`targetID` set) plus one on the New Tab button
/// (`targetID` nil, meaning "the end of the list"). The moved tab is tracked in
/// `TabDragContext` rather than decoded from the item provider, because
/// `dropEntered` is synchronous and provider loading is not.
private struct TabReorderDropDelegate: DropDelegate {
    /// The tab whose slot the dragged tab should take — nil for "the end".
    let targetID: Tab.ID?
    let drag: TabDragContext
    let session: BrowserSession

    func dropEntered(info: DropInfo) {
        guard let draggedID = drag.draggedID, draggedID != targetID else { return }
        // Short and bounceless on purpose. Dragging briskly down a long list
        // fires this once per row crossed, and a springy curve leaves each
        // crossing still settling as the next arrives — the overlap is what
        // read as lag. This lands before the next row is reached.
        withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
            let moved: Bool
            if let groupID = drag.draggedGroupID {
                moved = targetID.map { session.moveGroup(groupID, before: $0) }
                    ?? session.moveGroupToEnd(groupID)
            } else if drag.isDraggingPair {
                moved = targetID.map { session.moveSplitPair(before: $0) }
                    ?? session.moveSplitPairToEnd()
            } else {
                moved = targetID.map { session.moveTab(draggedID, before: $0) }
                    ?? session.moveTabToEnd(draggedID)
            }
            if moved { drag.noteMoved() }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Move, not copy — no green plus badge on the cursor.
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let dragged = drag.draggedID
        defer { drag.end() }

        // Dragging a tab out of the pair is the way out of a split that doesn't
        // need the menu: the group in the list *is* the split, so pulling a row
        // out of it takes that page off the screen.
        //
        // A drag that ends where it started hasn't pulled anything out — that's
        // picking a tab up and changing your mind, and it leaves the pair
        // alone. The focused pane is the one kept, so ending the split this way
        // never also changes which page you were reading.
        if let dragged, drag.didMove, !drag.isDraggingPair, !drag.isDraggingGroup,
           session.split?.contains(dragged) == true {
            withAnimation(.snappy(duration: 0.26, extraBounce: 0)) {
                session.closeSplit()
            }
        }
        return true
    }
}

// MARK: - Media

/// Its own view purely so that reading `mediaTabs` — which touches the media
/// state of *every* tab in the session — doesn't make the whole sidebar depend
/// on all of it. A playing tab reports its position about once a second.
private struct SidebarMediaSection: View {
    let session: BrowserSession

    var body: some View {
        let mediaTabs = session.mediaTabs
        Group {
            if !mediaTabs.isEmpty {
                MediaPlayerStack(session: session)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: mediaTabs.count)
    }
}

// MARK: - Navigation

/// The back/forward/reload row. Separated because it reads the selected tab's
/// `progress`, which `WKWebView` reports many times per load.
private struct SidebarNavigationBar: View {
    let session: BrowserSession
    @Binding var isPinned: Bool
    let hold: SidebarHold

    var body: some View {
        let tab = session.selectedTab

        return HStack(spacing: 2) {
            IconButton(
                systemName: "chevron.left",
                isEnabled: tab.canGoBack,
                drawsIn: true,
                help: "Back (⌘[)"
            ) { tab.goBack() }

            IconButton(
                systemName: "chevron.right",
                isEnabled: tab.canGoForward,
                drawsIn: true,
                help: "Forward (⌘])"
            ) { tab.goForward() }

            // While loading, the arrow spins and a ring around it fills with
            // real progress; it only becomes a stop button under the pointer.
            // The control reports state at rest and offers the action on hover.
            ReloadControl(tab: tab)

            Spacer()

            // Zoom has no other visible home, and a page stuck at 125% with
            // nothing saying so reads as a rendering bug.
            if tab.isZoomed {
                Button { tab.resetZoom() } label: {
                    Text(tab.zoomLabel)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background { Capsule().fill(Color.primary.opacity(0.09)) }
                }
                .buttonStyle(.plain)
                .help("Reset zoom (⌘0)")
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }

            BlockButton(session: session, hold: hold)

            DownloadsButton(session: session, hold: hold)

            IconButton(
                systemName: "magnifyingglass",
                motion: .pulse,
                drawsIn: true,
                help: "Open Address Bar (⌘L)"
            ) { session.requestAddressFocus() }

            IconButton(
                systemName: isPinned ? "sidebar.left" : "pin",
                drawsIn: true,
                help: isPinned ? "Unpin Sidebar (⌘S)" : "Pin Sidebar (⌘S)"
            ) {
                isPinned.toggle()
            }
            .animation(.easeOut(duration: 0.2), value: isPinned)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: tab.isZoomed)
    }
}

/// The reload button and its progress ring.
///
/// Split out from the navigation bar for the same reason the bar is split from
/// the sidebar: `progress` changes continuously while a page loads, and this is
/// the only thing that reads it. Now that is all it re-renders.
private struct ReloadControl: View {
    let tab: Tab

    var body: some View {
        ZStack {
            IconButton(
                systemName: "arrow.clockwise",
                hoverSymbol: tab.isLoading ? "xmark" : nil,
                isEnabled: tab.mode == .browsing,
                isSpinning: tab.isLoading,
                help: tab.isLoading ? "Stop" : "Reload (⌘R)"
            ) {
                tab.isLoading ? tab.stop() : tab.reload()
            }

            if tab.isLoading {
                progressRing(tab.progress)
            }
        }
        .animation(.easeOut(duration: 0.2), value: tab.isLoading)
    }

    /// Load progress drawn around the reload button, so the control *is* the
    /// indicator and no separate bar is needed.
    private func progressRing(_ progress: Double) -> some View {
        Circle()
            // A floor keeps a visible arc at 0%, so the ring appears the moment
            // loading starts rather than materialising partway through.
            .trim(from: 0, to: max(0.04, progress))
            .stroke(
                Color.accentColor,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )
            // Starts the arc at twelve o'clock instead of three.
            .rotationEffect(.degrees(-90))
            .frame(width: 21, height: 21)
            .animation(.easeOut(duration: 0.25), value: progress)
            .transition(.opacity.combined(with: .scale(scale: 0.7)))
            // Purely decorative: clicks belong to the button underneath.
            .allowsHitTesting(false)
    }
}

// MARK: - Rows

/// One tab in the list.
///
/// Its own struct so that a tab's title arriving, favicon loading, or spinner
/// starting re-renders that row and nothing else. Hover and the momentary
/// "copied" tick are local `@State` for the same reason — held on the sidebar,
/// moving the pointer down the list re-evaluated every row on every row change.
private struct TabRow: View {
    let tab: Tab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var didCopy = false

    private var showsActions: Bool { isHovered || didCopy }

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(tab: tab)
                .scaleEffect(isHovered ? 1.12 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isHovered)

            Text(tab.displayTitle)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(tab.isAwaitingRestore ? 0.55 : 1)

            Spacer(minLength: 0)
        }
        // The controls sit on top of the end of the title, so the text is faded
        // out beneath them rather than left to collide with them.
        .mask { titleFade }
        // Selection belongs to the title area, and is attached *before* the
        // controls are overlaid so they sit above it and take their own clicks.
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        // Overlaid rather than laid out, so the title gets the full width of
        // the row until the controls are actually wanted. Reserving their space
        // permanently made every tab name truncate early for the sake of two
        // buttons that are hidden most of the time.
        .overlay(alignment: .trailing) { actions }
        .padding(.horizontal, 9)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.14 : (isHovered ? 0.07 : 0)))
                .animation(.easeOut(duration: 0.16), value: isHovered)
                .animation(.easeOut(duration: 0.2), value: isSelected)
        }
        .onHover { isHovered = $0 }
        .help(tab.displayTitle)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            // Momentary checkmark: copying is invisible otherwise, and a
            // silent copy leaves you unsure it worked.
            IconButton(
                systemName: didCopy ? "checkmark" : "link",
                size: 10,
                weight: .bold,
                width: 21,
                height: 21,
                cornerRadius: 6,
                tint: didCopy ? .green : nil,
                help: "Copy Link"
            ) {
                copyURL()
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: didCopy)

            IconButton(
                systemName: "xmark",
                size: 10,
                weight: .bold,
                width: 21,
                height: 21,
                cornerRadius: 6,
                help: "Close Tab (⌘W)"
            ) {
                onClose()
            }
        }
        .opacity(showsActions ? 1 : 0)
        .scaleEffect(showsActions ? 1 : 0.7, anchor: .trailing)
        .allowsHitTesting(showsActions)
        .animation(.spring(response: 0.26, dampingFraction: 0.7), value: showsActions)
    }

    /// Full-width by default; on hover, dissolves the tail of the title into
    /// the space the controls occupy.
    ///
    /// Sized in points rather than as a gradient across the whole row, because
    /// the clear part has to line up exactly with the buttons over it.
    private var titleFade: some View {
        HStack(spacing: 0) {
            Rectangle()
            LinearGradient(
                colors: [.black, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: showsActions ? 18 : 0)
            Color.clear
                .frame(width: showsActions ? Sidebar.actionsWidth : 0)
        }
        .animation(.easeOut(duration: 0.2), value: showsActions)
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

/// Loading spinner > real favicon > generic placeholder. The spinner wins so
/// a cached icon can't make a loading tab look finished.
private struct StatusIcon: View {
    let tab: Tab

    var body: some View {
        if tab.isLoading {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.55)
                .frame(width: 16, height: 16)
        } else if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: tab.mode == .home ? "magnifyingglass" : "globe")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }
}
