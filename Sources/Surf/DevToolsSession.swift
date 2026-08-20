import SurfCore
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
        case elements, styles, network, storage, tags, performance, console

        var id: String { rawValue }

        var label: String {
            switch self {
            case .elements: "Elements"
            case .styles: "Styles"
            case .network: "Network"
            case .storage: "Storage"
            case .tags: "Tags"
            case .performance: "Speed"
            case .console: "Console"
            }
        }

        var symbol: String {
            switch self {
            case .elements: "chevron.left.forwardslash.chevron.right"
            case .styles: "paintbrush"
            case .network: "arrow.up.arrow.down"
            case .storage: "externaldrive"
            case .tags: "tag"
            case .performance: "gauge.with.needle"
            case .console: "terminal"
            }
        }

        /// The panes, grouped by the kind of question each one answers: what
        /// the document *is*, what it is *doing right now*, and what a run of
        /// it *produced*.
        ///
        /// The grouping is the reason the rail beats the segmented control it
        /// replaced. Seven equal segments assert seven peers, and these are
        /// not peers — Elements and Styles are one workspace you keep both
        /// halves of, Network and Console are live streams you leave running,
        /// and the last three are reports you go and pull. Three things to
        /// hold rather than seven, and room for an eighth pane without every
        /// existing one getting narrower.
        ///
        /// Separate from `allCases`, which stays in declaration order because
        /// `SURF_DEVTOOLS` parses a raw value and tests index it.
        /// Panes whose whole content is about the selected element — so a
        /// pick can land here rather than being redirected.
        var showsSelectedElement: Bool { self == .elements || self == .styles }

        static let groups: [[Pane]] = [
            [.elements, .styles],
            [.network, .console],
            [.performance, .tags, .storage],
        ]
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

    /// Writes one box-model measurement — `margin-top: 12px` — as an inline
    /// style on the selected element, and re-reads the box so the diagram
    /// answers with what the engine actually did rather than what was asked.
    ///
    /// Rides Phase 1 entirely: the style-attribute rule always exists now
    /// (the agent emits it even when empty, which was done for the add-row
    /// and pays off again here), so this is an edit when the property is
    /// already inline and an add when it isn't.
    func setBoxValue(_ property: String, _ value: String) async {
        guard let inline = styles?.rules.first(where: {
            $0.isStyleAttribute && !$0.isInherited
        }) else { return }

        if let existing = inline.declarations.first(where: { $0.name == property }) {
            await setValue(value, of: existing, in: inline)
        } else {
            _ = await addDeclaration(property, value, to: inline)
        }
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
    private(set) var computedColors: [String: ResolvedColor] = [:]
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
            await recoverUnreadableSheets()
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

    /// Off by default, like every browser. When on, the changeset is re-applied
    /// after a reload of the same page — which Surf can do without any of the
    /// setup Local Overrides needs, because it owns the browser.
    var preservesStyleEditsOnReload = false
    /// Edits that couldn't be put back, with why. Surfaced rather than dropped:
    /// an edit that quietly failed to return is worse than one that never
    /// claimed it would.
    private(set) var replayMisses: [(property: String, selector: String, reason: String)] = []
    private(set) var didReplayEdits = false

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

    func setValue(
        _ value: String,
        of declaration: CSSDeclaration,
        in rule: MatchedRule,
        live: Bool = false
    ) async {
        var edited = declaration
        edited.value = value.trimmingCharacters(in: .whitespaces)
        await apply(edited, replacing: declaration, in: rule, live: live)
    }

    /// Puts the collected edits back after a reload.
    ///
    /// Every rule handle was minted against a live CSSOM object, so none of
    /// them survived — each change has to find its rule again by selector,
    /// stylesheet and conditions.
    private func replayStyleEdits() async {
        guard preservesStyleEditsOnReload, !changeset.isEmpty else { return }
        let issued = generation

        // One descriptor per rule the changes touch. Rules are located by what
        // they are — selector, stylesheet, conditions, layer — because every
        // handle was minted against a CSSOM object the reload destroyed.
        var descriptors: [[String: any Sendable]] = []
        var groups: [[StyleChange]] = []
        for change in changeset.changes where change.selector != "element.style" {
            let key = [change.selector, change.sourceLabel, change.layer ?? ""]
                + change.conditions
            if let index = descriptors.indices.first(where: { position in
                let existing = descriptors[position]
                return (existing["selector"] as? String) == change.selector
                    && (existing["label"] as? String) == change.sourceLabel
                    && (existing["layer"] as? String) == (change.layer ?? "")
                    && (existing["conditions"] as? [String]) == change.conditions
            }) {
                groups[index].append(change)
            } else {
                _ = key
                descriptors.append([
                    "selector": change.selector,
                    "label": change.sourceLabel,
                    "layer": change.layer ?? "",
                    "conditions": change.conditions,
                ])
                groups.append([change])
            }
        }
        guard !descriptors.isEmpty else { return }

        guard let reply = try? await bridge.call(.cssFindRules, ["rules": descriptors]),
              issued == generation
        else { return }

        var found: [Int: (id: Int, declarations: [CSSDeclaration])] = [:]
        for entry in reply["matches"] as? [[String: Any]] ?? [] {
            guard let index = entry["index"] as? Int, let id = entry["id"] as? Int
            else { continue }
            found[index] = (id, CSSWire.decodeDeclarations(entry["declarations"]))
        }

        var misses: [(property: String, selector: String, reason: String)] = []
        var applied = 0

        for (index, changes) in groups.enumerated() {
            guard let match = found[index] else {
                for change in changes {
                    misses.append((
                        property: change.property, selector: change.selector,
                        reason: "its rule is no longer in the page"
                    ))
                }
                continue
            }
            // A stand-in carrying the new document's declarations, so the block
            // is rebuilt from what the page actually has rather than from what
            // it had before the reload.
            let rule = MatchedRule(
                id: match.id, selector: changes[0].selector,
                declarations: match.declarations
            )
            let text = StyleReplay.text(for: rule, applying: changes)
            _ = try? await bridge.call(
                .cssSetRuleText, ["ruleId": match.id, "text": text]
            )
            guard issued == generation else { return }
            editedRuleIds.insert(match.id)
            applied += changes.count
        }

        replayMisses = misses
        didReplayEdits = applied > 0
        if didReplayEdits, selectedNode != nil { loadStyles() }
    }

    func dismissReplayReport() {
        replayMisses = []
        didReplayEdits = false
    }

    /// Replaces one colour inside a value, leaving the rest of it alone.
    ///
    /// A swatch belongs to a token, not to the declaration: picking on the red
    /// in `2px solid red` must not turn the whole value into a colour, and
    /// picking on the second stop of a gradient must leave the first standing.
    func setColor(
        _ color: ResolvedColor,
        segment index: Int,
        of declaration: CSSDeclaration,
        in rule: MatchedRule,
        live: Bool = false
    ) async {
        let segments = declaration.valueSegments
        guard segments.indices.contains(index) else { return }

        // The notation to write back in, pinned to what the page shipped.
        //
        // CSSOM reserializes every colour it is handed: write `#ff0000` and the
        // rule reads back `rgb(255, 0, 0)`. Matching the *current* text would
        // therefore turn hex into rgb() after a single pick and never back —
        // so the first thing seen at this spot is what the notation stays.
        let key = "\(rule.id).\(declaration.index).\(index)"
        let notation = pickedNotation[key] ?? segments[index].text
        pickedNotation[key] = notation

        var edited = declaration
        edited.value = segments
            .map { $0.index == index ? color.css(matching: notation) : $0.text }
            .joined()
        await apply(edited, replacing: declaration, in: rule, live: live)
    }

    /// How each picked colour was written before anyone touched it.
    @ObservationIgnored private var pickedNotation: [String: String] = [:]

    /// Replaces one number inside a value, leaving the rest of it alone.
    ///
    /// The same rule as colours: a number belongs to its token, so scrubbing
    /// the `8` in `8px 16px` must not disturb the `16`.
    func setNumber(
        _ replacement: String,
        at offset: Int,
        of declaration: CSSDeclaration,
        in rule: MatchedRule,
        live: Bool = false
    ) async {
        let numbers = CSSValueScrub.numbers(in: declaration.value)
        guard let number = numbers.first(where: { $0.offset == offset }) else { return }
        var edited = declaration
        edited.value = CSSValueScrub.replacing(
            declaration.value, number: number, with: replacement
        )
        await apply(edited, replacing: declaration, in: rule, live: live)
    }

    /// The engine's own property vocabulary, fetched once per session.
    ///
    /// Once, not per document: the list is a fact about the WebKit build, not
    /// about any page. Empty until someone actually opens an add-row — most
    /// sessions never pay for it.
    private(set) var cssPropertyNames: [String] = []

    /// The states being simulated, and on which element. One element at a
    /// time, matching the agent's stamp — and kept even when the selection
    /// moves, because the workflow is "force hover on the menu, then inspect
    /// the submenu it revealed".
    private(set) var forcedStates: Set<String> = []
    private(set) var forcedNode: DOMNodeID?

    /// The states the strip offers. `target` and `visited` are parsed but not
    /// offered: target requires a matching fragment to be honest, and visited
    /// styling is privacy-restricted to the point that forcing it shows
    /// nothing getComputedStyle will admit to.
    static let forcibleStates = ["hover", "active", "focus", "focus-visible", "focus-within"]

    func setForcedState(_ state: String, enabled: Bool) async {
        guard let selectedNode else { return }
        // Forcing on a new element implicitly releases the old one — the
        // agent moves the stamp — so the local set starts over too.
        var states = selectedNode == forcedNode ? forcedStates : []
        if enabled { states.insert(state) } else { states.remove(state) }

        let issued = generation
        guard let reply = try? await bridge.call(
            .cssForceState, ["nodeId": selectedNode, "states": Array(states)]
        ), issued == generation else { return }
        if let failure = reply["error"] as? String {
            debugLog("force state failed: \(failure)")
            return
        }
        forcedStates = states
        forcedNode = states.isEmpty ? nil : selectedNode
        loadStyles()
    }

    /// The grid/flex overlay: which node it is armed on, and the geometry
    /// the page last reported for it. Geometry arrives by event — fresh on
    /// arming and again on scroll and resize — never by polling.
    private(set) var layoutOverlayNode: DOMNodeID?
    private(set) var layoutOverlay: LayoutOverlay?

    /// Arms the overlay on a node, or disarms it when asked for the node it
    /// is already on — a badge is a toggle, not a command.
    func toggleLayoutOverlay(_ nodeId: DOMNodeID) {
        let next: DOMNodeID? = layoutOverlayNode == nodeId ? nil : nodeId
        layoutOverlayNode = next
        if next == nil { layoutOverlay = nil }
        var params: [String: any Sendable] = [:]
        if let next { params["nodeId"] = next }
        bridge.send(.overlaySetLayout, params)
    }

    /// The row being edited in the Elements tree, if any. Set by Return on
    /// the selection or the row's context menu; the row view watches it and
    /// swaps its markup for a field.
    var editingNode: DOMNodeID?

    /// Applies an edited attribute line to an element: parse, diff against
    /// what it had, and write only what changed — every set echoes back
    /// through the mutation observer, so writing the unchanged ones would
    /// storm the tree with non-changes. Returns false when the text refuses
    /// to parse (unclosed quote, trailing =), so the editor can say so
    /// instead of guessing.
    func applyAttributeText(_ text: String, to nodeId: DOMNodeID) async -> Bool {
        guard let node = tree[nodeId] else { return false }
        guard let parsed = DOMAttributeText.parse(text) else { return false }

        let old = node.attributes.map {
            DOMAttributeText.Attribute(name: $0.name, value: $0.value)
        }
        let issued = generation
        for change in DOMAttributeText.diff(old: old, new: parsed) {
            let params: [String: any Sendable] = switch change {
            case .set(let name, let value):
                ["nodeId": nodeId, "name": name, "value": value]
            case .remove(let name):
                ["nodeId": nodeId, "name": name, "remove": true]
            }
            guard let reply = try? await bridge.call(.domSetAttribute, params),
                  issued == generation
            else { return false }
            if let failure = reply["error"] as? String {
                debugLog("attribute edit failed: \(failure)")
                return false
            }
        }
        // Class or style may have been among the edits; what matches changed.
        loadStyles()
        return true
    }

    func setText(_ value: String, on nodeId: DOMNodeID) async {
        let issued = generation
        guard let reply = try? await bridge.call(
            .domSetText, ["nodeId": nodeId, "value": value]
        ), issued == generation else { return }
        if let failure = reply["error"] as? String {
            debugLog("text edit failed: \(failure)")
        }
    }

    /// Classes toggled off through the strip, per node — kept so a chip
    /// stays on screen unchecked after its class is removed from the element.
    /// Without this the class would vanish from the attribute, therefore from
    /// the strip, and switching it back on would mean retyping it.
    private(set) var removedClasses: [DOMNodeID: Set<String>] = [:]

    /// What the class strip shows for the selected element: the classes it
    /// has, plus the ones this panel took away — each with its current state.
    var elementClasses: [(name: String, isOn: Bool)] {
        guard let selectedNode, let node = tree[selectedNode],
              node.nodeType == .element
        else { return [] }
        let current = (node.attributes.first { $0.name.lowercased() == "class" }?.value ?? "")
            .split(separator: " ").map(String.init)
        let removed = removedClasses[selectedNode] ?? []
        var seen = Set<String>()
        var out: [(String, Bool)] = []
        for name in current where seen.insert(name).inserted {
            out.append((name, true))
        }
        for name in removed.sorted() where seen.insert(name).inserted {
            out.append((name, false))
        }
        return out
    }

    /// Adds or removes a class on the selected element, and refreshes what
    /// that changed: the rules that match are different now.
    func setClass(_ name: String, enabled: Bool) async {
        guard let selectedNode else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        let issued = generation
        guard let reply = try? await bridge.call(
            .domSetClass, ["nodeId": selectedNode, "name": name, "on": enabled]
        ), issued == generation else { return }
        if let failure = reply["error"] as? String {
            debugLog("set class failed: \(failure)")
            return
        }
        if enabled {
            removedClasses[selectedNode]?.remove(name)
        } else {
            removedClasses[selectedNode, default: []].insert(name)
        }
        // The attribute change comes back through DOM.watch on its own; the
        // styles need asking for, since a different set of rules matches now.
        loadStyles()
    }

    /// Selectors worth offering for a new rule on the selected element —
    /// generated from its tag, id and classes, so every one is valid and
    /// matches by construction.
    var newRuleSelectors: [String] {
        guard let selectedNode, let node = tree[selectedNode],
              node.nodeType == .element
        else { return [] }
        let attributes = Dictionary(
            uniqueKeysWithValues: node.attributes.map { ($0.name.lowercased(), $0.value) }
        )
        return CSSSelectorSuggestion.candidates(
            tag: node.nodeName,
            id: attributes["id"],
            classes: (attributes["class"] ?? "").split(separator: " ").map(String.init)
        )
    }

    func loadPropertyNamesIfNeeded() {
        guard cssPropertyNames.isEmpty else { return }
        Task { @MainActor in
            guard let reply = try? await bridge.call(.cssPropertyNames, [:]) else { return }
            cssPropertyNames = reply["names"] as? [String] ?? []
        }
    }

    /// Creates an empty rule for a selector, in Surf's own sheet on the page.
    ///
    /// The rule arrives empty and stays visible because it is flagged as the
    /// inspector's (`isInspectorRule`); its declarations then come through
    /// `addDeclaration` like anyone else's. Nothing is recorded in the
    /// changeset here — an empty rule *is* no change, and the declarations
    /// record themselves as they land.
    func addRule(_ selector: String) async -> Bool {
        let issued = generation
        guard let reply = try? await bridge.call(.cssAddRule, ["selector": selector]),
              issued == generation
        else { return false }
        if let failure = reply["error"] as? String {
            debugLog("add rule failed: \(failure)")
            return false
        }
        loadStyles()
        return true
    }

    /// Appends a brand-new declaration to a rule — the other half of editing.
    ///
    /// Returns whether the engine accepted it, so the add-row can complain in
    /// place instead of routing through `rejectedEdit`, which is keyed by the
    /// index of a declaration that, on failure, never came to exist.
    func addDeclaration(
        _ name: String, _ value: String, to rule: MatchedRule
    ) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces).lowercased()
        let value = value.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !value.isEmpty else { return false }

        // Recomposed exactly like an edit: the whole block, in authored order,
        // with the new line at the end — which is also where the cascade puts
        // its weight, so the addition wins against anything earlier in the
        // same rule, which is what "I just typed this" should mean.
        let text = (rule.declarations
            .filter { disabled[DeclarationRef(ruleId: rule.id, index: $0.index)] == nil }
            .map(\.text)
            + ["\(name): \(value)"])
            .joined(separator: "; ")

        var params: [String: any Sendable] = ["text": text, "probe": name]
        if rule.isStyleAttribute {
            params["nodeId"] = -rule.id
        } else {
            params["ruleId"] = rule.id
        }

        let issued = generation
        guard let reply = try? await bridge.call(.cssSetRuleText, params),
              issued == generation
        else { return false }

        if let failure = reply["error"] as? String {
            debugLog("add declaration failed: \(failure) — \(name) on rule \(rule.id)")
            return false
        }
        // Whether *this* line survived, asked of the engine by name. The
        // `applied` list is no use here: it enumerates longhands, so a
        // successful `margin` add reports margin-top and never `margin` —
        // and a declaration that never existed has no longhand list to
        // compare against. `getPropertyValue` answers for both kinds.
        guard let probe = reply["probe"] as? String, !probe.isEmpty else {
            debugLog("add declaration rejected by engine: \(name): \(value)")
            return false
        }

        changeset.record(StyleChange(
            ruleId: rule.id,
            selector: rule.isStyleAttribute ? "element.style" : rule.selector,
            sourceLabel: rule.isStyleAttribute ? "element" : rule.sourceLabel,
            layer: rule.layer,
            conditions: rule.conditions,
            property: name,
            original: nil,
            updated: value
        ))
        editedRuleIds.insert(rule.id)
        loadStyles()
        return true
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
        enabled: Bool = true,
        /// A step in a gesture rather than the end of one. The page is written
        /// to, but the pane is not rebuilt — dragging in the colour wheel would
        /// otherwise tear down and rebuild the row being dragged from, sixty
        /// times a second.
        live: Bool = false
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
        // The agent could not find what it was asked to change: a stale rule
        // id, a frame that navigated under us, a stylesheet that went away.
        //
        // This used to read as success. `applied` comes back absent, so the
        // emptiness check below passes, the edit is recorded into the
        // changeset and drawn as though it landed — while the page never
        // moved. An edit that silently does nothing is the worst failure this
        // pane can have, because you go and look for the bug somewhere else.
        if let failure = reply["error"] as? String {
            debugLog("style edit failed: \(failure) — \(original.name) on rule \(rule.id)")
            rejectedEdit = ref
            return
        }

        let applied = Set(reply["applied"] as? [String] ?? [])
        debugLog(
            "style edit: \(original.name)=\(edited.value) rule=\(rule.id) "
                + "live=\(live) applied=\(applied.count) props"
        )
        let rejected = enabled && !applied.isEmpty
            && !edited.longhands.contains(where: { applied.contains($0) })
        if rejected {
            // Only complain once the edit is finished. Typing "1p" on the way
            // to "12px" is not a mistake, and flashing "not a value color
            // accepts" at every keystroke would make live editing unusable.
            if !live { rejectedEdit = ref }
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
        if !live { loadStyles() }
    }

    /// Settles up after a live gesture: one read, once.
    func commitLiveEdit() {
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
        pickedNotation = pickedNotation.filter { !$0.key.hasPrefix("\(ruleId).") }
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
        pickedNotation.removeAll()
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

    // MARK: - Recovering cross-origin stylesheets

    private(set) var recoveredSheets: Set<String> = []
    /// By URL, with the reason — so a sheet that couldn't be fetched says why
    /// rather than silently staying missing.
    private(set) var failedRecoveries: [String: String] = [:]
    private(set) var isRecovering = false

    /// Attempted at most once per sheet per document. Without that guard this
    /// loops forever: recovering triggers a re-read, and a re-read reports the
    /// same unreadable sheets.
    @ObservationIgnored private var recoveryAttempted: Set<String> = []
    /// Set when a navigation lands and the edits are meant to come back, so the
    /// replay happens once the new document's rules have actually been read.
    @ObservationIgnored private var pendingStyleReplay = false

    private func recoverUnreadableSheets() async {
        guard let tab, let payload = stylePayload else { return }
        let pending = payload.unreadableSheets.filter { !recoveryAttempted.contains($0) }
        guard !pending.isEmpty else { return }

        isRecovering = true
        let issued = generation
        var recoveredAny = false

        for href in pending {
            recoveryAttempted.insert(href)
            let result = await StylesheetFetcher.fetch(href, in: tab)
            guard issued == generation else { isRecovering = false; return }

            switch result {
            case .success(let text):
                // Parsed in the page, because matching a selector against an
                // element is something only the page can do.
                let reply = try? await bridge.call(
                    .cssAddRecoveredSheet, ["href": href, "text": text]
                )
                guard issued == generation else { isRecovering = false; return }
                if reply != nil {
                    recoveredSheets.insert(href)
                    failedRecoveries.removeValue(forKey: href)
                    recoveredAny = true
                } else {
                    failedRecoveries[href] = "couldn't be parsed"
                }
            case .failure(let error):
                failedRecoveries[href] = error.errorDescription ?? "couldn't be fetched"
            }
        }

        isRecovering = false
        // Only when something actually landed: re-reading after a run of pure
        // failures would just produce the same list again.
        if recoveredAny { loadStyles() }
    }

    // MARK: - Network

    private(set) var network = NetworkBuffer()
    private(set) var visibleRequests: [NetworkRequest] = []
    private(set) var networkCounts: [NetworkKind: Int] = [:]
    private(set) var networkSummary = NetworkBuffer.Summary()
    private(set) var selectedRequest: NetworkRequest.ID?

    /// Off by default, like every browser: the previous page's traffic is
    /// usually noise.
    var preservesNetworkOnNavigation = false

    var networkKinds: Set<NetworkKind> = Set(NetworkKind.allCases) {
        didSet { if networkKinds != oldValue { refreshNetworkView() } }
    }
    var networkQuery = "" {
        didSet { if networkQuery != oldValue { refreshNetworkView() } }
    }

    var isNetworkFiltered: Bool {
        networkKinds.count != NetworkKind.allCases.count
            || !networkQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Cached for the same reason the console's list is: SwiftUI reads these
    /// several times per render pass and each one walks the whole buffer.
    private func refreshNetworkView() {
        // Chronological, not the order the two observers happened to report in.
        // A patched record is created when the request starts and its timing
        // observation arrives later, so recording order puts every fetch above
        // images that loaded before it — and a waterfall whose rows aren't in
        // time order is worse than no waterfall.
        visibleRequests = network
            .filtered(kinds: networkKinds, query: networkQuery)
            .sorted { $0.startedAt < $1.startedAt }
        networkCounts = network.counts()
        networkSummary = network.summary()
    }

    private(set) var requestBody: NetworkBody?
    private(set) var responseBody: NetworkBody?
    private(set) var isLoadingBody = false

    /// Bodies for replayed requests, which the page's agent knows nothing
    /// about — they never went through the page at all.
    @ObservationIgnored private var replayBodies: [String: NetworkBody] = [:]
    private(set) var isReplaying = false

    /// The request being edited before it is sent again, if any.
    var replayDraft: ReplayRequest?
    var replayDraftOrigin: NetworkRequest?

    /// Opens the editor for a request, seeded with what was observed.
    func beginReplay(_ request: NetworkRequest) {
        replayDraftOrigin = request
        replayDraft = ReplayRequest(from: request, body: requestBody?.text ?? "")
    }

    func cancelReplay() {
        replayDraft = nil
        replayDraftOrigin = nil
    }

    /// Sends a request again through `URLSession`, with the tab's real cookies.
    ///
    /// Never automatic. Replaying a POST re-runs whatever it did the first
    /// time, so it happens only when someone asks for it by name.
    func replay(_ draft: ReplayRequest, of original: NetworkRequest?) async {
        guard let tab else { return }
        isReplaying = true
        defer { isReplaying = false }

        // Placed at the end of the timeline so the waterfall stays readable —
        // a replay didn't happen during the page load.
        let offset = network.summary().finishedAt + 20
        let result = await RequestReplayer.send(
            draft, replacing: original, in: tab, startingAt: offset
        )

        network.record(result.request)
        if let body = result.body { replayBodies[result.request.id] = body }
        refreshNetworkView()
        replayDraft = nil
        replayDraftOrigin = nil
        selectRequest(result.request.id)
    }

    /// What changed between a replay and the request it came from.
    func comparison(for request: NetworkRequest) -> ReplayComparison? {
        guard let originalId = request.replayOf,
              let original = network.requests.first(where: { $0.id == originalId })
        else { return nil }
        return ReplayComparison(
            original: original,
            originalBody: originalBodyText,
            replayed: request,
            replayedBody: replayBodies[request.id]?.text
        )
    }

    /// Kept so a comparison can be made against what the original actually
    /// returned rather than against nothing.
    @ObservationIgnored private var originalBodyText: String?

    func selectRequest(_ id: NetworkRequest.ID?) {
        selectedRequest = id
        requestBody = nil
        responseBody = nil
        guard let id else { return }
        Task { @MainActor in await loadBodies(for: id) }
    }

    /// Bodies for one request, read only when its row is opened.
    private func loadBodies(for id: NetworkRequest.ID) async {
        // A replayed request never went through the page, so its body lives
        // here rather than in the agent.
        if let body = replayBodies[id] {
            responseBody = body
            requestBody = nil
            return
        }

        isLoadingBody = true
        let issued = generation
        defer { isLoadingBody = false }

        guard let reply = try? await bridge.call(.networkGetBody, ["id": id]),
              issued == generation, selectedRequest == id
        else { return }

        let bodies = NetworkWire.decodeBodies(reply)
        requestBody = bodies.request
        responseBody = bodies.response
        originalBodyText = bodies.response?.text
    }

    var selectedRequestDetail: NetworkRequest? {
        guard let selectedRequest else { return nil }
        return network.requests.first { $0.id == selectedRequest }
    }

    func clearNetwork() {
        network.clear()
        selectedRequest = nil
        requestBody = nil
        responseBody = nil
        replayBodies.removeAll()
        refreshNetworkView()
        bridge.send(.networkClear)
    }

    /// Collects what the page recorded before this window existed.
    private func drainNetworkBacklog() async {
        let issued = generation
        guard let reply = try? await bridge.call(.networkDrain), issued == generation
        else { return }

        // The document first, so it heads the list even when the panel opened
        // long after the page finished loading.
        if let document = tab?.lastDocumentResponse { recordDocument(document) }

        let batch = NetworkWire.decodeBatch(reply["requests"])
        for request in batch.records { network.record(request) }
        // Merged after, so a timing observation always has its patched record
        // to attach to rather than becoming a duplicate row.
        for timing in batch.timings { network.merge(timing: timing) }
        if let dropped = reply["dropped"] as? Int, dropped > 0 { noteDroppedRequests(dropped) }
        refreshNetworkView()
        bridge.send(.networkSetLive, ["live": true])
    }

    private func noteDroppedRequests(_ count: Int) {
        record(ConsoleEntry(
            id: 0,
            level: .warning,
            arguments: [RemoteObject(
                type: .string,
                description: "\(count.formatted()) requests were dropped — the page made them faster than Surf could read."
            )]
        ))
    }

    /// The main document, as the *native* layer saw it.
    ///
    /// Worth taking from here rather than from the page: `WKNavigationDelegate`
    /// reports the real status and the real response headers, including for
    /// cross-origin redirects that page script is forbidden to look at. It is
    /// the one row in the list that no JS-based inspector can report honestly.
    func recordDocument(_ response: Tab.DocumentResponse) {
        var request = NetworkRequest(
            id: "document:\(generation)",
            url: response.url,
            method: "GET",
            kind: .document,
            status: response.status,
            transferSize: nil,
            startedAt: 0,
            duration: nil,
            protocolName: "",
            initiator: "navigation",
            responseHeaders: response.headers,
            isDetailed: true
        )
        if let length = response.headers
            .first(where: { $0.key.lowercased() == "content-length" })?.value,
           let bytes = Int(length) {
            request.transferSize = bytes
        }
        network.record(request)
        refreshNetworkView()
    }

    // MARK: - Storage

    var storageArea: StorageArea = .cookies {
        didSet { if storageArea != oldValue { Task { @MainActor in await loadStorage() } } }
    }
    var storageQuery = "" {
        didSet { if storageQuery != oldValue { refreshStorageView() } }
    }
    /// Cookies for every origin, not just this page's. Off by default because
    /// the question is nearly always "what does this site have".
    var showsAllCookies = false {
        didSet { if showsAllCookies != oldValue { Task { @MainActor in await loadStorage() } } }
    }

    private(set) var cookies: [StorageCookie] = []
    private(set) var storageItems: [StorageItem] = []
    private(set) var siteData: [SiteDataRecord] = []
    private(set) var storageUsage: (used: Int, quota: Int)?
    private(set) var storageError: String?
    private(set) var isLoadingStorage = false

    private(set) var visibleCookies: [StorageCookie] = []
    private(set) var visibleItems: [StorageItem] = []
    private(set) var visibleSiteData: [SiteDataRecord] = []

    private func refreshStorageView() {
        visibleCookies = StorageFilter.cookies(cookies, query: storageQuery)
        visibleItems = StorageFilter.items(storageItems, query: storageQuery)
        visibleSiteData = StorageFilter.siteData(siteData, query: storageQuery)
    }

    func loadStorage() async {
        isLoadingStorage = true
        storageError = nil
        defer { isLoadingStorage = false }
        let issued = generation

        switch storageArea {
        case .cookies:
            guard let tab else { return }
            cookies = showsAllCookies
                ? await CookieStore.cookies(for: tab)
                : await CookieStore.cookies(for: tab, matching: pageURL)

        case .local, .session:
            guard let reply = try? await bridge.call(
                .storageRead, ["area": storageArea.rawValue]
            ), issued == generation else { return }
            // A sandboxed document denies access outright. Saying so beats an
            // empty table, which reads as "nothing stored".
            if let message = reply["error"] as? String {
                storageError = message
                storageItems = []
            } else {
                storageItems = decodeItems(reply["items"])
            }

        case .caches:
            guard let reply = try? await bridge.call(.storageListCaches),
                  issued == generation else { return }
            storageItems = decodeItems(reply["items"])

        case .databases:
            guard let reply = try? await bridge.call(.storageListDatabases),
                  issued == generation else { return }
            storageItems = decodeItems(reply["items"])

        case .siteData:
            guard let tab else { return }
            siteData = await CookieStore.siteData(for: tab)
        }

        if let estimate = try? await bridge.call(.storageEstimate), issued == generation,
           let used = estimate["usage"] as? Int, let quota = estimate["quota"] as? Int, quota > 0 {
            storageUsage = (used, quota)
        }
        guard issued == generation else { return }
        refreshStorageView()
    }

    private func decodeItems(_ value: Any?) -> [StorageItem] {
        guard let raw = value as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let key = entry["key"] as? String else { return nil }
            return StorageItem(
                key: key,
                value: entry["value"] as? String ?? "",
                detail: entry["detail"] as? String ?? ""
            )
        }
    }

    func setStorageValue(_ value: String, for key: String) async {
        guard storageArea.isEditable else { return }
        _ = try? await bridge.call(
            .storageWrite, ["area": storageArea.rawValue, "key": key, "value": value]
        )
        await loadStorage()
    }

    func removeStorageItem(_ key: String) async {
        guard storageArea.isEditable else { return }
        _ = try? await bridge.call(
            .storageRemove, ["area": storageArea.rawValue, "key": key]
        )
        await loadStorage()
    }

    func deleteCookie(_ cookie: StorageCookie) async {
        guard let tab else { return }
        await CookieStore.delete(cookie, in: tab)
        await loadStorage()
    }

    /// Clears whatever the current area holds.
    ///
    /// Deliberately scoped to the area on screen rather than offering one
    /// button that wipes everything: "clear site data" and "delete these three
    /// cookies" are very different actions to take by accident.
    func clearStorageArea() async {
        switch storageArea {
        case .cookies:
            guard let tab else { return }
            await CookieStore.deleteAll(visibleCookies, in: tab)
        case .local, .session:
            _ = try? await bridge.call(.storageRemove, ["area": storageArea.rawValue])
        case .caches, .databases, .siteData:
            return
        }
        await loadStorage()
    }

    func clearSiteData(_ record: SiteDataRecord) async {
        guard let tab else { return }
        await CookieStore.clear(record, in: tab)
        await loadStorage()
    }

    // MARK: - Tags

    public enum TagSection: String, CaseIterable, Identifiable {
        case detected, events, libraries
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .detected: "Detected"
            case .events: "Events"
            case .libraries: "Ad libraries"
            }
        }
    }

    var tagSection: TagSection = .detected
    private(set) var tagEvents: [TagEvent] = []
    private(set) var detectedTags: [DetectedTag] = []
    private(set) var tagFindings: [TagFinding] = []
    private(set) var consentManagers: [String] = []
    /// What to search an ad library for. A guess, and editable, because the
    /// tool that does this for a living just asks a human.
    var advertiserName = ""
    /// The accounts the site declares about itself, and the deep links to them.
    private(set) var socialProfiles: [SocialProfile] = []
    private(set) var isLoadingTags = false

    /// Bodies for the vendors that POST their payload, fetched only for
    /// requests already known to be tags.
    @ObservationIgnored private var tagBodies: [String: String] = [:]

    var siteDomain: String {
        URLComponents(string: pageURL)?.host ?? ""
    }

    /// Reads the tags off the page and out of the traffic already recorded.
    ///
    /// The events need no new capture: every pixel fire is a network request,
    /// including the `<img>` and beacon ones most tags use, and those are
    /// already in the buffer. This decodes what is there.
    func loadTags() async {
        isLoadingTags = true
        defer { isLoadingTags = false }
        let issued = generation

        // Bodies first, for the vendors that POST — TikTok and GA4 batch that
        // way, and without the body those events decode as empty.
        let candidates = network.requests.filter {
            TagDecoder.signature(for: $0.url) != nil && $0.hasRequestBody
                && tagBodies[$0.id] == nil
        }
        for request in candidates.prefix(30) {
            guard let reply = try? await bridge.call(.networkGetBody, ["id": request.id]),
                  issued == generation
            else { break }
            if let body = NetworkWire.decodeBodies(reply).request?.text {
                tagBodies[request.id] = body
            }
        }

        let events = network.requests.compactMap {
            TagDecoder.decode($0, body: tagBodies[$0.id])
        }.sorted { $0.at < $1.at }

        // What is installed, whether or not it has spoken.
        let globals = TagDecoder.signatures.compactMap { signature -> [String: any Sendable]? in
            guard !signature.globals.isEmpty else { return nil }
            return ["id": signature.id, "names": signature.globals]
        }
        var evidenceByVendor: [String: [String]] = [:]
        if let reply = try? await bridge.call(.tagsDetect, ["globals": globals]),
           issued == generation {
            for entry in reply["found"] as? [[String: Any]] ?? [] {
                guard let id = entry["id"] as? String else { continue }
                evidenceByVendor[id] = entry["evidence"] as? [String] ?? []
            }
            consentManagers = reply["consent"] as? [String] ?? []
            advertiserName = AdvertiserName.guess(
                siteName: reply["siteName"] as? String ?? "",
                title: reply["title"] as? String ?? "",
                domain: siteDomain
            )
            let identity = SocialDetection.identity(
                metaPages: reply["metaPages"] as? [String] ?? [],
                links: reply["links"] as? [String] ?? []
            )
            socialProfiles = SocialDetection.profiles(
                for: identity,
                fallbackTerm: advertiserName.isEmpty ? siteDomain : advertiserName
            )
        }

        // A vendor counts as present if it left a global *or* sent traffic —
        // a tag loaded from a manager may leave no global at all.
        var vendors: [String: DetectedTag] = [:]
        for signature in TagDecoder.signatures {
            let evidence = evidenceByVendor[signature.id] ?? []
            let mine = events.filter { $0.vendorId == signature.id }
            guard !evidence.isEmpty || !mine.isEmpty else { continue }

            var accounts: [String] = []
            for event in mine where !event.accountId.isEmpty {
                if !accounts.contains(event.accountId) { accounts.append(event.accountId) }
            }
            vendors[signature.id] = DetectedTag(
                vendorId: signature.id, name: signature.name, category: signature.category,
                accountIds: accounts,
                evidence: evidence + (mine.isEmpty ? [] : ["\(mine.count) requests"]),
                eventCount: mine.count
            )
        }

        guard issued == generation else { return }
        tagEvents = events
        detectedTags = vendors.values.sorted {
            $0.category == $1.category
                ? $0.name < $1.name
                : $0.category.rawValue < $1.category.rawValue
        }
        tagFindings = TagValidation.findings(
            events: events, detected: detectedTags,
            hasConsentManager: !consentManagers.isEmpty,
            // The moment a consent record first appears in the cookie jar is
            // the closest thing to a timestamp for the visitor's choice.
            consentSignalAt: nil
        )
    }

    func adLibraries() -> [(vendor: String, library: AdLibrary, accountId: String, url: String)] {
        TagDecoder.signatures.compactMap { signature in
            guard let library = signature.adLibrary,
                  let detected = detectedTags.first(where: { $0.vendorId == signature.id })
            else { return nil }
            let account = detected.accountIds.first ?? ""
            let term = advertiserName.isEmpty ? siteDomain : advertiserName
            return (
                signature.name, library, account,
                library.url(id: account, domain: term)
            )
        }
    }

    // MARK: - Performance

    private(set) var performance = PerformanceReport()
    private(set) var isMeasuringLayout = false
    /// What the pane asked for, as opposed to what the current document is
    /// doing. A reload replaces the agent with a fresh one that is watching
    /// nothing, so the intent has to outlive the document or "reload and
    /// measure" would reload and then measure nothing.
    @ObservationIgnored private var wantsLayoutWatching = false
    @ObservationIgnored private var performanceTimer: Task<Void, Never>?

    func loadPerformance() async {
        let issued = generation
        guard let reply = try? await bridge.call(.performanceRead), issued == generation
        else { return }
        performance = PerformanceWire.decode(reply)
        isMeasuringLayout = performance.isWatchingLayout

        // Re-arms itself after a navigation. Cheaper and more reliable than
        // hooking the load: the poll is already running, and this converges
        // within one tick however the document changed.
        if wantsLayoutWatching, !performance.isWatchingLayout {
            _ = try? await bridge.call(.performanceWatchLayout, ["enabled": true])
        }
    }

    /// Starts watching for layout shifts.
    ///
    /// Opt-in and self-stopping, because reading element rects forces layout —
    /// measuring this way costs a little of the thing it measures. It runs
    /// while the pane is open and stops once the page settles.
    func setLayoutWatching(_ enabled: Bool) async {
        wantsLayoutWatching = enabled
        _ = try? await bridge.call(.performanceWatchLayout, ["enabled": enabled])
        isMeasuringLayout = enabled
        await loadPerformance()
    }

    /// Polls while the pane is on screen. Metrics arrive over the life of a
    /// page — LCP is refined as bigger content paints, interactions happen when
    /// someone interacts — so a single read would be a snapshot of the first
    /// moment rather than a picture of the page.
    func startPerformanceUpdates() {
        performanceTimer?.cancel()
        performanceTimer = Task { @MainActor in
            while !Task.isCancelled {
                await loadPerformance()
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    func stopPerformanceUpdates() {
        performanceTimer?.cancel()
        performanceTimer = nil
    }

    /// Reloads with the agent already installed, which is the only way to get a
    /// complete picture: layout shifts and blocked frames can't be recovered
    /// after the fact the way paint timings can.
    func reloadAndMeasure() async {
        await setLayoutWatching(true)
        tab?.reload()
    }

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

    /// Deliberately `currentURL` rather than `webView.url`.
    ///
    /// Reading `webView` *builds* one when the tab is asleep, and this is read
    /// on every render of the panel header — so describing a tab through it
    /// would resurrect a reclaimed tab as a blank view with no agents in it,
    /// leaving `isLive` true and every command failing. Measured, not guessed:
    /// that is exactly what happened the first time this merge was tested.
    var pageURL: String { tab?.currentURL ?? "" }

    // MARK: - Lifecycle

    func start() {
        Task { @MainActor in
            do {
                try await bridge.attach()
                await drainConsoleBacklog()
                await drainNetworkBacklog()
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
        stopPerformanceUpdates()
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
        removedClasses = [:]
        layoutOverlayNode = nil
        layoutOverlay = nil
        forcedStates = []
        forcedNode = nil
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
        performance = PerformanceReport()
        tagEvents = []
        detectedTags = []
        tagFindings = []
        socialProfiles = []
        tagBodies.removeAll()
        cookies = []
        storageItems = []
        siteData = []
        storageError = nil
        refreshStorageView()
        recoveredSheets.removeAll()
        failedRecoveries.removeAll()
        recoveryAttempted.removeAll()
        // Every rule handle belonged to the old document. What is dropped
        // depends on whether the edits are meant to come back: without
        // preservation the page has genuinely reloaded its own stylesheets and
        // offering a patch for a state that no longer exists would be a lie,
        // and with it the changeset is the only record of what to reapply.
        disabled.removeAll()
        disabledRules.removeAll()
        pickedNotation.removeAll()
        editedRuleIds.removeAll()
        rejectedEdit = nil
        replayMisses = []
        didReplayEdits = false
        if preservesStyleEditsOnReload, !changeset.isEmpty {
            pendingStyleReplay = true
        } else {
            changeset.clear()
        }
        console.markNavigation(url: pageURL, preservingLog: preservesLogOnNavigation)
        refreshConsoleView()
        network.markNavigation(preserving: preservesNetworkOnNavigation)
        selectedRequest = nil
        requestBody = nil
        responseBody = nil
        replayBodies.removeAll()
        replayDraft = nil
        replayDraftOrigin = nil
        refreshNetworkView()
        releaseEvictedObjects()

        Task { @MainActor in
            // The new document's console agent starts buffering rather than
            // live — it has no idea a window is open — so it has to be told,
            // and its startup logs collected, exactly as at attach time.
            await drainConsoleBacklog()
            await drainNetworkBacklog()
            await loadDocument()
            await refreshStatus()
            // After the document, and independent of whether anything is
            // selected: a reload clears the selection, and the edits have to
            // come back regardless.
            if pendingStyleReplay {
                pendingStyleReplay = false
                await replayStyleEdits()
            }
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

        case .layoutChanged(let overlay):
            // Only if it's still the node we armed — a report racing a toggle
            // would resurrect an overlay that was just dismissed.
            guard overlay?.nodeId == layoutOverlayNode || overlay == nil else { return }
            layoutOverlay = overlay

        case .boxChanged(let nodeId, let box):
            // Ignored unless it's still the element we asked about — a reply
            // for a node selected two clicks ago would drag the highlight back.
            guard nodeId == selectedNode else { return }
            selectedBox = box

        case .inspectPicked(let nodeId):
            isPicking = false
            hoveredNode = nil
            hoveredBox = nil
            // Answer in the pane that asked.
            //
            // This used to switch to Elements unconditionally, which made the
            // picker useless from Styles: arm it, click a heading, and land in
            // the DOM tree having to navigate back to the pane you were
            // reading. Both panes are about the selected element, so either is
            // a valid place to land — only a pane that has nothing to do with
            // the selection needs redirecting.
            if !pane.showsSelectedElement { pane = .elements }
            revealAndSelect(nodeId)
            // The result is in the panel, so the panel comes forward. The page
            // was fronted to receive the click; that job is done.
            if let tab { DevToolsController.shared.bringPanelForward(for: tab) }

        case .inspectCancelled:
            isPicking = false
            hoveredNode = nil
            hoveredBox = nil

        case .networkBatch(let requests, let timings, let sequence, let dropped):
            if dropped > 0 { noteDroppedRequests(dropped) }
            for request in requests { network.record(request) }
            for timing in timings { network.merge(timing: timing) }
            refreshNetworkView()
            bridge.send(.networkAck, ["sequence": sequence])

        case .networkOverflowed:
            // Everything is still in the agent's map, so the answer is to read
            // it again rather than to replay — a replay would double-count.
            Task { @MainActor in await drainNetworkBacklog() }

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
            "\($0.formatted()) messages were dropped — the page logged faster than Surf could read."
        } ?? "Some messages were dropped — the page logged faster than Surf could read."

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

    /// TEMP seam for the merge check.
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
