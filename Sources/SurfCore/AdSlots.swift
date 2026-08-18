import Foundation

/// What to do about the hole an ad leaves behind.
///
/// Blocking the request is only half of it. A page reserves the space before it
/// knows what will fill it — a banner slot is a container with a height and
/// nothing in it yet — so refusing the ad leaves the reservation standing, and
/// the reader gets a blank band where the ad was. Blocked but not gone.
///
/// The rule here is to stop *reserving* rather than to hide. An element told to
/// display nothing is a decision that can't be walked back if the site fills it
/// a second later; an element merely no longer holding a height open collapses
/// while it is empty and grows again if something real arrives. That difference
/// is why this is safe to apply on a heuristic at all.
public enum AdSlot {

    /// Below this, a reserved height isn't a hole worth closing — it's padding,
    /// a rule, a gap between sections.
    public static let reservedHeightFloor: Double = 50

    /// The words sites name ad containers with.
    ///
    /// Matched as whole tokens against an id or class, never as substrings: a
    /// class called `download` contains "ad" and names nothing of the sort. And
    /// a name alone never collapses anything — the element also has to be
    /// holding a height open with nothing inside it, which is the condition
    /// that actually means "this space is for something that isn't coming".
    public static let slotNames: Set<String> = [
        "ad", "ads", "adslot", "adslots", "adunit", "adbox", "adwrapper",
        "adcontainer", "adholder", "adspace", "adzone", "adbanner", "adlabel",
        "advert", "adverts", "advertisement", "advertising",
        "dfp", "dfpad", "gpt", "gptad", "googlead", "googleads", "doubleclick",
        "sponsored", "sponsorship", "leaderboard", "skyscraper",
        "taboola", "outbrain",
    ]

    /// Whether an element's id or class marks it as an ad container.
    public static func namesAnAdSlot(_ identifier: String) -> Bool {
        !tokens(in: identifier).isDisjoint(with: slotNames)
    }

    /// Splits on the separators used in ids and class names, and on camel case,
    /// so `adSlot`, `ad-slot`, `ad_slot`, and `ad slot` are all the same name.
    static func tokens(in identifier: String) -> Set<String> {
        var tokens: Set<String> = []
        var current = ""

        func flush() {
            if !current.isEmpty { tokens.insert(current.lowercased()) }
            current = ""
        }

        for character in identifier {
            if character.isLetter || character.isNumber {
                // A capital starts a new word, but only after lowercase — `GPT`
                // is one word, not three.
                if character.isUppercase, let last = current.last, last.isLowercase {
                    flush()
                }
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// The token list as a JavaScript array literal, so the page-side sweep and
    /// the tests here are working from the same words rather than two lists that
    /// drift apart.
    public static var slotNamesJSArray: String {
        "[" + slotNames.sorted().map { "'\($0)'" }.joined(separator: ",") + "]"
    }
}
