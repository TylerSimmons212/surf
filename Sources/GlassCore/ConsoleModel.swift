import Foundation

// MARK: - Values

/// How a JavaScript value is described across the bridge.
///
/// Modelled on the Chrome DevTools Protocol's `RemoteObject`, because the shape
/// solves a real problem rather than being a convention: a console has to render
/// something useful for a value it has *not* fully serialized. So every value
/// carries a `description` that renders collapsed, an optional shallow
/// `preview`, and — later — an `objectId` to fetch the rest on demand.
public enum RemoteObjectType: String, Sendable, Equatable {
    case object, function, string, number, boolean, undefined, symbol, bigint
}

public enum RemoteObjectSubtype: String, Sendable, Equatable {
    case array, null, node, regexp, date, map, set, error, promise
}

/// One line of a collapsed object's inline preview: `{ name: "ada", age: 36 }`.
public struct PreviewEntry: Sendable, Equatable {
    /// Nil for array elements, which are shown positionally.
    public var key: String?
    public var value: RemoteObject

    public init(key: String?, value: RemoteObject) {
        self.key = key
        self.value = value
    }
}

public struct ObjectPreview: Sendable, Equatable {
    public var entries: [PreviewEntry]
    /// True when the object had more than the preview shows, so the UI can say
    /// "…" rather than implying the object is small.
    public var overflow: Bool

    public init(entries: [PreviewEntry], overflow: Bool) {
        self.entries = entries
        self.overflow = overflow
    }
}

public struct RemoteObject: Sendable, Equatable {
    public var type: RemoteObjectType
    public var subtype: RemoteObjectSubtype?
    public var className: String?
    /// What renders when collapsed. Always present — a value with no readable
    /// description is a value the console can't show at all.
    public var description: String
    public var preview: ObjectPreview?
    /// A handle for fetching the rest. Nil means there is nothing more to get,
    /// and nothing to release either.
    public var objectId: String?

    public init(
        type: RemoteObjectType,
        subtype: RemoteObjectSubtype? = nil,
        className: String? = nil,
        description: String,
        preview: ObjectPreview? = nil,
        objectId: String? = nil
    ) {
        self.type = type
        self.subtype = subtype
        self.className = className
        self.description = description
        self.preview = preview
        self.objectId = objectId
    }

    /// Strings print bare at the top level (`console.log("hi")` → `hi`) but
    /// quoted inside a structure, so `["hi"]` can't be mistaken for `[hi]`.
    public var quotedDescription: String {
        type == .string ? "\"\(description)\"" : description
    }
}

// MARK: - Entries

public enum ConsoleLevel: String, Sendable, Equatable, CaseIterable, Comparable {
    case debug, log, info, warning, error

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// Grouped for the filter bar, where "Errors" sensibly means errors *and*
    /// warnings would be a lie — so they stay separate, but debug folds into
    /// log because nobody filters for it alone.
    public var isProblem: Bool { self == .error || self == .warning }
}

public struct SourceLocation: Sendable, Equatable {
    public var url: String
    public var line: Int
    public var column: Int

    public init(url: String, line: Int, column: Int) {
        self.url = url
        self.line = line
        self.column = column
    }

    /// `app.js:42` — the filename alone, since the full URL is long and the
    /// interesting part is at the end.
    public var shortLabel: String {
        let file = url.split(separator: "/").last.map(String.init) ?? url
        let trimmed = file.split(separator: "?").first.map(String.init) ?? file
        return trimmed.isEmpty ? "\(line)" : "\(trimmed):\(line)"
    }
}

/// One property of an expanded object.
public struct ObjectProperty: Sendable, Equatable, Identifiable {
    public var name: String
    public var value: RemoteObject
    /// A getter, shown unevaluated. Running it would execute page code as a
    /// side effect of looking at the object, which can change the state being
    /// inspected — so it's displayed as `(…)` and left alone.
    public var isAccessor: Bool
    /// Non-enumerable properties are dimmed, matching every other devtools.
    public var isEnumerable: Bool

    public var id: String { name }

    public init(
        name: String,
        value: RemoteObject,
        isAccessor: Bool = false,
        isEnumerable: Bool = true
    ) {
        self.name = name
        self.value = value
        self.isAccessor = isAccessor
        self.isEnumerable = isEnumerable
    }
}

public enum ConsoleEntryKind: Sendable, Equatable {
    case message
    /// A page load, rendered as a divider. Kept in the same list rather than
    /// clearing it, so "preserve log" is a display decision rather than a
    /// different data path.
    case navigation(url: String)
    /// What was typed at the prompt, echoed back so the log reads as a
    /// conversation rather than a stream of unattributed answers.
    case input
    /// What an evaluation returned.
    case result
}

public struct ConsoleEntry: Sendable, Equatable, Identifiable {
    public var id: Int
    public var kind: ConsoleEntryKind
    public var level: ConsoleLevel
    public var arguments: [RemoteObject]
    public var source: SourceLocation?
    public var groupDepth: Int
    public var timestamp: Double
    /// Set for logs from a subframe, so an iframe's noise is attributable.
    public var frameLabel: String?
    /// How many identical messages this row stands for. 1 means "just this one".
    public var repeatCount: Int
    /// True for entries captured before dev tools opened. Their arguments were
    /// serialized eagerly and the references dropped, so they can be read but
    /// not expanded — worth saying rather than showing a dead disclosure arrow.
    public var isBacklog: Bool

    public init(
        id: Int,
        kind: ConsoleEntryKind = .message,
        level: ConsoleLevel = .log,
        arguments: [RemoteObject] = [],
        source: SourceLocation? = nil,
        groupDepth: Int = 0,
        timestamp: Double = 0,
        frameLabel: String? = nil,
        repeatCount: Int = 1,
        isBacklog: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.level = level
        self.arguments = arguments
        self.source = source
        self.groupDepth = groupDepth
        self.timestamp = timestamp
        self.frameLabel = frameLabel
        self.repeatCount = repeatCount
        self.isBacklog = isBacklog
    }

    /// The whole message as one line, for display and for searching.
    public var text: String {
        arguments.map(\.description).joined(separator: " ")
    }

    /// Two entries are "the same message" when everything but identity and
    /// count matches. Timestamps deliberately don't count — a message repeating
    /// is the same message whenever it happens.
    func isRepeat(of other: ConsoleEntry) -> Bool {
        kind == other.kind
            && level == other.level
            && arguments == other.arguments
            && source == other.source
            && groupDepth == other.groupDepth
            && frameLabel == other.frameLabel
    }
}

// MARK: - Buffer

public enum ConsoleAppendResult: Sendable, Equatable {
    case added(id: Int)
    /// Folded into the row above, whose `repeatCount` went up.
    case coalesced(into: Int)
}

/// A bounded, coalescing console log.
///
/// Both properties matter for the same reason: the page you have dev tools open
/// on is disproportionately likely to be the page logging in a loop. Without a
/// cap the browser grows without limit; without coalescing the interesting
/// message is buried under ten thousand copies of a boring one.
public struct ConsoleBuffer: Sendable, Equatable {

    public private(set) var entries: [ConsoleEntry] = []
    /// Object handles that fell off the end of the buffer and must be released
    /// in the page. Draining this is the caller's job — an unreleased id pins a
    /// page object alive for as long as the document lives.
    public private(set) var evictedObjectIds: [String] = []

    public let capacity: Int
    private var nextID = 1

    public init(capacity: Int = 5_000) {
        self.capacity = max(1, capacity)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Appends, or folds into the previous row if it's the same message again.
    ///
    /// The incoming entry's own `id` is ignored: ids are the buffer's to hand
    /// out, so the page can't collide with itself across a navigation.
    @discardableResult
    public mutating func append(_ entry: ConsoleEntry) -> ConsoleAppendResult {
        // Only *consecutive* repeats fold. A message that recurs after other
        // output is genuinely a second event, and burying it in an earlier
        // row's count would move it back in time.
        if case .message = entry.kind,
           var last = entries.last,
           last.isRepeat(of: entry) {
            last.repeatCount += 1
            last.timestamp = entry.timestamp
            entries[entries.count - 1] = last
            return .coalesced(into: last.id)
        }

        var stored = entry
        stored.id = nextID
        nextID += 1
        entries.append(stored)
        trim()
        return .added(id: stored.id)
    }

    public mutating func clear() {
        for entry in entries {
            evictedObjectIds.append(contentsOf: entry.arguments.compactMap(\.objectId))
        }
        entries.removeAll()
    }

    /// Records a page load. With preservation off this empties the log, which
    /// is the default every browser ships and the right one — yesterday's
    /// output is usually noise.
    public mutating func markNavigation(url: String, preservingLog: Bool) {
        if !preservingLog {
            clear()
            return
        }
        append(ConsoleEntry(id: 0, kind: .navigation(url: url), timestamp: 0))
    }

    /// Hands back the object ids that need releasing, and forgets them.
    public mutating func takeEvictedObjectIds() -> [String] {
        defer { evictedObjectIds.removeAll() }
        return evictedObjectIds
    }

    /// What the pane renders. Navigation dividers survive a level filter —
    /// they're structure, not messages — but not a text search, where they'd
    /// be noise between hits.
    public func filtered(levels: Set<ConsoleLevel>, query: String) -> [ConsoleEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()

        return entries.filter { entry in
            switch entry.kind {
            case .navigation:
                return needle.isEmpty
            case .input, .result:
                // Never hidden by a level filter — what you typed, and what it
                // answered, are the one part of the log you definitely meant
                // to see. A text search still applies.
                return needle.isEmpty || entry.text.lowercased().contains(needle)
            case .message:
                break
            }
            guard levels.contains(entry.level) else { return false }
            guard !needle.isEmpty else { return true }
            if entry.text.lowercased().contains(needle) { return true }
            return entry.source?.url.lowercased().contains(needle) ?? false
        }
    }

    /// Per-level totals for the filter bar's badges. Counts repeats, because a
    /// row standing for 400 errors is 400 errors.
    public func counts() -> [ConsoleLevel: Int] {
        var totals: [ConsoleLevel: Int] = [:]
        for entry in entries {
            guard case .message = entry.kind else { continue }
            totals[entry.level, default: 0] += entry.repeatCount
        }
        return totals
    }

    private mutating func trim() {
        guard entries.count > capacity else { return }
        let overflow = entries.prefix(entries.count - capacity)
        for entry in overflow {
            evictedObjectIds.append(contentsOf: entry.arguments.compactMap(\.objectId))
        }
        entries.removeFirst(entries.count - capacity)
    }
}
