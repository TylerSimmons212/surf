import Foundation

/// Why a body isn't here, when it isn't.
///
/// Distinguished rather than collapsed into an empty string, because "we did
/// not capture this" and "the response was empty" are different facts and
/// showing a blank pane for both is how an inspector loses your trust.
public enum BodyOmission: String, Sendable, Equatable {
    /// Nothing was recorded — the panel wasn't attached when this ran.
    case notCaptured
    /// Not text, so there is nothing useful to print.
    case binary
    /// Past the cap. Bodies are held in the page, and an unbounded cache in
    /// someone's tab is not a thing a devtools panel gets to create.
    case tooLarge
    case empty
    /// Only fetch and XHR can be observed at all.
    case notObservable

    public var explanation: String {
        switch self {
        case .notCaptured:
            "Not captured — dev tools wasn't open when this request ran."
        case .binary:
            "Binary response — nothing to show as text."
        case .tooLarge:
            "Too large to capture."
        case .empty:
            "Empty response."
        case .notObservable:
            "Only fetch and XMLHttpRequest bodies can be observed."
        }
    }
}

public enum BodyFormat: String, Sendable, Equatable {
    case json, html, css, javascript, xml, text, form, binary

    public static func from(contentType: String) -> BodyFormat {
        let type = contentType.lowercased()
        if type.contains("json") { return .json }
        if type.contains("html") { return .html }
        if type.contains("css") { return .css }
        if type.contains("javascript") || type.contains("ecmascript") { return .javascript }
        if type.contains("xml") { return .xml }
        if type.contains("x-www-form-urlencoded") { return .form }
        if type.hasPrefix("text/") { return .text }
        if type.isEmpty { return .text }
        return .binary
    }
}

public struct NetworkBody: Sendable, Equatable {
    public var text: String
    public var byteCount: Int
    public var isTruncated: Bool
    public var contentType: String
    public var omission: BodyOmission?

    public init(
        text: String = "",
        byteCount: Int = 0,
        isTruncated: Bool = false,
        contentType: String = "",
        omission: BodyOmission? = nil
    ) {
        self.text = text
        self.byteCount = byteCount
        self.isTruncated = isTruncated
        self.contentType = contentType
        self.omission = omission
    }

    public var isEmpty: Bool { text.isEmpty }
    public var format: BodyFormat { BodyFormat.from(contentType: contentType) }

    /// JSON re-indented; anything else as it came.
    public var pretty: String {
        format == .json ? JSONPretty.format(text) : text
    }

    /// `application/json · 1.2 kB` — the line above the body.
    public var summary: String {
        let type = contentType.split(separator: ";").first.map(String.init) ?? contentType
        let size = NetworkRequest.formatBytes(byteCount)
        if type.isEmpty { return size }
        return "\(type) · \(size)"
    }
}

/// Re-indents JSON without reordering it.
///
/// Deliberately a re-indenter rather than a parse-and-reserialize:
/// `JSONSerialization` builds a dictionary, and a dictionary has no order, so
/// round-tripping through it shuffles every key in the payload. For reading an
/// API response the order the server sent is part of the information — and a
/// body that came back scrambled would be worse than one left minified.
public enum JSONPretty {

    public static func format(_ source: String, indent: String = "  ") -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cheap guards: not JSON, or already laid out.
        guard let first = trimmed.first, first == "{" || first == "[" else { return source }
        guard !trimmed.contains("\n") else { return source }

        var out = ""
        out.reserveCapacity(source.count + source.count / 4)
        var depth = 0
        var inString = false
        var escaped = false

        func newline(_ level: Int) {
            out.append("\n")
            out.append(String(repeating: indent, count: max(0, level)))
        }

        for character in trimmed {
            if escaped {
                out.append(character)
                escaped = false
                continue
            }
            if inString {
                out.append(character)
                if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }

            switch character {
            case "\"":
                inString = true
                out.append(character)
            case "{", "[":
                out.append(character)
                depth += 1
                newline(depth)
            case "}", "]":
                depth -= 1
                newline(depth)
                out.append(character)
            case ",":
                out.append(character)
                newline(depth)
            case ":":
                out.append(": ")
            case " ", "\t":
                // Whitespace between tokens is noise; inside strings it was
                // handled above.
                continue
            default:
                out.append(character)
            }
        }
        return out
    }
}
