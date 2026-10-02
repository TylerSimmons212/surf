import Foundation
import SurfCore

/// Downloads a YouTube stream by asking its own streaming endpoint for it.
///
/// Everywhere else, Surf reads a manifest and fetches the segments it names.
/// YouTube does not have one any more: every format in a player response arrives
/// with no url and no signature cipher, and the only route to media is a protobuf
/// POST whose answer is a stream of typed parts with audio and video woven
/// together.
///
/// What makes this tractable rather than an arms race is that the expensive parts
/// of that request are copied rather than built. The ustreamer config and the
/// streamer context — which carries the proof-of-origin token — are lifted out of
/// a request the player already made and written back as opaque bytes. YouTube
/// can change what is inside them whenever it likes. A command-line tool has to
/// manufacture both by simulating a browser; a browser simply has them.
///
/// Measured before any of this was written: a request built this way returns
/// media, HTTP 200 and `application/vnd.yt-ump`, carrying our own minimal client
/// state and their two opaque fields.
///
/// **It is sequential, and that is the protocol rather than a shortcoming.** The
/// server decides how much to send per request, so a download is a loop: ask from
/// where we have got to, write what comes back, ask again. The parallel fetcher
/// the rest of the engine uses buys nothing here, which is consistent with
/// yt-dlp's own SABR downloader listing concurrency as unsupported.
@MainActor
enum SABRClient {

    /// How many requests before giving up on a stream that is not progressing.
    ///
    /// A bound rather than a budget. Each round normally returns megabytes, so a
    /// long video takes tens of requests; this is high enough never to be reached
    /// by a working download and low enough that one making no progress stops.
    static let roundLimit = 400

    /// What one video needs, taken from the page.
    struct Session {
        /// The streaming endpoint, already signed by YouTube.
        var url: URL
        /// Copied, never parsed.
        var ustreamerConfig: Data
        /// Copied, never parsed. Carries the proof-of-origin token.
        var streamerContext: Data
        /// What we are asking for, when we have chosen.
        var audioFormats: [Data] = []
        var videoFormats: [Data] = []

        /// The formats the player named, reused as-is.
        ///
        /// Field 2, `initialization_format_ids`, which is what the player
        /// actually sends — not `selected_audio_format_ids` and
        /// `selected_video_format_ids`, which the schema offers at 16 and 17 and
        /// which a real request turned out not to carry at all. Built around the
        /// wrong pair first, on the strength of reading the schema rather than a
        /// request.
        var formats: [Data]

        /// Picks the best pair AVFoundation can actually read.
        ///
        /// Without this the server chooses, and on a real download it chose 144p
        /// VP9 in WebM — which arrived complete and then would not mux, because
        /// AVFoundation reads neither WebM nor VP9. The quality was an accident
        /// too: nothing had asked for anything.
        ///
        /// MP4 only, therefore, and the tallest of those. Falls back to whatever
        /// is on offer if nothing is MP4, where the mux will fail honestly rather
        /// than this refusing to try.
        static func choose(
            from formats: [StreamTap.Format], maxHeight: Int? = nil
        ) -> (video: StreamTap.Format, audio: StreamTap.Format)? {
            let usable = formats.filter { $0.revision != nil }
            let videos = usable.filter { $0.isVideo && $0.isMP4 }
            let audios = usable.filter { $0.isAudio && $0.isMP4 }
            guard !videos.isEmpty, !audios.isEmpty else { return nil }

            let eligible = maxHeight.map { cap in videos.filter { $0.height <= cap } } ?? videos
            var candidates = eligible.isEmpty ? videos : eligible

            // Codec before resolution, which is the opposite of what every other
            // choice in this engine does.
            //
            // Not a technical limit — ffmpeg muxes the 2160p AV1 this would
            // otherwise pick, and does it in a second. A preference: a file
            // someone downloaded from a browser should play in whatever they open
            // it with, and H.264 plays everywhere while AV1 needs a recent
            // machine. It is also a third of the size for the same video, 224MB
            // against 543MB on the one measured here.
            //
            // On YouTube this usually means 1080p rather than 2160p, which is the
            // real cost of the choice and worth stating rather than hiding.
            for codec in ["avc1", "avc3", "hvc1", "hev1"] {
                let readable = candidates.filter { $0.mimeType.contains(codec) }
                if !readable.isEmpty { candidates = readable; break }
            }

            guard let video = candidates.max(by: { a, b in
                a.height != b.height ? a.height < b.height : a.bitrate < b.bitrate
            }) else { return nil }
            // The best sound available: it is a fraction of the video's size, so
            // there is nothing to save by taking less.
            guard let audio = audios.max(by: { $0.bitrate < $1.bitrate }) else { return nil }
            return (video, audio)
        }

        /// Reads a captured request rather than building one.
        ///
        /// Everything here is lifted out of bytes the player sent. Taking the
        /// format ids from it too means the request differs from a working one in
        /// exactly one way — our own minimal client state — which is the smallest
        /// difference that can be wrong.
        init?(capturedRequest: Data, url: URL) {
            let fields = Protobuf.fields(in: capturedRequest)
            func opaque(_ number: Int) -> Data? {
                fields.last { $0.number == number }?.value.data
            }
            func all(_ number: Int) -> [Data] {
                fields.filter { $0.number == number }.compactMap { $0.value.data }
            }
            guard let config = opaque(5), let context = opaque(19) else { return nil }
            self.url = url
            self.ustreamerConfig = config
            self.streamerContext = context
            // Not required. A request carrying neither these nor any format ids
            // was measured returning media, so the server is content to choose —
            // and demanding them here rejected a request that would have worked.
            self.formats = all(2)
        }
    }

    /// One round's worth of what came back.
    struct Round {
        /// Media bytes, keyed by the header id they belong to.
        var media: [Int: Data] = [:]
        /// Headers seen this round, by id.
        var headers: [Int: SABR.MediaHeader] = [:]
        /// What each itag turned out to be, from the server rather than the
        /// request. A `FormatId` says which rendition but not whether it is
        /// picture or sound; the initialisation metadata carries the mime type,
        /// which is the only thing in the exchange that does.
        var mimeTypes: [Int: String] = [:]
        /// The server wants us somewhere else. Not a failure.
        var redirect: URL?
        var protection: SABR.ProtectionStatus?
        var hadError = false
        var sawEnd = false
    }

    /// Sends one request and reads its answer.
    static func round(
        _ session: Session,
        from startMs: Int,
        buffered: [Data],
        with fetcher: SegmentFetcher
    ) async -> Round? {
        var writer = Protobuf.Writer()
        // Our own client state, deliberately two fields where the player sends
        // twenty-one. Measured as accepted: the extra twenty describe a player
        // adapting to a living network, and inventing them would be describing a
        // client that does not exist.
        writer.message(1) { state in
            state.varint(28, startMs)
            state.varint(40, SABR.TrackTypes.both.rawValue)
        }
        // `selected_*_format_ids` where the player sends
        // `initialization_format_ids`, because these are a choice rather than a
        // description of what is already loaded, and choosing is the whole point.
        for format in session.audioFormats { writer.message(16, format) }
        for format in session.videoFormats { writer.message(17, format) }
        for format in session.formats { writer.message(2, format) }
        for range in buffered { writer.message(3, range) }
        writer.varint(4, startMs)
        writer.bytes(5, session.ustreamerConfig)
        writer.message(19, session.streamerContext)

        guard let data = await fetcher.post(writer.data, to: session.url) else {
            return nil
        }

        var reader = UMPReader()
        reader.feed(data)
        var round = Round()
        for part in reader.parse() {
            switch part.kind {
            case .mediaHeader:
                if let header = SABR.MediaHeader.decoded(part.payload) {
                    round.headers[header.headerID] = header
                }
            case .media:
                if let (id, bytes) = part.media, !bytes.isEmpty {
                    round.media[id, default: Data()].append(bytes)
                }
            case .mediaEnd:
                round.sawEnd = true
            case .sabrRedirect:
                round.redirect = SABR.Redirect.decoded(part.payload)
                    .flatMap { URL(string: $0.url) }
            case .streamProtectionStatus:
                round.protection = SABR.ProtectionStatus.decoded(part.payload)
            case .formatInitializationMetadata:
                let meta = SABR.FormatInitialization.decoded(part.payload)
                if let itag = meta.formatID?.itag, let mime = meta.mimeType {
                    round.mimeTypes[itag] = mime
                }
            case .sabrError:
                round.hadError = true
            default:
                // Forty-odd part types exist and the stream carries whichever
                // ones YouTube feels like sending. Anything unrecognised is
                // skipped rather than treated as a problem.
                break
            }
        }
        // Bytes left over mean the response ended mid-part, which for a single
        // complete HTTP body is a truncated answer rather than a part spanning
        // responses.
        if reader.pendingBytes > 0 {
            debugLog("sabr: \(reader.pendingBytes) bytes left unframed")
        }
        return round
    }
}
