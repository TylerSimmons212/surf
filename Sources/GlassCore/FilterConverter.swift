import Foundation

/// Adblock Plus filter syntax, translated into WebKit's content-blocker rules.
///
/// This is the piece that was previously borrowed. EasyList's publisher builds a
/// converted copy of *that one list*, and taking it meant Glass could never
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
/// honest measure of how much of a list Glass isn't carrying.
public enum FilterConverter {

    /// What a list came out as.
    public struct Result: Sendable, Equatable {
        /// Rule objects, already encoded, in the order WebKit must see them.
        public var rules: [String]
        /// The same list with the element-hiding rules left out.
        ///
        /// Hiding an ad container is the one thing a blocker does that a page
        /// can see from the inside: it puts an element on the page, measures it,
        /// and knows. Some players do exactly that and stop playing when the
        /// measurement comes back wrong — so this variant exists to keep
        /// refusing the requests while giving them nothing to measure.
        public var networkOnlyRules: [String]
        /// Domains blocked outright, for naming what the panel caught.
        public var blockedDomains: Set<String>
        public var converted: Int
        public var skipped: Int

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

    /// `subdocument` means a nested document — an iframe — and WebKit has no
    /// type for one. Its only near-neighbour is `document`, which also covers
    /// the page the user typed the address of, so translating a *block* rule
    /// that way would hand an ad list the power to refuse a top-level
    /// navigation. Those rules are dropped, and the cost is an ad iframe
    /// getting through.
    ///
    /// An *exception* carrying it is kept and does become `document`, because
    /// the asymmetry runs the other way there: a broader exception un-blocks
    /// more than the list asked for, where a dropped one would leave a request
    /// refused that the list said to allow.
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

    public static func convert(_ text: String) -> Result {
        var blocks: [String] = []
        var cosmetics: [String] = []
        var exceptions: [String] = []
        var domains: Set<String> = []
        var skipped = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let filter = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if filter.isEmpty || filter.hasPrefix("!") || filter.hasPrefix("[Adblock") {
                continue
            }

            switch parse(filter) {
            case .block(let rule, let domain):
                blocks.append(rule)
                if let domain { domains.insert(domain) }
            case .cosmetic(let rule):
                cosmetics.append(rule)
            case .exception(let rule):
                exceptions.append(rule)
            case .ignored:
                continue
            case .unsupported:
                skipped += 1
            }
        }

        // Exceptions last, and this is not cosmetic ordering: WebKit applies
        // rules in the order given, and `ignore-previous-rules` cancels only
        // what came *before* it. An exception emitted above the block it exists
        // to override does nothing at all.
        return Result(
            rules: blocks + cosmetics + exceptions,
            networkOnlyRules: blocks + exceptions,
            blockedDomains: domains,
            converted: blocks.count + cosmetics.count + exceptions.count,
            skipped: skipped
        )
    }

    enum Parsed {
        /// A rule, and the domain it blocks outright if it blocks one.
        case block(String, domain: String?)
        /// An element-hiding rule, kept apart because it is the half a page can
        /// detect.
        case cosmetic(String)
        case exception(String)
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

        guard let encoded = encode(
            trigger: trigger,
            action: Action(type: isException ? "ignore-previous-rules" : "block")
        ) else { return .unsupported }

        if isException { return .exception(encoded) }

        // Only a rule that blocks a whole domain names one. A rule against a
        // path on a shared host names a domain that isn't blocked.
        let blocksWholeDomain = translated.isWholeDomain
            && options.ifDomain == nil
            && options.loadType == nil
        return .block(encoded, domain: blocksWholeDomain ? translated.host : nil)
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

        /// Returns nil when the rule carries an option WebKit has no answer for.
        ///
        /// `isException` is not a detail: the same option can be convertible on
        /// an exception and not on a block, because the two fail in opposite
        /// directions.
        init?(_ text: String, isException: Bool = false) {
            guard !text.isEmpty else {
                resourceTypes = FilterConverter.defaultResourceTypes
                return
            }

            var included: [String] = []
            var excluded: Set<String> = []
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
                    // Convertible only on an exception. See the note there.
                    guard isException else { return nil }
                    sawTypeOption = true
                    if isNegated { excluded.insert("document") } else { included.append("document") }
                default:
                    guard let type = FilterConverter.resourceTypeNames[name] else { return nil }
                    sawTypeOption = true
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
            } else if !included.isEmpty {
                resourceTypes = orderedTypes(included)
            } else {
                let remaining = FilterConverter.defaultResourceTypes.filter { !excluded.contains($0) }
                guard !remaining.isEmpty else { return nil }
                resourceTypes = remaining
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
        return .cosmetic(encoded)
    }

    // MARK: - Encoding

    struct Trigger: Encodable {
        var urlFilter: String
        var urlFilterIsCaseSensitive: Bool?
        var resourceType: [String]?
        var loadType: [String]?
        var ifDomain: [String]?
        var unlessDomain: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case resourceType = "resource-type"
            case loadType = "load-type"
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
