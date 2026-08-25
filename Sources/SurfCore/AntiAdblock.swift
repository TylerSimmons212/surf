import Foundation

/// The two things a page does once it notices blocking, and what to do back.
///
/// Both were found the same way: by reading what a site that stops its video
/// mid-play actually runs. Neither is exotic, and neither is specific to that
/// site — they are what the templates behind a great many video sites do.
public enum AntiAdblock {

    // MARK: - Bait globals

    /// A page cannot ask whether a request was blocked. What it can do is load a
    /// script whose only job is to set a variable, and then check whether the
    /// variable is there:
    ///
    /// ```js
    /// video.addEventListener('play', () => {
    ///   if (typeof bait_b3j4hu231 === 'undefined') { showWall(); video.pause(); }
    /// });
    /// ```
    ///
    /// The name is random per site, so no filter list can carry it and no
    /// surrogate can be written for it in advance. What *is* constant is the
    /// shape: an identifier tested with `typeof`, never assigned anywhere in the
    /// page, and named after what it is.
    ///
    /// So the answer is the same as the ad SDK's — let the page find what it is
    /// looking for — reached by reading the check rather than by knowing the
    /// name in advance.
    ///
    /// Deliberately narrow. Defining a global a page expects to be missing is a
    /// real way to break a site: `typeof jQuery === 'undefined'` is how a page
    /// decides whether to load jQuery, and answering that one would leave it
    /// calling methods on a stub forever. So only names that announce
    /// themselves as bait qualify, and only when the page never assigns them.
    public static let baitPrefixes = ["bait", "adbait", "advbait", "blockbait", "adblockbait"]

    /// Whether an identifier names a bait variable rather than a real one.
    ///
    /// The prefix has to be followed by a separator or a random-looking tail —
    /// `bait_b3j4hu231` qualifies, and a legitimate `baiting` or `baitShopAPI`
    /// does not, because a word that merely starts with "bait" is a word.
    public static func namesBait(_ identifier: String) -> Bool {
        let lowered = identifier.lowercased()
        for prefix in baitPrefixes where lowered.hasPrefix(prefix) {
            let tail = lowered.dropFirst(prefix.count)
            if tail.isEmpty { return true }
            guard let first = tail.first else { return true }
            // `bait_x`, `bait2`, `baitB3j4` — a separator or a digit, not more
            // letters that would make it an ordinary word.
            return first == "_" || first == "$" || first.isNumber
        }
        return false
    }

    /// The JavaScript pattern that finds those checks in a page's own scripts.
    ///
    /// Both orders, because `'undefined' === typeof x` is the same test written
    /// the other way round and appears about as often.
    public static let baitCheckPattern =
        #"typeof\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*[!=]==?\s*['"]undefined['"]"#
    public static let baitCheckPatternReversed =
        #"['"]undefined['"]\s*[!=]==?\s*typeof\s+([A-Za-z_$][A-Za-z0-9_$]*)"#

    /// The prefixes as a JavaScript array, so the page tests the same list.
    public static var baitPrefixesJSArray: String {
        "[" + baitPrefixes.map { "'\($0)'" }.joined(separator: ",") + "]"
    }

    // MARK: - Windows opened by pressing play

    /// The other half: a player configured to open a window when you click it.
    ///
    /// ```
    /// popunder_url: 'https://bewhidare.com/…', popunder_duration: '120',
    /// ```
    ///
    /// The click that plays the video is the click that opens the tab, so every
    /// defence that reasons about *gestures* is defeated by design — the gesture
    /// is real, and it is the one the viewer made. Checking the destination
    /// doesn't help either, because these land on throwaway affiliate domains
    /// that no list carries and none of them are on for long.
    ///
    /// What is constant is the intent. Pressing play on a video is a request to
    /// play a video; it is not a request to open a window, and no legitimate
    /// player has ever needed one. So a window opened *during* a click on a
    /// video is refused on that basis alone — not on where it points, which is
    /// what makes it work on a domain nobody has ever seen before.
    ///
    /// Scoped as tightly as the claim: only while a click on a video or its
    /// player chrome is being handled, and only for somewhere other than the
    /// site you are on. A share button that opens a window still opens it, and
    /// so does everything else on the page.
    public static let playerClickWindow: TimeInterval = 1.0

    /// What counts as the video and the furniture around it. A player's own
    /// controls are not inside the `<video>` element, and the click that starts
    /// playback usually lands on an overlay above it.
    public static let playerSelectors = [
        "video", "[id*=player i]", "[class*=player i]",
        "[class*=video i]", "[id*=video i]", "[class*=play-]", "[class*=btn-play]",
    ]

    public static var playerSelectorsJS: String {
        "'" + playerSelectors.joined(separator: ",") + "'"
    }

    // MARK: - The layer over the play button

    /// A transparent sheet laid over a video player to catch the click meant
    /// for it.
    ///
    /// ```html
    /// <div style="inset:0; position:absolute; z-index:171; background:none"></div>
    /// ```
    ///
    /// Unnamed, empty, invisible, and stacked above the player's own controls.
    /// The viewer aims at play and hits this instead, which opens a window and
    /// then gets out of the way so the second click works — which is exactly why
    /// it reads as "I clicked play and got an ad".
    ///
    /// What identifies it is not any one of those properties but the
    /// combination, and above all the last one: a player has no reason to cover
    /// its own controls. Its own overlays are named — `fp-ui`, `fp-ui-block` —
    /// because its own code has to find them, where this one is anonymous
    /// because nothing needs to refer to it again.
    ///
    /// The answer is to stop it *receiving* clicks rather than to remove it.
    /// Removing an element a player put there is a guess about someone else's
    /// code; making it transparent to the pointer changes nothing except who
    /// gets the click, and the click was always meant for the player.
    public static let clickTrapCoverage = 0.8

    /// Below this a player is a thumbnail or a hidden pre-roll frame, and an
    /// overlay on it isn't worth reasoning about.
    public static let smallestPlayer = 120.0
}
