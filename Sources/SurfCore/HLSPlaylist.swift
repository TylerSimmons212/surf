import Foundation

/// Reads an m3u8 into a `StreamIndex`.
///
/// Both kinds of playlist go through the one function, because which kind you
/// have is something you discover by reading it: a master lists other playlists,
/// a media playlist lists segments, and the tags tell you which. So fetching a
/// master and then fetching the variant it named is two passes through `parse`
/// rather than two functions, and `StreamIndex.needsSecondPass` is how the caller
/// knows it owes another one.
///
/// Nothing here knows which site it is reading. That is the point: the input is
/// the playlist the page itself fetched to play the video, so the format is the
/// specification rather than anyone's house style, and a parser for it does not
/// rot the way a site extractor does.
public enum HLSPlaylist {

    /// Nil when this is not a playlist at all.
    ///
    /// The caller treats that as a refusal and falls back, which is the right
    /// response to both "the server sent an error page" and "our parser is
    /// missing something". Neither is the user's problem to solve.
    public static func parse(_ text: String, baseURL: URL) -> StreamIndex? {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Every playlist starts with this. Checking it is what distinguishes an
        // empty playlist from a 200-with-an-error-page, which otherwise parses
        // to the same nothing.
        guard lines.first == "#EXTM3U" else { return nil }

        // `#EXT-X-MEDIA` counts as well as `#EXT-X-STREAM-INF`, because both are
        // master-only tags and a playlist can carry the second without the first:
        // a subtitle or audio group with no variants beside it is unusual but
        // legal. Keying only on STREAM-INF sent such a playlist down the media
        // path, where it parsed into one rendition with no segments and a role of
        // muxed — which then looked to the planner like a perfectly good video to
        // download.
        let isMaster = lines.contains {
            $0.hasPrefix("#EXT-X-STREAM-INF") || $0.hasPrefix("#EXT-X-MEDIA:")
        }
        return isMaster
            ? master(lines, baseURL: baseURL)
            : media(lines, baseURL: baseURL)
    }

    // MARK: - A playlist of playlists

    private static func master(_ lines: [String], baseURL: URL) -> StreamIndex {
        var renditions: [StreamRendition] = []
        var pendingVariant: [String: String]?

        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingVariant = attributes(after: "#EXT-X-STREAM-INF:", in: line)
                continue
            }

            if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = attributes(after: "#EXT-X-MEDIA:", in: line)
                // A TYPE=AUDIO entry without a URI is describing a soundtrack
                // already inside the variants, not a separate stream to fetch.
                guard let uri = attrs["URI"], let url = resolve(uri, against: baseURL)
                else { continue }
                let role: StreamRendition.Role = switch attrs["TYPE"] {
                case "AUDIO": .audio
                case "VIDEO": .video
                default: .other
                }
                renditions.append(StreamRendition(
                    id: attrs["NAME"] ?? attrs["GROUP-ID"] ?? uri,
                    role: role,
                    manifestURL: url,
                    codecs: attrs["CODECS"],
                    audioGroup: attrs["GROUP-ID"],
                    isDefault: attrs["DEFAULT"]?.uppercased() == "YES"
                ))
                continue
            }

            // Trick-play streams: all keyframes, no sound, meant for scrubbing.
            // Skipped rather than ranked, because one would otherwise look like
            // an excellent video rendition right up until you watched it.
            if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") { continue }
            if line.hasPrefix("#") { continue }

            // A bare line following EXT-X-STREAM-INF is that variant's URI.
            guard let attrs = pendingVariant else { continue }
            pendingVariant = nil
            guard let url = resolve(line, against: baseURL) else { continue }

            let (width, height) = resolution(attrs["RESOLUTION"])

            // An AUDIO group overrules CODECS about what is in this stream.
            //
            // CODECS does not describe the variant. It lists, in the
            // specification's words, formats "present in one or more Renditions
            // specified by the Variant Stream" — so a variant with
            // `CODECS="avc1.640028,ec-3"` and `AUDIO="ec3-48-768"` is declaring
            // what the *presentation* will contain once the two are played
            // together, and its own segments carry no sound at all.
            //
            // Reading CODECS alone calls that muxed, downloads the video
            // playlist, and produces a silent file. Found by parsing Apple's own
            // reference stream, where 100 variants are shaped exactly this way;
            // no fixture written from the same misunderstanding would have caught
            // it.
            var variantRole = role(forCodecs: attrs["CODECS"])
            if attrs["AUDIO"] != nil, variantRole == .muxed { variantRole = .video }

            renditions.append(StreamRendition(
                id: line,
                role: variantRole,
                manifestURL: url,
                width: width,
                height: height,
                // Peak, not average: it is what a player would plan against, and
                // the two disagree by enough to reorder renditions.
                bandwidth: attrs["BANDWIDTH"].flatMap(Int.init),
                codecs: attrs["CODECS"],
                audioGroup: attrs["AUDIO"]
            ))
        }

        return StreamIndex(renditions: renditions)
    }

    // MARK: - A playlist of segments

    private static func media(_ lines: [String], baseURL: URL) -> StreamIndex {
        var segments: [StreamSegment] = []
        var initSegment: StreamSegment?
        var protection = StreamProtection.none
        var isLive = true
        var pendingDuration: Double?
        var pendingRange: Range<Int>?
        // An EXT-X-BYTERANGE with no offset continues from the end of the last
        // one. Dropping this makes every sub-range playlist silently wrong.
        var rangeCursor = 0

        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                // `#EXTINF:9.009,` and `#EXTINF:9.009,Title` are both legal.
                let value = line.dropFirst("#EXTINF:".count)
                    .split(separator: ",", maxSplits: 1).first ?? ""
                pendingDuration = Double(value.trimmingCharacters(in: .whitespaces))
                continue
            }

            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = byteRange(
                    String(line.dropFirst("#EXT-X-BYTERANGE:".count)),
                    continuingFrom: rangeCursor
                )
                if let pendingRange { rangeCursor = pendingRange.upperBound }
                continue
            }

            if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(after: "#EXT-X-MAP:", in: line)
                if let uri = attrs["URI"], let url = resolve(uri, against: baseURL) {
                    initSegment = StreamSegment(
                        url: url,
                        byteRange: attrs["BYTERANGE"].flatMap {
                            byteRange($0, continuingFrom: 0)
                        }
                    )
                }
                continue
            }

            if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                let method = attributes(
                    after: line.hasPrefix("#EXT-X-KEY:") ? "#EXT-X-KEY:" : "#EXT-X-SESSION-KEY:",
                    in: line
                )["METHOD"] ?? "NONE"
                // Worst case wins: a playlist that switches from a fetchable key
                // to a protected one is protected.
                protection = max(protection, self.protection(forMethod: method))
                continue
            }

            // Its presence is the only thing that says this stream has an end.
            if line == "#EXT-X-ENDLIST" {
                isLive = false
                continue
            }

            if line.hasPrefix("#") { continue }

            guard let url = resolve(line, against: baseURL) else {
                pendingDuration = nil
                pendingRange = nil
                continue
            }
            segments.append(StreamSegment(
                url: url,
                duration: pendingDuration ?? 0,
                byteRange: pendingRange
            ))
            pendingDuration = nil
            pendingRange = nil
        }

        let container = container(of: initSegment, segments)
        let total = segments.reduce(0) { $0 + $1.duration }

        return StreamIndex(
            renditions: [StreamRendition(
                id: baseURL.lastPathComponent,
                // A media playlist on its own does not say what is in it. Muxed
                // is the honest default: it is what a single-stream playlist
                // almost always is, and the planner re-labels it from the master
                // when there was one.
                role: .muxed,
                container: container,
                initSegment: initSegment,
                segments: segments
            )],
            protection: protection,
            isLive: isLive,
            declaredDuration: total > 0 ? total : nil
        )
    }

    // MARK: - Reading attribute lists

    /// Splits `KEY=VALUE,KEY="V,A,L"` without being fooled by the commas inside
    /// the quotes.
    ///
    /// `CODECS="avc1.4d401e,mp4a.40.2"` is one attribute containing a comma, and
    /// splitting the line on commas is the classic way to misparse a master
    /// playlist: you get a CODECS of `avc1.4d401e` and a junk attribute named
    /// `mp4a.40.2`, which then reads as a video-only variant and changes every
    /// decision downstream.
    static func attributes(after prefix: String, in line: String) -> [String: String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        for character in line.dropFirst(prefix.count) {
            switch character {
            case "\"": quoted.toggle()
            case "," where !quoted:
                fields.append(current)
                current = ""
            default: current.append(character)
            }
        }
        fields.append(current)

        var attributes: [String: String] = [:]
        for field in fields {
            guard let split = field.firstIndex(of: "=") else { continue }
            let key = field[..<split].trimmingCharacters(in: .whitespaces).uppercased()
            guard !key.isEmpty else { continue }
            attributes[key] = field[field.index(after: split)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return attributes
    }

    private static func resolution(_ value: String?) -> (Int?, Int?) {
        guard let parts = value?.lowercased().split(separator: "x"),
              parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1])
        else { return (nil, nil) }
        return (width, height)
    }

    /// `<length>` or `<length>@<offset>`.
    private static func byteRange(
        _ value: String, continuingFrom cursor: Int
    ) -> Range<Int>? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: "@")
        guard let length = Int(parts[0]), length > 0 else { return nil }
        let offset = parts.count > 1 ? (Int(parts[1]) ?? cursor) : cursor
        return offset..<(offset + length)
    }

    private static func resolve(_ uri: String, against baseURL: URL) -> URL? {
        // Absolute wins; otherwise relative to the playlist, never to the page.
        // The distinction matters: a manifest naming its own segments is
        // ordinary, and a manifest reaching a host the page never mentioned is
        // the thing a plan has to be able to refuse.
        URL(string: uri, relativeTo: baseURL)?.absoluteURL
    }

    // MARK: - Reading what the strings imply

    /// A variant carrying both a video and an audio codec is one stream with
    /// both in it. One carrying only video has its sound somewhere else.
    private static func role(forCodecs codecs: String?) -> StreamRendition.Role {
        // No CODECS attribute is legal and common, and says nothing. Muxed is the
        // safe reading: a lone variant with no audio group almost always is.
        guard let codecs, !codecs.isEmpty else { return .muxed }
        return switch (StreamCodecs.declaresVideo(codecs), StreamCodecs.declaresAudio(codecs)) {
        case (true, true): .muxed
        case (true, false): .video
        case (false, true): .audio
        case (false, false): .muxed
        }
    }

    private static func protection(forMethod method: String) -> StreamProtection {
        switch method.uppercased() {
        case "NONE": .none
        // A key anyone can fetch over the same connection. Genuinely not DRM,
        // whatever the word "KEY" suggests.
        case "AES-128", "AES-256": .fetchableKey
        // FairPlay. The decoder gets encrypted samples and a key we cannot ask
        // for.
        default: .protected
        }
    }

    /// An `EXT-X-MAP` means fragmented MP4: the tag exists precisely because
    /// fMP4 needs an initialisation segment and transport streams do not.
    private static func container(
        of initSegment: StreamSegment?, _ segments: [StreamSegment]
    ) -> StreamContainer {
        if initSegment != nil { return .fragmentedMP4 }
        let extensions = Set(segments.prefix(4).map { $0.url.pathExtension.lowercased() })
        if extensions.contains("ts") { return .mpegTS }
        if extensions.contains("m4s") || extensions.contains("mp4")
            || extensions.contains("m4a") || extensions.contains("m4v") {
            return .fragmentedMP4
        }
        return .unknown
    }
}

/// So the worst protection seen in a playlist is the one that counts.
extension StreamProtection: Comparable {
    private var severity: Int {
        switch self {
        case .none: 0
        case .fetchableKey: 1
        case .protected: 2
        }
    }

    public static func < (lhs: StreamProtection, rhs: StreamProtection) -> Bool {
        lhs.severity < rhs.severity
    }
}
