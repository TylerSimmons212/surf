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

    /// Which rendition or pair of renditions to take, or why we will not.
    ///
    /// Called against a master playlist, before its variants have been expanded,
    /// because fetching every variant's segment list in order to decide which one
    /// you wanted is not a reasonable way to answer the question.
    public static func pick(
        from index: StreamIndex,
        preferring preference: StreamPreference = .init()
    ) -> Result<StreamPick, StreamRefusal> {
        // Order matters. Protection and liveness are facts about the whole stream
        // and make every rendition in it moot, so they are answered before
        // anything is compared.
        if index.protection == .protected { return .failure(.protected) }
        if index.protection == .fetchableKey { return .failure(.encryptedWithFetchableKey) }
        if index.isLive { return .failure(.live) }

        // Muxed and video-only renditions compete on equal terms, and the tallest
        // wins whichever it is. Preferring one packaging over the other would
        // mean handing back 720p from a muxed variant while a 1080p video stream
        // sat next to it, for no reason the user would recognise.
        let playable = index.renditions.filter { $0.role == .muxed || $0.role == .video }
        guard !playable.isEmpty else { return .failure(.noRenditions) }
        guard let video = best(of: playable, under: preference.maxHeight) else {
            return .failure(.noRenditions)
        }

        guard video.role == .video else {
            return .success(StreamPick(video: video, audio: nil))
        }

        // A video-only stream needs its soundtrack, and the manifest says which
        // group it belongs to. No group, or a group with nothing in it, means the
        // manifest is describing something we cannot assemble.
        guard let group = video.audioGroup,
              let audio = soundtrack(forGroup: group, in: index.renditions)
        else { return .failure(.separateTracks) }

        return .success(StreamPick(video: video, audio: audio))
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
    /// stream, and on plenty of single-variant sites it is the only candidate.
    private static func best(
        of renditions: [StreamRendition], under cap: Int?
    ) -> StreamRendition? {
        func taller(_ a: StreamRendition, _ b: StreamRendition) -> Bool {
            if (a.height ?? 0) != (b.height ?? 0) { return (a.height ?? 0) < (b.height ?? 0) }
            return (a.bandwidth ?? 0) < (b.bandwidth ?? 0)
        }

        let eligible = cap.map { cap in
            renditions.filter { ($0.height ?? 0) <= cap }
        } ?? renditions

        // A cap below every rendition would otherwise refuse the stream outright.
        // The smallest on offer is the more useful reading of "no bigger than
        // this" — and it has to be the smallest, not the tallest, or the cap is
        // worse than having no cap at all.
        guard !eligible.isEmpty else { return renditions.min(by: taller) }
        return eligible.max(by: taller)
    }

    /// `DEFAULT=YES` first, then whatever came first in the manifest.
    ///
    /// A group routinely holds several languages and a described-video track, and
    /// `DEFAULT` is the only thing in the format that states the publisher's
    /// preference between them. Manifest order is the tiebreak because it is the
    /// order the publisher chose to list them in.
    private static func soundtrack(
        forGroup group: String, in renditions: [StreamRendition]
    ) -> StreamRendition? {
        let candidates = renditions.filter { $0.role == .audio && $0.audioGroup == group }
        return candidates.first { $0.isDefault } ?? candidates.first
    }

    // MARK: - Building

    /// The plan, once the picked renditions' own playlists have been read.
    ///
    /// `videoIndex` and `audioIndex` are those playlists and carry the segments.
    /// `pick` is what the master said about them and carries the resolution,
    /// bandwidth and codecs, which a media playlist does not restate. Neither
    /// side has the whole picture, which is why both are arguments.
    public static func make(
        video videoIndex: StreamIndex,
        audio audioIndex: StreamIndex? = nil,
        labelledBy pick: StreamPick,
        preferring preference: StreamPreference = .init()
    ) -> Result<StreamPlan, StreamRefusal> {
        // Re-checked rather than trusted from `pick`. Most streams declare their
        // protection in the media playlist, not the master, so checking only at
        // pick time would miss nearly all of them.
        for index in [videoIndex, audioIndex].compactMap({ $0 }) {
            if index.protection == .protected { return .failure(.protected) }
            if index.protection == .fetchableKey {
                return .failure(.encryptedWithFetchableKey)
            }
            if index.isLive { return .failure(.live) }
        }

        guard var video = expanded(videoIndex, matching: pick.video) else {
            return .failure(.noSegments)
        }

        // fMP4 concatenates into a file AVFoundation reads, and separate fMP4
        // tracks mux into one with no re-encode. Nothing else does either, and
        // attempting it produces something that looks like a video and is not.
        guard video.container == .fragmentedMP4 else {
            return .failure(.unsupportedContainer(video.container))
        }

        // Carry the master's description across. The media playlist knows the
        // segments; only the master knew what they are.
        video.id = pick.video.id
        video.width = pick.video.width ?? video.width
        video.height = pick.video.height ?? video.height
        video.bandwidth = pick.video.bandwidth ?? video.bandwidth
        video.codecs = pick.video.codecs ?? video.codecs

        var audio: StreamRendition?
        if let chosenAudio = pick.audio {
            // A DASH soundtrack arrives already expanded, because one document
            // described both tracks; an HLS one is a pointer to a playlist that
            // has to have been fetched. Deliberately not a loose fallback to the
            // video index: `expanded` would then find the *video* rendition and
            // hand back its segments as the audio track, which is the bug this
            // function was just fixed for, in its worst possible form.
            let found: StreamRendition?
            if !chosenAudio.segments.isEmpty {
                found = chosenAudio
            } else if let audioIndex {
                found = expanded(audioIndex, matching: chosenAudio)
            } else {
                found = nil
            }
            guard var track = found else { return .failure(.noSegments) }
            guard track.container == .fragmentedMP4 else {
                return .failure(.unsupportedContainer(track.container))
            }
            track.id = chosenAudio.id
            track.role = .audio
            track.codecs = chosenAudio.codecs ?? track.codecs
            audio = track
        }

        let segments = ([video.initSegment] + [audio?.initSegment]).compactMap { $0 }
            + video.segments + (audio?.segments ?? [])
        let hosts = Set(segments.compactMap { $0.url.host })
        // The manifest names the hosts we are about to send cookies to, which
        // makes a manifest reaching across a dozen of them worth refusing. Real
        // CDNs use one or two; a long list is not a pattern worth serving.
        guard hosts.count <= preference.hostLimit else {
            return .failure(.tooManyHosts(hosts.count))
        }

        return .success(StreamPlan(
            video: video,
            audio: audio,
            container: .fragmentedMP4,
            expectation: SavedMedia.Expectation(
                wantsVideo: true,
                // A separate audio track is the manifest stating outright that
                // this has sound. Otherwise only a CODECS attribute naming an
                // audio format counts: a variant that declared nothing is not a
                // promise, and failing a silent stream for lacking what nothing
                // claimed it had would be the guard inventing a bug.
                wantsAudio: audio != nil || StreamCodecs.declaresAudio(video.codecs),
                declaredDuration: videoIndex.declaredDuration
            ),
            hosts: hosts
        ))
    }

    /// The rendition that was chosen, with its segments.
    ///
    /// Matching by id matters and took a wrong download to notice. An HLS second
    /// pass returns a playlist holding exactly one rendition, so "the first one
    /// with segments" and "the one we picked" were the same thing and the
    /// difference never showed. A DASH manifest describes everything at once, so
    /// the index holds every rendition and the first is whichever the publisher
    /// listed first — on one real manifest that meant choosing 3840x2160 and then
    /// fetching the segments of a 1024x576 stream, labelled as 4K. On another it
    /// meant the video track's segments being the audio file.
    ///
    /// The pick is preferred outright when it already carries its own segments,
    /// which is the DASH case and needs no searching at all.
    private static func expanded(
        _ index: StreamIndex, matching pick: StreamRendition
    ) -> StreamRendition? {
        if !pick.segments.isEmpty { return pick }
        if let exact = index.renditions.first(where: {
            $0.id == pick.id && !$0.segments.isEmpty
        }) { return exact }
        // A media playlist does not restate the id the master knew it by, so for
        // HLS there is nothing to match on and the single rendition it holds is
        // the answer.
        return index.renditions.first { !$0.segments.isEmpty }
    }
}

/// The renditions chosen, before their playlists have been fetched.
///
/// Two fields rather than a pair of overloads, because "one stream with sound in
/// it" and "a video stream and its soundtrack" are the same decision with
/// different packaging, and every caller downstream has to handle both anyway.
public struct StreamPick: Equatable, Sendable {
    public var video: StreamRendition
    /// Nil when `video` carries its own sound.
    public var audio: StreamRendition?

    public init(video: StreamRendition, audio: StreamRendition? = nil) {
        self.video = video
        self.audio = audio
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

    /// The transfer began and then stopped — a segment the server would not
    /// serve, a connection that dropped.
    ///
    /// The one refusal that does not fall back, and the reason is the invariant
    /// the engine is built on: refuse before the first segment byte, or own the
    /// download to completion. Handing a half-transferred download to the
    /// subprocess throws away everything already fetched and starts again from
    /// nothing, which on a large file is minutes of someone's time traded for a
    /// worse outcome than saying so and keeping the bytes.
    ///
    /// Found by testing resume: a stalled download fell back, the fallback
    /// removed the row, and removing the row deleted the partial output the retry
    /// was supposed to continue from. Resume was unreachable by construction and
    /// the invariant was being broken in the same breath.
    case interrupted

    /// Whether handing this to the subprocess is worth trying.
    ///
    /// The distinction that matters most in this type. Everything we cannot do
    /// yet is something yt-dlp may well manage, and should be passed along
    /// quietly. DRM is the one case where it will also fail, slower and with a
    /// worse message, so refusing immediately in a sentence someone wrote is the
    /// better outcome.
    public var allowsFallback: Bool {
        self != .protected && self != .interrupted
    }

    /// Shown only when there is no fallback left. Everything else is invisible,
    /// because a download that succeeds by another route is not an error.
    public var message: String {
        switch self {
        case .protected:
            "This video is protected and can't be saved"
        case .live:
            "This is a live stream, so there's no file to save yet"
        case .interrupted:
            // Says what to do, because unlike the others this one is worth
            // doing: the partial file is kept and a retry carries on from it.
            "The download stopped partway — retry to carry on from here"
        default:
            "Couldn't save this video"
        }
    }
}
