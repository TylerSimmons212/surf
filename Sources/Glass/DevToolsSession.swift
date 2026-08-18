import GlassCore
import Observation
import SwiftUI

/// One tab's dev tools state — everything the panel's views read.
///
/// Per-tab rather than per-window, and that's the whole reason panels aren't
/// shared: node ids, console history, REPL scope and expanded subtrees all
/// belong to a *document*. A single panel that followed the selection would
/// either throw that away on every tab switch or keep every session alive
/// behind one window, which is the memory cost of per-tab panels without the
/// ability to look at two pages side by side.
@Observable
@MainActor
final class DevToolsSession: Identifiable {

    enum Pane: String, CaseIterable, Identifiable {
        case elements, styles, console

        var id: String { rawValue }

        var label: String {
            switch self {
            case .elements: "Elements"
            case .styles: "Styles"
            case .console: "Console"
            }
        }

        var symbol: String {
            switch self {
            case .elements: "chevron.left.forwardslash.chevron.right"
            case .styles: "paintbrush"
            case .console: "terminal"
            }
        }
    }

    enum Status: Equatable {
        case connecting
        case connected(nodeCount: Int)
        /// The page can't be inspected at all — `about:blank`, a PDF view, a
        /// sandboxed document. Worth saying plainly instead of showing an inert
        /// UI that looks broken.
        case unavailable(String)
    }

    nonisolated let id: UUID
    private(set) weak var tab: Tab?

    var pane: Pane = .console
    private(set) var status: Status = .connecting

    /// Bumped on every committed navigation. Replies are stamped with the
    /// generation they were issued in and dropped if it has moved on — without
    /// this, a style or DOM read still in flight across a navigation paints the
    /// new page with the old page's answers.
    private(set) var generation = 0

    // MARK: - Elements

    private(set) var tree = DOMTree()
    private(set) var selectedNode: DOMNodeID?
    private(set) var selectedBox: BoxModel?
    /// What the picker is currently over, which is highlighted but not
    /// selected. Kept apart from the selection's box on purpose: sharing one
    /// field meant cancelling the picker left the highlight sitting on
    /// whatever the pointer happened to be over rather than on the element
    /// that is actually selected.
    private(set) var hoveredNode: DOMNodeID?
    private(set) var hoveredBox: BoxModel?

    /// What the overlay draws. While picking, the pointer wins.
    var highlightBox: BoxModel? {
        isPicking ? (hoveredBox ?? selectedBox) : selectedBox
    }
    private(set) var isPicking = false

    /// Cached for the same reason the console's list is: SwiftUI reads it
    /// several times per render pass and flattening walks the whole open tree.
    private(set) var visibleRows: [DOMRow] = []

    var breadcrumb: [DOMNode] {
        guard let selectedNode else { return [] }
        return (tree.ancestors(of: selectedNode) + [selectedNode]).compactMap { tree[$0] }
    }

    var selectedSelector: String {
        selectedNode.map { tree.selectorPath(to: $0) } ?? ""
    }

    private func refreshTree() {
        visibleRows = tree.visibleRows()
    }

    /// Reads the document and opens the first couple of levels.
    func loadDocument() async {
        let issued = generation
        guard let reply = try? await bridge.call(.domGetDocument),
              issued == generation,
              let root = DOMWire.decodeNode(reply["root"])
        else { return }

        tree.setRoot(root)
        // The nested payload saves round trips; the tree stores by id, so
        // flattening it here is all that's needed.
        adopt(reply["root"], into: root.id)
        refreshTree()

        // <html> alone is not a useful first screen — open down to <body>.
        if let body = tree[root.id]?.childIds?.compactMap({ tree[$0] })
            .first(where: { $0.nodeName.lowercased() == "body" }) {
            await expand(body.id)
        }
    }

    /// Walks the nested wire payload, recording each level's children.
    private func adopt(_ payload: Any?, into parent: DOMNodeID) {
        guard let dict = payload as? [String: Any],
              let rawChildren = dict["children"] as? [[String: Any]]
        else { return }
        let children = rawChildren.compactMap { DOMWire.decodeNode($0) }
        guard !children.isEmpty else { return }
        tree.setChildren(children, of: parent)
        for (index, child) in children.enumerated() {
            adopt(rawChildren[index], into: child.id)
        }
    }

    func toggle(_ id: DOMNodeID) {
        guard let needsFetch = tree.toggleExpansion(id) else {
            refreshTree()
            return
        }
        refreshTree()
        Task { @MainActor in await fetchChildren(of: needsFetch) }
    }

    func expand(_ id: DOMNodeID) async {
        tree.expand(id)
        if tree[id]?.childIds == nil { await fetchChildren(of: id) }
        refreshTree()
    }

    private func fetchChildren(of id: DOMNodeID) async {
        let issued = generation
        guard let reply = try? await bridge.call(.domRequestChildNodes, ["nodeId": id]),
              issued == generation
        else { return }
        let children = (reply["children"] as? [[String: Any]] ?? []).compactMap(DOMWire.decodeNode)
        tree.setChildren(children, of: id)
        refreshTree()
    }

    /// Right opens a node, or steps into it when it's already open. Left
    /// closes it, or steps out to its parent when it's already closed — the
    /// standard outline-view keys, and the fastest way to walk a document.
    func expandSelection() {
        guard let id = selectedNode, let node = tree[id] else { return }
        if node.hasChildren, !tree.isExpanded(id) {
            toggle(id)
        } else if let first = node.childIds?.first {
            select(first)
        }
    }

    func collapseSelection() {
        guard let id = selectedNode else { return }
        if tree.isExpanded(id) {
            tree.collapse(id)
            refreshTree()
        } else if let parent = tree[id]?.parentId {
            select(parent)
        }
    }

    /// Moves through the rows as drawn, so it follows what's on screen rather
    /// than the shape of the document.
    func moveSelection(by offset: Int) {
        guard let id = selectedNode else {
            if let first = visibleRows.first { select(first.nodeId) }
            return
        }
        guard let index = visibleRows.firstIndex(where: { $0.nodeId == id && $0.kind != .close })
        else { return }

        var next = index + offset
        while visibleRows.indices.contains(next) {
            // Closing tags are punctuation, not stops.
            if visibleRows[next].kind != .close {
                select(visibleRows[next].nodeId)
                return
            }
            next += offset
        }
    }

    func select(_ id: DOMNodeID) {
        selectedNode = id
        // The page reports this one's geometry from now on, so the highlight
        // follows scrolling without anything here asking on a timer.
        bridge.send(.domWatch, ["nodeId": id])
        loadStyles()
        Task { @MainActor in await refreshBox() }
    }

    /// Brings a node into view in both the tree and the page.
    func revealAndSelect(_ id: DOMNodeID) {
        Task { @MainActor in await revealAndSelectNow(id) }
    }

    private func revealAndSelectNow(_ id: DOMNodeID) async {
        let issued = generation

        // A picked node is very often one the tree has never fetched — the id
        // was minted on the spot for whatever was under the pointer. With no
        // node and therefore no ancestry, revealing it did nothing at all and
        // the tree simply never moved. So ask the page where it lives.
        if tree[id] == nil {
            guard let reply = try? await bridge.call(.domPathToNode, ["nodeId": id]),
                  issued == generation
            else { return }

            // Walked root-first: fetching a level yields the next ancestor,
            // because the page's ids are stable, so the chain materialises as
            // we descend.
            for ancestor in reply["path"] as? [Int] ?? [] {
                guard tree[ancestor] != nil else { break }
                if tree[ancestor]?.childIds == nil { await fetchChildren(of: ancestor) }
                guard issued == generation else { return }
                tree.expand(ancestor)
            }
        }

        let missing = tree.reveal(id)
        for parent in missing {
            await fetchChildren(of: parent)
            guard issued == generation else { return }
        }
        refreshTree()

        selectedNode = id
        bridge.send(.domWatch, ["nodeId": id])
        loadStyles()
        await refreshBox()
    }

    private func refreshBox() async {
        guard let selectedNode else { selectedBox = nil; return }
        let issued = generation
        guard let reply = try? await bridge.call(.domGetBoxModel, ["nodeId": selectedNode]),
              issued == generation
        else { return }
        selectedBox = DOMWire.decodeBox(reply["box"])
    }

    func scrollPageTo(_ id: DOMNodeID) {
        bridge.send(.domScrollIntoView, ["nodeId": id])
        Task { @MainActor in
            // The scroll is animated by the page, so the box is only correct
            // once it settles.
            try? await Task.sleep(for: .milliseconds(320))
            await refreshBox()
        }
    }

    func setPicking(_ enabled: Bool) {
        isPicking = enabled
        if !enabled {
            hoveredNode = nil
            hoveredBox = nil
        }
        bridge.send(.overlaySetInspectMode, ["enabled": enabled])

        // Bring the page forward when arming.
        //
        // Without this the browser window is behind the panel, and the first
        // click on an inactive window is spent activating it rather than
        // picking — which reads as the picker ignoring you. Hovering already
        // worked, because tracking areas fire on geometry regardless of which
        // window is key; only the click was being eaten.
        if enabled { tab?.webView.window?.makeKeyAndOrderFront(nil) }
    }

    // MARK: - Styles

    private(set) var styles: ResolvedStyles?
    private(set) var stylePayload: MatchedStylesPayload?
    private(set) var computed: [String: String] = [:]
    /// Resolved by the page, so `oklch()` and `color-mix()` need no parser here.
    private(set) var computedColors: [String: CSSColor] = [:]
    private(set) var isLoadingStyles = false

    /// Which box the pane is resolving: the element, or one of its
    /// pseudo-elements. They cascade separately, so they're shown separately.
    var stylePseudo: String? {
        didSet { if stylePseudo != oldValue { resolveStyles() } }
    }

    /// Computed values are only worth the round trip when they're on screen —
    /// there are several hundred of them, against a couple of dozen rules.
    var isShowingComputed = false {
        didSet {
            guard isShowingComputed, isShowingComputed != oldValue else { return }
            Task { @MainActor in await loadComputed() }
        }
    }

    /// Pseudo-elements this element actually has rules for, so the switcher
    /// only offers boxes that exist.
    var availablePseudoElements: [String] {
        let all = stylePayload?.rules.compactMap(\.pseudoElement) ?? []
        return Array(Set(all)).sorted()
    }

    @ObservationIgnored private var styleTask: Task<Void, Never>?

    /// Reads every rule that reaches the selected element.
    ///
    /// Debounced rather than fired per selection change: walking every
    /// stylesheet and testing each selector against the element and ten
    /// ancestors is real work, and arrowing down the tree would otherwise
    /// queue one full walk per keystroke.
    func loadStyles() {
        styleTask?.cancel()
        guard let selectedNode, tree[selectedNode]?.isElement == true else {
            styles = nil
            stylePayload = nil
            computed = [:]
            computedColors = [:]
            return
        }

        isLoadingStyles = true
        styleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }

            let issued = generation
            let reply = try? await bridge.call(.cssGetMatchedStyles, ["nodeId": selectedNode])
            guard !Task.isCancelled, issued == generation, selectedNode == self.selectedNode
            else { return }

            isLoadingStyles = false
            guard let reply else {
                stylePayload = nil
                styles = nil
                return
            }
            var payload = CSSWire.decodeMatchedStyles(reply)
            payload.rules = reinstateDisabled(payload.rules)
            stylePayload = payload
            changeset.refreshColors(from: payload.rules)
            // A pseudo-element the previous selection had is very unlikely to
            // exist on this one, and resolving against a box that isn't there
            // shows an empty pane rather than the element's own styles.
            if let pseudo = stylePseudo, !availablePseudoElements.contains(pseudo) {
                stylePseudo = nil
            }
            resolveStyles()
            if isShowingComputed { await loadComputed() }
        }
    }

    private func resolveStyles() {
        guard let stylePayload else {
            styles = nil
            return
        }
        styles = CSSCascade.resolve(
            rules: stylePayload.rules,
            layerOrder: stylePayload.layerOrder,
            pseudoElement: stylePseudo
        )
    }

    private func loadComputed() async {
        guard let selectedNode else { return }
        let issued = generation
        guard let reply = try? await bridge.call(.cssGetComputed, ["nodeId": selectedNode]),
              issued == generation, selectedNode == self.selectedNode
        else { return }
        computed = reply["computed"] as? [String: String] ?? [:]
        computedColors = CSSWire.decodeComputedColors(reply)
    }

    /// A `var()` reference resolved to what it actually evaluates to.
    func resolvedVariable(_ name: String) -> String? {
        stylePayload?.variables[name]
    }

    // MARK: - Editing

    /// Everything altered this session, as a net difference rather than a log.
    private(set) var changeset = StyleChangeset()
    private(set) var editedRuleIds: Set<Int> = []

    /// Declarations switched off.
    ///
    /// Held here because they are genuinely gone from the page — a disabled
    /// declaration isn't in the rule any more, so no re-read can bring it back.
    /// Re-injecting them at their original index on every load is also what
    /// keeps declaration indices stable, and therefore what stops a later edit
    /// addressing the wrong line.
    @ObservationIgnored private var disabled: [DeclarationRef: CSSDeclaration] = [:]

    /// The rules those declarations came from, kept because a rule whose last
    /// declaration is switched off has an empty block — and an empty rule isn't
    /// reported at all, so the row would vanish and take the only means of
    /// switching it back on with it.
    @ObservationIgnored private var disabledRules: [Int: MatchedRule] = [:]

    /// A value the engine refused, so the row can say so instead of showing an
    /// edit that silently didn't happen.
    private(set) var rejectedEdit: DeclarationRef?

    func isDisabled(_ declaration: CSSDeclaration, in rule: MatchedRule) -> Bool {
        disabled[DeclarationRef(ruleId: rule.id, index: declaration.index)] != nil
    }

    /// What it would take to make this declaration actually apply.
    func escalation(for declaration: CSSDeclaration, in rule: MatchedRule) -> StyleEscalation? {
        guard let payload = stylePayload,
              let property = declaration.longhands.first
        else { return nil }
        return CascadeEscalation.escalation(
            for: DeclarationRef(ruleId: rule.id, index: declaration.index),
            property: property,
            rules: payload.rules,
            layerOrder: payload.layerOrder,
            pseudoElement: stylePseudo
        )
    }

    func setValue(_ value: String, of declaration: CSSDeclaration, in rule: MatchedRule) async {
        var edited = declaration
        edited.value = value.trimmingCharacters(in: .whitespaces)
        await apply(edited, replacing: declaration, in: rule)
    }

    func setImportant(_ important: Bool, of declaration: CSSDeclaration, in rule: MatchedRule) async {
        var edited = declaration
        edited.isImportant = important
        await apply(edited, replacing: declaration, in: rule)
    }

    func setEnabled(_ enabled: Bool, _ declaration: CSSDeclaration, in rule: MatchedRule) async {
        let ref = DeclarationRef(ruleId: rule.id, index: declaration.index)
        if enabled {
            disabled.removeValue(forKey: ref)
            if !disabled.keys.contains(where: { $0.ruleId == rule.id }) {
                disabledRules.removeValue(forKey: rule.id)
            }
        } else {
            disabled[ref] = declaration
            var shell = rule
            shell.declarations = []
            disabledRules[rule.id] = shell
        }
        await apply(declaration, replacing: declaration, in: rule, enabled: enabled)
    }

    private func apply(
        _ edited: CSSDeclaration,
        replacing original: CSSDeclaration,
        in rule: MatchedRule,
        enabled: Bool = true
    ) async {
        let ref = DeclarationRef(ruleId: rule.id, index: original.index)
        rejectedEdit = nil

        // The whole block, recomposed. Setting properties one at a time moves a
        // re-enabled declaration to the end, which changes the cascade inside
        // the rule without anyone asking for it.
        let text = rule.declarations
            .map { $0.index == original.index ? edited : $0 }
            .filter { disabled[DeclarationRef(ruleId: rule.id, index: $0.index)] == nil }
            .map(\.text)
            .joined(separator: "; ")

        var params: [String: any Sendable] = ["text": text]
        // The style attribute has no CSSOM rule to address, so it's carried as
        // the node it sits on — negated to keep the two id spaces apart.
        if rule.isStyleAttribute {
            params["nodeId"] = -rule.id
        } else {
            params["ruleId"] = rule.id
        }

        let issued = generation
        guard let reply = try? await bridge.call(.cssSetRuleText, params),
              issued == generation
        else { return }

        // A value the engine can't parse is dropped without complaint. Catching
        // it here is the difference between "that isn't a colour" and an edit
        // that appears to have worked and didn't.
        let applied = Set(reply["applied"] as? [String] ?? [])
        if enabled, !applied.isEmpty,
           !edited.longhands.contains(where: { applied.contains($0) }) {
            rejectedEdit = ref
        } else {
            changeset.record(StyleChange(
                ruleId: rule.id,
                selector: rule.isStyleAttribute ? "element.style" : rule.selector,
                sourceLabel: rule.isStyleAttribute ? "element" : rule.sourceLabel,
                layer: rule.layer,
                conditions: rule.conditions,
                property: original.name,
                original: original.value,
                updated: enabled ? edited.value : nil,
                wasImportant: original.isImportant,
                isImportant: edited.isImportant
            ))
            editedRuleIds.insert(rule.id)
        }
        loadStyles()
    }

    /// Puts one rule back exactly as the page shipped it.
    func revert(_ rule: MatchedRule) async {
        await revertRule(id: rule.id)
    }

    /// Addressed by id, because the changes list holds ids rather than rules —
    /// it outlives the element the edits were made on.
    func revertRule(id ruleId: Int) async {
        var params: [String: any Sendable] = [:]
        // A negative id is an element's style attribute, carried as its node.
        if ruleId < 0 { params["nodeId"] = -ruleId } else { params["ruleId"] = ruleId }
        _ = try? await bridge.call(.cssRevert, params)

        disabled = disabled.filter { $0.key.ruleId != ruleId }
        disabledRules.removeValue(forKey: ruleId)
        changeset.clear(ruleId: ruleId)
        editedRuleIds.remove(ruleId)
        loadStyles()
    }

    func revertAll() async {
        for ruleId in editedRuleIds {
            var params: [String: any Sendable] = [:]
            if ruleId < 0 { params["nodeId"] = -ruleId } else { params["ruleId"] = ruleId }
            _ = try? await bridge.call(.cssRevert, params)
        }
        disabled.removeAll()
        disabledRules.removeAll()
        changeset.clear()
        editedRuleIds.removeAll()
        loadStyles()
    }

    /// Puts switched-off declarations back into the rules the page reported.
    ///
    /// They aren't in the page any more, so a re-read can't return them — but
    /// they still have to be drawn, and their indices still have to line up, or
    /// the next edit addresses the wrong line.
    private func reinstateDisabled(_ rules: [MatchedRule]) -> [MatchedRule] {
        guard !disabled.isEmpty else { return rules }

        // A rule emptied by switching off its last declaration is gone from the
        // page's report. Put the shell back so the row — and its checkbox —
        // stay where they were.
        var all = rules
        let reported = Set(rules.map(\.id))
        for (id, shell) in disabledRules where !reported.contains(id) {
            all.append(shell)
        }

        return all.map { rule in
            let missing = disabled
                .filter { $0.key.ruleId == rule.id }
                .values
                .sorted { $0.index < $1.index }
            guard !missing.isEmpty else { return rule }

            var copy = rule
            var list = rule.declarations
            for declaration in missing {
                let at = min(declaration.index, list.count)
                list.insert(declaration, at: at)
            }
            // Renumbered so the positions match what is drawn.
            copy.declarations = list.enumerated().map { index, declaration in
                var renumbered = declaration
                renumbered.index = index
                return renumbered
            }
            return copy
        }
    }

    var unreadableSheets: [String] { stylePayload?.unreadableSheets ?? [] }

    // MARK: - Console

    private(set) var console = ConsoleBuffer()

    var consoleLevels: Set<ConsoleLevel> = Set(ConsoleLevel.allCases) {
        didSet { if consoleLevels != oldValue { refreshConsoleView() } }
    }
    var consoleQuery = "" {
        didSet { if consoleQuery != oldValue { refreshConsoleView() } }
    }
    /// Off by default, like every browser: yesterday's output is usually noise.
    var preservesLogOnNavigation = false

    /// Cached rather than computed on demand.
    ///
    /// SwiftUI reads these several times per render pass, and filtering or
    /// counting walks the whole buffer — up to five thousand entries. As
    /// computed properties they turned every mouse move over the pane into
    /// tens of thousands of comparisons. They are recomputed when the data or
    /// the filter actually changes, which is the only time they can differ.
    private(set) var visibleConsoleEntries: [ConsoleEntry] = []
    private(set) var consoleCounts: [ConsoleLevel: Int] = [:]

    /// The only way anything reaches the buffer. Centralised so a future call
    /// site cannot forget to refresh the cache and leave the pane stale.
    private func record(_ entry: ConsoleEntry) {
        console.append(entry)
        refreshConsoleView()
    }

    private func refreshConsoleView() {
        visibleConsoleEntries = console.filtered(levels: consoleLevels, query: consoleQuery)
        consoleCounts = console.counts()
    }

    /// True when a filter is hiding output, so the pane can say so rather than
    /// letting someone conclude their page went quiet.
    var isConsoleFiltered: Bool {
        consoleLevels.count != ConsoleLevel.allCases.count
            || !consoleQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func clearConsole() {
        console.clear()
        refreshConsoleView()
        releaseEvictedObjects()
    }

    // MARK: - The prompt

    /// What has been typed, newest last. Memory only — a REPL history that
    /// outlived the window would be a record of what you were debugging.
    private(set) var inputHistory: [String] = []
    private static let historyDepth = 100

    /// Runs an entry, echoing both the input and what it answered.
    func evaluate(_ input: String) async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Consecutive duplicates aren't worth a second history slot.
        if inputHistory.last != trimmed { inputHistory.append(trimmed) }
        if inputHistory.count > Self.historyDepth { inputHistory.removeFirst() }

        record(ConsoleEntry(
            id: 0,
            kind: .input,
            arguments: [RemoteObject(type: .string, description: trimmed)]
        ))

        let wrapped = ConsoleREPL.wrap(trimmed)
        let issued = generation

        do {
            let reply = try await bridge.call(.runtimeEvaluate, [
                "source": wrapped.source,
                "usesAwait": wrapped.usesAwait,
            ])
            guard issued == generation else { return }
            guard let result = ConsoleWire.decodeEvaluation(reply) else { return }

            record(ConsoleEntry(
                id: 0,
                kind: .result,
                // A thrown value is an error however it was produced, and
                // colouring it like a result would hide the failure.
                level: result.thrown ? .error : .log,
                arguments: [result.value]
            ))
        } catch {
            guard issued == generation else { return }
            record(ConsoleEntry(
                id: 0,
                kind: .result,
                level: .error,
                arguments: [RemoteObject(type: .string, description: error.localizedDescription)]
            ))
        }
        releaseEvictedObjects()
    }

    // MARK: - Completion

    private(set) var completions: [String] = []
    private(set) var highlightedCompletion = 0
    @ObservationIgnored private var completionQuery: ConsoleCompletion.Query?
    @ObservationIgnored private var completionTask: Task<Void, Never>?

    var isShowingCompletions: Bool { !completions.isEmpty }

    /// Recomputed as the prompt changes.
    ///
    /// Debounced, because each request crosses into the page and lists a
    /// prototype chain — cheap, but not cheap enough to do on every keystroke
    /// of a fast typist.
    func updateCompletions(for input: String) {
        completionTask?.cancel()

        guard let query = ConsoleCompletion.query(for: input) else {
            dismissCompletions()
            return
        }
        completionQuery = query

        completionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }

            let issued = generation
            guard let reply = try? await bridge.call(
                .runtimeCompletions, ["base": query.base]
            ), !Task.isCancelled, issued == generation else { return }

            let names = (reply["names"] as? [String]) ?? []
            let ranked = ConsoleCompletion.rank(names, matching: query.prefix)
            // An exact and only match is already typed; offering it is noise.
            completions = (ranked == [query.prefix]) ? [] : Array(ranked.prefix(40))
            highlightedCompletion = 0
        }
    }

    func highlightCompletion(_ index: Int) {
        guard completions.indices.contains(index) else { return }
        highlightedCompletion = index
    }

    func moveCompletionHighlight(by offset: Int) {
        guard isShowingCompletions else { return }
        let count = completions.count
        highlightedCompletion = ((highlightedCompletion + offset) % count + count) % count
    }

    /// The input with the highlighted name accepted, or nil if there is none.
    func acceptingCompletion(_ input: String) -> String? {
        guard isShowingCompletions,
              let query = completionQuery,
              completions.indices.contains(highlightedCompletion)
        else { return nil }
        let applied = ConsoleCompletion.apply(
            completions[highlightedCompletion], to: input, query: query
        )
        dismissCompletions()
        return applied
    }

    func dismissCompletions() {
        completionTask?.cancel()
        completions = []
        completionQuery = nil
        highlightedCompletion = 0
    }

    /// One level of an object, fetched only when someone opens it.
    /// One page of an object's properties.
    ///
    /// Paged at the source, not just in the view. Reading a value is the
    /// expensive part — `innerHTML` on a real page materialises the whole
    /// document before it can even be truncated — so the agent must never be
    /// asked for more than is about to be shown.
    func properties(
        of objectId: String,
        offset: Int = 0,
        limit: Int = 100
    ) async -> (properties: [ObjectProperty], total: Int) {
        let issued = generation
        guard let reply = try? await bridge.call(.runtimeGetProperties, [
            "objectId": objectId, "offset": offset, "limit": limit,
        ]), issued == generation
        else { return ([], 0) }
        return ConsoleWire.decodeProperties(reply)
    }

    func toggleConsoleLevel(_ level: ConsoleLevel) {
        if consoleLevels.contains(level) {
            // Never leave zero levels selected — an empty console that looks
            // broken is worse than a filter that refuses to hide everything.
            guard consoleLevels.count > 1 else { return }
            consoleLevels.remove(level)
        } else {
            consoleLevels.insert(level)
        }
    }

    @ObservationIgnored private let bridge: DevToolsBridge

    init(tab: Tab) {
        self.id = tab.id
        self.tab = tab
        self.bridge = DevToolsBridge(tab: tab)

        bridge.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    var pageURL: String { tab?.webView.url?.absoluteString ?? "" }

    // MARK: - Lifecycle

    func start() {
        Task { @MainActor in
            do {
                try await bridge.attach()
                await drainConsoleBacklog()
                await loadDocument()
                await refreshStatus()
            } catch {
                status = .unavailable(error.localizedDescription)
            }
        }
    }

    /// Collects everything the page logged before this window existed, and puts
    /// the agent into live mode. This is the payoff for capturing always: a
    /// console that opens already holding the startup errors you opened it for.
    ///
    /// Retried, because `didCommit` can land a hair before the document-start
    /// scripts are reachable. Failing silently there would be the worst kind of
    /// bug: the agent would stay in buffering mode and the console would simply
    /// show nothing, for ever, with no error to explain it.
    private func drainConsoleBacklog() async {
        let issued = generation

        for attempt in 0..<4 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(80))
                guard issued == generation else { return }
            }
            guard let reply = try? await bridge.call(.consoleDrain),
                  let batch = ConsoleWire.decodeBatch(reply)
            else { continue }

            guard issued == generation else { return }
            for entry in batch.entries { console.append(entry) }
            refreshConsoleView()
            return
        }
    }

    func stop() {
        bridge.detach()
    }

    /// A committed navigation replaces the document: every id the agent handed
    /// out is now meaningless.
    func documentDidChange() {
        generation += 1
        status = .connecting
        // Every id the agent handed out belonged to the old document.
        tree = DOMTree()
        visibleRows = []
        selectedNode = nil
        selectedBox = nil
        hoveredNode = nil
        hoveredBox = nil
        styleTask?.cancel()
        styles = nil
        stylePayload = nil
        computed = [:]
        computedColors = [:]
        stylePseudo = nil
        // Every rule handle belonged to the old document, and the page has
        // reloaded its own stylesheets — so the edits are gone whether we like
        // it or not, and pretending otherwise would offer a patch for a state
        // that no longer exists.
        disabled.removeAll()
        disabledRules.removeAll()
        changeset.clear()
        editedRuleIds.removeAll()
        rejectedEdit = nil
        console.markNavigation(url: pageURL, preservingLog: preservesLogOnNavigation)
        refreshConsoleView()
        releaseEvictedObjects()

        Task { @MainActor in
            // The new document's console agent starts buffering rather than
            // live — it has no idea a window is open — so it has to be told,
            // and its startup logs collected, exactly as at attach time.
            await drainConsoleBacklog()
            await loadDocument()
            await refreshStatus()
        }
    }

    private func handle(_ event: DevToolsEvent) {
        switch event {
        case .bootstrapped:
            // Liveness only, deliberately *not* a document reset. `didCommit`
            // is the single authority for that: this event also fires when
            // `attach()` injects the agent by hand into a document that's
            // already on screen, and treating that as a navigation would wipe
            // the backlog we just went to the trouble of collecting.
            Task { @MainActor in await refreshStatus() }

        case .overflowed:
            noteDroppedOutput(nil)

        case .consoleBatch(let entries, let sequence, let dropped):
            // Reported before the batch it preceded, so the gap appears where
            // it actually happened rather than at the end of the run.
            if dropped > 0 { noteDroppedOutput(dropped) }
            for entry in entries { console.append(entry) }
            refreshConsoleView()
            releaseEvictedObjects()
            // Acknowledging is what lets the page keep sending: unacked batches
            // past the window stop the agent emitting, which is the whole
            // backpressure mechanism.
            bridge.send(.consoleAck, ["sequence": sequence])

        case .domMutations(let mutations, let sequence):
            tree.apply(mutations)
            refreshTree()
            bridge.send(.domAck, ["sequence": sequence])
            // A mutation may have moved whatever is highlighted.
            if selectedNode != nil { Task { @MainActor in await refreshBox() } }
            // A class or style change anywhere up the chain can change which
            // rules reach the selection — that's the whole point of a class
            // toggle. `loadStyles` debounces, so a re-rendering app coalesces
            // into one walk rather than one per mutation.
            if selectedNode != nil, mutations.contains(where: {
                if case .attributeChanged = $0 { return true } else { return false }
            }) {
                loadStyles()
            }
            // Anything open whose children were dropped has to be re-read.
            let pending = tree.pendingFetches()
            if !pending.isEmpty {
                Task { @MainActor in
                    for id in pending { await fetchChildren(of: id) }
                }
            }

        case .inspectHover(let nodeId, let box):
            hoveredNode = nodeId
            hoveredBox = box

        case .boxChanged(let nodeId, let box):
            // Ignored unless it's still the element we asked about — a reply
            // for a node selected two clicks ago would drag the highlight back.
            guard nodeId == selectedNode else { return }
            selectedBox = box

        case .inspectPicked(let nodeId):
            isPicking = false
            hoveredNode = nil
            hoveredBox = nil
            pane = .elements
            revealAndSelect(nodeId)
            // The result is in the panel, so the panel comes forward. The page
            // was fronted to receive the click; that job is done.
            if let tab { DevToolsController.shared.bringPanelForward(for: tab) }

        case .inspectCancelled:
            isPicking = false
            hoveredNode = nil
            hoveredBox = nil

        case .consoleCleared:
            // The page called console.clear() itself. Honouring it matches
            // every other browser, and a page that clears its own console is
            // usually doing it for a reason worth respecting.
            clearConsole()
        }
    }

    /// A gap in the log, said out loud.
    ///
    /// A console that silently skips output is worse than one that admits it:
    /// the whole value of the thing is that what you see is what happened.
    private func noteDroppedOutput(_ count: Int?) {
        let text = count.map {
            "\($0.formatted()) messages were dropped — the page logged faster than Glass could read."
        } ?? "Some messages were dropped — the page logged faster than Glass could read."

        record(ConsoleEntry(
            id: 0,
            level: .warning,
            arguments: [RemoteObject(type: .string, description: text)]
        ))
    }

    /// Handles that fell out of the buffer still pin page objects alive, so the
    /// page has to be told. A no-op until Phase 2 hands out any ids.
    private func releaseEvictedObjects() {
        let ids = console.takeEvictedObjectIds()
        guard !ids.isEmpty else { return }
        bridge.send(.runtimeReleaseObject, ["objectIds": ids])
    }

    private func refreshStatus() async {
        let issued = generation
        do {
            let reply = try await bridge.call(.runtimePing)
            // Dropped if the page moved on while this was in flight.
            guard issued == generation else { return }
            status = .connected(nodeCount: reply["nodeCount"] as? Int ?? 0)
        } catch {
            guard issued == generation else { return }
            status = .unavailable(error.localizedDescription)
        }
    }
}
