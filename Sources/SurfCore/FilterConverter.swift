import Foundation

/// Adblock Plus filter syntax, translated into WebKit's content-blocker rules.
///
/// This is the piece that was previously borrowed. EasyList's publisher builds a
/// converted copy of *that one list*, and taking it meant Surf could never
/// carry a list they don't convert — EasyPrivacy, which is where the trackers
/// are, is published in filter syntax only. It also meant inheriting their
/// conversion's limits: their rules are host-exact, so `||adnxs.com^` came out
/// matching `adnxs.com` and not `ib.adnxs.com`, which is the host the ads
/// actually come from.
///
/// The two syntaxes don't fully meet, and the gap is handled in one direction
/// only. A **block** rule that can't be expressed is dropped: the cost is one
/// ad getting through, which is the state the browser was in a moment ago. An
/// **exception** that can't be expressed is the dangerous one, because dropping
/// it leaves a site blocked that the list says shouldn't be — so an exception is
/// only ever dropped when its effect is limited to cosmetic filtering, and never
/// when it would leave a request refused.
///
/// Everything unrecognised is counted rather than guessed at. `skipped` is the
/// honest measure of how much of a list Surf isn't carrying.
public enum FilterConverter {

    /// What a list came out as.
    /// Bumped whenever conversion starts producing different rules from the
    /// same filter text.
    ///
    /// Converted lists are cached on disk and reused for as long as the
    /// published list itself is unchanged, which is up to a week. Without a
    /// stamp the cache has no way to know the *converter* moved, so a change
    /// like frame blocking would land in the binary and simply not happen —
    /// silently, and for exactly the people who already had the app.
    public static let formatVersion = 2

    public struct Result: Sendable, Equatable {
        /// Rule objects, already encoded, in the order WebKit must see them.
        public var rules: [String]
        /// Domains blocked outright, for naming what the panel caught.
        public var blockedDomains: Set<String>
        public var converted: Int
        public var skipped: Int
        /// How many of `rules` are the child-frame companions described in
        /// `frameRule(for:)`, and how many had to be left out to stay under
        /// WebKit's ceiling. Both are reported rather than inferred so the
        /// panel — and the tests — can tell a list that didn't need them from
        /// one that couldn't afford them.
        public var frameRules: Int = 0
        public var droppedFrameRules: Int = 0

        public var isEmpty: Bool { rules.isEmpty }
    }

    // MARK: - Resource types

    /// What a rule applies to when it doesn't say.
    ///
    /// Everything except a top-level document and a popup, which is Adblock
    /// Plus's own default and matters more than it looks: a rule that applied to
    /// documents would let a list block a page the user typed the address of,
    /// turning an ad filter into a site blocker.
    static let defaultResourceTypes = [
        "image", "style-sheet", "script", "font", "media", "raw", "svg-document",
    ]

    static let resourceTypeNames: [String: String] = [
        "script": "script",
        "image": "image",
        "stylesheet": "style-sheet",
        "css": "style-sheet",
        "font": "font",
        "media": "media",
        "object": "raw",
        "object-subrequest": "raw",
        "xmlhttprequest": "raw",
        "xhr": "raw",
        "websocket": "raw",
        "ping": "raw",
        "beacon": "raw",
        "other": "raw",
        "document": "document",
        "popup": "popup",
    ]

    /// What a frame-blocking companion rule applies to.
    ///
    /// `subdocument` means a nested document — an iframe — and WebKit has no
    /// type of its own for one. Its near-neighbour `document` covers the page
    /// the user typed the address of as well, so for a long time these rules
    /// were dropped outright rather than risk handing an ad list the power to
    /// refuse a top-level navigation. That caution was right: a rule carrying
    /// only `resource-type: ["document"]` does block the address bar, which is
    /// verifiable in about twenty lines against a real `WKWebView`.
    ///
    /// `load-context` is the missing piece. Pinned to `child-frame`, the same
    /// rule blocks the iframe and leaves a top-level navigation to the very
    /// same URL alone. WebKit validates the key — an unrecognised value fails
    /// the compile rather than being ignored — so this is a real guarantee and
    /// not a hopeful one.
    ///
    /// It has to be a *separate* rule rather than another entry in an existing
    /// trigger's `resource-type`, because `load-context` narrows the whole
    /// trigger: adding `document` to a script rule and pinning it to child
    /// frames would stop that rule blocking scripts in the top frame. That is
    /// what makes frame blocking cost rules rather than characters, and why
    /// `convert` gives itself a budget.
    static let frameResourceTypes = ["document"]
    static let frameLoadContext = ["child-frame"]

    static let nestedDocumentOption = "subdocument"

    /// Options that change what a rule *does* rather than what it matches, in
    /// ways WebKit has no equivalent for. A rule carrying one is not converted.
    static let unsupportedOptions: Set<String> = [
        "csp", "redirect", "redirect-rule", "rewrite", "replace", "removeparam",
        "important", "badfilter", "method", "denyallow", "header", "to", "from",
        "app", "empty", "mp4", "inline-script", "inline-font", "genericblock",
        "cookie", "stealth", "network", "permissions", "referrerpolicy",
    ]

    /// Exception-only options whose whole effect is on cosmetic filtering.
    /// Dropping one of these can leave an element hidden that a site wanted
    /// shown; it can never leave a request blocked.
    static let cosmeticOnlyOptions: Set<String> = [
        "generichide", "elemhide", "specifichide", "ehide", "ghide",
    ]

    /// Adblock Plus's separator: anything that isn't part of a name.
    static let separator = "[^a-z0-9_.%-]"

    /// A separator and whatever follows, or the end of the URL. What `^` means
    /// at the end of a pattern, and the reason `||example.com^` doesn't match
    /// `example.community`.
    static let boundary = "([^a-z0-9_.%-].*)?$"

    // MARK: - Converting

    /// Converts a list, keeping frame rules only while there is room for them.
    ///
    /// `limit` exists because the child-frame companions roughly double a
    /// list's rule count, and WebKit refuses a list over its ceiling outright —
    /// the failure mode is not "fewer rules" but "no blocking at all". EasyList
    /// fits today with room to spare, and lists only grow, so the budget is
    /// enforced here rather than discovered later by a compile that fails on
    /// somebody's machine and not on mine.
    ///
    /// Companions are what gets dropped, and they're dropped from the end, so
    /// an over-budget list degrades to exactly the blocking it had before this
    /// existed rather than to something arbitrary.
    public static func convert(
        _ text: String, limit: Int = FilterList.maximumRuleCount
    ) -> Result {
        var blocks: [String] = []
        var frames: [String] = []
        var exceptions: [String] = []
        var frameExceptions: [String] = []
        var domains: Set<String> = []
        var skipped = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let filter = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if filter.isEmpty || filter.hasPrefix("!") || filter.hasPrefix("[Adblock") {
                continue
            }

            switch parse(filter) {
            case .block(let rule, let frame, let domain):
                if let rule { blocks.append(rule) }
                if let frame { frames.append(frame) }
                if let domain { domains.insert(domain) }
            case .exception(let rule, let frame):
                if let rule { exceptions.append(rule) }
                if let frame { frameExceptions.append(frame) }
            case .ignored:
                continue
            case .unsupported:
                skipped += 1
            }
        }

        // An exception has to survive its own block, so the two are budgeted
        // together: dropping a frame block while keeping the frame exception
        // that allows it is harmless, but the reverse would leave a site
        // allowlisted for subresources and blocked for its frames.
        let fixed = blocks.count + exceptions.count
        let room = max(0, limit - fixed)
        let requested = frames.count + frameExceptions.count
        var dropped = 0

        if requested > room {
            // Exceptions are kept ahead of blocks: an over-broad allow is the
            // safe direction, an over-broad block is not.
            let blockRoom = max(0, room - frameExceptions.count)
            dropped = frames.count - min(frames.count, blockRoom)
            frames = Array(frames.prefix(blockRoom))
            if frameExceptions.count > room {
                dropped += frameExceptions.count - room
                frameExceptions = Array(frameExceptions.prefix(room))
            }
        }

        // Exceptions last, and this is not cosmetic ordering: WebKit applies
        // rules in the order given, and `ignore-previous-rules` cancels only
        // what came *before* it. An exception emitted above the block it exists
        // to override does nothing at all.
        let rules = blocks + frames + exceptions + frameExceptions
        return Result(
            rules: rules,
            blockedDomains: domains,
            converted: rules.count,
            skipped: skipped,
            frameRules: frames.count + frameExceptions.count,
            droppedFrameRules: dropped
        )
    }

    enum Parsed {
        /// A rule, the child-frame companion it needs (if any), and the domain
        /// it blocks outright if it blocks one. The main rule is nil for a
        /// filter that named `$subdocument` and nothing else — that rule is
        /// entirely about frames.
        case block(String?, frame: String?, domain: String?)
        case exception(String?, frame: String?)
        /// Deliberately not carried, and not counted against the list.
        case ignored
        case unsupported
    }

    static func parse(_ filter: String) -> Parsed {
        // Cosmetic markers are checked before anything else, because a filter
        // carrying one is not a URL pattern and reading it as one would produce
        // a rule matching something nobody wrote.
        if filter.contains("#@#") {
            // An un-hiding rule. WebKit can't cancel element hiding separately
            // from blocking, and an exception broad enough to do it would
            // unblock the site's requests too. Dropped, which can leave
            // something hidden and can never leave something blocked.
            return .ignored
        }
        for marker in ["#?#", "#$#", "#%#"] where filter.contains(marker) {
            // Procedural filters: selectors with logic in them, for an engine
            // WebKit doesn't have.
            return .unsupported
        }
        if let separator = filter.range(of: "##") {
            return cosmeticRule(filter, at: separator)
        }
        return networkRule(filter)
    }

    // MARK: - Network rules

    static func networkRule(_ filter: String) -> Parsed {
        var pattern = filter
        var isException = false

        if pattern.hasPrefix("@@") {
            isException = true
            pattern = String(pattern.dropFirst(2))
        }

        // Options are after the last `$` that isn't inside a regex literal. A
        // literal is dropped whole below, so splitting on the first is safe.
        var optionText = ""
        if let dollar = pattern.firstIndex(of: "$") {
            optionText = String(pattern[pattern.index(after: dollar)...])
            pattern = String(pattern[pattern.startIndex..<dollar])
        }

        guard !pattern.isEmpty else { return .unsupported }

        // A regex literal is handed to a different engine than the one that
        // wrote it. WebKit's is a subset, a rule it rejects fails the whole
        // list's compile, and there are a few dozen of these in a list of a
        // hundred thousand.
        if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count > 2 {
            return .unsupported
        }

        guard var options = Options(optionText, isException: isException)
        else { return .unsupported }
        if options.isCosmeticOnly {
            // Its entire effect is on element hiding, which WebKit can't scope
            // separately. Dropping it can leave something hidden; it cannot
            // leave anything blocked.
            return .ignored
        }

        guard let translated = urlFilter(for: pattern) else { return .unsupported }
        if !options.isCaseSensitive { options.lowercaseFilter = true }

        let filterText = options.lowercaseFilter ? translated.regex.lowercased() : translated.regex

        var trigger = Trigger(urlFilter: filterText)
        trigger.urlFilterIsCaseSensitive = options.isCaseSensitive ? true : nil
        trigger.resourceType = options.resourceTypes
        trigger.loadType = options.loadType
        trigger.ifDomain = options.ifDomain
        trigger.unlessDomain = options.unlessDomain

        let action = Action(type: isException ? "ignore-previous-rules" : "block")

        var encoded: String?
        if !options.isFrameOnly {
            guard let main = encode(trigger: trigger, action: action) else { return .unsupported }
            encoded = main
        }

        var frame: String?
        if options.reachesFrames || options.isFrameOnly {
            var frameTrigger = trigger
            frameTrigger.resourceType = frameResourceTypes
            frameTrigger.loadContext = frameLoadContext
            // A rule that produced nothing at all is worse than one that only
            // covers subresources, so a failed companion is dropped quietly
            // rather than taking the main rule down with it.
            frame = encode(trigger: frameTrigger, action: action)
        }

        guard encoded != nil || frame != nil else { return .unsupported }

        if isException { return .exception(encoded, frame: frame) }

        // Only a rule that blocks a whole domain names one. A rule against a
        // path on a shared host names a domain that isn't blocked.
        let blocksWholeDomain = translated.isWholeDomain
            && options.ifDomain == nil
            && options.loadType == nil
        return .block(encoded, frame: frame, domain: blocksWholeDomain ? translated.host : nil)
    }

    // MARK: - Patterns

    struct TranslatedPattern {
        var regex: String
        /// The host the rule is anchored to, when it is anchored to one.
        var host: String?
        /// Whether it blocks that host entirely rather than a path on it.
        var isWholeDomain: Bool
    }

    static func urlFilter(for pattern: String) -> TranslatedPattern? {
        if pattern.hasPrefix("||") {
            return hostAnchored(String(pattern.dropFirst(2)))
        }

        var body = Substring(pattern)
        var regex = ""
        if body.hasPrefix("|") {
            body = body.dropFirst()
            regex += "^"
        }
        var anchorEnd = false
        if body.hasSuffix("|") {
            body = body.dropLast()
            anchorEnd = true
        }

        regex += escape(body)
        if anchorEnd { regex += "$" }
        guard !regex.isEmpty, regex != "^", regex != "$" else { return nil }
        return TranslatedPattern(regex: regex, host: nil, isWholeDomain: false)
    }

    /// `||host^tail` — the shape all but a handful of a list's rules take.
    ///
    /// `||` means "this host or any subdomain of it", which is exactly the
    /// subdomain group. Getting this one translation right is most of what the
    /// converter is for: it is the difference between blocking `adnxs.com` and
    /// blocking the `ib.adnxs.com` that serves the ad.
    static func hostAnchored(_ rest: String) -> TranslatedPattern? {
        var host = ""
        var index = rest.startIndex
        while index < rest.endIndex {
            let character = rest[index]
            guard character.isLetter || character.isNumber || character == "." || character == "-"
            else { break }
            host.append(character)
            index = rest.index(after: index)
        }

        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }

        var tail = Substring(rest[index...])
        var regex = "^https?://([^:/?#]*\\.)?" + escape(Substring(host))

        var anchorEnd = false
        if tail.hasSuffix("|") { tail = tail.dropLast(); anchorEnd = true }

        // A trailing separator is a boundary, not a character to match. Without
        // this, `||example.com^` would also match `example.community`.
        let endsAtBoundary = tail.isEmpty || tail.hasSuffix("^")
        if tail.hasSuffix("^") { tail = tail.dropLast() }

        regex += escape(tail)
        if endsAtBoundary && !anchorEnd { regex += boundary }
        if anchorEnd { regex += "$" }

        return TranslatedPattern(
            regex: regex,
            host: host,
            // Anything after the host narrows the rule to part of it.
            isWholeDomain: tail.isEmpty
        )
    }

    /// Adblock Plus's pattern language into a regex: `*` is any run, `^` is a
    /// separator, and everything else is a literal.
    static func escape(_ pattern: Substring) -> String {
        var out = ""
        for character in pattern {
            switch character {
            case "*": out += ".*"
            case "^": out += separator
            case ".", "$", "+", "?", "(", ")", "[", "]", "{", "}", "|", "\\", "/":
                out.append("\\")
                out.append(character)
            default:
                out.append(character)
            }
        }
        return out
    }

    // MARK: - Options

    struct Options {
        var resourceTypes: [String]?
        var loadType: [String]?
        var ifDomain: [String]?
        var unlessDomain: [String]?
        var isCaseSensitive = false
        var isCosmeticOnly = false
        var lowercaseFilter = false
        /// Whether this rule should also reach nested documents, which needs a
        /// companion rule of its own — see `frameResourceTypes`.
        var reachesFrames = false
        /// The rule named `$subdocument` and nothing else, so the companion is
        /// the *only* rule it should produce. Without this a bare
        /// `||ads.example^$subdocument` would fall through to the default types
        /// and start blocking scripts and images the filter never mentioned.
        var isFrameOnly = false

        /// Returns nil when the rule carries an option WebKit has no answer for.
        ///
        /// `isException` is not a detail: the same option can be convertible on
        /// an exception and not on a block, because the two fail in opposite
        /// directions.
        init?(_ text: String, isException: Bool = false) {
            guard !text.isEmpty else {
                resourceTypes = FilterConverter.defaultResourceTypes
                // Adblock Plus's default is every type, nested documents
                // included. That default is most of a list, and it's why an ad
                // iframe used to load even when its host was blocked outright.
                reachesFrames = true
                return
            }

            var included: [String] = []
            var excluded: Set<String> = []
            var namedFrames: Bool?
            var namedOtherTypes = false
            var ifDomains: [String] = []
            var unlessDomains: [String] = []
            var sawTypeOption = false

            for part in text.split(separator: ",") {
                var option = part.trimmingCharacters(in: .whitespaces)
                var isNegated = false
                if option.hasPrefix("~") {
                    isNegated = true
                    option = String(option.dropFirst())
                }

                let name = option.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                let value = option.contains("=")
                    ? String(option[option.index(after: option.firstIndex(of: "=")!)...])
                    : ""

                if FilterConverter.cosmeticOnlyOptions.contains(name) {
                    isCosmeticOnly = true
                    continue
                }
                if FilterConverter.unsupportedOptions.contains(name) { return nil }

                switch name {
                case "third-party", "3p":
                    loadType = isNegated ? ["first-party"] : ["third-party"]
                case "first-party", "1p":
                    loadType = isNegated ? ["third-party"] : ["first-party"]
                case "match-case":
                    isCaseSensitive = true
                case "domain":
                    for entry in value.split(separator: "|") {
                        let domain = entry.trimmingCharacters(in: .whitespaces).lowercased()
                        guard !domain.isEmpty else { continue }
                        if domain.hasPrefix("~") {
                            // `*` is WebKit's spelling of "and its subdomains",
                            // which is what a bare domain means here.
                            unlessDomains.append("*" + domain.dropFirst())
                        } else {
                            ifDomains.append("*" + domain)
                        }
                    }
                case FilterConverter.nestedDocumentOption:
                    // Never a resource type of its own: it becomes a separate
                    // child-frame rule instead. See `frameResourceTypes`.
                    sawTypeOption = true
                    namedFrames = !isNegated
                    if isException {
                        // An exception keeps its old, broader translation as
                        // well. Un-blocking more than asked is the safe
                        // direction; refusing something a list allowed is not.
                        if isNegated {
                            excluded.insert("document")
                        } else {
                            included.append("document")
                        }
                    }
                default:
                    guard let type = FilterConverter.resourceTypeNames[name] else { return nil }
                    sawTypeOption = true
                    namedOtherTypes = true
                    if isNegated { excluded.insert(type) } else { included.append(type) }
                }
            }

            // WebKit takes one list or the other, never both, and a rule that
            // wanted both would silently become the wrong rule.
            if !ifDomains.isEmpty && !unlessDomains.isEmpty { return nil }
            if !ifDomains.isEmpty { ifDomain = ifDomains }
            if !unlessDomains.isEmpty { unlessDomain = unlessDomains }

            if !sawTypeOption {
                resourceTypes = FilterConverter.defaultResourceTypes
                reachesFrames = true
            } else {
                // An exception that named its types has said what it means, and
                // its `document` translation already covers nested ones. Only a
                // *plain* exception needs a companion — and it does need one,
                // or an allowlist entry would stop protecting a site's frames
                // the moment blocks started reaching them.
                reachesFrames = isException ? false : (namedFrames ?? false)

                if !included.isEmpty {
                    resourceTypes = orderedTypes(included)
                } else if namedFrames == true, !namedOtherTypes, excluded.isEmpty {
                    resourceTypes = nil
                    isFrameOnly = true
                } else {
                    let remaining = FilterConverter.defaultResourceTypes
                        .filter { !excluded.contains($0) }
                    guard !remaining.isEmpty else { return nil }
                    resourceTypes = remaining
                }
            }
        }

        /// Deduplicated and in a fixed order, so the same rule always encodes to
        /// the same bytes — the compiled list is cached under a hash of them.
        private func orderedTypes(_ types: [String]) -> [String] {
            let unique = Set(types)
            let known = FilterConverter.defaultResourceTypes + ["document", "popup"]
            return known.filter { unique.contains($0) }
        }
    }

    // MARK: - Cosmetic rules

    static func cosmeticRule(_ filter: String, at separator: Range<String.Index>) -> Parsed {
        let scope = String(filter[filter.startIndex..<separator.lowerBound])
        let selector = String(filter[separator.upperBound...])
            .trimmingCharacters(in: .whitespaces)

        guard !selector.isEmpty else { return .unsupported }
        // Procedural pseudo-classes, which are a filter language rather than CSS.
        for marker in [":has(", ":has-text(", ":-abp-", ":matches-", ":contains(", ":xpath(", ":upward("]
        where selector.lowercased().contains(marker) {
            return .unsupported
        }

        var trigger = Trigger(urlFilter: ".*")
        if !scope.isEmpty {
            var ifDomains: [String] = []
            var unlessDomains: [String] = []
            for entry in scope.split(separator: ",") {
                let domain = entry.trimmingCharacters(in: .whitespaces).lowercased()
                guard !domain.isEmpty else { continue }
                if domain.hasPrefix("~") {
                    unlessDomains.append("*" + domain.dropFirst())
                } else {
                    ifDomains.append("*" + domain)
                }
            }
            if !ifDomains.isEmpty && !unlessDomains.isEmpty { return .unsupported }
            if !ifDomains.isEmpty { trigger.ifDomain = ifDomains }
            if !unlessDomains.isEmpty { trigger.unlessDomain = unlessDomains }
        }

        guard let encoded = encode(
            trigger: trigger,
            action: Action(type: "css-display-none", selector: selector)
        ) else { return .unsupported }
        // No frame companion: element hiding already applies inside whatever
        // document the rule matched, and a nested one gets its own pass.
        return .block(encoded, frame: nil, domain: nil)
    }

    // MARK: - Encoding

    struct Trigger: Encodable {
        var urlFilter: String
        var urlFilterIsCaseSensitive: Bool?
        var resourceType: [String]?
        var loadType: [String]?
        var loadContext: [String]?
        var ifDomain: [String]?
        var unlessDomain: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case loadContext = "load-context"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
        }
    }

    struct Action: Encodable {
        var type: String
        var selector: String?
    }

    private struct Rule: Encodable {
        var trigger: Trigger
        var action: Action
    }

    /// Encoded by `JSONEncoder` rather than by string building, because a CSS
    /// selector is arbitrary text and one unescaped quote in twenty thousand of
    /// them would fail the whole list's compile.
    static func encode(trigger: Trigger, action: Action) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Rule(trigger: trigger, action: action)),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }
}
