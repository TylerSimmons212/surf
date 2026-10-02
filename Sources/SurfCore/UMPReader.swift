import Foundation

/// Frames a UMP stream into its parts.
///
/// UMP is what YouTube answers a streaming request with: a sequence of typed
/// parts, each prefixed by its type and its length, with the audio and the video
/// woven together rather than delivered as separate files. It is not DASH, it is
/// not HLS, and no player outside YouTube's own reads it.
///
/// The framing is three lines of structure:
///
///     struct UmpPart { varInt type; varInt size; uint8_t data[size]; }
///
/// The varints are not protobuf's. They are closer to RFC 8794's, where the
/// first byte's leading bits give the total length and its remaining bits are
/// the top of the value. Reading them as protobuf varints appears to work on
/// small numbers — a part type under 128 encodes identically — and then
/// silently desynchronises the whole stream on the first length over 127, which
/// is every media part. That trap is the reason this is its own type with its
/// own tests rather than a few lines inside the client.
///
/// Parts span responses. A media part can be cut in half by the end of an HTTP
/// chunk, so this buffers and only yields parts that are whole.
public struct UMPReader: Sendable {

    private var buffer = Data()

    public init() {}

    /// More bytes off the wire. Several small feeds are equivalent to one large
    /// one, which is the property that lets a caller hand over whatever a chunked
    /// response gave it without thinking about boundaries.
    public mutating func feed(_ data: Data) {
        buffer.append(data)
    }

    /// Bytes held because the part they belong to is not complete yet. Nonzero
    /// at the end of a well-formed stream means the stream was truncated.
    public var pendingBytes: Int { buffer.count }

    /// The next complete part, or nil when there is not one yet.
    ///
    /// Nil is deliberately not an error. A reader that has run out mid-part and a
    /// reader that has run out cleanly are the same situation from the caller's
    /// side: feed more, or stop.
    public mutating func next() -> UMPPart? {
        var offset = buffer.startIndex
        guard let type = Self.varint(in: buffer, at: &offset),
              let size = Self.varint(in: buffer, at: &offset),
              size >= 0,
              buffer.endIndex - offset >= size
        else { return nil }

        let payload = buffer[offset..<(offset + size)]
        buffer = Data(buffer[(offset + size)...])
        return UMPPart(type: type, payload: Data(payload))
    }

    /// Every complete part available now.
    public mutating func parse() -> [UMPPart] {
        var parts: [UMPPart] = []
        while let part = next() { parts.append(part) }
        return parts
    }

    /// Reads one UMP variable-length integer, advancing `offset`.
    ///
    /// The first byte's leading set bits give the total length: a clear top bit
    /// is one byte, `10…` is two, `110…` is three, `1110…` is four, `11110…` is
    /// five, and all five set is invalid. Whatever is left of the first byte is
    /// the low end of the value, with each later byte shifted above it — except
    /// at five bytes, where the first byte's remaining bits are discarded and the
    /// value is a plain little-endian 32-bit integer in the four that follow.
    ///
    /// Internal rather than private so the arithmetic can be tested against
    /// byte sequences worked out from the specification by hand. Testing it only
    /// through a round trip would prove the reader agrees with a writer that
    /// shares its misunderstanding, which is a mistake already made once in this
    /// branch.
    static func varint(in data: Data, at offset: inout Int) -> Int? {
        guard offset < data.endIndex else { return nil }
        let first = data[offset]

        var size = 0
        for shift in 1...5 where first & (128 >> (shift - 1)) == 0 {
            size = shift
            break
        }
        // All five leading bits set. Not a length this format defines.
        guard size >= 1, size <= 5 else { return nil }
        guard data.endIndex - offset >= size else { return nil }

        func byte(_ index: Int) -> Int { Int(data[offset + index]) }

        let value: Int
        switch size {
        case 1:
            value = Int(first)
        case 2:
            value = Int(first & 0b0011_1111) | (byte(1) << 6)
        case 3:
            value = Int(first & 0b0001_1111) | (byte(1) << 5) | (byte(2) << 13)
        case 4:
            value = Int(first & 0b0000_1111)
                | (byte(1) << 4) | (byte(2) << 12) | (byte(3) << 20)
        default:
            // The first byte carries nothing at this size.
            value = byte(1) | (byte(2) << 8) | (byte(3) << 16) | (byte(4) << 24)
        }

        offset += size
        return value
    }
}

/// One part of a UMP stream, before anyone decides what it means.
public struct UMPPart: Equatable, Sendable {
    public var type: Int
    public var payload: Data

    public init(type: Int, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public var kind: UMPPartType? { UMPPartType(rawValue: type) }

    /// A media part's payload with its header id removed.
    ///
    /// Media bytes do not start at the beginning of the payload: a varint header
    /// id comes first, saying which of the preceding media headers these bytes
    /// belong to, because one response interleaves several formats. Writing the
    /// payload straight to a file puts that byte in the middle of the video —
    /// once per part, a few hundred times a download, each one corrupting the
    /// frame it lands in.
    public var media: (headerID: Int, bytes: Data)? {
        guard type == UMPPartType.media.rawValue else { return nil }
        var offset = payload.startIndex
        guard let headerID = UMPReader.varint(in: payload, at: &offset) else { return nil }
        return (headerID, Data(payload[offset...]))
    }
}

/// The parts worth recognising.
///
/// A short list on purpose. Forty-odd types are documented and the stream
/// contains whichever ones YouTube feels like sending; a reader that switched
/// exhaustively over them would need changing every time one was added. These
/// are the ones a download cannot work without, and everything else is carried
/// as a number.
public enum UMPPartType: Int, Sendable, CaseIterable {
    /// Describes the media bytes that follow it: which format, which segment,
    /// how long, how big.
    case mediaHeader = 20
    /// The bytes themselves, after a header id.
    case media = 21
    /// That header's bytes are complete.
    case mediaEnd = 22
    /// How soon to ask again, and with what to ask.
    case nextRequestPolicy = 35
    /// A format's initialisation segment and index ranges, which is what makes
    /// its bytes a file rather than a fragment.
    case formatInitializationMetadata = 42
    /// Ask a different host instead. Not an error: the first answer to a
    /// streaming request is often this.
    case sabrRedirect = 43
    case sabrError = 44
    /// Seek elsewhere, which the server may insist on.
    case sabrSeek = 45
    /// The player response has expired and must be fetched again.
    case reloadPlayerResponse = 46
    /// Whether the request was accepted as coming from a real client.
    case streamProtectionStatus = 58
}
