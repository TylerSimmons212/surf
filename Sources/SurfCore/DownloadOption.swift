import Foundation

/// One thing a person could choose to download.
///
/// The engine already decides this for itself, and well — tallest wins, codec
/// breaks a tie. This exists because the decision is sometimes theirs: 4K AV1 is
/// two and a half times the size of 1080p H.264 for the same ten minutes, and on
/// a metered connection or an older machine that is not obviously the better
/// answer. Deciding it silently was the mistake; offering it is the fix.
///
/// Built from whatever the source knows — a page's format list, or a parsed
/// manifest's renditions — so the menu reads the same whichever it came from.
public struct DownloadOption: Equatable, Sendable, Identifiable {

    /// Whatever the source calls this rendition. An itag on YouTube, a playlist
    /// URL elsewhere. Opaque here, and handed back untouched when it is chosen.
    public var id: String

    public var height: Int?
    /// Bits per second, for estimating a size.
    public var bitrate: Int?
    /// The mime or codec string the source gave, kept verbatim.
    public var codecs: String
    public var isAudioOnly: Bool
    /// An exact byte count, where the source states one.
    ///
    /// Preferred over the estimate whenever it exists, because the estimate is
    /// wrong in a way that matters: a bitrate is the peak and the figure it
    /// produces ran more than double the real file — 550MB against 214MB for the
    /// same rendition. A menu whose whole job is comparing sizes cannot be out by
    /// that much.
    public var exactBytes: Int?

    public init(
        id: String, height: Int? = nil, bitrate: Int? = nil,
        codecs: String = "", isAudioOnly: Bool = false, exactBytes: Int? = nil
    ) {
        self.id = id
        self.height = height
        self.bitrate = bitrate
        self.codecs = codecs
        self.isAudioOnly = isAudioOnly
        self.exactBytes = exactBytes
    }

    /// `2160p`, or `Audio only`.
    public var title: String {
        if isAudioOnly { return "Audio only" }
        guard let height, height > 0 else { return "Video" }
        return "\(height)p"
    }

    /// `AV1 · 543 MB`, with whichever halves are known.
    ///
    /// Takes the duration because neither a format list nor a manifest carries a
    /// size: both give a bitrate, and a size is the thing someone actually wants
    /// to compare. An estimate rather than a promise, which is why it is written
    /// with a `~`.
    public func detail(duration: Double?) -> String {
        var parts: [String] = []
        let name = DownloadOption.codecName(codecs)
        if !name.isEmpty { parts.append(name) }
        if let size = exactBytes ?? estimatedBytes(duration: duration) {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = [.useMB, .useGB]
            let text = formatter.string(fromByteCount: Int64(size))
            // The tilde is the difference between a figure and a promise, so it
            // is only there when the figure is one.
            parts.append(exactBytes == nil ? "~" + text : text)
        }
        return parts.joined(separator: " · ")
    }

    /// Nil when there is nothing to estimate from, so a caller shows no size
    /// rather than a confident zero.
    public func estimatedBytes(duration: Double?) -> Int? {
        guard let bitrate, bitrate > 0,
              let duration, duration > 0, duration.isFinite
        else { return nil }
        return Int(Double(bitrate) * duration / 8)
    }

    /// The short name people recognise, from a codec string nobody reads.
    ///
    /// `avc1.64002a` means nothing to anyone outside this file, and the thing a
    /// person is choosing between is "will this play on my machine" — which is a
    /// question about H.264 and AV1, not about profiles and levels.
    public static func codecName(_ codecs: String) -> String {
        let text = codecs.lowercased()
        if text.contains("av01") { return "AV1" }
        if text.contains("avc1") || text.contains("avc3") || text.contains("h264") {
            return "H.264"
        }
        if text.contains("hvc1") || text.contains("hev1") || text.contains("hevc") {
            return "HEVC"
        }
        if text.contains("vp9") || text.contains("vp09") { return "VP9" }
        if text.contains("vp8") { return "VP8" }
        if text.contains("opus") { return "Opus" }
        if text.contains("mp4a") || text.contains("aac") { return "AAC" }
        if text.contains("ec-3") { return "Dolby" }
        if text.contains("ac-3") { return "Dolby" }
        return ""
    }
}

/// Turning what a source offers into what a menu shows.
public enum DownloadOptions {

    /// One row per height, tallest first.
    ///
    /// A site offers the same resolution several times over — YouTube lists
    /// 1080p in H.264, VP9 and AV1, and more than one bitrate of each — and a
    /// menu with six rows saying 1080p is a worse menu than one with six rows
    /// saying different things. So each height appears once, represented by the
    /// encoding most things can play, and the rest are reachable by taking that
    /// height rather than by being listed.
    public static func video(from options: [DownloadOption]) -> [DownloadOption] {
        let videos = options.filter { !$0.isAudioOnly && ($0.height ?? 0) > 0 }
        var best: [Int: DownloadOption] = [:]
        for option in videos {
            guard let height = option.height else { continue }
            guard let existing = best[height] else {
                best[height] = option
                continue
            }
            if rank(option) > rank(existing) { best[height] = option }
        }
        return best.values.sorted { ($0.height ?? 0) > ($1.height ?? 0) }
    }

    /// The best sound on offer, which is the only audio choice worth making.
    ///
    /// Audio is a fraction of a video's size, so there is nothing to save by
    /// taking less of it, and nobody opening a menu wants to compare two
    /// bitrates of the same soundtrack.
    public static func audio(from options: [DownloadOption]) -> DownloadOption? {
        options.filter(\.isAudioOnly).max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
    }

    /// How much a codec is worth when two encodings are the same size of picture.
    /// Higher is more widely playable.
    private static func rank(_ option: DownloadOption) -> Int {
        switch DownloadOption.codecName(option.codecs) {
        case "H.264": 4
        case "HEVC": 3
        case "VP9": 2
        case "AV1": 1
        default: 0
        }
    }
}
