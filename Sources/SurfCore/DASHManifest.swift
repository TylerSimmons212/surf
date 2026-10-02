import Foundation

/// Reads an MPD into a `StreamIndex`.
///
/// The other half of the bet `StreamIndex` represents: if the boundary was drawn
/// in the right place, a second manifest format is a parser and nothing else.
///
/// DASH differs from HLS in one way that matters here. An m3u8 master names other
/// playlists and you fetch the one you chose; an MPD describes everything in a
/// single document, so there is no second pass and the segments are already known
/// when the choice is made.
///
/// It differs in a second way that is purely more work: a segment's URL can be
/// stated four different ways. A template with a number in it, a template with an
/// explicit timeline, an enumerated list, or a single file for the whole track.
/// All four are here. What is not is `SegmentBase` with an `indexRange`, where
/// the segment boundaries live inside the file's own index box — such a
/// representation is treated as the one file it is, which downloads correctly and
/// skips the boxes entirely.
public enum DASHManifest {

    /// Nil when this is not an MPD, or not one we can read.
    public static func parse(_ text: String, baseURL: URL) -> StreamIndex? {
        guard let document = try? XMLDocument(xmlString: text, options: []),
              let mpd = document.rootElement(),
              mpd.name == "MPD"
        else { return nil }

        // A dynamic manifest is a stream still being produced. There is no whole
        // file to make from one, and the segment list it states now is a window
        // rather than the content.
        let isLive = mpd.string("type") == "dynamic"

        let mpdBase = resolve(base: mpd, against: baseURL)
        let total = duration(mpd.string("mediaPresentationDuration"))

        var renditions: [StreamRendition] = []
        var protection = StreamProtection.none

        if mpd.has("ContentProtection") { protection = .protected }

        // Only the first period. A multi-period manifest is advertising breaks or
        // a concatenation, and producing one file from several periods means
        // splicing timelines — a different problem from downloading, and one worth
        // refusing by only reading what we can honestly deliver.
        guard let period = mpd.children(named: "Period").first else { return nil }
        if period.has("ContentProtection") { protection = .protected }
        let periodBase = resolve(base: period, against: mpdBase)
        let periodDuration = duration(period.string("duration")) ?? total

        for set in period.children(named: "AdaptationSet") {
            if set.has("ContentProtection") { protection = .protected }
            let setBase = resolve(base: set, against: periodBase)

            for representation in set.children(named: "Representation") {
                if representation.has("ContentProtection") { protection = .protected }
                let base = resolve(base: representation, against: setBase)

                // DASH lets these sit on either the set or the representation, and
                // the representation wins. Sony's test vector puts codecs and
                // mimeType on the AdaptationSet and nothing on the Representation
                // at all, so reading only the representation yields a stream with
                // no codec, no role, and no way to be chosen.
                let mime = representation.string("mimeType") ?? set.string("mimeType")
                let codecs = representation.string("codecs") ?? set.string("codecs")
                let contentType = set.string("contentType")

                guard let rendition = build(
                    representation,
                    in: set,
                    base: base,
                    mime: mime,
                    codecs: codecs,
                    contentType: contentType,
                    periodDuration: periodDuration
                ) else { continue }
                renditions.append(rendition)
            }
        }

        // A live manifest states no total, so no segment count can be computed
        // from a template and every rendition comes back empty. Returning nil
        // then reports "not a manifest", which is wrong and sends the caller
        // looking for a parse bug. It is a manifest; it is a stream that has not
        // finished. Keep whatever was found so the planner can say so.
        guard !renditions.isEmpty || isLive else { return nil }

        // DASH states no link between a video stream and its soundtrack. HLS does
        // — `AUDIO="group"` on the variant — and `audioGroup` is named for it, so
        // the two formats have to be reconciled somewhere. Here, because which
        // soundtracks belong to a picture is a fact about the format rather than a
        // decision about the download, and putting it in the planner would mean
        // the planner knowing which format it was handed.
        //
        // Every audio adaptation set is a candidate for every video one, so the
        // video renditions adopt the first soundtrack group on offer.
        if let group = renditions.first(where: { $0.role == .audio })?.audioGroup {
            for index in renditions.indices where renditions[index].role == .video
                && renditions[index].audioGroup == nil {
                renditions[index].audioGroup = group
            }
        }

        // The manifest's own total is better than a sum of segment durations: the
        // last segment is usually short and a template states a nominal length for
        // every one of them.
        let declared = periodDuration ?? renditions.map(\.duration).max()

        return StreamIndex(
            renditions: renditions,
            protection: protection,
            isLive: isLive,
            declaredDuration: declared.map { $0 > 0 ? $0 : 0 }.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    // MARK: - One representation

    private static func build(
        _ representation: XMLElement,
        in set: XMLElement,
        base: URL,
        mime: String?,
        codecs: String?,
        contentType: String?,
        periodDuration: Double?
    ) -> StreamRendition? {
        let id = representation.string("id") ?? base.lastPathComponent

        // A template can be on either level too, and the representation's wins.
        let template = representation.children(named: "SegmentTemplate").first
            ?? set.children(named: "SegmentTemplate").first
        let list = representation.children(named: "SegmentList").first
            ?? set.children(named: "SegmentList").first

        let variables = Variables(
            representationID: representation.string("id") ?? "",
            bandwidth: representation.string("bandwidth") ?? ""
        )

        var initSegment: StreamSegment?
        var segments: [StreamSegment] = []

        if let template {
            if let initialization = template.string("initialization"),
               let url = URL(string: expand(initialization, with: variables, number: nil, time: nil),
                             relativeTo: base) {
                initSegment = StreamSegment(url: url.absoluteURL)
            }
            segments = templated(
                template, base: base, variables: variables, periodDuration: periodDuration
            )
        } else if let list {
            if let initialization = list.children(named: "Initialization").first?
                .string("sourceURL"),
               let url = URL(string: initialization, relativeTo: base) {
                initSegment = StreamSegment(url: url.absoluteURL)
            }
            let listDuration = Double(list.string("duration") ?? "")
                .map { $0 / timescale(of: list) }
            segments = list.children(named: "SegmentURL").compactMap { entry in
                guard let media = entry.string("media"),
                      let url = URL(string: media, relativeTo: base)
                else { return nil }
                return StreamSegment(url: url.absoluteURL, duration: listDuration ?? 0)
            }
        } else {
            // No addressing at all: the representation's BaseURL *is* the track,
            // one file. The on-demand profile is built this way, and so is every
            // `SegmentBase` representation once you decline to read its index box.
            guard base != resolve(base: set, against: base) || !base.lastPathComponent.isEmpty
            else { return nil }
            segments = [StreamSegment(url: base, duration: periodDuration ?? 0)]
        }

        // Empty is allowed only for a live stream, where the count is unknowable
        // and the rendition exists to be refused rather than fetched.
        guard !segments.isEmpty || periodDuration == nil else { return nil }

        return StreamRendition(
            id: id,
            role: role(mime: mime, contentType: contentType, codecs: codecs),
            container: container(mime: mime, segments: segments),
            width: Int(representation.string("width") ?? set.string("width") ?? ""),
            height: Int(representation.string("height") ?? set.string("height") ?? ""),
            bandwidth: Int(representation.string("bandwidth") ?? ""),
            codecs: codecs,
            // Only a soundtrack names its own group. A video stream leaves this
            // empty and has it filled in afterwards, because in DASH nothing in
            // the document says which soundtrack goes with which picture — and a
            // video rendition labelled with its *own* adaptation set's id would
            // match no soundtrack at all, which is a refusal rather than a
            // download.
            audioGroup: role(mime: mime, contentType: contentType, codecs: codecs) == .audio
                ? (set.string("id") ?? set.string("group") ?? "audio")
                : nil,
            isDefault: set.children(named: "Role").contains {
                $0.string("value") == "main"
            },
            initSegment: initSegment,
            segments: segments
        )
    }

    // MARK: - Segment addressing

    /// Internal rather than private so `expand` can be tested directly. Template
    /// substitution is where a DASH parser silently builds 404s, and it deserves
    /// its own tests rather than only being exercised through a whole manifest.
    struct Variables {
        var representationID: String
        var bandwidth: String
    }

    private static func templated(
        _ template: XMLElement, base: URL, variables: Variables, periodDuration: Double?
    ) -> [StreamSegment] {
        guard let media = template.string("media") else { return [] }
        let scale = timescale(of: template)
        let start = Int(template.string("startNumber") ?? "1") ?? 1

        func segment(number: Int?, time: Int?, duration: Double) -> StreamSegment? {
            let path = expand(media, with: variables, number: number, time: time)
            guard let url = URL(string: path, relativeTo: base) else { return nil }
            return StreamSegment(url: url.absoluteURL, duration: duration)
        }

        // An explicit timeline is exact, so it wins over arithmetic wherever both
        // are present.
        if let timeline = template.children(named: "SegmentTimeline").first {
            var segments: [StreamSegment] = []
            var number = start
            var clock = 0
            for entry in timeline.children(named: "S") {
                // `@t` restarts the clock; without it this run continues the last.
                if let t = Int(entry.string("t") ?? "") { clock = t }
                guard let d = Int(entry.string("d") ?? "") else { continue }
                // `@r` is *additional* repeats, so r="4" means five segments. Off
                // by one here produces a file short by its last segment, which
                // plays and ends early.
                let repeats = Int(entry.string("r") ?? "0") ?? 0
                for _ in 0...max(0, repeats) {
                    if let made = segment(
                        number: number, time: clock, duration: Double(d) / scale
                    ) { segments.append(made) }
                    number += 1
                    clock += d
                }
            }
            return segments
        }

        // Otherwise the count comes from arithmetic: how many nominal segments fit
        // in the period.
        guard let nominal = Double(template.string("duration") ?? ""), nominal > 0,
              let total = periodDuration, total > 0
        else { return [] }
        let each = nominal / scale
        let count = Int((total / each).rounded(.up))
        return (0..<count).compactMap { offset in
            segment(number: start + offset, time: nil, duration: each)
        }
    }

    private static func timescale(of element: XMLElement) -> Double {
        // Omitted means 1, which is seconds. Reading it as zero would divide by
        // nothing.
        let declared = Double(element.string("timescale") ?? "") ?? 1
        return declared > 0 ? declared : 1
    }

    /// Fills in `$Number$`, `$Time$`, `$RepresentationID$` and `$Bandwidth$`,
    /// honouring the printf-style width some manifests put inside them.
    ///
    /// `$Number%04d$` is real and common — Axinom's test vectors use it — and a
    /// parser that only knows the bare form builds `.../1.m4s` where the server
    /// has `.../0001.m4s`, which is a 404 per segment and a download that fails
    /// completely while looking like a network problem.
    ///
    /// `$$` is an escaped dollar sign and is substituted last, so a literal `$` in
    /// a path cannot open a variable.
    static func expand(
        _ template: String, with variables: Variables, number: Int?, time: Int?
    ) -> String {
        // The escape is set aside before anything else happens and restored at the
        // end. Neither order works without it: substituting `$$` first turns
        // `odd$$Number$$path` into `odd$Number$path` and then the substitution
        // finds a variable that was escaped, while substituting it last leaves the
        // variable pass to match the `$Number$` sitting inside the escape and eat
        // half of it. A sentinel no URL template can contain avoids both.
        let sentinel = "\u{0}"
        var result = template.replacingOccurrences(of: "$$", with: sentinel)
        result = result.replacingOccurrences(
            of: "$RepresentationID$", with: variables.representationID
        )
        result = result.replacingOccurrences(of: "$Bandwidth$", with: variables.bandwidth)
        if let number { result = substitute("Number", value: number, in: result) }
        if let time { result = substitute("Time", value: time, in: result) }
        return result.replacingOccurrences(of: sentinel, with: "$")
    }

    /// `$Name$` or `$Name%0Nd$`.
    private static func substitute(_ name: String, value: Int, in text: String) -> String {
        var result = text.replacingOccurrences(of: "$\(name)$", with: String(value))
        // Scan for the formatted form rather than regex: the whole grammar is
        // `$Name%0<digits>d$`, and a hand-rolled scan is both shorter to read and
        // impossible to get subtly wrong about greediness.
        while let open = result.range(of: "$\(name)%0"),
              let close = result.range(of: "d$", range: open.upperBound..<result.endIndex) {
            let digits = result[open.upperBound..<close.lowerBound]
            guard let width = Int(digits), width > 0, width <= 20 else { break }
            let padded = String(format: "%0\(width)d", value)
            result.replaceSubrange(open.lowerBound..<close.upperBound, with: padded)
        }
        return result
    }

    // MARK: - Reading the document

    /// A `BaseURL` child, resolved against what it is nested in.
    ///
    /// These chain: the MPD's, then the period's, then the adaptation set's, then
    /// the representation's, each relative to the last. Resolving against the page
    /// rather than the chain is how a manifest ends up pointing somewhere it never
    /// named.
    private static func resolve(base element: XMLElement, against parent: URL) -> URL {
        guard let stated = element.children(named: "BaseURL").first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !stated.isEmpty,
            let url = URL(string: stated, relativeTo: parent)
        else { return parent }
        return url.absoluteURL
    }

    private static func role(
        mime: String?, contentType: String?, codecs: String?
    ) -> StreamRendition.Role {
        let kind = (contentType ?? mime?.components(separatedBy: "/").first ?? "").lowercased()
        switch kind {
        case "video":
            // A video adaptation set whose codecs name an audio format too is one
            // muxed stream, which is unusual in DASH but legal.
            return StreamCodecs.declaresAudio(codecs) ? .muxed : .video
        case "audio": return .audio
        case "text", "application": return .other
        default:
            guard StreamCodecs.declaresVideo(codecs) || StreamCodecs.declaresAudio(codecs)
            else { return .other }
            return switch (
                StreamCodecs.declaresVideo(codecs), StreamCodecs.declaresAudio(codecs)
            ) {
            case (true, true): .muxed
            case (true, false): .video
            default: .audio
            }
        }
    }

    private static func container(mime: String?, segments: [StreamSegment]) -> StreamContainer {
        let declared = (mime ?? "").lowercased()
        if declared.contains("webm") { return .webm }
        if declared.contains("mp2t") { return .mpegTS }
        if declared.contains("mp4") { return .fragmentedMP4 }
        let extensions = Set(segments.prefix(2).map { $0.url.pathExtension.lowercased() })
        if extensions.contains("webm") { return .webm }
        if extensions.contains("ts") { return .mpegTS }
        return .fragmentedMP4
    }

    /// `PT9M57S`, `PT10M34.6S`, `PT1H2M3.5S`.
    ///
    /// Only the time half, because a media presentation measured in years is not a
    /// thing and pretending to support it would mean caring how long a month is.
    static func duration(_ text: String?) -> Double? {
        guard var text, text.hasPrefix("P") else { return nil }
        guard let timeStart = text.firstIndex(of: "T") else { return nil }
        text = String(text[text.index(after: timeStart)...])

        var total = 0.0
        var number = ""
        for character in text {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            guard let value = Double(number) else { return nil }
            switch character {
            case "H": total += value * 3600
            case "M": total += value * 60
            case "S": total += value
            default: return nil
            }
            number = ""
        }
        // A trailing number with no unit is malformed, not a count of seconds.
        guard number.isEmpty else { return nil }
        return total > 0 ? total : nil
    }
}

/// Reading an `XMLElement` without the ceremony.
private extension XMLElement {
    func string(_ name: String) -> String? {
        guard let value = attribute(forName: name)?.stringValue, !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Direct children only. `elements(forName:)` already does this; the wrapper
    /// exists so a call site reads as a question about structure.
    func children(named name: String) -> [XMLElement] {
        elements(forName: name)
    }

    /// Anywhere below here, which is what a protection check wants: a
    /// `ContentProtection` nested three levels down protects this content just as
    /// much as one on the element itself.
    func has(_ name: String) -> Bool {
        if !elements(forName: name).isEmpty { return true }
        return (children ?? []).contains { child in
            (child as? XMLElement)?.has(name) ?? false
        }
    }
}
