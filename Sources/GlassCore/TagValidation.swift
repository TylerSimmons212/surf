import Foundation

/// What's wrong with the tags on this page.
///
/// The reason this exists rather than leaving you to read the Network pane:
/// the common tag bugs are specific, silent, and expensive. A `Purchase` that
/// fires twice inflates reported revenue and trains the ad platform's bidding
/// on numbers that never happened. Nothing on the page goes wrong when it
/// does — which is exactly why it survives to production.
public enum TagValidation {

    /// Events counted as the same fire when they land close together.
    private static let duplicateWindow: Double = 3000

    /// Parameters each platform needs for the events people most often get
    /// wrong. Deliberately not a complete schema per vendor — only the ones
    /// where the absence is a real reporting bug rather than a style choice.
    private static let required: [String: [String: [String]]] = [
        "meta": [
            "Purchase": ["value", "currency"],
            "AddToCart": ["content_ids"],
            "InitiateCheckout": ["value", "currency"],
        ],
        "ga4": [
            "purchase": ["value", "currency", "transaction_id"],
            "add_to_cart": ["value", "currency"],
            "begin_checkout": ["value", "currency"],
        ],
        "tiktok": [
            "CompletePayment": ["value", "currency"],
        ],
        "pinterest": [
            "checkout": ["value", "currency"],
        ],
    ]

    public static func findings(
        events: [TagEvent],
        detected: [DetectedTag],
        hasConsentManager: Bool,
        consentSignalAt: Double?
    ) -> [TagFinding] {
        var findings: [TagFinding] = []
        findings.append(contentsOf: duplicates(in: events))
        findings.append(contentsOf: missingParameters(in: events))
        findings.append(contentsOf: multipleAccounts(in: detected))
        findings.append(contentsOf: silentTags(in: detected))
        if hasConsentManager {
            findings.append(contentsOf: consentOrder(events, consentAt: consentSignalAt))
        }
        return findings
    }

    /// The same event twice in quick succession.
    ///
    /// Nearly always a tag manager and a hardcoded snippet both firing, and
    /// nearly always invisible until someone reconciles revenue at the end of
    /// the month.
    static func duplicates(in events: [TagEvent]) -> [TagFinding] {
        var findings: [TagFinding] = []
        let ordered = events.sorted { $0.at < $1.at }

        for (index, event) in ordered.enumerated() {
            for other in ordered[(index + 1)...] {
                guard other.at - event.at <= duplicateWindow else { break }
                guard other.vendorId == event.vendorId,
                      other.name == event.name,
                      other.accountId == event.accountId
                else { continue }
                // Same value too, where there is one: two genuinely different
                // purchases in three seconds is unusual but not a bug.
                let sameValue = other.parameters["value"] == event.parameters["value"]
                guard sameValue else { continue }

                findings.append(TagFinding(
                    id: "duplicate.\(event.id).\(other.id)",
                    severity: .error,
                    title: "\(event.name) fired twice",
                    detail: "\(event.vendorName) sent \(event.name) to \(event.accountId) "
                        + "twice within \(Int(other.at - event.at)) ms — usually a tag manager "
                        + "and a hardcoded snippet both firing.",
                    vendorName: event.vendorName
                ))
                break
            }
        }
        return findings
    }

    static func missingParameters(in events: [TagEvent]) -> [TagFinding] {
        events.compactMap { event in
            guard let forVendor = required[event.vendorId],
                  let needed = forVendor[event.name]
            else { return nil }
            let missing = needed.filter { (event.parameters[$0] ?? "").isEmpty }
            guard !missing.isEmpty else { return nil }

            return TagFinding(
                id: "missing.\(event.id)",
                severity: .warning,
                title: "\(event.name) is missing \(missing.joined(separator: ", "))",
                detail: "\(event.vendorName) needs \(missing.joined(separator: " and ")) on "
                    + "\(event.name) for reporting and optimisation to work.",
                vendorName: event.vendorName
            )
        }
    }

    /// Two account ids for one vendor — the signature of a half-finished tag
    /// migration, and it usually means events are being split across two
    /// properties with neither telling the whole story.
    static func multipleAccounts(in detected: [DetectedTag]) -> [TagFinding] {
        detected.compactMap { tag in
            let ids = tag.accountIds.filter { !$0.isEmpty }
            guard ids.count > 1 else { return nil }
            return TagFinding(
                id: "accounts.\(tag.vendorId)",
                severity: .warning,
                title: "\(tag.name) has \(ids.count) account ids",
                detail: "Firing to \(ids.joined(separator: ", ")) — usually a migration that "
                    + "never finished, splitting data across properties.",
                vendorName: tag.name
            )
        }
    }

    /// Installed but never fired. Sometimes deliberate; more often a tag that
    /// loaded and then threw, which looks identical to working from the outside.
    static func silentTags(in detected: [DetectedTag]) -> [TagFinding] {
        detected.compactMap { tag in
            guard tag.isSilent, tag.category != .consent, tag.category != .tagManager
            else { return nil }
            return TagFinding(
                id: "silent.\(tag.vendorId)",
                severity: .info,
                title: "\(tag.name) is installed but hasn't fired",
                detail: "Found on the page — \(tag.evidence.joined(separator: ", ")) — "
                    + "but no events were seen.",
                vendorName: tag.name
            )
        }
    }

    /// Marketing tags that fired before any consent signal appeared.
    ///
    /// Reported as an observation about ordering, never as a compliance
    /// verdict: whether that ordering is *allowed* depends on jurisdiction,
    /// the category of the tag and what the visitor actually chose, none of
    /// which a browser can see. Naming the sequence is useful; ruling on it
    /// would be pretending to knowledge this doesn't have.
    static func consentOrder(_ events: [TagEvent], consentAt: Double?) -> [TagFinding] {
        let marketing = events.filter { $0.category == .advertising }
        let early = marketing.filter { event in
            guard let consentAt else { return true }
            return event.at < consentAt
        }
        guard !early.isEmpty else { return [] }

        let vendors = Set(early.map(\.vendorName)).sorted()
        return [TagFinding(
            id: "consent.order",
            severity: .warning,
            title: "\(early.count) advertising events fired before a consent signal",
            detail: "\(vendors.joined(separator: ", ")) fired "
                + (consentAt == nil
                    ? "with no consent signal recorded on this page."
                    : "before consent was recorded.")
                + " Whether that's permitted depends on your jurisdiction and setup.",
            vendorName: ""
        )]
    }
}
