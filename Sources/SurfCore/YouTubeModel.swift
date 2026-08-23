import Foundation

/// YouTube's own page data, as the site lens renders it.
///
/// The payloads come from `ytInitialData` and `ytInitialPlayerResponse` —
/// undocumented internals, and filthy in the specific way that matters: the
/// same field arrives as `simpleText` on one video and `runs` on the next, a
/// live stream has no duration and counts viewers instead of views, and an
/// unaired premiere has neither. The injected script copies a fixed set of
/// keys and makes no judgement; every judgement is here, where it is tested
/// against payloads captured from the real site.
///
/// Nothing here fails a whole page over one field. A result that can't name
/// its video is dropped; a result missing a view count renders without one.

// MARK: - Search results

/// One video in the results grid.
public struct YouTubeResult: Equatable, Sendable, Identifiable {
    /// The eleven-character video id, which is also the identity the grid
    /// diffs on and the argument `youtube.load` takes.
    public var id: String
    public var title: String
    public var channel: String
    /// The channel carries YouTube's verified check.
    public var isVerified: Bool
    /// Runtime in seconds. Nil for a live stream or an unaired premiere —
    /// both genuinely have no length, which is why this isn't zero.
    public var duration: Int?
    /// Display-ready and already compacted: "156K views", "3 watching".
    /// Empty when the payload carried no count at all.
    public var viewText: String
    /// "4 years ago", "5 hours ago". Empty for an unaired premiere.
    public var publishedText: String
    public var thumbnailURL: String
    public var isLive: Bool
    /// The quality and caption chips YouTube hangs on a result: "4K", "CC".
    /// The LIVE badge is not among them — it is `isLive` instead.
    public var badges: [String]

    public init(
        id: String, title: String = "", channel: String = "",
        isVerified: Bool = false, duration: Int? = nil, viewText: String = "",
        publishedText: String = "", thumbnailURL: String = "",
        isLive: Bool = false, badges: [String] = []
    ) {
        self.id = id
        self.title = title
        self.channel = channel
        self.isVerified = isVerified
        self.duration = duration
        self.viewText = viewText
        self.publishedText = publishedText
        self.thumbnailURL = thumbnailURL
        self.isLive = isLive
        self.badges = badges
    }

    /// The page the lens navigates to, or hands to `youtube.load`.
    public var watchURL: URL? { YouTubePage.watchURL(id: id) }

    /// "10:31:02", "2:51" — nil when there is no runtime to show.
    public var durationText: String? {
        duration.map(YouTubeFormat.clock)
    }

    /// Parses the pruned `videoRenderer` payloads the bridge hands over, in
    /// the order the site ranked them.
    ///
    /// A renderer without a usable video id is dropped rather than rendered
    /// as a card that can't be clicked, and duplicates are dropped too —
    /// YouTube repeats a video across shelves on the same results page.
    public static func parse(fromRenderers renderers: [String]) -> [YouTubeResult] {
        var results: [YouTubeResult] = []
        var seen = Set<String>()
        for renderer in renderers {
            guard let data = renderer.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
                      as? [String: Any],
                  let result = parse(renderer: object),
                  !seen.contains(result.id)
            else { continue }
            seen.insert(result.id)
            results.append(result)
        }
        return results
    }

    static func parse(renderer: [String: Any]) -> YouTubeResult? {
        guard let id = renderer["videoId"] as? String,
              YouTubePage.isValidVideoID(id)
        else { return nil }

        // The badge list carries both the chips worth showing and the LIVE
        // marker, which is a state rather than a chip.
        var chips: [String] = []
        var isLive = false
        for badge in renderer["badges"] as? [Any] ?? [] {
            guard let wrapper = badge as? [String: Any],
                  let data = wrapper["metadataBadgeRenderer"] as? [String: Any]
            else { continue }
            let style = data["style"] as? String ?? ""
            let label = (data["label"] as? String ?? "")
                .trimmingCharacters(in: .whitespaces)
            if style.contains("LIVE") || label.caseInsensitiveCompare("live") == .orderedSame {
                isLive = true
                continue
            }
            // "New" is a recency marker YouTube already says in words with
            // its published text; the chips worth keeping describe the file.
            if label.isEmpty || label.caseInsensitiveCompare("new") == .orderedSame {
                continue
            }
            chips.append(label)
        }

        let verified = (renderer["ownerBadges"] as? [Any] ?? []).contains { badge in
            guard let wrapper = badge as? [String: Any],
                  let data = wrapper["metadataBadgeRenderer"] as? [String: Any],
                  let style = data["style"] as? String
            else { return false }
            return style.contains("VERIFIED")
        }

        return YouTubeResult(
            id: id,
            title: YouTubeText.read(renderer["title"]),
            // ownerText is the usual home of the channel name; longBylineText
            // carries it on the renderers that ship no ownerText at all.
            channel: YouTubeText.firstNonEmpty(
                renderer["ownerText"], renderer["longBylineText"]
            ),
            isVerified: verified,
            duration: YouTubeFormat.seconds(
                fromClock: YouTubeText.read(renderer["lengthText"])
            ),
            viewText: YouTubeFormat.compactCount(
                YouTubeText.read(renderer["viewCountText"])
            ),
            publishedText: YouTubeFormat.published(
                YouTubeText.read(renderer["publishedTimeText"])
            ),
            thumbnailURL: thumbnail(renderer["thumbnail"], id: id),
            isLive: isLive,
            badges: chips
        )
    }

    /// The widest thumbnail the payload offers, falling back to the address
    /// every video has. YouTube's signed thumbnail URLs are the better
    /// picture but they expire; the derived one never does, so a payload
    /// that ships none still draws a card with an image in it.
    static func thumbnail(_ node: Any?, id: String) -> String {
        let candidates = (node as? [String: Any])?["thumbnails"] as? [Any] ?? []
        var best: (url: String, width: Int)?
        for candidate in candidates {
            guard let entry = candidate as? [String: Any],
                  let url = entry["url"] as? String, !url.isEmpty
            else { continue }
            let width = entry["width"] as? Int ?? 0
            if best == nil || width > best!.width { best = (url, width) }
        }
        return best?.url ?? "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"
    }
}

// MARK: - The watch page

/// The video on the stage, as the player chrome names it.
public struct YouTubeVideo: Equatable, Sendable {
    public var id: String
    public var title: String
    public var channel: String
    public var channelID: String
    /// Runtime in seconds; nil for a live stream, which has no end yet.
    public var duration: Int?
    /// Display-ready: "31K views".
    public var viewText: String
    public var isLive: Bool

    public init(
        id: String, title: String = "", channel: String = "",
        channelID: String = "", duration: Int? = nil, viewText: String = "",
        isLive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.channel = channel
        self.channelID = channelID
        self.duration = duration
        self.viewText = viewText
        self.isLive = isLive
    }

    /// Parses `ytInitialPlayerResponse.videoDetails`.
    ///
    /// The numbers arrive as strings here rather than as numbers, which is
    /// YouTube's own inconsistency and not worth being surprised by twice.
    public static func parse(fromDetails json: String) -> YouTubeVideo? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any],
              let id = object["videoId"] as? String,
              YouTubePage.isValidVideoID(id)
        else { return nil }

        let seconds = YouTubeText.integer(object["lengthSeconds"])
        let views = YouTubeText.integer(object["viewCount"])
        let isLive = object["isLiveContent"] as? Bool ?? false

        return YouTubeVideo(
            id: id,
            title: (object["title"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            channel: (object["author"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            channelID: object["channelId"] as? String ?? "",
            // A live stream reports zero length, which is not a length.
            duration: (seconds ?? 0) > 0 ? seconds : nil,
            viewText: views.map { YouTubeFormat.compactCount("\($0) views") } ?? "",
            isLive: isLive
        )
    }
}

/// One chapter of a video — the item the site lens can offer that generic
/// theater mode cannot, because only YouTube knows where they start.
public struct YouTubeChapter: Equatable, Sendable, Identifiable {
    /// Position in the video, which is also its identity in the list: two
    /// chapters can share a title, and none can share a start.
    public var id: Int { start }
    public var title: String
    /// Seconds from the beginning.
    public var start: Int

    public init(title: String, start: Int) {
        self.title = title
        self.start = start
    }

    public var startText: String { YouTubeFormat.clock(start) }

    /// Parses the `chapterRenderer` payloads, in playing order.
    ///
    /// Sorted rather than trusted: chapters arrive in order today, and a
    /// list that seeks backwards would be a strange thing to hand someone.
    /// A chapter without a title is dropped — an unnamed row in a chapter
    /// list is a seek button pretending to be information.
    public static func parse(fromRenderers renderers: [String]) -> [YouTubeChapter] {
        var chapters: [YouTubeChapter] = []
        var seen = Set<Int>()
        for renderer in renderers {
            guard let data = renderer.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
                      as? [String: Any]
            else { continue }
            let title = YouTubeText.read(object["title"])
            guard !title.isEmpty else { continue }
            guard let millis = YouTubeText.integer(object["timeRangeStartMillis"])
            else { continue }
            let start = millis / 1000
            guard start >= 0, !seen.contains(start) else { continue }
            seen.insert(start)
            chapters.append(YouTubeChapter(title: title, start: start))
        }
        return chapters.sorted { $0.start < $1.start }
    }

    /// The chapter playing at a given moment, for the name in the transport.
    /// Nil before the first chapter starts, which is a real state on videos
    /// whose chapter list doesn't begin at zero.
    public static func current(
        at seconds: Double, in chapters: [YouTubeChapter]
    ) -> YouTubeChapter? {
        var current: YouTubeChapter?
        for chapter in chapters {
            if Double(chapter.start) <= seconds { current = chapter } else { break }
        }
        return current
    }
}

/// One subtitle track the player can be switched to.
public struct YouTubeCaptionTrack: Equatable, Sendable, Identifiable {
    /// The code `youtube.captions` takes — "en", "pt-BR", "es-419".
    public var id: String { languageCode }
    public var languageCode: String
    public var label: String
    /// Machine transcription rather than an authored track.
    public var isAutomatic: Bool

    public init(languageCode: String, label: String, isAutomatic: Bool = false) {
        self.languageCode = languageCode
        self.label = label
        self.isAutomatic = isAutomatic
    }

    /// Parses `captions.playerCaptionsTracklistRenderer.captionTracks`.
    ///
    /// One track per language: YouTube ships an authored English track and
    /// an auto-generated one under the same code, and a menu offering
    /// "English" twice is a menu that can't be used. The authored one wins.
    public static func parse(fromTracks tracks: [String]) -> [YouTubeCaptionTrack] {
        var byLanguage: [String: YouTubeCaptionTrack] = [:]
        var order: [String] = []
        for track in tracks {
            guard let data = track.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
                      as? [String: Any],
                  let code = object["languageCode"] as? String, !code.isEmpty
            else { continue }
            let automatic = (object["kind"] as? String) == "asr"
            let label = YouTubeText.read(object["name"])
            let parsed = YouTubeCaptionTrack(
                languageCode: code,
                label: label.isEmpty ? code : label,
                isAutomatic: automatic
            )
            if let existing = byLanguage[code] {
                // Authored beats automatic; otherwise first seen wins.
                if existing.isAutomatic, !automatic { byLanguage[code] = parsed }
            } else {
                byLanguage[code] = parsed
                order.append(code)
            }
        }
        return order.compactMap { byLanguage[$0] }
    }
}

// MARK: - Reading YouTube's text nodes

/// The two shapes every piece of text on YouTube arrives in.
enum YouTubeText {

    /// Reads `{simpleText:}`, `{runs:[{text:}]}`, or a bare string.
    ///
    /// Runs are joined rather than taking the first: a live stream's view
    /// count is `["3", " watching"]`, and the first run alone says "3".
    static func read(_ node: Any?) -> String {
        if let string = node as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let object = node as? [String: Any] else { return "" }
        if let simple = object["simpleText"] as? String {
            return simple.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let runs = object["runs"] as? [Any] {
            let joined = runs.compactMap { ($0 as? [String: Any])?["text"] as? String }
                .joined()
            return joined.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// The first of several nodes that reads as anything.
    static func firstNonEmpty(_ nodes: Any?...) -> String {
        for node in nodes {
            let text = read(node)
            if !text.isEmpty { return text }
        }
        return ""
    }

    /// An integer that may have been shipped as a number or as a string —
    /// YouTube does both, in the same payload.
    static func integer(_ node: Any?) -> Int? {
        if let value = node as? Int { return value }
        if let value = node as? Double { return Int(value) }
        if let string = node as? String { return Int(string) }
        return nil
    }
}

// MARK: - Formatting

/// The judgements about how YouTube's numbers should read.
public enum YouTubeFormat {

    /// "10:31:02" or "2:51" into seconds. Nil when there is no clock to read
    /// — a live stream ships no length text at all.
    public static func seconds(fromClock text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Seconds back into a clock, dropping the hour when there isn't one.
    public static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "156,290 views" into "156K views", keeping whatever noun followed.
    ///
    /// Truncated rather than rounded, which is what YouTube itself does:
    /// 743,996 reads as 743K on the site, not 744K. Text with no leading
    /// number — "No views" — passes through untouched, because it is
    /// already the sentence it wants to be.
    public static func compactCount(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        var digits = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character.isNumber { digits.append(character) }
            else if character != "," { break }
            index = trimmed.index(after: index)
        }
        guard let value = Int(digits) else { return trimmed }

        let suffix = String(trimmed[index...])
            .trimmingCharacters(in: .whitespaces)
        let compacted = abbreviate(value)
        return suffix.isEmpty ? compacted : "\(compacted) \(suffix)"
    }

    /// 156,290 → "156K"; 4,120,465 → "4.1M"; 11,035,546 → "11M".
    ///
    /// The decimal appears only in the first decade of each magnitude, where
    /// it carries information; past ten the tenth of a million is noise.
    public static func abbreviate(_ value: Int) -> String {
        func scaled(_ value: Int, _ unit: Int, _ symbol: String) -> String {
            let whole = value / unit
            if whole >= 10 { return "\(whole)\(symbol)" }
            let tenths = (value % unit) / (unit / 10)
            return tenths == 0 ? "\(whole)\(symbol)" : "\(whole).\(tenths)\(symbol)"
        }
        switch value {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return scaled(value, 1_000, "K")
        case ..<1_000_000_000: return scaled(value, 1_000_000, "M")
        default: return scaled(value, 1_000_000_000, "B")
        }
    }

    /// "Streamed 4 years ago" into "4 years ago".
    ///
    /// That a video was once a livestream is something the card has no room
    /// to say and no reason to: what the reader wants from this field is
    /// when, and the prefix pushes the when out of a narrow column.
    public static func published(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let prefix = "streamed "
        guard trimmed.lowercased().hasPrefix(prefix) else { return trimmed }
        return String(trimmed.dropFirst(prefix.count))
    }
}
