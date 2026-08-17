import Foundation

/// Decodes what the injected console agent sends.
///
/// Every field is optional on the wire and defaulted here. The page is not a
/// trusted peer — a half-written batch, a version skew, or a site deliberately
/// posting nonsense to our handler must degrade to a readable row rather than
/// take the browser down with it.
public enum ConsoleWire {

    /// One batch: `{ entries: [...], sequence: n, dropped: n }`.
    public static func decodeBatch(
        _ body: Any
    ) -> (entries: [ConsoleEntry], sequence: Int, dropped: Int)? {
        guard let dict = body as? [String: Any] else { return nil }
        let raw = dict["entries"] as? [[String: Any]] ?? []
        let isBacklog = dict["backlog"] as? Bool ?? false
        return (
            raw.map { decodeEntry($0, isBacklog: isBacklog) },
            dict["sequence"] as? Int ?? 0,
            max(0, dict["dropped"] as? Int ?? 0)
        )
    }

    public static func decodeEntry(_ dict: [String: Any], isBacklog: Bool = false) -> ConsoleEntry {
        ConsoleEntry(
            // Replaced by the buffer, which owns identity.
            id: 0,
            level: ConsoleLevel(rawValue: dict["level"] as? String ?? "") ?? .log,
            arguments: (dict["args"] as? [[String: Any]] ?? []).map(decodeObject),
            source: decodeSource(dict["source"]),
            groupDepth: max(0, dict["groupDepth"] as? Int ?? 0),
            timestamp: dict["timestamp"] as? Double ?? 0,
            frameLabel: (dict["frame"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            repeatCount: max(1, dict["repeatCount"] as? Int ?? 1),
            isBacklog: isBacklog
        )
    }

    /// The reply to `Runtime.getProperties`.
    public static func decodeProperties(_ body: Any) -> [ObjectProperty] {
        guard let dict = body as? [String: Any],
              let raw = dict["properties"] as? [[String: Any]]
        else { return [] }

        return raw.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return ObjectProperty(
                name: name,
                value: decodeObject(entry["value"] as? [String: Any] ?? [:]),
                isAccessor: entry["isAccessor"] as? Bool ?? false,
                isEnumerable: entry["isEnumerable"] as? Bool ?? true
            )
        }
    }

    /// The reply to `Runtime.evaluate`: a value, and whether it was thrown.
    public static func decodeEvaluation(
        _ body: Any
    ) -> (value: RemoteObject, thrown: Bool)? {
        guard let dict = body as? [String: Any] else { return nil }
        return (
            decodeObject(dict["value"] as? [String: Any] ?? [:]),
            dict["thrown"] as? Bool ?? false
        )
    }

    static func decodeSource(_ value: Any?) -> SourceLocation? {
        guard let dict = value as? [String: Any],
              let url = dict["url"] as? String, !url.isEmpty
        else { return nil }
        return SourceLocation(
            url: url,
            line: dict["line"] as? Int ?? 0,
            column: dict["column"] as? Int ?? 0
        )
    }

    static func decodeObject(_ dict: [String: Any]) -> RemoteObject {
        RemoteObject(
            type: RemoteObjectType(rawValue: dict["type"] as? String ?? "") ?? .object,
            subtype: (dict["subtype"] as? String).flatMap(RemoteObjectSubtype.init(rawValue:)),
            className: dict["className"] as? String,
            // A value with no description can't be rendered at all, so an
            // unreadable one becomes the string the console would print anyway.
            description: dict["description"] as? String ?? "undefined",
            preview: decodePreview(dict["preview"]),
            objectId: (dict["objectId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    static func decodePreview(_ value: Any?) -> ObjectPreview? {
        guard let dict = value as? [String: Any],
              let raw = dict["entries"] as? [[String: Any]]
        else { return nil }

        let entries = raw.map { entry in
            PreviewEntry(
                key: entry["key"] as? String,
                // Preview values are shallow by construction, so this never
                // recurses more than one level regardless of what arrives.
                value: decodeObject(entry["value"] as? [String: Any] ?? [:])
            )
        }
        return ObjectPreview(entries: entries, overflow: dict["overflow"] as? Bool ?? false)
    }
}
