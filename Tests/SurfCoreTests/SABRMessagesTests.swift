import Foundation
import Testing
@testable import SurfCore

@Suite("SABR messages")
struct SABRMessagesTests {

    private let config = Data([0xC0, 0xFF, 0xEE, 0x00, 0x11])

    // MARK: - The request, checked field by field against the schema

    @Test("A request puts each thing in the field the schema names")
    func requestFieldNumbers() throws {
        // Checked by number rather than by round trip, because the numbers are
        // the entire contract with a server that will simply refuse anything
        // else. A round trip through my own writer and reader would agree about
        // whatever I had got wrong.
        let request = SABR.PlaybackRequest(
            clientState: .init(playerTimeMs: 0, enabledTrackTypes: SABR.TrackTypes.both.rawValue),
            ustreamerConfig: config,
            videoFormats: [.init(itag: 136, lastModified: 1_689_000_000_000_000)],
            audioFormats: [.init(itag: 140, lastModified: 1_689_000_000_000_001)],
            mediaStartTimeMs: 0
        )
        let fields = Protobuf.fields(in: request.encoded)
        let numbers = Set(fields.map(\.number))

        #expect(numbers.contains(1))   // client_abr_state
        #expect(numbers.contains(4))   // media_start_time_ms
        #expect(numbers.contains(5))   // video_playback_ustreamer_config
        #expect(numbers.contains(16))  // selected_audio_format_ids
        #expect(numbers.contains(17))  // selected_video_format_ids
        // Nothing invented. A request describing a client that does not exist is
        // a request a server can notice.
        #expect(numbers == [1, 4, 5, 16, 17])
    }

    @Test("The config is carried byte for byte and never parsed")
    func configIsOpaque() throws {
        // The field the whole approach rests on. It is declared `bytes` in the
        // schema, so YouTube may change its contents whenever it likes, and
        // copying it out of the page and back in is correct regardless.
        let request = SABR.PlaybackRequest(
            clientState: .init(), ustreamerConfig: config
        )
        #expect(Protobuf.value(5, in: request.encoded)?.data == config)
    }

    @Test("A config with bytes that look like protobuf is still just bytes")
    func configIsNotReinterpreted() throws {
        // A real config is base64 of something structured, so its bytes parse as
        // protobuf by coincidence. Anything that tried to normalise it would
        // re-encode it differently and the server would reject it.
        var looksLikeAMessage = Protobuf.Writer()
        looksLikeAMessage.varint(1, 42)
        looksLikeAMessage.string(2, "not ours to read")
        let request = SABR.PlaybackRequest(
            clientState: .init(), ustreamerConfig: looksLikeAMessage.data
        )
        #expect(Protobuf.value(5, in: request.encoded)?.data == looksLikeAMessage.data)
    }

    @Test("The streamer context is carried opaquely too, when there is one")
    func streamerContextIsOpaque() throws {
        let context = Data([1, 2, 3, 4, 5])
        let with = SABR.PlaybackRequest(
            clientState: .init(), ustreamerConfig: config, streamerContext: context
        )
        #expect(Protobuf.value(19, in: with.encoded)?.data == context)

        // And omitted entirely when absent, rather than sent empty. An empty
        // message and a missing one are different things to a server.
        let without = SABR.PlaybackRequest(clientState: .init(), ustreamerConfig: config)
        #expect(Protobuf.value(19, in: without.encoded) == nil)
    }

    @Test("Several formats are several fields, not the last one")
    func repeatedFormats() throws {
        // `selected_video_format_ids` is repeated. A writer that overwrote would
        // ask for one rendition out of the several offered and look like it
        // worked.
        let request = SABR.PlaybackRequest(
            clientState: .init(),
            ustreamerConfig: config,
            videoFormats: [
                .init(itag: 136, lastModified: 1),
                .init(itag: 137, lastModified: 2),
            ]
        )
        #expect(Protobuf.values(17, in: request.encoded).count == 2)
    }

    // MARK: - The number that would have been wrong

    @Test("lastModified survives being a value a Double cannot hold")
    func lastModifiedPrecision() throws {
        // Around 1.7×10¹⁸, well past the 2⁵³ where a Double stops holding
        // integers exactly. Reading it out of JSON as a number drops the low
        // digits, and the server then rejects the request for a reason that
        // looks like anything else. Carried as UInt64 end to end.
        let exact: UInt64 = 1_689_123_456_789_012_345
        #expect(UInt64(Double(exact)) != exact, "the premise: a Double loses this")

        let format = SABR.FormatID(itag: 136, lastModified: exact)
        let decoded = try #require(SABR.FormatID.decoded(format.encoded))
        #expect(decoded.lastModified == exact)
        #expect(decoded.itag == 136)
    }

    @Test("A format id round trips through the wire")
    func formatIDRoundTrip() throws {
        let original = SABR.FormatID(itag: 251, lastModified: 1_700_000_000_000_001, xtags: "a=b")
        let decoded = try #require(SABR.FormatID.decoded(original.encoded))
        #expect(decoded == original)
    }

    @Test("Track types are the bitfield the schema wants")
    func trackTypes() {
        #expect(SABR.TrackTypes.audio.rawValue == 1)
        #expect(SABR.TrackTypes.video.rawValue == 2)
        #expect(SABR.TrackTypes.both.rawValue == 3)
    }

    @Test("Client state writes the two fields that matter and nothing else")
    func clientStateIsMinimal() {
        let state = SABR.ClientABRState(playerTimeMs: 4000, enabledTrackTypes: 3)
        let fields = Protobuf.fields(in: state.encoded)
        #expect(Set(fields.map(\.number)) == [28, 40])
        #expect(Protobuf.value(28, in: state.encoded)?.int == 4000)
        #expect(Protobuf.value(40, in: state.encoded)?.int == 3)
    }

    // MARK: - Reading what comes back

    @Test("A media header says which stream and which segment")
    func mediaHeader() throws {
        var writer = Protobuf.Writer()
        writer.varint(1, 3)                      // header_id
        writer.varint(3, 136)                    // itag
        writer.varint(4, 1_689_123_456_789_012_345) // lmt
        writer.varint(9, 7)                      // segment_num
        writer.varint(11, 28_000)                // start_ms
        writer.varint(12, 4_000)                 // duration_ms
        writer.varint(14, 1_234_567)             // segment_length_bytes

        let header = try #require(SABR.MediaHeader.decoded(writer.data))
        #expect(header.headerID == 3)
        #expect(header.itag == 136)
        #expect(header.lastModified == 1_689_123_456_789_012_345)
        #expect(header.segmentNumber == 7)
        #expect(header.startMs == 28_000)
        #expect(header.durationMs == 4_000)
        #expect(header.segmentLengthBytes == 1_234_567)
        #expect(!header.isInitializationSegment)
    }

    @Test("An absent bool is false, which is the difference between a header and corruption")
    func absentBoolIsFalse() throws {
        // Protobuf omits a false optional bool entirely. Reading absence as
        // anything else means writing the initialisation segment into the middle
        // of the video, or never writing it at all.
        var without = Protobuf.Writer()
        without.varint(1, 0)
        #expect(try #require(SABR.MediaHeader.decoded(without.data)).isInitializationSegment
            == false)

        var with = Protobuf.Writer()
        with.varint(1, 0)
        with.bool(8, true)
        #expect(try #require(SABR.MediaHeader.decoded(with.data)).isInitializationSegment)
    }

    @Test("A media header with no id at all is refused")
    func mediaHeaderNeedsAnID() {
        // Without it the media parts cannot be tied to anything, so the header is
        // useless rather than partially useful.
        var writer = Protobuf.Writer()
        writer.varint(3, 136)
        #expect(SABR.MediaHeader.decoded(writer.data) == nil)
    }

    @Test("A header id of zero is a real id")
    func headerIDZero() throws {
        // And the common one, which makes it exactly the value a truthiness check
        // would discard.
        var writer = Protobuf.Writer()
        writer.varint(1, 0)
        #expect(try #require(SABR.MediaHeader.decoded(writer.data)).headerID == 0)
    }

    @Test("A redirect is a destination, not a failure")
    func redirect() throws {
        // Worth its own test because it looks like an error and is not: the first
        // answer to a streaming request is very often this, and treating it as a
        // failure would mean concluding the protocol does not work.
        var writer = Protobuf.Writer()
        writer.string(1, "https://rr3---sn-example.googlevideo.com/videoplayback?x=1")
        let redirect = try #require(SABR.Redirect.decoded(writer.data))
        #expect(redirect.url.hasPrefix("https://rr3---"))
    }

    @Test("A redirect to nowhere is not a redirect")
    func emptyRedirect() {
        var writer = Protobuf.Writer()
        writer.string(1, "")
        #expect(SABR.Redirect.decoded(writer.data) == nil)
        #expect(SABR.Redirect.decoded(Data()) == nil)
    }

    @Test("Protection status distinguishes malformed from unattested")
    func protectionStatus() throws {
        // The field that matters when it fails. "Your request was wrong" and "you
        // need a proof-of-origin token" look identical from outside and have
        // completely different answers.
        var ok = Protobuf.Writer()
        ok.varint(1, 1)
        #expect(try #require(SABR.ProtectionStatus.decoded(ok.data)).status == .ok)

        var required = Protobuf.Writer()
        required.varint(1, 3)
        #expect(try #require(SABR.ProtectionStatus.decoded(required.data)).status
            == .attestationRequired)
    }

    @Test("A status nobody has seen before is carried as its number")
    func unknownStatus() throws {
        var writer = Protobuf.Writer()
        writer.varint(1, 99)
        let status = try #require(SABR.ProtectionStatus.decoded(writer.data))
        #expect(status.raw == 99)
        // Unmapped rather than guessed, so a log says 99 instead of claiming OK.
        #expect(status.status == nil)
    }

    @Test("Format initialization carries the format and its mime type")
    func formatInitialization() throws {
        var inner = Protobuf.Writer()
        inner.varint(1, 136)
        inner.varint(2, 1_689_000_000_000_000)

        var writer = Protobuf.Writer()
        writer.string(1, "aqz-KE-bpKQ")
        writer.message(2, inner.data)
        writer.varint(3, 634_601)
        writer.varint(4, 159)
        writer.string(5, "video/mp4; codecs=\"avc1.4d401f\"")

        let meta = SABR.FormatInitialization.decoded(writer.data)
        #expect(meta.formatID?.itag == 136)
        #expect(meta.formatID?.lastModified == 1_689_000_000_000_000)
        #expect(meta.mimeType?.hasPrefix("video/mp4") == true)
        #expect(meta.endTimeMs == 634_601)
        #expect(meta.endSegmentNumber == 159)
    }

    // MARK: - Nothing here traps

    @Test("Garbage decodes to nothing rather than crashing", arguments: [
        [UInt8]([]),
        [0x08],
        [0xFF, 0xFF, 0xFF],
        Array(repeating: 0xFF, count: 40),
        [0x12, 0x7F, 0x01],
    ])
    func garbage(_ raw: [UInt8]) {
        let data = Data(raw)
        // Each of these is bytes a hostile or simply changed server could send.
        _ = SABR.MediaHeader.decoded(data)
        _ = SABR.Redirect.decoded(data)
        _ = SABR.ProtectionStatus.decoded(data)
        _ = SABR.FormatID.decoded(data)
        _ = SABR.FormatInitialization.decoded(data)
        _ = SABR.StreamError.decoded(data)
        #expect(Bool(true), "none of the decoders trapped")
    }

    @Test("A message with fields we do not know keeps the ones we do")
    func unknownFieldsIgnored() throws {
        // The protocol gains fields on YouTube's schedule. A decoder that failed
        // on an unexpected one would break on a Tuesday for no reason.
        var writer = Protobuf.Writer()
        writer.varint(1, 2)
        writer.varint(777, 1)
        writer.string(888, "something new")
        writer.varint(3, 251)
        let header = try #require(SABR.MediaHeader.decoded(writer.data))
        #expect(header.headerID == 2)
        #expect(header.itag == 251)
    }
}
