import Foundation

/// What a manifest says is available, with no trace of which kind of manifest
/// said it.
///
/// This type is the whole reason the HLS and DASH parsers can live in `SurfCore`
/// and everything downstream can live anywhere. The planner, the schedule, the
/// fetcher and the assembler each see exactly one shape, so adding a second
/// manifest format is a parser and nothing else.
///
/// That is a testable claim, and it is the acceptance criterion for this design:
/// **adding DASH should require no new code outside `SurfCore`.** If it does, the
/// boundary was drawn in the wrong place and this type is the thing to fix.
public struct StreamIndex: Equatable, Sendable {

    /// Every stream the manifest offered, in the order it offered them.
    ///
    /// Unfiltered on purpose. Deciding which one to take is `StreamPlan`'s job,
    /// and a parser that drops what it thinks is uninteresting cannot be tested
    /// against the manifest it was given.
    public var renditions: [StreamRendition]

    public var protection: StreamProtection

    /// A stream with no end. There is no whole file to produce from one, which
    /// makes it a refusal rather than a hard download.
    public var isLive: Bool

    /// Seconds, when the manifest states or implies a total. Nil for a master
    /// playlist, which lists variants and leaves their contents to be fetched.
    public var declaredDuration: Double?

    public init(
        renditions: [StreamRendition],
        protection: StreamProtection = .none,
        isLive: Bool = false,
        declaredDuration: Double? = nil
    ) {
        self.renditions = renditions
        self.protection = protection
        self.isLive = isLive
        self.declaredDuration = declaredDuration
    }

    /// True when the renditions are pointers to other manifests rather than
    /// lists of segments — an HLS master, or a DASH manifest whose
    /// representations have not been expanded yet.
    ///
    /// The caller's signal to fetch and parse again, which is why HLS needs two
    /// passes through the same function rather than two functions.
    public var needsSecondPass: Bool {
        !renditions.isEmpty && renditions.allSatisfy { $0.segments.isEmpty }
    }
}

/// One playable stream: a quality of video, a language of audio, or both at once.
public struct StreamRendition: Equatable, Sendable, Identifiable {

    /// What the manifest called it. For logs and for choosing between two
    /// otherwise identical entries, never parsed for meaning.
    public var id: String

    public var role: Role
    public var container: StreamContainer

    /// Where to fetch this rendition's own manifest, when it has one. Nil once
    /// `segments` is populated.
    public var manifestURL: URL?

    public var width: Int?
    public var height: Int?
    /// Bits per second, as declared. Peak where the manifest offers both peak
    /// and average, because that is what a player would plan against.
    public var bandwidth: Int?
    /// The manifest's own codec string, `avc1.640028,mp4a.40.2`. Kept verbatim
    /// rather than parsed: it is what tells a muxer what it is about to be
    /// handed, and every attempt to normalise it loses something.
    public var codecs: String?

    /// Which audio rendition group this video variant expects, for HLS. The
    /// linkage that says a video-only stream has a separate soundtrack and which
    /// one.
    public var audioGroup: String?

    /// The header that makes the segments mean anything. Concatenating it with
    /// them produces a file AVFoundation reads directly, which is why fMP4
    /// assembly is not a remux.
    public var initSegment: StreamSegment?

    public var segments: [StreamSegment]

    public init(
        id: String,
        role: Role,
        container: StreamContainer = .unknown,
        manifestURL: URL? = nil,
        width: Int? = nil,
        height: Int? = nil,
        bandwidth: Int? = nil,
        codecs: String? = nil,
        audioGroup: String? = nil,
        initSegment: StreamSegment? = nil,
        segments: [StreamSegment] = []
    ) {
        self.id = id
        self.role = role
        self.container = container
        self.manifestURL = manifestURL
        self.width = width
        self.height = height
        self.bandwidth = bandwidth
        self.codecs = codecs
        self.audioGroup = audioGroup
        self.initSegment = initSegment
        self.segments = segments
    }

    public enum Role: Equatable, Sendable {
        /// Picture and sound in one stream. The easy case, and the only one that
        /// needs no muxer.
        case muxed
        case video
        case audio
        /// Subtitles and anything else not being saved yet.
        case other
    }

    /// Seconds, summed from the segments. Zero before a second pass.
    public var duration: Double {
        segments.reduce(0) { $0 + $1.duration }
    }
}

/// One fetch.
public struct StreamSegment: Equatable, Sendable {
    public var url: URL
    /// Seconds. Zero for an init segment, which has no playable length, and the
    /// reason progress is weighted by this rather than counted by segment.
    public var duration: Double
    /// Byte offsets within `url`, when several segments share one file. HLS
    /// calls this `EXT-X-BYTERANGE` and DASH calls it `SegmentBase`; both mean
    /// the fetch is a ranged request.
    public var byteRange: Range<Int>?

    public init(url: URL, duration: Double = 0, byteRange: Range<Int>? = nil) {
        self.url = url
        self.duration = duration
        self.byteRange = byteRange
    }
}

/// What the segments are wrapped in, which decides whether we can assemble them
/// ourselves.
public enum StreamContainer: Equatable, Sendable {
    /// Fragmented MP4, which CMAF standardised and which is now most of the web.
    /// Concatenating the init segment and the media segments produces a file
    /// AVFoundation parses, so this case needs no external tool.
    case fragmentedMP4
    /// The legacy transport stream. AVFoundation will not read it, so this goes
    /// to ffmpeg.
    case mpegTS
    /// AVFoundation will neither read nor write it.
    case webm
    case unknown
}

/// Whether anything stands between the segments and a playable file.
public enum StreamProtection: Equatable, Sendable {
    case none
    /// AES-128 with a key the manifest names and anyone may fetch. Not DRM, and
    /// plenty of ordinary sites use it. Out of scope for now, but a refusal
    /// rather than a reason to stop trying.
    case fetchableKey
    /// FairPlay, Widevine, PlayReady. The bytes are encrypted before they reach
    /// the decoder and there is no key to fetch. Refused on purpose and
    /// permanently.
    case protected
}
