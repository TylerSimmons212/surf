import Foundation

/// The filename a screenshot saves under: the page's own name, then the
/// moment — `Wikipedia — 2026-08-20 at 10.42.13.png`.
///
/// Title first rather than "Screenshot" first, deliberately: a folder of
/// captures sorts and scans by what they're *of*, and the macOS convention of
/// leading with "Screenshot" makes every file findable only by squinting at
/// timestamps.
public enum ScreenshotNaming {

    public static func filename(title: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Dots in the time, not colons — HFS+ history aside, colons are the
        // one character Finder still refuses.
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(sanitize(title)) — \(formatter.string(from: date)).png"
    }

    /// A title is arbitrary page text; a filename is not.
    static func sanitize(_ title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        var out = title
            .components(separatedBy: illegal)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse runs of whitespace the removal may have left.
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        if out.isEmpty { out = "Page" }
        // Long enough to keep any real title, short enough that the full
        // name with its timestamp never brushes filesystem limits.
        if out.count > 120 {
            out = String(out.prefix(120)).trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}
