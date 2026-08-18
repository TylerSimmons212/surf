import Testing

@testable import GlassCore

@Suite("Network bodies")
struct NetworkBodyTests {

    /// "We didn't capture this" and "the response was empty" are different
    /// facts, and showing a blank pane for both is how an inspector stops
    /// being believed.
    @Test("Every reason a body is missing says which one it is")
    func omissions() {
        #expect(BodyOmission.notCaptured.explanation.contains("wasn't open"))
        #expect(BodyOmission.binary.explanation.contains("Binary"))
        #expect(BodyOmission.empty.explanation.contains("Empty"))
        #expect(BodyOmission.notObservable.explanation.contains("fetch"))
    }

    @Test("Content types map to the format the body should be read as")
    func formats() {
        #expect(BodyFormat.from(contentType: "application/json") == .json)
        #expect(BodyFormat.from(contentType: "application/json; charset=utf-8") == .json)
        #expect(BodyFormat.from(contentType: "text/html") == .html)
        #expect(BodyFormat.from(contentType: "application/javascript") == .javascript)
        #expect(BodyFormat.from(contentType: "image/png") == .binary)
        #expect(BodyFormat.from(contentType: "application/x-www-form-urlencoded") == .form)
        // No type at all is likelier to be text than to be a PNG.
        #expect(BodyFormat.from(contentType: "") == .text)
    }

    @Test("The summary names the type and the size")
    func summary() {
        let body = NetworkBody(
            text: "{}", byteCount: 2048, contentType: "application/json; charset=utf-8"
        )
        #expect(body.summary == "application/json · 2.0 kB")
    }

    // MARK: - Pretty printing

    /// The reason this is a re-indenter and not a parse-and-reserialize:
    /// `JSONSerialization` round-trips through a dictionary, which has no
    /// order, so every key in the payload comes back shuffled. For reading an
    /// API response the order the server sent is part of the information.
    @Test("Formatting preserves the order the server sent")
    func preservesOrder() {
        let formatted = JSONPretty.format(#"{"zebra":1,"alpha":2,"middle":3}"#)
        let keys = ["zebra", "alpha", "middle"].map { formatted.range(of: "\"\($0)\"")! }
        #expect(keys[0].lowerBound < keys[1].lowerBound)
        #expect(keys[1].lowerBound < keys[2].lowerBound)
    }

    @Test("Objects and arrays are laid out with nesting")
    func indents() {
        let formatted = JSONPretty.format(#"{"a":1,"b":[2,3]}"#)
        #expect(formatted.contains("\n  \"a\": 1"))
        #expect(formatted.contains("\n  \"b\": ["))
        #expect(formatted.contains("\n    2"))
    }

    /// Braces, commas and colons inside a string are content, not structure.
    /// Formatting on them would corrupt the very values people came to read.
    @Test("Punctuation inside strings is left alone")
    func stringsAreSafe() {
        let formatted = JSONPretty.format(#"{"url":"https://x.test/a,b{c}"}"#)
        #expect(formatted.contains(#""https://x.test/a,b{c}""#))
    }

    @Test("An escaped quote doesn't end the string")
    func escapes() {
        let formatted = JSONPretty.format(#"{"quote":"say \"hi\", ok"}"#)
        #expect(formatted.contains(#"say \"hi\", ok"#))
        // One key, so one line of content — a mis-parsed escape would split it.
        #expect(formatted.components(separatedBy: "\n").count == 3)
    }

    @Test("Anything that isn't JSON is returned untouched")
    func leavesOtherFormatsAlone() {
        #expect(JSONPretty.format("<html><body>hi</body></html>") == "<html><body>hi</body></html>")
        #expect(JSONPretty.format("plain text") == "plain text")
        #expect(JSONPretty.format("") == "")
    }

    /// Already-formatted JSON is left as it came rather than being re-flowed
    /// into a different shape than the server chose.
    @Test("JSON that already has newlines is left as it came")
    func alreadyFormatted() {
        let source = "{\n  \"a\": 1\n}"
        #expect(JSONPretty.format(source) == source)
    }

    @Test("A body only pretty-prints when it's actually JSON")
    func prettyRespectsType() {
        let json = NetworkBody(text: #"{"a":1}"#, contentType: "application/json")
        #expect(json.pretty.contains("\n"))
        let html = NetworkBody(text: #"{"a":1}"#, contentType: "text/html")
        #expect(html.pretty == #"{"a":1}"#)
    }

    /// This runs on whatever a server happened to send, so malformed input must
    /// come back rather than hang or crash.
    @Test("Truncated JSON still terminates")
    func malformed() {
        #expect(!JSONPretty.format(#"{"a":[1,2"#).isEmpty)
        #expect(!JSONPretty.format(#"{"unclosed"#).isEmpty)
    }
}
