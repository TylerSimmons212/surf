import Testing

@testable import SurfCore

@Suite("Console buffer")
struct ConsoleBufferTests {

    private func message(
        _ text: String,
        level: ConsoleLevel = .log,
        at timestamp: Double = 0
    ) -> ConsoleEntry {
        ConsoleEntry(
            id: 0,
            level: level,
            arguments: [RemoteObject(type: .string, description: text)],
            timestamp: timestamp
        )
    }

    /// A page logging the same line in a loop would otherwise bury everything
    /// else under thousands of identical rows.
    @Test("A message repeating in a row folds into one counted line")
    func coalescesRepeats() {
        var buffer = ConsoleBuffer()
        let first = buffer.append(message("tick"))
        let second = buffer.append(message("tick", at: 1))

        #expect(first == .added(id: 1))
        #expect(second == .coalesced(into: 1))
        #expect(buffer.entries.count == 1)
        #expect(buffer.entries[0].repeatCount == 2)
        // The row moves to the latest occurrence — "when did this last happen"
        // is the question being asked of a repeating message.
        #expect(buffer.entries[0].timestamp == 1)
    }

    /// A message that recurs *after* other output is a genuinely separate
    /// event; folding it into the earlier row would move it back in time.
    @Test("A repeat separated by other output stays its own line")
    func doesNotCoalesceAcrossOtherMessages() {
        var buffer = ConsoleBuffer()
        buffer.append(message("tick"))
        buffer.append(message("tock"))
        buffer.append(message("tick"))

        #expect(buffer.entries.count == 3)
        #expect(buffer.entries.allSatisfy { $0.repeatCount == 1 })
    }

    @Test("Same text at a different level is a different message")
    func levelBreaksCoalescing() {
        var buffer = ConsoleBuffer()
        buffer.append(message("careful"))
        buffer.append(message("careful", level: .error))

        #expect(buffer.entries.count == 2)
    }

    @Test("The buffer never grows past its capacity")
    func capacityHolds() {
        var buffer = ConsoleBuffer(capacity: 3)
        for index in 0..<10 {
            buffer.append(message("line \(index)"))
        }

        #expect(buffer.entries.count == 3)
        // Oldest first out, so the newest output is what survives.
        #expect(buffer.entries.first?.text == "line 7")
        #expect(buffer.entries.last?.text == "line 9")
    }

    /// An objectId that falls off the end without being released pins a page
    /// object alive for as long as the document lives — a leak the user causes
    /// simply by leaving the console open.
    @Test("Evicted rows surrender their object handles exactly once")
    func evictionReleasesObjects() {
        var buffer = ConsoleBuffer(capacity: 1)
        buffer.append(ConsoleEntry(
            id: 0,
            arguments: [RemoteObject(type: .object, description: "{}", objectId: "obj-1")]
        ))
        buffer.append(message("pushes the first one out"))

        let released = buffer.takeEvictedObjectIds()
        #expect(released == ["obj-1"])
        // Taken means taken: a second drain must not re-release.
        #expect(buffer.takeEvictedObjectIds().isEmpty)
    }

    @Test("Clearing releases every handle it was holding")
    func clearReleasesObjects() {
        var buffer = ConsoleBuffer()
        buffer.append(ConsoleEntry(
            id: 0,
            arguments: [RemoteObject(type: .object, description: "{}", objectId: "obj-1")]
        ))
        buffer.clear()

        #expect(buffer.isEmpty)
        #expect(buffer.takeEvictedObjectIds() == ["obj-1"])
    }

    @Test("Navigating clears the log unless preservation is on")
    func navigationClears() {
        var buffer = ConsoleBuffer()
        buffer.append(message("from the old page"))
        buffer.markNavigation(url: "https://example.com/", preservingLog: false)

        #expect(buffer.isEmpty)
    }

    @Test("Preserving the log leaves a divider rather than a gap")
    func navigationDivides() {
        var buffer = ConsoleBuffer()
        buffer.append(message("from the old page"))
        buffer.markNavigation(url: "https://example.com/", preservingLog: true)
        buffer.append(message("from the new page"))

        #expect(buffer.entries.count == 3)
        #expect(buffer.entries[1].kind == .navigation(url: "https://example.com/"))
    }

    /// A divider is structure rather than a message: hiding it because it isn't
    /// an error would silently merge two pages' output into one stream.
    @Test("A level filter keeps navigation dividers")
    func filterKeepsDividers() {
        var buffer = ConsoleBuffer()
        buffer.append(message("chatter"))
        buffer.markNavigation(url: "https://example.com/", preservingLog: true)
        buffer.append(message("boom", level: .error))

        let errorsOnly = buffer.filtered(levels: [.error], query: "")
        #expect(errorsOnly.count == 2)
        #expect(errorsOnly.first?.kind == .navigation(url: "https://example.com/"))
    }

    /// Between search hits a divider is noise, not structure.
    @Test("A text search drops navigation dividers")
    func searchDropsDividers() {
        var buffer = ConsoleBuffer()
        buffer.markNavigation(url: "https://example.com/", preservingLog: true)
        buffer.append(message("findable"))

        #expect(buffer.filtered(levels: Set(ConsoleLevel.allCases), query: "find").count == 1)
    }

    @Test("Search matches message text and source, case-insensitively")
    func searchMatchesTextAndSource() {
        var buffer = ConsoleBuffer()
        buffer.append(message("Something Happened"))
        var withSource = message("quiet")
        withSource.source = SourceLocation(url: "https://example.com/app.js", line: 4, column: 1)
        buffer.append(withSource)

        let all = Set(ConsoleLevel.allCases)
        #expect(buffer.filtered(levels: all, query: "SOMETHING").count == 1)
        #expect(buffer.filtered(levels: all, query: "app.js").count == 1)
        #expect(buffer.filtered(levels: all, query: "absent").isEmpty)
    }

    /// A row standing for 400 errors is 400 errors — a badge reading "1" would
    /// understate the problem by the exact factor that makes it a problem.
    @Test("Level counts include folded repeats")
    func countsIncludeRepeats() {
        var buffer = ConsoleBuffer()
        buffer.append(message("boom", level: .error))
        buffer.append(message("boom", level: .error, at: 1))
        buffer.append(message("fine"))

        let counts = buffer.counts()
        #expect(counts[.error] == 2)
        #expect(counts[.log] == 1)
    }
}

@Suite("Console values")
struct ConsoleValueTests {

    /// `console.log("hi")` prints `hi`, but `["hi"]` has to print `["hi"]` or
    /// it's indistinguishable from an array holding a variable named hi.
    @Test("Strings are bare at the top level and quoted when nested")
    func stringQuoting() {
        let string = RemoteObject(type: .string, description: "hi")
        #expect(string.description == "hi")
        #expect(string.quotedDescription == "\"hi\"")

        let number = RemoteObject(type: .number, description: "42")
        #expect(number.quotedDescription == "42")
    }

    @Test("A source location shows the filename, not the whole URL")
    func sourceLabel() {
        let location = SourceLocation(
            url: "https://example.com/static/js/app.bundle.js?v=3",
            line: 42,
            column: 7
        )
        #expect(location.shortLabel == "app.bundle.js:42")
    }
}

@Suite("Console wire format")
struct ConsoleWireTests {

    @Test("A full entry decodes")
    func decodesEntry() {
        let entry = ConsoleWire.decodeEntry([
            "level": "error",
            "args": [["type": "string", "description": "boom"]],
            "source": ["url": "https://example.com/app.js", "line": 12, "column": 3],
            "groupDepth": 2,
            "timestamp": 1000.5,
            "frame": "https://example.com/frame.html",
        ])

        #expect(entry.level == .error)
        #expect(entry.text == "boom")
        #expect(entry.source?.line == 12)
        #expect(entry.groupDepth == 2)
        #expect(entry.frameLabel == "https://example.com/frame.html")
    }

    /// The page can post anything it likes to our handler. Nothing it sends may
    /// produce an unreadable row, let alone crash the browser hosting it.
    @Test("A hostile or empty entry still decodes to something renderable")
    func toleratesGarbage() {
        let empty = ConsoleWire.decodeEntry([:])
        #expect(empty.level == .log)
        #expect(empty.arguments.isEmpty)
        #expect(empty.source == nil)
        #expect(empty.repeatCount == 1)

        let nonsense = ConsoleWire.decodeEntry([
            "level": "catastrophe",
            "groupDepth": -5,
            "repeatCount": 0,
            "args": [["type": "wat"]],
        ])
        #expect(nonsense.level == .log)
        // An unmatched groupEnd must not indent the rest of the log backwards.
        #expect(nonsense.groupDepth == 0)
        #expect(nonsense.repeatCount == 1)
        #expect(nonsense.arguments.first?.type == .object)
        #expect(nonsense.arguments.first?.description == "undefined")
    }

    @Test("An empty frame label reads as the main frame, not a blank iframe")
    func emptyFrameIsNil() {
        #expect(ConsoleWire.decodeEntry(["frame": ""]).frameLabel == nil)
    }

    @Test("Previews decode with their overflow flag")
    func decodesPreview() {
        let object = ConsoleWire.decodeObject([
            "type": "object",
            "className": "Object",
            "description": "Object",
            "preview": [
                "entries": [
                    ["key": "name", "value": ["type": "string", "description": "ada"]]
                ],
                "overflow": true,
            ],
        ])

        #expect(object.preview?.entries.count == 1)
        #expect(object.preview?.entries.first?.key == "name")
        #expect(object.preview?.entries.first?.value.description == "ada")
        // Without this the UI would imply a five-key object was the whole thing.
        #expect(object.preview?.overflow == true)
    }

    @Test("A batch carries its sequence number for acking")
    func decodesBatch() {
        let batch = ConsoleWire.decodeBatch([
            "entries": [["level": "log", "args": []]],
            "sequence": 7,
        ])
        #expect(batch?.sequence == 7)
        #expect(batch?.entries.count == 1)
        #expect(batch?.entries.first?.isBacklog == false)
        #expect(batch?.dropped == 0)
    }

    /// A console that silently skips output is worse than one that admits it,
    /// so the count has to survive the wire rather than being inferred.
    @Test("A batch reports how much output the agent had to drop")
    func decodesDropCount() {
        #expect(ConsoleWire.decodeBatch(["entries": [], "dropped": 4000])?.dropped == 4000)
        // A negative count is nonsense and must not become a negative gap.
        #expect(ConsoleWire.decodeBatch(["entries": [], "dropped": -1])?.dropped == 0)
    }

    /// Backlog entries were serialized before dev tools opened, so their
    /// arguments can be read but not expanded. Rendering a disclosure arrow
    /// that does nothing is worse than rendering none.
    @Test("Backlog batches mark their entries as unexpandable")
    func marksBacklog() {
        let batch = ConsoleWire.decodeBatch([
            "entries": [["level": "log", "args": []]],
            "backlog": true,
        ])
        #expect(batch?.entries.first?.isBacklog == true)
    }

    @Test("A malformed batch is dropped rather than guessed at")
    func rejectsMalformedBatch() {
        #expect(ConsoleWire.decodeBatch("not a dictionary") == nil)
    }
}

@Suite("Object property pages")
struct ObjectPropertyTests {

    /// The count has to survive the wire separately from the page. It used to
    /// ride on the JS array as an extra property, which `JSON.stringify` drops
    /// — so a five-thousand-key object reported exactly the page size and the
    /// "show more" affordance never appeared.
    @Test("A page reports the object's real size, not the page size")
    func totalSurvivesTheWire() {
        let reply = ConsoleWire.decodeProperties([
            "properties": [["name": "a", "value": ["type": "number", "description": "1"]]],
            "total": 5000,
        ])
        #expect(reply.properties.count == 1)
        #expect(reply.total == 5000)
    }

    /// A total smaller than the page in hand is nonsense, and would render as
    /// a negative "show N more".
    @Test("A total below the page size is corrected upward")
    func totalNeverUnderstatesThePage() {
        let reply = ConsoleWire.decodeProperties([
            "properties": [
                ["name": "a", "value": [:]],
                ["name": "b", "value": [:]],
            ],
            "total": 0,
        ])
        #expect(reply.total == 2)
    }

    @Test("A getter is marked so it can be shown unevaluated")
    func accessorsAreMarked() {
        let reply = ConsoleWire.decodeProperties([
            "properties": [["name": "x", "isAccessor": true, "value": ["description": "(…)"]]],
        ])
        #expect(reply.properties.first?.isAccessor == true)
    }
}
