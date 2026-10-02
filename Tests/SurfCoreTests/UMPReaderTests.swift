import Foundation
import Testing
@testable import SurfCore

@Suite("UMP framing")
struct UMPReaderTests {

    private func read(_ raw: [UInt8]) -> Int? {
        var offset = 0
        return UMPReader.varint(in: Data(raw), at: &offset)
    }

    private func read(_ raw: [UInt8], consuming: inout Int) -> Int? {
        var offset = 0
        let value = UMPReader.varint(in: Data(raw), at: &offset)
        consuming = offset
        return value
    }

    // MARK: - The varint, against bytes worked out from the specification
    //
    // Hand-computed rather than round-tripped. A writer of mine would share any
    // misunderstanding with the reader and the pair would agree enthusiastically
    // about the wrong answer — which is exactly what happened to an HLS parser
    // earlier in this branch, where I had written both the fixtures and the code.
    // Each expectation below has its arithmetic beside it.

    @Test("One byte: a clear top bit means the whole byte is the value")
    func oneByte() {
        #expect(read([0x00]) == 0)
        #expect(read([0x01]) == 1)
        #expect(read([0x7F]) == 127)
    }

    @Test("Two bytes: six bits from the first, eight more above them")
    func twoBytes() {
        // 0x80 0x02 — first byte 10000000, so six value bits are 0; second byte
        // 2 shifted left six is 128.
        #expect(read([0x80, 0x02]) == 128)
        // 0xBF 0xFF — 0x3F is 63, plus 255 << 6 = 16320, total 16383.
        #expect(read([0xBF, 0xFF]) == 16383)
        // 0x81 0x00 — one from the first byte, nothing above it.
        #expect(read([0x81, 0x00]) == 1)
    }

    @Test("Three bytes: five bits, then eight, then eight")
    func threeBytes() {
        // 0xC0 0x00 0x01 — 0 | 0 << 5 | 1 << 13 = 8192.
        #expect(read([0xC0, 0x00, 0x01]) == 8192)
        // 0xDF 0xFF 0xFF — 31 | 255 << 5 | 255 << 13 = 31 + 8160 + 2088960.
        #expect(read([0xDF, 0xFF, 0xFF]) == 2_097_151)
    }

    @Test("Four bytes: four bits, then three more bytes")
    func fourBytes() {
        // 0xE0 0x00 0x00 0x01 — 1 << 20 = 1048576.
        #expect(read([0xE0, 0x00, 0x00, 0x01]) == 1_048_576)
        // 0xEF 0xFF 0xFF 0xFF — 15 | 255<<4 | 255<<12 | 255<<20.
        #expect(read([0xEF, 0xFF, 0xFF, 0xFF]) == 15 + 4080 + 1_044_480 + 267_386_880)
    }

    @Test("Five bytes: the first byte carries nothing at all")
    func fiveBytes() {
        // The remaining bits of the first byte are discarded at this size, and
        // the value is a plain little-endian 32-bit integer in the four that
        // follow. So these two must agree despite differing in the first byte.
        #expect(read([0xF0, 0x01, 0x00, 0x00, 0x00]) == 1)
        #expect(read([0xF7, 0x01, 0x00, 0x00, 0x00]) == 1)
        #expect(read([0xF0, 0x00, 0x00, 0x00, 0x01]) == 1 << 24)
        #expect(read([0xF0, 0xFF, 0xFF, 0xFF, 0xFF]) == 4_294_967_295)
    }

    @Test("All five leading bits set is not a length")
    func invalidLength() {
        #expect(read([0xF8]) == nil)
        #expect(read([0xFF, 0, 0, 0, 0, 0]) == nil)
    }

    @Test("Each size consumes exactly its own bytes", arguments: [
        ([UInt8]([0x7F]), 1),
        ([0x80, 0x02], 2),
        ([0xC0, 0x00, 0x01], 3),
        ([0xE0, 0x00, 0x00, 0x01], 4),
        ([0xF0, 0x01, 0x00, 0x00, 0x00], 5),
    ])
    func consumesExactly(_ raw: [UInt8], _ expected: Int) {
        // Off by one here desynchronises every part after the first, which looks
        // like corrupt media rather than a parsing bug.
        var consumed = 0
        _ = read(raw, consuming: &consumed)
        #expect(consumed == expected)
    }

    @Test("A varint cut short is nil rather than a guess", arguments: [
        [UInt8]([0x80]),
        [0xC0, 0x00],
        [0xE0, 0x00, 0x00],
        [0xF0, 0x01, 0x00, 0x00],
        [],
    ])
    func truncatedVarint(_ raw: [UInt8]) {
        #expect(read(raw) == nil)
    }

    @Test("It is not protobuf's varint, and the difference bites above 127")
    func notProtobuf() {
        // The trap this type exists for, and it bites in both directions.
        // Protobuf writes 128 as 0x80 0x01; read as UMP that is 64. UMP writes
        // 128 as 0x80 0x02; read as protobuf that is 256. Either way the next
        // part starts at the wrong offset and the whole stream desynchronises,
        // which surfaces as corrupt media rather than as a parsing error.
        #expect(read([0x80, 0x01]) == 64)
        #expect(read([0x80, 0x02]) == 128)
        // Below 128 the two agree exactly, which is why the mistake survives
        // small test data and fails on real media.
        for small in 0...127 {
            #expect(read([UInt8(small)]) == small)
        }
    }

    // MARK: - Framing

    /// Builds a part the way the specification says, for framing tests. Uses only
    /// one-byte varints so it exercises the framing rather than the varint.
    private func part(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        precondition(type < 128 && payload.count < 128)
        return [type, UInt8(payload.count)] + payload
    }

    @Test("A single part comes back whole")
    func singlePart() throws {
        var reader = UMPReader()
        reader.feed(Data(part(20, [1, 2, 3])))
        // Bound first: `next()` is mutating, and the macro cannot take one.
        let first = reader.next()
        let read = try #require(first)
        #expect(read.type == 20)
        #expect(read.payload == Data([1, 2, 3]))
        #expect(reader.pendingBytes == 0)
        #expect(reader.next() == nil)
    }

    @Test("Parts come back in order")
    func severalParts() {
        var reader = UMPReader()
        reader.feed(Data(part(20, [0xAA]) + part(21, [0x00, 0xBB]) + part(22, [0x00])))
        let parts = reader.parse()
        #expect(parts.map(\.type) == [20, 21, 22])
        #expect(parts[1].payload == Data([0x00, 0xBB]))
    }

    @Test("An empty payload is a part, not an absence")
    func emptyPayload() throws {
        // MEDIA_END is typically a single null byte, and a zero-length part is
        // legal too. Treating either as "nothing more to read" ends the stream
        // early.
        var reader = UMPReader()
        reader.feed(Data(part(22, [])))
        let only = reader.next()
        let read = try #require(only)
        #expect(read.type == 22)
        #expect(read.payload.isEmpty)
    }

    @Test("A part split across feeds is held until it is whole")
    func partSpansFeeds() throws {
        // The case the buffer exists for: a media part cut in half by the end of
        // an HTTP chunk. Yielding the first half would write a fragment and
        // desynchronise everything after it.
        var reader = UMPReader()
        reader.feed(Data([20, 4, 1, 2]))
        #expect(reader.next() == nil)
        #expect(reader.pendingBytes == 4)
        reader.feed(Data([3, 4]))
        let joined = reader.next()
        let read = try #require(joined)
        #expect(read.payload == Data([1, 2, 3, 4]))
        #expect(reader.pendingBytes == 0)
    }

    @Test("A header split across feeds is held too")
    func headerSpansFeeds() throws {
        // Even the length can be cut in half, which is easy to miss because it is
        // rare and silent.
        var reader = UMPReader()
        reader.feed(Data([20]))
        #expect(reader.next() == nil)
        reader.feed(Data([2]))
        #expect(reader.next() == nil)
        reader.feed(Data([9, 9]))
        let joined = try #require(reader.next() as UMPPart?)
        #expect(joined.payload == Data([9, 9]))
    }

    @Test("One byte at a time reads the same as all at once")
    func byteAtATime() {
        let stream = part(20, [1, 2, 3]) + part(21, [0, 4, 5]) + part(22, [0])
        var whole = UMPReader()
        whole.feed(Data(stream))

        var dripped = UMPReader()
        var parts: [UMPPart] = []
        for byte in stream {
            dripped.feed(Data([byte]))
            while let next = dripped.next() { parts.append(next) }
        }
        #expect(parts == whole.parse())
        #expect(dripped.pendingBytes == 0)
    }

    @Test("A truncated stream leaves its bytes pending rather than inventing a part")
    func truncatedStream() {
        var reader = UMPReader()
        reader.feed(Data([20, 10, 1, 2, 3]))
        #expect(reader.parse().isEmpty)
        // Nonzero pending at the end of a stream is how a caller knows it was cut
        // off rather than finished.
        #expect(reader.pendingBytes == 5)
    }

    @Test("A length larger than the stream is waited on, not rejected")
    func hugeLength() {
        // Because a part legitimately spans responses, a length beyond what has
        // arrived is the normal case rather than an error.
        var reader = UMPReader()
        reader.feed(Data([20, 0x81, 0x00]))
        #expect(reader.next() == nil)
        #expect(reader.pendingBytes == 3)
    }

    // MARK: - Media payloads

    @Test("A media part's header id is not part of the media")
    func mediaStripsHeaderID() throws {
        // Media bytes do not start at the beginning of the payload: a varint
        // header id comes first, saying which of the preceding headers these
        // bytes belong to. Writing the payload straight to a file puts that byte
        // in the middle of the video, once per part, a few hundred times a
        // download.
        var reader = UMPReader()
        reader.feed(Data(part(21, [0x00, 0xDE, 0xAD, 0xBE, 0xEF])))
        let only = reader.next()
        let read = try #require(only)
        let media = try #require(read.media)
        #expect(media.headerID == 0)
        #expect(media.bytes == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test("A header id above 127 takes two bytes, and both come off")
    func mediaMultiByteHeaderID() throws {
        var reader = UMPReader()
        reader.feed(Data(part(21, [0x80, 0x02, 0x11, 0x22])))
        let only = reader.next()
        // Not nested: the macro expands recursively.
        let read = try #require(only)
        let media = try #require(read.media)
        #expect(media.headerID == 128)
        #expect(media.bytes == Data([0x11, 0x22]))
    }

    @Test("Only a media part has media in it")
    func mediaOnlyForMediaParts() throws {
        var reader = UMPReader()
        reader.feed(Data(part(20, [0x00, 0x01])))
        let only = try #require(reader.next() as UMPPart?)
        #expect(only.media == nil)
    }

    @Test("A media part with nothing but a header id has no bytes")
    func emptyMedia() throws {
        var reader = UMPReader()
        reader.feed(Data(part(21, [0x00])))
        let only = reader.next()
        let read = try #require(only)
        let media = try #require(read.media)
        #expect(media.headerID == 0)
        #expect(media.bytes.isEmpty)
    }

    // MARK: - Types

    @Test("The parts a download cannot work without are named")
    func namedTypes() {
        #expect(UMPPartType(rawValue: 20) == .mediaHeader)
        #expect(UMPPartType(rawValue: 21) == .media)
        #expect(UMPPartType(rawValue: 22) == .mediaEnd)
        #expect(UMPPartType(rawValue: 42) == .formatInitializationMetadata)
        #expect(UMPPartType(rawValue: 43) == .sabrRedirect)
        #expect(UMPPartType(rawValue: 58) == .streamProtectionStatus)
    }

    @Test("A type nobody named is still carried")
    func unnamedTypesSurvive() throws {
        // Forty-odd types are documented and the stream contains whichever ones
        // YouTube feels like sending. An unrecognised one has to pass through as
        // a number rather than stopping the parse.
        var reader = UMPReader()
        reader.feed(Data(part(67, [1])))
        let only = reader.next()
        let read = try #require(only)
        #expect(read.type == 67)
        #expect(read.kind == nil)
    }
}
