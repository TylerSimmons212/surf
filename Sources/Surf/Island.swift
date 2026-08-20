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
/// `dataStore` is a `let` acquired once from `IslandStores` and held for the
/// island's life. A tab can sleep and wake, and a web view can be built and
/// released underneath it, but the store outlives all of that: it is the thing
/// that stays the same while everything holding it comes and goes.
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
    @ObservationIgnored let dataStoreID: UUID?
    @ObservationIgnored let dataStore: WKWebsiteDataStore

    /// The tabs in this island, in sidebar order.
    ///
    /// `private(set)` with narrow mutators rather than an open array:
    /// `BrowserSession` owns the rules about selection and teardown, and the
    /// only thing worth enforcing here is that nothing edits the list behind
    /// its back.
    private(set) var tabs: [Tab] = []

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

    var isHome: Bool { dataStoreID == nil }

    /// Whether this island failed to get persistent storage this run, so the
    /// UI can say so rather than quietly forgetting the user on every quit.
    var isDegraded: Bool { IslandStores.shared.isDegraded(dataStoreID) }

    init(id: UUID, name: String, symbol: String, tint: IslandTint, dataStoreID: UUID?) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.dataStoreID = dataStoreID
        self.dataStore = IslandStores.shared.store(forIdentifier: dataStoreID)
    }

    convenience init(_ persisted: PersistedIsland) {
        self.init(
            id: persisted.id,
            name: persisted.name,
            symbol: persisted.symbol,
            tint: persisted.tint,
            dataStoreID: persisted.dataStoreID
        )
        self.stickers = persisted.stickers ?? []
    }

    // MARK: - Stickers

    /// A no-op when the URL is already pinned — see `Sticker.adding`.
    func addSticker(_ sticker: Sticker) {
        stickers = Sticker.adding(sticker, to: stickers)
    }

    func removeSticker(id: Sticker.ID) {
        stickers = Sticker.removing(id, from: stickers)
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

    func index(of tab: Tab) -> Int? {
        tabs.firstIndex { $0.id == tab.id }
    }

    func contains(_ tab: Tab) -> Bool {
        index(of: tab) != nil
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
            tabs: tabs.map { $0.snapshot(refreshingState: refreshingState) },
            selectedIndex: tabs.firstIndex { $0.id == selectedID } ?? 0,
            // Written as nil when empty, so a shelf nobody uses adds nothing
            // to the file.
            stickers: stickers.isEmpty ? nil : stickers
        )
    }
}
