import Foundation

/// What to download, decided before anything is requested.
///
/// Every refusal this type can return happens with no scratch directory created
/// and no byte fetched. That is not a stylistic preference: "refuses protected
/// content before downloading anything" is a claim, and putting the decision in a
/// pure function is what makes it a claim a test can check rather than a sentence
/// in a comment.
///
/// It is also where "no site-specific extractors" stops being a slogan. The input
/// is a `StreamIndex` parsed from the manifest the page itself fetched, so there
/// is nothing here that knows one site from another.
public struct StreamPlan: Equatable, Sendable {

    /// The picture, or the whole thing when picture and sound arrive together.
    public var video: StreamRendition

    /// The sound, when it arrives separately. Nil means `video` carries it.
    public var audio: StreamRendition?

    public var container: StreamContainer

    /// Handed to `SavedMedia` when the file is finished. Built here because this
    /// is the last place that knows what the manifest promised.
    public var expectation: SavedMedia.Expectation

    /// Every host the plan will send a request to. Collected so the count can be
    /// refused, and so a log line can say where a download actually went.
    public var hosts: Set<String>

    public var segmentCount: Int {
        video.segments.count + (audio?.segments.count ?? 0)
    }

    public var duration: Double { video.duration }

    // MARK: - Choosing

    /// Which rendition to take, or why we will not.
    ///
    /// Called against a master playlist, before its variants have been expanded,
    /// because you cannot sensibly fetch every variant's segment list in order to
    /// decide which one you wanted.
    public static func pick(
        from index: StreamIndex,
        preferring preference: StreamPreference = .init()
    ) -> Result<StreamRendition, StreamRefusal> {
        // Order matters. Protection and liveness are facts about the whole stream
        // and make every rendition in it moot, so they are answered before
        // anything is compared.
        if index.protection == .protected { return .failure(.protected) }
        if index.protection == .fetchableKey { return .failure(.encryptedWithFetchableKey) }
        if index.isLive { return .failure(.live) }

        let playable = index.renditions.filter { $0.role == .muxed || $0.role == .video }
        guard !playable.isEmpty else { return .failure(.noRenditions) }

        // Only streams that carry their own sound, for now. A video rendition
        // with its audio in another playlist needs a muxer, and until there is
        // one, saying so and falling back beats producing a silent file.
        let muxed = playable.filter { $0.role == .muxed }
        guard !muxed.isEmpty else { return .failure(.separateTracks) }

        guard let best = best(of: muxed, under: preference.maxHeight) else {
            return .failure(.noRenditions)
        }
        return .success(best)
    }

    /// Tallest first, then fastest.
    ///
    /// A height cap is a ceiling and never a target: asking for 720 on a stream
    /// offering 480 and 1080 returns the 480, because the alternative is handing
    /// someone a bigger file than they asked for.
    ///
    /// Bandwidth breaks ties because two renditions at one height are the same
    /// picture at two qualities. Renditions with no declared height sort last
    /// rather than being dropped: a stream that declares nothing is still a
    /// stream, and it is the only candidate on plenty of single-variant sites.
    private static func best(
        of renditions: [StreamRendition], under cap: Int?
    ) -> StreamRendition? {
        let eligible = cap.map { cap in
            renditions.filter { ($0.height ?? 0) <= cap }
        } ?? renditions

        func taller(_ a: StreamRendition, _ b: StreamRendition) -> Bool {
            if (a.height ?? 0) != (b.height ?? 0) { return (a.height ?? 0) < (b.height ?? 0) }
            return (a.bandwidth ?? 0) < (b.bandwidth ?? 0)
        }

        // A cap below every rendition would otherwise refuse the stream outright.
        // The smallest on offer is the more useful reading of "no bigger than
        // this" — and it has to be the smallest, not the tallest, or the cap is
        // worse than having no cap at all.
        guard !eligible.isEmpty else { return renditions.min(by: taller) }
        return eligible.max(by: taller)
    }

    // MARK: - Building

    /// The plan, once the picked rendition's own playlist has been read.
    ///
    /// `index` is that second playlist and carries the segments. `chosen` is what
    /// the master said about it and carries the resolution, bandwidth and codecs,
    /// which a media playlist does not restate. Neither has the whole picture,
    /// which is why both are arguments.
    public static func make(
        from index: StreamIndex,
        labelledBy chosen: StreamRendition,
        preferring preference: StreamPreference = .init()
    ) -> Result<StreamPlan, StreamRefusal> {
        if index.protection == .protected { return .failure(.protected) }
        if index.protection == .fetchableKey { return .failure(.encryptedWithFetchableKey) }
        if index.isLive { return .failure(.live) }

        guard let expanded = index.renditions.first(where: { !$0.segments.isEmpty }) else {
            return .failure(.noSegments)
        }

        // fMP4 concatenates into a file AVFoundation reads. Nothing else does,
        // and attempting one produces something that looks like a video and is
        // not.
        guard expanded.container == .fragmentedMP4 else {
            return .failure(.unsupportedContainer(expanded.container))
        }

        var video = expanded
        // Carry the master's description across. The media playlist knows the
        // segments; only the master knew what they are.
        video.id = chosen.id
        video.width = chosen.width ?? video.width
        video.height = chosen.height ?? video.height
        video.bandwidth = chosen.bandwidth ?? video.bandwidth
        video.codecs = chosen.codecs ?? video.codecs

        let hosts = Set(
            ([video.initSegment].compactMap { $0 } + video.segments)
                .compactMap { $0.url.host }
        )
        // The manifest names the hosts we are about to send cookies to, which
        // makes a manifest reaching across a dozen of them worth refusing. Real
        // CDNs use one or two; a long list is not a pattern worth serving.
        guard hosts.count <= preference.hostLimit else {
            return .failure(.tooManyHosts(hosts.count))
        }

        return .success(StreamPlan(
            video: video,
            audio: nil,
            container: expanded.container,
            expectation: SavedMedia.Expectation(
                wantsVideo: true,
                // Only when the manifest positively said so. A variant with no
                // CODECS attribute is not a promise of sound, and failing a
                // silent stream for lacking what nothing claimed it had would be
                // the guard inventing a bug.
                wantsAudio: StreamCodecs.declaresAudio(video.codecs),
                declaredDuration: index.declaredDuration
            ),
            hosts: hosts
        ))
    }
}

/// How the choice should be made.
public struct StreamPreference: Equatable, Sendable {

    /// A ceiling in pixels, or nil for the best on offer.
    public var maxHeight: Int?

    /// How many distinct hosts one download may touch.
    ///
    /// Four, because a manifest naming its own CDN plus a backup is ordinary and
    /// a manifest fanning out across a dozen hosts is not. This is a privacy
    /// limit rather than a performance one: each of those hosts would be sent the
    /// tab's cookies.
    public var hostLimit: Int

    public init(maxHeight: Int? = nil, hostLimit: Int = 4) {
        self.maxHeight = maxHeight
        self.hostLimit = hostLimit
    }
}

/// Why we are not downloading this ourselves.
///
/// An `Error` so it can ride in a `Result`, which is the shape that forces every
/// caller to deal with it. `PageProtocol.Failure` is the same idea for the same
/// reason.
public enum StreamRefusal: Error, Equatable, Sendable {

    /// Not a manifest, or one we could not read. Our parser being incomplete is
    /// not the user's problem, so this falls back like anything else.
    case unreadable

    /// DRM. The samples are encrypted before they reach the decoder and there is
    /// no key to ask for.
    case protected

    /// AES-128 with a fetchable key. Genuinely not DRM, and a thing to support
    /// later rather than a wall.
    case encryptedWithFetchableKey

    /// No end, so no whole file to produce.
    case live

    case noRenditions
    case noSegments

    /// Picture and sound in separate playlists, which needs a muxer.
    case separateTracks

    case unsupportedContainer(StreamContainer)

    /// More hosts than a plan may send cookies to.
    case tooManyHosts(Int)

    /// Whether handing this to the subprocess is worth trying.
    ///
    /// The distinction that matters most in this type. Everything we cannot do
    /// yet is something yt-dlp may well manage, and should be passed along
    /// quietly. DRM is the one case where it will also fail, slower and with a
    /// worse message, so refusing immediately in a sentence someone wrote is the
    /// better outcome.
    public var allowsFallback: Bool {
        self != .protected
    }

    /// Shown only when there is no fallback left. Everything else is invisible,
    /// because a download that succeeds by another route is not an error.
    public var message: String {
        switch self {
        case .protected:
            "This video is protected and can't be saved"
        case .live:
            "This is a live stream, so there's no file to save yet"
        default:
            "Couldn't save this video"
        }
    }
}
