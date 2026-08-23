import CryptoKit
import Foundation
import SurfCore
import Observation
import WebKit

/// Compiles the filter rules and hands them to every tab.
///
/// The blocking itself is WebKit's. `WKContentRuleList` matches in the network
/// process, before a request is made rather than after it returns, which is why
/// this is a browser feature and not an extension: nothing is fetched and then
/// thrown away, and no page script can be first past the post.
///
/// What Surf adds is everything around that — keeping the list current, folding
/// the user's own two decisions into it, and knowing enough about what the rules
/// say to be able to describe them afterwards.
@Observable
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()

    /// Compiled and ready to hand to a web view. Empty until `prepare()` has
    /// run, and empty forever if there is no list on disk and no network.
    private(set) var lists: [WKContentRuleList] = []

    /// The domain sets behind those rules, for naming what got blocked.
    private(set) var classifier = BlockClassifier()

    /// How many domains the rules in force name. Shown in Settings, because
    /// "blocking is on" is a claim and this is the evidence for it — and a count
    /// of domains says something a reader can picture, where a count of rules
    /// says only that there are a lot of them.
    private(set) var blockedDomainCount = 0

    private(set) var isPreparing = false

    private(set) var userRules: UserBlockRules

    /// The compile in flight or last finished. Each new one is chained behind
    /// it, so awaiting `compile()` means the rules as they stood when it was
    /// called are in force by the time it returns — which is what lets a
    /// caller reload a page *after* the change it just made rather than
    /// before. Compiles are slow enough that a second click during one is
    /// normal; chaining keeps it rather than dropping it, and a compile that
    /// finds nothing changed is a cache hit in the store, not a second wait.
    private var compileChain: Task<Void, Never>?

    private init() {
        userRules = Self.loadUserRules()
        classifier.userBlockedDomains = userRules.blockedDomains
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKeys.blockAds)
    }

    // MARK: - Storage

    /// Alongside the helper binaries rather than inside the bundle, for the same
    /// reason: the bundle is signed and read-only.
    static let directory: URL = SupportDirectory.subdirectory("Filters")

    private static var userRulesURL: URL { directory.appendingPathComponent("rules.json") }

    /// A list as published, as converted, and the domains that came out of it.
    ///
    /// The rules and the domains are written beside the source rather than
    /// rebuilt each launch. Converting a hundred thousand filters is not
    /// expensive enough to care about once; it is expensive enough to care
    /// about on every single launch, for a result that can't have changed.
    private static func sourceURL(_ source: FilterListSource) -> URL {
        directory.appendingPathComponent("\(source.id).txt")
    }

    /// Both artifacts carry the converter's format version, so a build that
    /// converts differently can't be served last build's answers. Naming rather
    /// than a side-car marker: an old file is then simply never opened, which
    /// needs no comparison and can't half-fail.
    private static func rulesURL(_ source: FilterListSource) -> URL {
        directory.appendingPathComponent(
            "\(source.id).rules.v\(FilterConverter.formatVersion).json")
    }

    private static func domainsURL(_ source: FilterListSource) -> URL {
        directory.appendingPathComponent(
            "\(source.id).domains.v\(FilterConverter.formatVersion).txt")
    }

    /// Removes conversions left behind by an older format version.
    ///
    /// They are never read once the version moves, so this is only about not
    /// leaving thirteen megabytes of dead JSON per list on disk for ever.
    private nonisolated static func discardStaleConversions(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        let current = ".v\(FilterConverter.formatVersion)."
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.contains(".rules.v") || name.contains(".domains.v"),
                  !name.contains(current)
            else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
        // The unversioned originals, from before this existed.
        for source in FilterList.sources {
            for legacy in ["\(source.id).rules.json", "\(source.id).domains.txt"] {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(legacy))
            }
        }
    }

    /// The list as published: the copy fetched last, or the one inside the app.
    ///
    /// Newest-first, matching how the helper binaries resolve. The bundled copy
    /// exists so a fresh install blocks on its first page rather than after its
    /// first update.
    private static func publishedList(_ source: FilterListSource) -> Data? {
        if let installed = try? Data(contentsOf: sourceURL(source)) { return installed }
        guard let bundled = Bundle.main.url(forResource: source.id, withExtension: "txt")
        else { return nil }
        return try? Data(contentsOf: bundled)
    }

    /// The converted rules and their domains, converting first if that hasn't
    /// happened yet. Runs off the main actor: this is the expensive call.
    private static func converted(_ source: FilterListSource) async -> (Data, Set<String>)? {
        if let rules = try? Data(contentsOf: rulesURL(source)),
           let domainText = try? String(contentsOf: domainsURL(source), encoding: .utf8) {
            let domains = Set(domainText.split(separator: "\n").map(String.init))
            return (rules, domains)
        }
        guard let published = publishedList(source) else { return nil }
        return await convertAndStore(published, for: source)
    }

    /// Converts a published list and writes both artifacts beside it.
    @discardableResult
    private static func convertAndStore(
        _ published: Data, for source: FilterListSource
    ) async -> (Data, Set<String>)? {
        let outcome = await Task.detached(priority: .utility) { () -> (Data, Set<String>, Int, Int)? in
            guard let text = String(data: published, encoding: .utf8) else { return nil }
            let result = FilterConverter.convert(text)
            guard result.converted >= source.minimumRuleCount,
                  let json = ContentRuleJSON.list(result.rules)
            else { return nil }
            return (Data(json.utf8), result.blockedDomains, result.converted, result.skipped)
        }.value

        guard let outcome else {
            debugLog("\(source.name): conversion produced nothing usable")
            return nil
        }

        debugLog("\(source.name): \(outcome.2) rules converted, \(outcome.3) skipped")

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try? outcome.0.write(to: rulesURL(source), options: .atomic)
        try? Data(outcome.1.sorted().joined(separator: "\n").utf8)
            .write(to: domainsURL(source), options: .atomic)

        return (outcome.0, outcome.1)
    }

    private static func loadUserRules() -> UserBlockRules {
        guard let data = try? Data(contentsOf: userRulesURL),
              let rules = try? JSONDecoder().decode(UserBlockRules.self, from: data)
        else { return UserBlockRules() }
        return rules
    }

    private func saveUserRules() {
        try? FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(userRules) else { return }
        try? data.write(to: Self.userRulesURL, options: .atomic)
    }

    // MARK: - Preparing

    /// Called at launch. Compiles what's on disk, then checks for a newer list
    /// if one is due — in that order, so a slow network never delays blocking
    /// on the first page.
    func prepare() {
        Task { @MainActor in
            await primeFromCache()
            await compile()
            // After compiling, not before: `compile` is what rebuilds the
            // current version's artifacts, and sweeping first would delete the
            // old ones while the new ones don't exist yet.
            let folder = Self.directory
            Task.detached(priority: .background) {
                Self.discardStaleConversions(in: folder)
            }
            await updateIfDue()
        }
    }

    /// Puts last launch's compiled lists into force before anything is read or
    /// parsed.
    ///
    /// Compiling is the slow part, and so is everything that leads to it —
    /// reading nine megabytes, hashing it, decoding it for the domain index.
    /// None of that is needed to *block*: WebKit already holds the compiled
    /// result from last time, and the identifier it's filed under is a value
    /// small enough to remember. So blocking is live within a few milliseconds
    /// of launch, and the full pass behind it only confirms what's already in
    /// place — or replaces it, if the list changed underneath.
    ///
    /// It has to be this quick because a page that starts loading before the
    /// rules arrive is a page whose ads were already requested, and the first
    /// wave is the one they're in.
    private func primeFromCache() async {
        let identifiers = Self.cachedIdentifiers
        guard !identifiers.isEmpty, let store = WKContentRuleListStore.default() else { return }

        var primed: [WKContentRuleList] = []
        for identifier in identifiers {
            // All or nothing. Half a rule set is a blocker that looks like it's
            // working and isn't.
            guard let list = try? await store.contentRuleList(forIdentifier: identifier)
            else { return }
            primed.append(list)
        }

        lists = primed
        NotificationCenter.default.post(name: .surfBlockingChanged, object: nil)
        debugLog("rules primed from cache — \(primed.count) lists")
    }

    /// What `primeFromCache` reads. Written only after a compile has actually
    /// produced these lists, so an identifier here is one the store has.
    private static var cachedIdentifiers: [String] {
        get { UserDefaults.standard.stringArray(forKey: "blockListIdentifiers") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "blockListIdentifiers") }
    }

    /// Rebuilds the compiled lists and republishes them.
    ///
    /// One list per source plus one of the user's own, and the split is about
    /// how long a compile takes. EasyList is around a hundred thousand rules
    /// and compiling it costs seconds; the user's own rules are a handful and
    /// compile instantly. If they shared a list, clicking Block in the panel
    /// would mean recompiling EasyList to add one line, and the button would
    /// feel broken.
    ///
    /// A paused site is not in here at all. WebKit's spelling of one is an
    /// `ignore-previous-rules` inside each list — a recompile of EasyList per
    /// flip, and a list that un-blocks the site for as long as it carries the
    /// rule, which made *resuming* wait on the compile too. The pause is
    /// applied per tab instead, in `apply(to:host:)`.
    private func compile() async {
        let previous = compileChain
        queuedCompiles += 1
        let task = Task { @MainActor in
            await previous?.value
            queuedCompiles -= 1
            // A compile with another queued behind it would build a rule set
            // the next one is about to replace; the last one reads the rules
            // as they stand and does all of them at once.
            guard queuedCompiles == 0 else { return }
            await compileNow()
        }
        compileChain = task
        await task.value
    }

    /// Compiles waiting behind the one in flight. Only the last of them runs.
    private var queuedCompiles = 0

    private func compileNow() async {
        isPreparing = true
        defer { isPreparing = false }

        let rules = userRules

        var compiled: [WKContentRuleList] = []
        var identifiers: [String] = []
        var listed: Set<String> = []

        // One compiled list per source. Separately, because WebKit caps a single
        // list's size and because a list that fails to convert should cost its
        // own rules rather than the other's.
        for source in FilterList.sources {
            guard let (rules, domains) = await Self.converted(source) else { continue }

            let prepared = await Task.detached(priority: .utility) {
                (
                    json: String(data: rules, encoding: .utf8),
                    identifier: "surf-\(source.id)-" + Self.digest(rules)
                )
            }.value

            listed.formUnion(domains)

            guard let json = prepared.json,
                  let list = await Self.ruleList(identifier: prepared.identifier, json: json)
            else { continue }

            compiled.append(list)
            identifiers.append(prepared.identifier)
        }

        // No source list at all — nothing on disk and nothing bundled — is
        // the one outcome that must not be published. The lists in force may
        // have been primed from the store a moment ago, and replacing them
        // with nothing would also sweep that store, so the next launch pays
        // a cold compile for a list that was never wrong. The update that
        // follows is what fills an empty directory; until it does, what was
        // blocking keeps blocking.
        guard !compiled.isEmpty || lists.isEmpty else {
            debugLog("no filter list converted — keeping the \(lists.count) in force")
            return
        }

        classifier.listedDomains = listed
        blockedDomainCount = listed.count + rules.blockedDomains.count

        let userRuleJSON = ContentRuleJSON.list(
            ContentRuleJSON.blockRules(for: rules.blockedDomains)
        )
        if let userRuleJSON {
            let identifier = "surf-user-" + Self.digest(Data(userRuleJSON.utf8))
            if let list = await Self.ruleList(identifier: identifier, json: userRuleJSON) {
                compiled.append(list)
                identifiers.append(identifier)
            }
        }

        classifier.userBlockedDomains = rules.blockedDomains
        lists = compiled
        Self.cachedIdentifiers = identifiers
        debugLog("""
        rules ready — \(compiled.count) lists, \
        \(classifier.listedDomains.count) blocked domains
        """)
        await Self.discardStaleLists(keeping: Set(identifiers))
        NotificationCenter.default.post(name: .surfBlockingChanged, object: nil)
    }

    /// A compiled list, from the store's cache when it has one.
    ///
    /// The identifier is a hash of the rules themselves, so a cache hit is proof
    /// the compiled copy was built from exactly these rules — and a list that
    /// hasn't changed since last launch is never compiled twice.
    private static func ruleList(identifier: String, json: String) async -> WKContentRuleList? {
        // Nil only when WebKit can't open its own store — a sandbox with no
        // writable container. There is nothing to fall back to, and nothing to
        // report: blocking is simply unavailable.
        guard let store = WKContentRuleListStore.default() else { return nil }
        if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
            return cached
        }
        do {
            return try await store.compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: json
            )
        } catch {
            // A list that won't compile is a list we don't install. The previous
            // one stays in force, which is the same posture the helper updates
            // take: never trade something working for something unverified.
            debugLog("rule list \(identifier) failed to compile — \(error.localizedDescription)")
            return nil
        }
    }

    /// Removes compiled lists left behind by earlier rule sets. Each is a file
    /// in WebKit's store, and without this every list update and every click on
    /// Block would leave one there forever.
    private static func discardStaleLists(keeping current: Set<String>) async {
        guard let store = WKContentRuleListStore.default(),
              let existing = await store.availableIdentifiers()
        else { return }
        for identifier in existing
        where identifier.hasPrefix("surf-") && !current.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }

    nonisolated private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Applying

    /// Whether a page on `host` is blocked at all: the setting is on and the
    /// site isn't paused. Nil is a view with no page yet, which is blocked —
    /// the host is re-read the moment it navigates.
    func isActive(for host: String?) -> Bool {
        Self.isEnabled && !isPaused(on: host)
    }

    /// Hands the compiled rules to a web view's configuration — or takes them
    /// away, when the page is on a paused site.
    ///
    /// Called when a tab builds its view, whenever the rules change, and on
    /// every main-frame navigation, so a tab opened before the list finished
    /// compiling isn't left unprotected and a tab leaving a paused site is
    /// blocked again from its first request on.
    ///
    /// The per-site pause happens here, per tab, rather than in the compiled
    /// rules — WebKit's own spelling of a pause is an `ignore-previous-rules`
    /// *inside* each list, which is a recompile of EasyList, and a switch that
    /// takes a minute to act is a switch that looks broken. Stripping a tab's
    /// lists takes effect on its next request.
    func apply(to configuration: WKWebViewConfiguration, host: String?) {
        let controller = configuration.userContentController
        controller.removeAllContentRuleLists()
        guard isActive(for: host) else { return }
        for list in lists { controller.add(list) }
    }

    // MARK: - The user's two decisions

    func block(domain: String) {
        userRules.block(domain)
        saveUserRules()
        Task { await compile() }
    }

    func unblock(domain: String) {
        userRules.unblock(domain)
        saveUserRules()
        Task { await compile() }
    }

    func isUserBlocked(domain: String) -> Bool {
        userRules.isBlocked(host: domain)
    }

    func isPaused(on host: String?) -> Bool {
        guard let host else { return false }
        return userRules.isPaused(site: host)
    }

    /// In force immediately, and nothing compiles: every open tab re-reads
    /// the paused set against its own page and strips or restores its lists
    /// on the spot. Saved first, so it survives relaunch.
    ///
    /// The one thing a per-tab strip can't express: a window a page opened
    /// shares its opener's `WKUserContentController`, so when the two sit on
    /// different sites, one paused and one not, the pair follow whichever of
    /// them decided last. A rule that checked the top URL itself would tell
    /// them apart — at the price of the compile above, on every flip.
    func setPaused(_ isPaused: Bool, on host: String) {
        userRules.setPaused(isPaused, forSite: host)
        saveUserRules()
        NotificationCenter.default.post(
            name: .surfBlockingChanged, object: nil,
            userInfo: [Self.enabledChangedKey: true]
        )
    }

    /// The setting was toggled. Nothing recompiles — the lists are still valid —
    /// but every tab has to be told to add or drop them, and told that this
    /// was the switch rather than a list update: a switch is what empties the
    /// shield and reloads the page you're looking at, because a count
    /// gathered under the old rules is a claim about a page that no longer
    /// exists.
    func enabledDidChange() {
        NotificationCenter.default.post(
            name: .surfBlockingChanged, object: nil,
            userInfo: [Self.enabledChangedKey: true]
        )
    }

    /// Present in `surfBlockingChanged`'s `userInfo` when the user flipped a
    /// switch — the setting, or a site's pause — and absent when only the
    /// rules moved underneath it. A flip is what a tab reloads for.
    static let enabledChangedKey = "enabledChanged"

    // MARK: - Updating

    private var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: PreferenceKeys.lastFilterListCheck) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKeys.lastFilterListCheck) }
    }

    /// Weekly, and immediately when there is no list at all — a first launch
    /// from `swift run` has no bundled copy to fall back on, and waiting a week
    /// to start blocking would look like the feature doesn't work.
    private func updateIfDue() async {
        let hasList = FilterList.sources.contains { Self.publishedList($0) != nil }
        guard !hasList || UpdateSchedule.isDue(lastCheck: lastCheck, now: Date()) else { return }
        await update()
    }

    func update() async {
        // Stamped before the work: a publisher that's down shouldn't buy a
        // network round trip on every launch from then on.
        lastCheck = Date()

        var installedAny = false
        for source in FilterList.sources where await install(source) {
            installedAny = true
        }
        if installedAny { await compile() }
    }

    /// Fetches one list and installs it only if it converts to something real.
    ///
    /// There is no published checksum, so what stands in for one is what the
    /// payload has to be: filter syntax that converts to tens of thousands of
    /// rules. That catches the failure that actually happens — a captive portal
    /// or an error page arriving with a 200 — and it is the same principle as
    /// the checksums elsewhere, which is that nothing is installed on the
    /// strength of having downloaded.
    private func install(_ source: FilterListSource) async -> Bool {
        guard let data = await fetch(source.url) else { return false }

        do {
            try FileManager.default.createDirectory(
                at: Self.directory, withIntermediateDirectories: true
            )
        } catch {
            return false
        }

        // Converted before it is installed, not after: a payload that produces
        // nothing usable must not replace the list currently working.
        guard await Self.convertAndStore(data, for: source) != nil else { return false }

        try? data.write(to: Self.sourceURL(source), options: .atomic)
        debugLog("\(source.name) installed")
        return true
    }

    private func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return data
    }
}

extension WKContentRuleListStore {
    /// The async spelling the SDK doesn't provide for this one call.
    func availableIdentifiers() async -> [String]? {
        await withCheckedContinuation { continuation in
            getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0) }
        }
    }
}

extension Notification.Name {
    /// Rules changed, or the setting did. Every tab listens.
    static let surfBlockingChanged = Notification.Name("surfBlockingChanged")
}
