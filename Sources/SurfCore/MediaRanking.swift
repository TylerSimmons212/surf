import Foundation

/// What a page told us about one media element, reduced to the things that
/// bear on whether it's the one the viewer actually cares about.
///
/// Deliberately not the same type as the player's display state: this is
/// evidence, not presentation. Keeping it separate is what lets the choice be
/// made — and tested — without a browser anywhere near it.
public struct MediaSignals: Equatable, Sendable {
    public var isPlaying: Bool
    /// Muted *or* at zero volume. Browsers only allow autoplay when muted, so
    /// this is the single most telling thing about an unattended video.
    public var isMuted: Bool
    public var loops: Bool
    /// The element's rendered size in CSS pixels. Zero when it isn't laid out.
    public var width: Double
    public var height: Double
    /// Seconds, or zero when unknown — live streams and un-loaded metadata
    /// both report nothing, and neither should be punished for it.
    public var duration: Double
    /// The element's frame set `navigator.mediaSession.metadata`. Real players
    /// do this so the OS can show now-playing information; ad tags don't.
    ///
    /// Only that. It used to be true for anything in the top frame as well,
    /// because the bridge borrowed the flag that decides whether a title is
    /// worth showing — which handed every advert player injected into the top
    /// document the bonus meant for players that say what they are playing.
    public var hasMetadata: Bool
    /// Monotonic milliseconds since its frame loaded, for tie-breaking only.
    public var startedAt: Double

    /// Audio bytes the element has decoded so far, or nil when the engine
    /// didn't say.
    ///
    /// Raw rather than a yes/no, because nil and zero are different answers
    /// and only the caller knows what to do with each. Nil means "not
    /// reported"; zero means "reported, and there was no sound".
    ///
    /// Measured on macOS 27: WebKit does not report it, so this is nil in
    /// practice and the muted test below is what actually runs. It is kept
    /// because the distinction is the right shape and costs nothing — but
    /// nobody should read this and believe it is catching silent videos
    /// today. If sharper detection is wanted, `audioTracks` is the next thing
    /// to try.
    public var audioBytes: Double?

    public init(
        isPlaying: Bool = false,
        isMuted: Bool = false,
        loops: Bool = false,
        width: Double = 0,
        height: Double = 0,
        duration: Double = 0,
        hasMetadata: Bool = false,
        startedAt: Double = 0,
        audioBytes: Double? = nil
    ) {
        self.isPlaying = isPlaying
        self.isMuted = isMuted
        self.loops = loops
        self.width = width
        self.height = height
        self.duration = duration
        self.hasMetadata = hasMetadata
        self.startedAt = startedAt
        self.audioBytes = audioBytes
    }

    /// Whether this is making a noise, which is the only kind of video worth
    /// announcing on its own.
    ///
    /// The sidebar used to list every tab holding any media at all, and
    /// pop-out fired for anything playing with a picture. Both counted the
    /// muted autoplay ad that half the web carries, so a tab you had opened
    /// for an article would announce itself and then float a video of
    /// something you never asked to watch.
    ///
    /// Muted is the strongest tell — browsers only permit autoplay when muted,
    /// so an unattended video is a muted one almost by definition. Decoded
    /// audio bytes catch the rest: a video can be unmuted and still silent,
    /// having no audio track at all.
    ///
    /// Unknown bytes fall back to the muted test rather than to silence. If a
    /// WebKit release stops reporting them, the worst case is the old
    /// behaviour for a few odd videos, not a media section that never appears.
    public var isAudible: Bool { isPlaying && hasSound }

    /// Whether this would make a noise if it played — `isAudible` without the
    /// requirement that it is playing right now.
    ///
    /// The difference is a paused video. A video you started and then paused
    /// is still the one you came for, and the theater must still be offered
    /// for it; the muted advert looping beside it never had any sound to
    /// pause.
    public var hasSound: Bool { !isMuted && (audioBytes.map { $0 > 0 } ?? true) }

    public var area: Double { max(0, width) * max(0, height) }
}

/// Picks which of a page's media elements the player should be showing.
///
/// The player used to take whichever element started most recently, which is
/// right exactly until a page has more than one. Sites that run video also run
/// video ads — usually several, usually in their own iframes, usually on a
/// loop — and every one of them fires `play` after the thing you actually
/// opened the page for. Last-one-wins hands the sidebar, the play button, and
/// Pop Out to a 300×250 advert on repeat, and there is no way to get them back
/// short of pausing the ad.
///
/// So the choice is scored rather than sequenced. No single signal is trusted
/// on its own — each of them is wrong somewhere, and the ones that are wrong
/// are wrong in different places:
///
/// - **Audible** is the strongest, because autoplay is only permitted while
///   muted. A video making noise was almost always started deliberately. But a
///   viewer who mutes the film they're watching must not lose the player, so it
///   can't be decisive by itself.
/// - **Size** is nearly as good and fails in the opposite direction: the thing
///   you're watching is the big rectangle in the middle, but a full-bleed
///   background loop is bigger still. Capped, so a huge decorative video can't
///   out-argue everything else on its own.
/// - **Looping** and **ad-length duration** are what pull those two back down.
/// - **Media session metadata** is a near-certain positive when it's there and
///   says nothing when it isn't — plenty of real players never set it.
///
/// The weights below are chosen so that no *single* signal carries a decision,
/// and the combinations that matter come out right; the tests enumerate the
/// cases, including the one this was written for.
public enum MediaRanking {

    /// Higher is more likely to be what the viewer is watching.
    public static func score(_ signals: MediaSignals) -> Double {
        var score = 0.0

        // A playing element always outranks a stopped one, whatever else is
        // true — the gap is wider than every other term combined on purpose.
        if signals.isPlaying { score += 1000 }

        if !signals.isMuted { score += 220 }

        // Capped so a full-bleed background video can't win on size alone. The
        // divisor puts a 300×250 ad slot near 21 and a 900×500 player at the
        // ceiling, which is the separation that matters.
        score += min(120, signals.area / 3500)

        if signals.loops { score -= 60 }

        // Zero means unknown — live, or metadata not in yet — and is left
        // alone rather than guessed at.
        if signals.duration > 0 {
            if signals.duration < 45 {
                score -= 70
            } else if signals.duration > 300 {
                score += 40
            }
        }

        if signals.hasMetadata { score += 60 }

        return score
    }

    /// The index of the element to show, or nil when there's nothing at all.
    ///
    /// Ties break toward the larger element and then toward the more recently
    /// started one, so the old last-one-wins behaviour survives as the
    /// tie-breaker it should always have been.
    public static func primaryIndex(among candidates: [MediaSignals]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        return candidates.indices.max { left, right in
            let a = candidates[left], b = candidates[right]
            let scoreA = score(a), scoreB = score(b)
            if scoreA != scoreB { return scoreA < scoreB }
            if a.area != b.area { return a.area < b.area }
            return a.startedAt < b.startedAt
        }
    }

    /// The index of the element the theater should put on stage, or nil when
    /// nothing on the page is worth staging.
    ///
    /// Not `primaryIndex`, though it is the same ranking underneath. The
    /// primary pick answers "what is playing here", and a playing advert is a
    /// fair answer to that — it outranks a paused feature on purpose, because
    /// a now-playing strip describes what is playing. The theater asks a
    /// different question: what did you come here to watch. The theater used
    /// to stage the primary pick, which put the advert on stage whenever the
    /// real video was paused or not yet started, and offered a theater on
    /// articles whose only video was an advert.
    ///
    /// So only elements with a picture and with sound are eligible, and the
    /// ranking chooses among those. The cost is a feature someone muted
    /// before entering: it isn't offered. Muting first and staging second is
    /// rare; a muted autoplay advert on an article is on half the web.
    public static func stageIndex(
        among candidates: [(signals: MediaSignals, hasPicture: Bool)]
    ) -> Int? {
        let eligible = candidates.indices.filter {
            candidates[$0].hasPicture && candidates[$0].signals.hasSound
        }
        guard let pick = primaryIndex(among: eligible.map { candidates[$0].signals })
        else { return nil }
        return eligible[pick]
    }
}
