import Foundation
import Observation
import SurfCore
import WebKit

/// One isolated environment: an identity, a cookie jar, and the tabs filed
/// under it.
///
/// The jar is the point. Two islands are two `WKWebsiteDataStore`s, so a login
/// in one is invisible to the other — which is what makes a work account and a
/// personal account able to exist in the same browser at the same time.
///
/// `dataStore` is looked up from `IslandStores`, which memoises one live object
/// per identifier — so every read here hands back the same instance, and that
/// instance outlives everything holding it. A tab can sleep and wake, and a web
/// view can be built and released underneath it, while the store stays put.
///
/// Two islands may deliberately name the same jar: that is what an island
/// created with "keep my logins" is. Sharing is a property of the identifier,
/// so it costs nothing here — both islands read the same memoised store, which
/// is precisely the guarantee `IslandStores` exists to make.
@Observable
@MainActor
final class Island: Identifiable {

    nonisolated let id: UUID

    var name: String
    /// One emoji, shown in the sidebar strip.
    var symbol: String
    var tint: IslandTint

    /// nil for the home island, which uses WebKit's default store — the jar
    /// holding every cookie from before islands existed. Nobody is migrated
    /// into an identified store, because there is no supported way to move
    /// cookies between stores and the migration would sign the user out of
    /// everything they have.
    ///
    /// Also nil for an island created *from* home asking to keep its logins:
    /// sharing a jar is spelled by naming the same store, not by copying
    /// anything. Which is the same reason it isn't `let` any more — see
    /// `adoptStore`.
    @ObservationIgnored private(set) var dataStoreID: UUID?

    /// The store minted for this island alone, kept aside so the choice made
    /// while creating it can be taken back. Nil for home, which was never
    /// given one.
    ///
    /// Not persisted: the toggle only exists while an island is new and empty,
    /// so by the next launch there is nothing left to undo.
    @ObservationIgnored let ownStoreID: UUID?

    var dataStore: WKWebsiteDataStore {
        IslandStores.shared.store(forIdentifier: dataStoreID)
    }

    /// The tabs in this island, in sidebar order.
    ///
    /// `private(set)` with narrow mutators rather than an open array:
    /// `BrowserSession` owns the rules about selection and teardown, and the
    /// only thing worth enforcing here is that nothing edits the list behind
    /// its back.
    private(set) var tabs: [Tab] = []

    /// The groups in this island. Order is not meaningful — where a group sits
    /// in the sidebar is decided by where its tabs sit, which is the only
    /// answer that can't drift out of step with what's drawn.
    private(set) var groups: [TabGroup] = []

    /// The tab to return to when this island is selected again.
    ///
    /// Only meaningful while the island is in the background — the live
    /// selection is `BrowserSession.selectedTab`, which must stay a single
    /// non-optional value so that no view needs a nil branch.
    @ObservationIgnored var rememberedSelection: Tab.ID?

    /// Pinned sites, in shelf order — the stickers along the top of the
    /// sidebar. Saved URLs, not tabs: they hold no web view and cost nothing
    /// while unclicked.
    ///
    /// Per-island for the same reason `recentlyClosed` is: a sticker opens its
    /// site in this island's cookie jar, so showing it in another island would
    /// invite the site into the wrong identity with one click.
    private(set) var stickers: [Sticker] = []

    /// Closed tabs, newest first, for ⌘⇧T.
    ///
    /// Per-island, not global. A shared buffer would let ⌘⇧T resurrect a work
    /// tab into a personal island — which isn't merely surprising, it's a leak
    /// in the direction nobody thinks to check, and the restored tab would
    /// carry its back/forward history into a jar that never saw those pages.
    @ObservationIgnored var recentlyClosed: [PersistedTab] = []

    /// The island the browser started life as. Stored rather than derived from
    /// the store, because an island sharing home's jar uses the same store
    /// without being home — it can be deleted, and home can't.
    nonisolated let isHome: Bool


    /// Whether this island failed to get persistent storage this run, so the
    /// UI can say so rather than quietly forgetting the user on every quit.
    var isDegraded: Bool { IslandStores.shared.isDegraded(dataStoreID) }

    init(
        id: UUID,
        name: String,
        symbol: String,
        tint: IslandTint,
        dataStoreID: UUID?,
        ownStoreID: UUID? = nil,
        isHome: Bool
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.dataStoreID = dataStoreID
        self.ownStoreID = ownStoreID ?? dataStoreID
        self.isHome = isHome
    }

    convenience init(_ persisted: PersistedIsland) {
        self.init(
            id: persisted.id,
            name: persisted.name,
            symbol: persisted.symbol,
            tint: persisted.tint,
            dataStoreID: persisted.dataStoreID,
            isHome: persisted.isHome
        )
        groups = (persisted.groups ?? []).map(TabGroup.init)
        stickers = persisted.stickers ?? []
    }

    /// Re-points this island at another jar.
    ///
    /// Only ever called on an island that is brand new and empty, from the
    /// sheet that creates it — which is the only moment this is safe. A tab
    /// takes its store at construction and hands it to a web view that may
    /// already hold cookies, so switching under a live tab wouldn't move the
    /// tab, it would leave it browsing as whoever it was before. `BrowserSession`
    /// rebuilds the island's tabs around this call rather than trusting them to
    /// notice.
    func adoptStore(_ identifier: UUID?) {
        dataStoreID = identifier
    }

    // MARK: - Stickers

    /// A no-op when the URL is already pinned — see `Sticker.adding`.
    func addSticker(_ sticker: Sticker) {
        stickers = Sticker.adding(sticker, to: stickers)
    }

    func removeSticker(id: Sticker.ID) {
        stickers = Sticker.removing(id, from: stickers)
    }

    /// Replaces the shelf wholesale — the "bring over pinned tabs" switch, and
    /// the same switch turned back off.
    ///
    /// Each copy gets a fresh id. A sticker's id is what its lean and the shine
    /// across it are derived from, so two shelves sharing ids would sit at
    /// identical angles and read as one printed sheet rather than two — and
    /// peeling one off is by id, which must only ever reach one shelf.
    func replaceStickers(with replacement: [Sticker]) {
        stickers = replacement.map {
            Sticker(url: $0.url, title: $0.title, host: $0.host)
        }
    }

    // MARK: - Tabs

    /// The only place a `Tab` is constructed.
    ///
    /// A tab without a data store isn't a tab that browses badly, it's a tab
    /// that browses as the wrong person — so the one thing worth guaranteeing
    /// structurally is that there's no way to make one without an island to
    /// make it in.
    func makeTab(configuration: WKWebViewConfiguration? = nil) -> Tab {
        Tab(dataStore: dataStore, configuration: configuration)
    }

    func insert(_ tab: Tab, at index: Int) {
        tabs.insert(tab, at: min(max(0, index), tabs.count))
    }

    func append(_ tab: Tab) {
        tabs.append(tab)
    }

    @discardableResult
    func remove(at index: Int) -> Tab {
        tabs.remove(at: index)
    }

    func replaceTabs(with replacement: [Tab]) {
        tabs = replacement
    }

    /// Rearranges the existing tabs into `ids`.
    ///
    /// Applied only when `ids` is a permutation of what's here — the orders come
    /// from `TabOrder`, which works on ids alone and can't know that a tab was
    /// closed while a drag was in flight. Rebuilding from a stale list would
    /// drop the tabs missing from it, so a mismatch leaves the list untouched
    /// instead.
    func reorder(to ids: [UUID]) {
        var remaining = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let reordered = ids.compactMap { remaining.removeValue(forKey: $0) }
        guard reordered.count == tabs.count else { return }
        tabs = reordered
    }

    /// Reorders one tab within the island. Identity is untouched — selection
    /// follows `Tab.ID`, so moving a tab never changes which one is selected.
    func move(fromIndex: Int, toIndex: Int) {
        guard tabs.indices.contains(fromIndex),
              tabs.indices.contains(toIndex),
              fromIndex != toIndex
        else { return }
        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: toIndex)
    }

    func index(of tab: Tab) -> Int? {
        tabs.firstIndex { $0.id == tab.id }
    }

    func contains(_ tab: Tab) -> Bool {
        index(of: tab) != nil
    }

    // MARK: - Groups

    /// The tab list as `TabGrouping` wants it: ids paired with their group.
    var slots: [TabSlot] { tabs.map { TabSlot(id: $0.id, group: $0.groupID) } }

    func group(_ id: UUID) -> TabGroup? { groups.first { $0.id == id } }

    func addGroup(_ group: TabGroup) { groups.append(group) }

    /// Removes the group and unfiles anything still in it, so no tab is ever
    /// left naming a group that isn't there — a tab like that would vanish from
    /// the sidebar, since nothing draws a section that doesn't exist.
    func removeGroup(_ id: UUID) {
        for tab in tabs where tab.groupID == id { tab.groupID = nil }
        groups.removeAll { $0.id == id }
    }

    /// Drops groups that have no tabs left.
    ///
    /// A group is its members, so an empty one isn't an empty folder waiting to
    /// be filled — it has no position in the list, nothing to draw, and no way
    /// to reach it. Closing the last tab in a section therefore closes the
    /// section, which is also what it looks like from the outside.
    func pruneEmptyGroups() {
        let occupied = Set(tabs.compactMap(\.groupID))
        groups.removeAll { !occupied.contains($0.id) }
    }

    /// Restores the one thing a group needs to be drawable: its tabs together.
    ///
    /// Cheap and idempotent, so it can be called after anything that moves a
    /// tab rather than each such place having to reason about whether it broke
    /// a run.
    func normalizeGroups() {
        guard let order = TabGrouping.normalized(slots) else { return }
        reorder(to: order)
    }

    // MARK: - Persistence

    /// `refreshingState` is expensive — it asks each live tab for its
    /// back/forward blob — so it's paid only on the save that has to be right,
    /// the one at quit.
    func snapshot(refreshingState: Bool, selected: Tab.ID?) -> PersistedIsland {
        let selectedID = selected ?? rememberedSelection
        return PersistedIsland(
            id: id,
            name: name,
            symbol: symbol,
            tint: tint,
            dataStoreID: dataStoreID,
            isHomeIsland: isHome,
            tabs: tabs.map { $0.snapshot(refreshingState: refreshingState) },
            selectedIndex: tabs.firstIndex { $0.id == selectedID } ?? 0,
            groups: groups.isEmpty ? nil : groups.map(\.snapshot),
            // Written as nil when empty, so a shelf nobody uses adds nothing
            // to the file.
            stickers: stickers.isEmpty ? nil : stickers
        )
    }
}
