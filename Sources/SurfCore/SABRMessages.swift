import Foundation

/// The messages YouTube's streaming protocol is made of — the few of them a
/// download needs.
///
/// Eight of about forty, and the restraint is the design. The protocol is
/// undocumented and changes on YouTube's schedule, so every message understood
/// here is a thing that can break; every message left alone cannot. What is
/// written is the request, because we have to ask for something specific. What is
/// read is whatever says where the bytes are and whether we are allowed them.
///
/// **Field numbers come from LuanRT's `googlevideo`, which is MIT licensed and
/// maintained.** They are reproduced rather than vendored: this is a hundred
/// lines of Swift against a TypeScript library with its own build, and the field
/// numbers are the only part that matters.
///
/// **The two fields that would otherwise be an arms race are never parsed.** The
/// ustreamer config is declared `bytes` in the schema and the streamer context
/// carries a proof-of-origin token; both are lifted out of what the page already
/// has and written back as opaque blobs. YouTube can change their insides freely.
/// That is the whole reason a browser is a better place to do this than a
/// command-line tool, which has to manufacture both from nothing.
public enum SABR {

    // MARK: - What identifies a stream

    /// Which rendition, at which revision.
    ///
    /// `lastModified` is a `uint64` around 1.7×10¹⁸, past the point a `Double`
    /// holds integers exactly. Reading it out of JSON as a number silently drops
    /// the low digits and the server rejects the request for a reason that looks
    /// like anything else, so it is carried as a `UInt64` from end to end.
    public struct FormatID: Equatable, Sendable {
        public var itag: Int
        public var lastModified: UInt64
        public var xtags: String?

        public init(itag: Int, lastModified: UInt64, xtags: String? = nil) {
            self.itag = itag
            self.lastModified = lastModified
            self.xtags = xtags
        }

        var encoded: Data {
            var writer = Protobuf.Writer()
            writer.varint(1, itag)
            writer.varint(2, lastModified)
            if let xtags { writer.string(3, xtags) }
            return writer.data
        }

        static func decoded(_ data: Data) -> FormatID? {
            guard let itag = Protobuf.value(1, in: data)?.int else { return nil }
            guard case .varint(let lastModified) = Protobuf.value(2, in: data) ?? .varint(0)
            else { return nil }
            return FormatID(
                itag: itag, lastModified: lastModified,
                xtags: Protobuf.value(3, in: data)?.text
            )
        }
    }

    /// What of a stream is already held, so the server does not send it again.
    public struct BufferedRange: Equatable, Sendable {
        public var formatID: FormatID
        public var startTimeMs: Int
        public var durationMs: Int
        public var startSegmentIndex: Int
        public var endSegmentIndex: Int

        public init(
            formatID: FormatID, startTimeMs: Int = 0, durationMs: Int = 0,
            startSegmentIndex: Int = 0, endSegmentIndex: Int = 0
        ) {
            self.formatID = formatID
            self.startTimeMs = startTimeMs
            self.durationMs = durationMs
            self.startSegmentIndex = startSegmentIndex
            self.endSegmentIndex = endSegmentIndex
        }

        var encoded: Data {
            var writer = Protobuf.Writer()
            writer.message(1, formatID.encoded)
            writer.varint(2, startTimeMs)
            writer.varint(3, durationMs)
            writer.varint(4, startSegmentIndex)
            writer.varint(5, endSegmentIndex)
            return writer.data
        }
    }

    // MARK: - The request

    /// What a client says about itself and where it is in the video.
    ///
    /// Numbered from 13, which is not a mistake: the message has no fields below
    /// it. Almost everything is omitted — this is a download rather than a player
    /// adapting to a living network, so viewport sizes and bandwidth estimates
    /// describe nothing real and sending invented ones would be describing a
    /// client that does not exist.
    public struct ClientABRState: Equatable, Sendable {
        /// Where playback is, in milliseconds. For a download, where we have got
        /// to.
        public var playerTimeMs: Int
        /// Which kinds of track to send. A bitfield, and the one field here that
        /// must be right: leave it out and the server has no reason to send
        /// anything.
        public var enabledTrackTypes: Int

        public init(playerTimeMs: Int = 0, enabledTrackTypes: Int = 0) {
            self.playerTimeMs = playerTimeMs
            self.enabledTrackTypes = enabledTrackTypes
        }

        var encoded: Data {
            var writer = Protobuf.Writer()
            writer.varint(28, playerTimeMs)
            writer.varint(40, enabledTrackTypes)
            return writer.data
        }
    }

    /// One request for media.
    ///
    /// Everything optional is left out. A request carrying only what it needs is
    /// both smaller to be wrong about and easier to read in a log next to one
    /// the player made.
    public struct PlaybackRequest: Sendable {
        public var clientState: ClientABRState
        /// Copied verbatim from the page, never parsed. Declared `bytes` in the
        /// schema, so YouTube is free to change its contents and this stays
        /// correct.
        public var ustreamerConfig: Data
        /// Likewise opaque. Carries the proof-of-origin token, which a browser
        /// already has and a command-line tool has to simulate a browser to get.
        public var streamerContext: Data?
        public var videoFormats: [FormatID]
        public var audioFormats: [FormatID]
        public var bufferedRanges: [BufferedRange]
        public var mediaStartTimeMs: Int

        public init(
            clientState: ClientABRState,
            ustreamerConfig: Data,
            streamerContext: Data? = nil,
            videoFormats: [FormatID] = [],
            audioFormats: [FormatID] = [],
            bufferedRanges: [BufferedRange] = [],
            mediaStartTimeMs: Int = 0
        ) {
            self.clientState = clientState
            self.ustreamerConfig = ustreamerConfig
            self.streamerContext = streamerContext
            self.videoFormats = videoFormats
            self.audioFormats = audioFormats
            self.bufferedRanges = bufferedRanges
            self.mediaStartTimeMs = mediaStartTimeMs
        }

        public var encoded: Data {
            var writer = Protobuf.Writer()
            writer.message(1, clientState.encoded)
            for range in bufferedRanges { writer.message(3, range.encoded) }
            writer.varint(4, mediaStartTimeMs)
            writer.bytes(5, ustreamerConfig)
            for format in audioFormats { writer.message(16, format.encoded) }
            for format in videoFormats { writer.message(17, format.encoded) }
            if let streamerContext { writer.message(19, streamerContext) }
            return writer.data
        }
    }

    /// Which track types to ask for, as the bitfield field 40 wants.
    public struct TrackTypes: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let audio = TrackTypes(rawValue: 1)
        public static let video = TrackTypes(rawValue: 2)
        public static let both: TrackTypes = [.audio, .video]
    }

    // MARK: - What comes back

    /// Describes the media bytes that follow it.
    ///
    /// The part a download is built on: it says which format these bytes are,
    /// which segment, where it starts and how long it runs. Without it the media
    /// parts are bytes with no idea which of two interleaved streams they belong
    /// to.
    public struct MediaHeader: Equatable, Sendable {
        /// Ties the following media parts to this header.
        public var headerID: Int
        public var itag: Int?
        public var lastModified: UInt64?
        public var isInitializationSegment: Bool
        public var segmentNumber: Int?
        public var startMs: Int?
        public var durationMs: Int?
        public var segmentLengthBytes: Int?
        public var byteRangeStart: Int?

        public static func decoded(_ data: Data) -> MediaHeader? {
            let fields = Protobuf.fields(in: data)
            func value(_ number: Int) -> Protobuf.Value? {
                fields.last { $0.number == number }?.value
            }
            guard let headerID = value(1)?.int else { return nil }

            var lastModified: UInt64?
            if case .varint(let raw) = value(4) { lastModified = raw }

            return MediaHeader(
                headerID: headerID,
                itag: value(3)?.int,
                lastModified: lastModified,
                // Absent means false, which is protobuf's rule for an optional
                // bool and the difference between writing the header once and
                // writing it in the middle of the video.
                isInitializationSegment: (value(8)?.int ?? 0) != 0,
                segmentNumber: value(9)?.int,
                startMs: value(11)?.int,
                durationMs: value(12)?.int,
                segmentLengthBytes: value(14)?.int,
                byteRangeStart: value(6)?.int
            )
        }

        init(
            headerID: Int, itag: Int?, lastModified: UInt64?,
            isInitializationSegment: Bool, segmentNumber: Int?, startMs: Int?,
            durationMs: Int?, segmentLengthBytes: Int?, byteRangeStart: Int?
        ) {
            self.headerID = headerID
            self.itag = itag
            self.lastModified = lastModified
            self.isInitializationSegment = isInitializationSegment
            self.segmentNumber = segmentNumber
            self.startMs = startMs
            self.durationMs = durationMs
            self.segmentLengthBytes = segmentLengthBytes
            self.byteRangeStart = byteRangeStart
        }
    }

    /// What makes a format's bytes into a file: where its header and its index
    /// live, and how long the whole thing is.
    public struct FormatInitialization: Equatable, Sendable {
        public var formatID: FormatID?
        public var mimeType: String?
        public var endTimeMs: Int?
        public var endSegmentNumber: Int?

        public static func decoded(_ data: Data) -> FormatInitialization {
            FormatInitialization(
                formatID: Protobuf.value(2, in: data)?.data.flatMap(FormatID.decoded),
                mimeType: Protobuf.value(5, in: data)?.text,
                endTimeMs: Protobuf.value(3, in: data)?.int,
                endSegmentNumber: Protobuf.value(4, in: data)?.int
            )
        }
    }

    /// Ask that host instead.
    ///
    /// Not an error, and worth saying because it looks like one: the first answer
    /// to a streaming request is very often a redirect, and treating it as a
    /// failure would mean concluding the protocol does not work on the first try.
    public struct Redirect: Equatable, Sendable {
        public var url: String

        public static func decoded(_ data: Data) -> Redirect? {
            guard let url = Protobuf.value(1, in: data)?.text, !url.isEmpty else {
                return nil
            }
            return Redirect(url: url)
        }
    }

    /// Whether the request was accepted as coming from a real client.
    ///
    /// The field a download needs when it fails: it distinguishes "your request
    /// was malformed" from "you need a proof-of-origin token", which otherwise
    /// look identical from outside and have completely different answers.
    public struct ProtectionStatus: Equatable, Sendable {
        public enum Status: Int, Sendable {
            case unknown = 0
            case ok = 1
            case attestationPending = 2
            case attestationRequired = 3
        }

        public var raw: Int
        public var status: Status? { Status(rawValue: raw) }

        public static func decoded(_ data: Data) -> ProtectionStatus? {
            guard let raw = Protobuf.value(1, in: data)?.int else { return nil }
            return ProtectionStatus(raw: raw)
        }
    }

    /// Something went wrong, in the server's own words.
    public struct StreamError: Equatable, Sendable {
        public var code: Int?

        public static func decoded(_ data: Data) -> StreamError {
            StreamError(code: Protobuf.value(1, in: data)?.int)
        }
    }
}
