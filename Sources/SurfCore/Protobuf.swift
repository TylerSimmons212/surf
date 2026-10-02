import Foundation

/// Just enough Protocol Buffers to read and write the messages YouTube's
/// streaming protocol is made of.
///
/// Hand-written rather than generated, and with no package behind it, because
/// `Package.swift` has exactly one dependency and a paragraph explaining why it
/// earned the exception. The wire format is four encodings and a tag; what makes
/// protobuf large is the schema language, the code generator and the reflection,
/// none of which is wanted here.
///
/// It is deliberately schema-less. A reader hands back numbered fields and the
/// caller decides what they mean, which is the property that matters for a
/// protocol nobody published: a field that appears, moves or changes meaning does
/// not break the parse, it just stops being understood. And an unknown field can
/// be copied from a request we observed into a request we are making without
/// knowing anything about it at all — which is the whole strategy for the parts
/// of YouTube's protocol that would otherwise be an arms race.
///
/// Everything here refuses rather than traps. The input is bytes off a network
/// from a protocol that changes without notice, so a malformed message has to be
/// an answer of nil and never a crash.
public enum Protobuf {

    /// The four wire types still in use. Groups — 3 and 4 — were deprecated
    /// before this protocol existed and are treated as malformed.
    public enum WireType: UInt8, Sendable {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    /// One field as it appears on the wire, before anyone decides what it is.
    public enum Value: Equatable, Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)

        /// The field read as a signed integer in the ordinary two's-complement
        /// way, which is what `int32`, `int64`, `bool` and enums all are.
        public var int: Int? {
            guard case .varint(let raw) = self else { return nil }
            return Int(bitPattern: UInt(raw))
        }

        /// Zig-zag decoded, which is what `sint32` and `sint64` are. A different
        /// encoding rather than a different type, and reading one as the other
        /// turns -1 into 1 and 1 into 2.
        public var signed: Int64? {
            guard case .varint(let raw) = self else { return nil }
            return Int64(bitPattern: raw >> 1) ^ -(Int64(bitPattern: raw) & 1)
        }

        public var data: Data? {
            guard case .bytes(let value) = self else { return nil }
            return value
        }

        public var text: String? {
            guard case .bytes(let value) = self else { return nil }
            return String(data: value, encoding: .utf8)
        }
    }

    public struct Field: Equatable, Sendable {
        public var number: Int
        public var value: Value

        public init(number: Int, value: Value) {
            self.number = number
            self.value = value
        }
    }

    // MARK: - Reading

    /// Walks a message's fields in the order they appear.
    ///
    /// Order matters more than it looks. A repeated field is several fields with
    /// the same number, and collapsing them into a dictionary — which is the
    /// obvious shape — loses every value but one. So this is a sequence, and
    /// `fields(in:)` builds whatever structure a caller actually wants.
    public struct Reader {
        private let data: Data
        private var index: Data.Index

        public init(_ data: Data) {
            self.data = data
            self.index = data.startIndex
        }

        public var isAtEnd: Bool { index >= data.endIndex }

        /// The next field, or nil at the end and on anything malformed.
        ///
        /// The two are deliberately the same answer. A caller cannot do anything
        /// useful with "the remaining bytes were nonsense" that it would not do
        /// with "there are no more", and distinguishing them would mean every
        /// call site handling an error it has no response to.
        public mutating func next() -> Field? {
            guard let tag = varint(), tag > 0 else { return nil }
            let number = Int(tag >> 3)
            guard number > 0, let wire = WireType(rawValue: UInt8(tag & 0b111))
            else { return nil }

            switch wire {
            case .varint:
                guard let value = varint() else { return nil }
                return Field(number: number, value: .varint(value))
            case .fixed64:
                guard let value = fixed(8) else { return nil }
                return Field(number: number, value: .fixed64(value))
            case .fixed32:
                guard let value = fixed(4) else { return nil }
                return Field(number: number, value: .fixed32(UInt32(truncatingIfNeeded: value)))
            case .lengthDelimited:
                guard let length = varint(), length <= UInt64(data.endIndex - index),
                      let count = Int(exactly: length)
                else { return nil }
                let start = index
                index += count
                return Field(number: number, value: .bytes(data[start..<index]))
            }
        }

        /// Base-128, seven bits at a time, little end first.
        private mutating func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.endIndex {
                let byte = data[index]
                index += 1
                // Ten bytes is the most a 64-bit value can take. Beyond that the
                // input is malformed or hostile, and shifting past 63 is
                // undefined rather than merely wrong.
                guard shift <= 63 else { return nil }
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            // Ran out of bytes mid-value.
            return nil
        }

        private mutating func fixed(_ bytes: Int) -> UInt64? {
            guard data.endIndex - index >= bytes else { return nil }
            var result: UInt64 = 0
            for offset in 0..<bytes {
                result |= UInt64(data[index + offset]) << (8 * UInt64(offset))
            }
            index += bytes
            return result
        }
    }

    /// Every field in a message, in order.
    public static func fields(in data: Data) -> [Field] {
        var reader = Reader(data)
        var fields: [Field] = []
        while let field = reader.next() { fields.append(field) }
        return fields
    }

    /// The last value for a field number, which is what protobuf says a repeated
    /// scalar collapses to when a reader wants one.
    public static func value(_ number: Int, in data: Data) -> Value? {
        fields(in: data).last { $0.number == number }?.value
    }

    /// Every value for a field number, for the genuinely repeated ones.
    public static func values(_ number: Int, in data: Data) -> [Value] {
        fields(in: data).filter { $0.number == number }.map(\.value)
    }

    // MARK: - Writing

    public struct Writer {
        public private(set) var data = Data()

        public init() {}

        public mutating func varint(_ number: Int, _ value: UInt64) {
            tag(number, .varint)
            append(value)
        }

        public mutating func varint(_ number: Int, _ value: Int) {
            varint(number, UInt64(bitPattern: Int64(value)))
        }

        public mutating func bool(_ number: Int, _ value: Bool) {
            varint(number, value ? 1 : 0)
        }

        /// Zig-zag, for the `sint` fields.
        public mutating func signed(_ number: Int, _ value: Int64) {
            varint(number, UInt64(bitPattern: (value << 1) ^ (value >> 63)))
        }

        public mutating func bytes(_ number: Int, _ value: Data) {
            tag(number, .lengthDelimited)
            append(UInt64(value.count))
            data.append(value)
        }

        public mutating func string(_ number: Int, _ value: String) {
            bytes(number, Data(value.utf8))
        }

        /// A nested message, which on the wire is indistinguishable from bytes.
        ///
        /// That identity is what lets a field be copied from one message into
        /// another without being understood: `streamer_context` is a message with
        /// a proof-of-origin token somewhere inside it, and re-encoding it as the
        /// opaque bytes we observed is both correct and immune to its contents
        /// changing.
        public mutating func message(_ number: Int, _ body: Data) {
            bytes(number, body)
        }

        /// Writes `body`'s fields as a nested message under `number`.
        public mutating func message(_ number: Int, _ build: (inout Writer) -> Void) {
            var nested = Writer()
            build(&nested)
            message(number, nested.data)
        }

        private mutating func tag(_ number: Int, _ wire: WireType) {
            append(UInt64(number) << 3 | UInt64(wire.rawValue))
        }

        private mutating func append(_ value: UInt64) {
            var remaining = value
            repeat {
                var byte = UInt8(remaining & 0x7F)
                remaining >>= 7
                if remaining != 0 { byte |= 0x80 }
                data.append(byte)
            } while remaining != 0
        }
    }
}
