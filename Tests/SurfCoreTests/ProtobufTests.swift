import Foundation
import Testing
@testable import SurfCore

@Suite("Protobuf wire format")
struct ProtobufTests {

    private func bytes(_ values: [UInt8]) -> Data { Data(values) }

    // MARK: - Against bytes nobody here produced
    //
    // These are the worked examples from protobuf's own wire-format
    // documentation. Testing an encoder against its matching decoder proves only
    // that they agree, which is exactly the mistake that let an HLS parser ship
    // with a wrong idea about CODECS: I had written the fixtures as well as the
    // parser, so they shared the misunderstanding. Known-good bytes from the
    // specification cannot.

    @Test("Field 1 holding 150 is 08 96 01")
    func canonicalVarint() throws {
        let fields = Protobuf.fields(in: bytes([0x08, 0x96, 0x01]))
        #expect(fields.count == 1)
        #expect(fields.first?.number == 1)
        #expect(fields.first?.value == .varint(150))
    }

    @Test("Field 2 holding \"testing\" is 12 07 then the ASCII")
    func canonicalString() throws {
        let encoded = bytes([0x12, 0x07, 0x74, 0x65, 0x73, 0x74, 0x69, 0x6e, 0x67])
        let field = try #require(Protobuf.fields(in: encoded).first)
        #expect(field.number == 2)
        #expect(field.value.text == "testing")
    }

    @Test("A nested message is length-delimited bytes that parse again")
    func canonicalNested() throws {
        // 1a 03 08 96 01 — field 3, three bytes, and those three bytes are the
        // first example. That a message and a byte string are indistinguishable
        // on the wire is the property the whole SABR strategy rests on.
        let inner = try #require(Protobuf.value(3, in: bytes([0x1a, 0x03, 0x08, 0x96, 0x01]))?.data)
        #expect(Protobuf.value(1, in: inner) == .varint(150))
    }

    @Test("Writing the canonical examples produces the canonical bytes")
    func writesCanonicalBytes() {
        var writer = Protobuf.Writer()
        writer.varint(1, 150)
        #expect(Array(writer.data) == [0x08, 0x96, 0x01])

        var second = Protobuf.Writer()
        second.string(2, "testing")
        #expect(Array(second.data) == [0x12, 0x07, 0x74, 0x65, 0x73, 0x74, 0x69, 0x6e, 0x67])

        var third = Protobuf.Writer()
        third.message(3) { $0.varint(1, 150) }
        #expect(Array(third.data) == [0x1a, 0x03, 0x08, 0x96, 0x01])
    }

    @Test("Zig-zag matches the documented mapping", arguments: [
        (Int64(0), UInt64(0)), (-1, 1), (1, 2), (-2, 3), (2, 4),
        (2_147_483_647, 4_294_967_294), (-2_147_483_648, 4_294_967_295),
    ])
    func zigzag(_ value: Int64, _ encoded: UInt64) {
        // A different encoding, not a different type. Reading a `sint` as an
        // ordinary varint turns -1 into 1 and 1 into 2, which is the kind of
        // wrong that looks plausible in a log.
        var writer = Protobuf.Writer()
        writer.signed(1, value)
        #expect(Protobuf.value(1, in: writer.data) == .varint(encoded))
        #expect(Protobuf.value(1, in: writer.data)?.signed == value)
    }

    @Test("An ordinary varint is not zig-zag")
    func signedIsNotTheSameAsInt() throws {
        var writer = Protobuf.Writer()
        writer.varint(1, 1)
        let value = try #require(Protobuf.value(1, in: writer.data))
        #expect(value.int == 1)
        // The same byte read the other way is 0 under zig-zag, and nothing warns.
        #expect(value.signed == -1)
    }

    // MARK: - Round trips

    @Test("Large varints survive", arguments: [
        UInt64(0), 1, 127, 128, 300, 16_383, 16_384, 1 << 31, 1 << 62, UInt64.max,
    ])
    func varintRange(_ value: UInt64) {
        var writer = Protobuf.Writer()
        writer.varint(7, value)
        #expect(Protobuf.value(7, in: writer.data) == .varint(value))
    }

    @Test("High field numbers survive", arguments: [1, 2, 15, 16, 19, 42, 1000, 536_870_911])
    func fieldNumbers(_ number: Int) {
        // SABR's request message uses field 1000, and the tag for it is three
        // bytes rather than one.
        var writer = Protobuf.Writer()
        writer.varint(number, 1)
        let fields = Protobuf.fields(in: writer.data)
        #expect(fields.count == 1)
        #expect(fields.first?.number == number)
    }

    @Test("Fixed-width fields survive")
    func fixedWidth() {
        var writer = Protobuf.Writer()
        // Written by hand: the writer has no fixed32 helper because nothing in
        // this protocol needs to write one, but the reader has to understand one
        // it is handed.
        writer.bytes(1, Data([1, 2, 3]))
        #expect(Protobuf.value(1, in: writer.data)?.data == Data([1, 2, 3]))

        let fixed32 = bytes([0x0d, 0x78, 0x56, 0x34, 0x12])
        #expect(Protobuf.value(1, in: fixed32) == .fixed32(0x1234_5678))
        let fixed64 = bytes([0x09, 0x01, 0, 0, 0, 0, 0, 0, 0])
        #expect(Protobuf.value(1, in: fixed64) == .fixed64(1))
    }

    @Test("Empty bytes are a value, not an absence")
    func emptyBytes() {
        var writer = Protobuf.Writer()
        writer.bytes(5, Data())
        #expect(Protobuf.value(5, in: writer.data) == .bytes(Data()))
    }

    // MARK: - Repeated fields, which a dictionary would lose

    @Test("A repeated field keeps every value")
    func repeatedFields() {
        // The obvious shape for a parsed message is a dictionary keyed by field
        // number, and it silently keeps one of these three. SABR's request has
        // repeated format ids and repeated buffered ranges; losing all but the
        // last would ask for one rendition and claim nothing was buffered.
        var writer = Protobuf.Writer()
        for value in [10, 20, 30] { writer.varint(2, value) }
        #expect(Protobuf.values(2, in: writer.data) == [.varint(10), .varint(20), .varint(30)])
        // And the single-value accessor takes the last, which is what the
        // specification says a repeated scalar collapses to.
        #expect(Protobuf.value(2, in: writer.data) == .varint(30))
    }

    @Test("Fields keep the order they were written in")
    func preservesOrder() {
        var writer = Protobuf.Writer()
        writer.varint(3, 1)
        writer.varint(1, 2)
        writer.varint(2, 3)
        #expect(Protobuf.fields(in: writer.data).map(\.number) == [3, 1, 2])
    }

    // MARK: - Copying a field without understanding it
    //
    // The property the SABR strategy depends on. YouTube's streaming request
    // carries a ustreamer config and a streamer context whose contents change
    // without notice; both can be lifted out of a request the page made and put
    // into one we are making, as bytes, and nothing has to know what is in them.

    @Test("An opaque field survives being copied into another message")
    func opaqueCopy() throws {
        // Something structured, standing in for a context with a token inside.
        var original = Protobuf.Writer()
        original.message(19) { context in
            context.string(1, "a-token-we-never-parse")
            context.varint(2, 99)
            context.message(3) { $0.bytes(1, Data([0xDE, 0xAD, 0xBE, 0xEF])) }
        }

        // Read it as bytes, with no idea of its shape.
        let opaque = try #require(Protobuf.value(19, in: original.data)?.data)

        // Put it in a request of our own, beside fields we do understand.
        var request = Protobuf.Writer()
        request.varint(4, 0)
        request.message(19, opaque)
        request.varint(22, 137)

        // It comes back identical, and still parses for anyone who does know.
        let round = try #require(Protobuf.value(19, in: request.data)?.data)
        #expect(round == opaque)
        #expect(Protobuf.value(1, in: round)?.text == "a-token-we-never-parse")
        #expect(Protobuf.value(22, in: request.data)?.int == 137)
    }

    @Test("A field nobody understands is still readable as bytes")
    func unknownFieldsAreNotFatal() {
        // A protocol that changes without notice adds fields. They have to not
        // break the parse, and they have to remain copyable.
        var writer = Protobuf.Writer()
        writer.varint(1, 5)
        writer.bytes(777, Data([1, 2, 3]))
        writer.varint(2, 6)
        let fields = Protobuf.fields(in: writer.data)
        #expect(fields.count == 3)
        #expect(Protobuf.value(1, in: writer.data)?.int == 5)
        #expect(Protobuf.value(2, in: writer.data)?.int == 6)
        #expect(Protobuf.value(777, in: writer.data)?.data == Data([1, 2, 3]))
    }

    // MARK: - Refusing, never trapping
    //
    // The input is bytes off a network, from a protocol with no published
    // specification. Every one of these used to be a way to crash a parser.

    @Test("Malformed input stops the parse rather than the process", arguments: [
        [UInt8]([]),
        [0x08],                                  // a tag with no value
        [0x12, 0x05, 0x01, 0x02],                // a length past the end
        [0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F],    // an enormous length
        [0x1c],                                  // wire type 4, a deprecated group
        [0x1b],                                  // wire type 3, the other one
        [0x00],                                  // field number zero, which is illegal
        [0x0d, 0x01],                            // fixed32 with one byte
        [0x09, 0x01, 0x02],                      // fixed64 with two
        Array(repeating: 0xFF, count: 20),       // a varint that never terminates
    ])
    func malformed(_ raw: [UInt8]) {
        // Whatever it manages to read is fine; not crashing is the requirement,
        // and so is stopping rather than looping.
        let fields = Protobuf.fields(in: Data(raw))
        #expect(fields.count < 4)
    }

    @Test("A truncated message yields the fields that were whole")
    func truncation() {
        var writer = Protobuf.Writer()
        writer.varint(1, 150)
        writer.string(2, "intact")
        writer.varint(3, 7)
        // Cut two bytes off the end, which is what a dropped connection does.
        let cut = writer.data.dropLast(2)
        let fields = Protobuf.fields(in: cut)
        #expect(fields.first?.value == .varint(150))
        #expect(fields.count >= 1)
        #expect(fields.count <= 2)
    }

    @Test("Reading past the end is just the end")
    func readerStops() {
        var reader = Protobuf.Reader(Data([0x08, 0x01]))
        #expect(reader.next() != nil)
        #expect(reader.isAtEnd)
        #expect(reader.next() == nil)
        #expect(reader.next() == nil)
    }

    @Test("A length-delimited field claiming the rest of the message is allowed")
    func exactLength() throws {
        // Exactly to the end is legal; one past it is not. Off by one here is
        // either a crash or a silently dropped field.
        let exact = bytes([0x12, 0x02, 0xAA, 0xBB])
        #expect(Protobuf.value(2, in: exact)?.data == Data([0xAA, 0xBB]))
        let past = bytes([0x12, 0x03, 0xAA, 0xBB])
        #expect(Protobuf.value(2, in: past) == nil)
    }
}
