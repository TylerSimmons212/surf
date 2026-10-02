import Foundation

/// One rendition a YouTube page lists in `streamingData.adaptiveFormats`, as the
/// stream tap carries it across the bridge.
public struct YouTubeRendition: Decodable, Equatable, Sendable {
    public var itag: Int
    /// A string across the bridge and a `UInt64` here. The value is around
    /// 1.7×10¹⁸, past where a JSON number holds integers exactly, and the
    /// server rejects a request carrying a rounded one.
    public var lastModified: String
    public var mimeType: String
    public var height: Int
    public var bitrate: Int
    /// Stated by the page, exactly. Empty when it says nothing.
    public var contentLength: String = ""
    /// What distinguishes renditions that share an itag, as the page gives it:
    /// base64 of a small protobuf, `drc=1` for Stable Volume, `vb=1` for voice
    /// boost, a language for a dub. Nil on the plain rendition.
    public var xtags: String?

    public init(
        itag: Int, lastModified: String, mimeType: String,
        height: Int = 0, bitrate: Int = 0, contentLength: String = "",
        xtags: String? = nil
    ) {
        self.itag = itag
        self.lastModified = lastModified
        self.mimeType = mimeType
        self.height = height
        self.bitrate = bitrate
        self.contentLength = contentLength
        self.xtags = xtags
    }

    public var bytes: Int? {
        let value = Int(contentLength)
        return (value ?? 0) > 0 ? value : nil
    }

    public var revision: UInt64? { UInt64(lastModified) }
    public var isVideo: Bool { mimeType.hasPrefix("video/") }
    public var isAudio: Bool { mimeType.hasPrefix("audio/") }
    /// Whether AVFoundation can read it. WebM and its codecs it cannot, and
    /// asking for one produces a download that finishes and will not mux.
    public var isMP4: Bool { mimeType.contains("mp4") }

    /// The id a streaming request names this rendition by.
    ///
    /// All three parts, because an itag and a revision do not name one
    /// rendition. A page can list itag 140 three times — plain, Stable Volume,
    /// voice boost — told apart only by xtags, each with its own revision. Asking
    /// for a variant's itag and revision without its xtags names a format that
    /// does not exist, and the server answers with a request to reload the
    /// player and no media at all.
    public var formatID: SABR.FormatID? {
        revision.map { SABR.FormatID(itag: itag, lastModified: $0, xtags: isPlain ? nil : xtags) }
    }

    /// Unprocessed: not Stable Volume, voice boost, or one of several dubs.
    public var isPlain: Bool { xtags?.isEmpty ?? true }

    /// The rendition a menu row names. A row carries only an itag, so where the
    /// page lists that itag more than once this takes the plain one, which is
    /// what YouTube's own player plays unless someone opts into a variant.
    public static func named(_ itag: Int, in formats: [YouTubeRendition]) -> YouTubeRendition? {
        let matching = formats.filter { $0.itag == itag }
        return matching.first(where: \.isPlain) ?? matching.first
    }

    /// Picks the best pair AVFoundation can actually read.
    ///
    /// Without this the server chooses, and on a real download it chose 144p
    /// VP9 in WebM — which arrived complete and then would not mux, because
    /// AVFoundation reads neither WebM nor VP9. The quality was an accident
    /// too: nothing had asked for anything.
    ///
    /// MP4 only, therefore, and the tallest of those. Returns nil if nothing is
    /// MP4, and the caller lets the server choose.
    public static func choose(
        from formats: [YouTubeRendition], maxHeight: Int? = nil
    ) -> (video: YouTubeRendition, audio: YouTubeRendition)? {
        let usable = formats.filter { $0.revision != nil }
        let videos = usable.filter { $0.isVideo && $0.isMP4 }
        let audios = usable.filter { $0.isAudio && $0.isMP4 }
        guard !videos.isEmpty, !audios.isEmpty else { return nil }

        let eligible = maxHeight.map { cap in videos.filter { $0.height <= cap } } ?? videos
        let candidates = eligible.isEmpty ? videos : eligible

        // Tallest wins, as it does everywhere else in this engine, and the
        // codec only breaks a tie between equals.
        //
        // It was the other way round first — H.264 preferred outright — on
        // the grounds that a browser download should play in anything. That
        // reasoning is sound and the consequence was not: YouTube offers
        // H.264 no higher than 1080p, so preferring it silently capped every
        // download at 1080p on a site whose whole point above that is VP9 and
        // AV1. A rule about codecs turned into a rule about resolution
        // without saying so.
        //
        // There is no technical reason for the cap. ffmpeg muxes the 2160p
        // AV1 in about a second and the result reads back at exactly the
        // right duration.
        guard let video = candidates.max(by: { a, b in
            if a.height != b.height { return a.height < b.height }
            // Same picture, two encodings: take the one more things can play.
            if playability(a) != playability(b) { return playability(a) < playability(b) }
            return a.bitrate < b.bitrate
        }) else { return nil }
        // The best sound available: it is a fraction of the video's size, so
        // there is nothing to save by taking less. Among plain renditions when
        // there are any, because a variant can outbid the plain track by a few
        // bits a second and is not what anyone pressing download is asking for.
        let plainAudio = audios.filter(\.isPlain)
        let soundtracks = plainAudio.isEmpty ? audios : plainAudio
        guard let audio = soundtracks.max(by: { $0.bitrate < $1.bitrate }) else { return nil }
        return (video, audio)
    }

    private static func playability(_ format: YouTubeRendition) -> Int {
        let codecs = ["avc1", "avc3", "hvc1", "hev1"]
        for (index, codec) in codecs.enumerated() where format.mimeType.contains(codec) {
            return codecs.count - index
        }
        return 0
    }
}
