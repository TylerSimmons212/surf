import Foundation

/// What `youtube.page` sends back.
///
/// Deliberately shapeless: the script reports what it found and makes no
/// claim about what kind of page this is. Swift decides that from the address
/// (`YouTubePage.of`), and decides what every field *means* in
/// `YouTubeModel` — both under test, neither inside an injected string.
///
/// The renderer arrays carry YouTube's own JSON re-serialised, one object per
/// entry, exactly as `FocusArticle.jsonLD` carries a page's script tags. The
/// script copies a fixed list of keys off each one and interprets none of
/// them; a payload that changes shape is then a parser change with a failing
/// test, not a silent blank in the grid.
public struct YouTubePageReply: Decodable, Equatable, Sendable {
    /// Pruned `videoRenderer` objects from a results page, in ranked order.
    public var renderers: [String]
    /// `ytInitialPlayerResponse.videoDetails`, on a watch page.
    public var details: String
    /// Pruned `chapterRenderer` objects.
    public var chapters: [String]
    /// Pruned `captionTracks` entries.
    public var captionTracks: [String]
    /// The playback speeds this player will actually accept. Read from the
    /// player rather than assumed: it is the site's list, and a speed it
    /// refuses is a control that does nothing.
    public var rates: [Double]
    /// Whether `#movie_player` is present and answering. False on a results
    /// page, and briefly true-to-come on a watch page still booting — which
    /// is why staging waits for it rather than assuming a watch URL means a
    /// player exists.
    public var hasPlayer: Bool

    private enum CodingKeys: String, CodingKey {
        case renderers, details, chapters, captionTracks, rates, hasPlayer
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        renderers = try c.decodeIfPresent([String].self, forKey: .renderers) ?? []
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        chapters = try c.decodeIfPresent([String].self, forKey: .chapters) ?? []
        captionTracks = try c.decodeIfPresent([String].self, forKey: .captionTracks) ?? []
        rates = try c.decodeIfPresent([Double].self, forKey: .rates) ?? []
        hasPlayer = try c.decodeIfPresent(Bool.self, forKey: .hasPlayer) ?? false
    }

    public init(
        renderers: [String] = [], details: String = "", chapters: [String] = [],
        captionTracks: [String] = [], rates: [Double] = [], hasPlayer: Bool = false
    ) {
        self.renderers = renderers
        self.details = details
        self.chapters = chapters
        self.captionTracks = captionTracks
        self.rates = rates
        self.hasPlayer = hasPlayer
    }

    /// The results grid, parsed and normalised.
    public var results: [YouTubeResult] {
        YouTubeResult.parse(fromRenderers: renderers)
    }

    /// The video on the stage, when this reply came from a watch page.
    public var video: YouTubeVideo? {
        details.isEmpty ? nil : YouTubeVideo.parse(fromDetails: details)
    }

    public var parsedChapters: [YouTubeChapter] {
        YouTubeChapter.parse(fromRenderers: chapters)
    }

    public var parsedCaptionTracks: [YouTubeCaptionTrack] {
        YouTubeCaptionTrack.parse(fromTracks: captionTracks)
    }

    /// The speeds the transport offers. The player's own list when it gave
    /// one, and the familiar ladder when it didn't — a speed control with no
    /// speeds in it would be worse than no control.
    public var playbackRates: [Double] {
        let usable = rates.filter { $0 > 0 && $0 <= 4 }.sorted()
        return usable.isEmpty ? [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2] : usable
    }
}
