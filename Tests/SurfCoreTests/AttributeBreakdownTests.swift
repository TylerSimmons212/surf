import Testing

@testable import SurfCore

@Suite("Attribute breakdown")
struct AttributeBreakdownTests {

    /// The case this exists for: a Tailwind element carries forty classes on
    /// one line that runs off the edge of every devtools pane.
    @Test("A class attribute splits into its individual classes")
    func classList() {
        let parts = AttributeBreakdown.parts(
            of: "class", value: "flex   items-center\n  gap-2  rounded-lg"
        )
        #expect(parts.map(\.text) == ["flex", "items-center", "gap-2", "rounded-lg"])
    }

    /// Grouping is what makes forty classes legible: base styles separate from
    /// responsive ones from state ones, rather than forty chips in source order.
    @Test("Tailwind variants become groups")
    func variants() {
        let parts = AttributeBreakdown.parts(
            of: "class", value: "flex md:grid hover:bg-blue-500 dark:md:hidden"
        )
        #expect(parts.map(\.group) == [nil, "md", "hover", "dark:md"])
    }

    @Test("A single class is not a list worth expanding")
    func singleClass() {
        #expect(!AttributeBreakdown.isExpandable(name: "class", value: "container"))
        #expect(AttributeBreakdown.kind(of: "class", value: "container") == .plain)
    }

    @Test("An inline style splits into declarations with names and values")
    func styleRules() {
        let parts = AttributeBreakdown.parts(
            of: "style", value: "color: red; margin-top: 4px;"
        )
        #expect(parts.count == 2)
        #expect(parts[0].key == "color")
        #expect(parts[0].value == "red")
        #expect(parts[1].key == "margin-top")
        #expect(parts[1].value == "4px")
    }

    /// A data URL contains semicolons that are not separators — and it is
    /// exactly the sort of value someone opens an inspector to read.
    @Test("Semicolons inside a url() do not split a declaration")
    func dataURLSurvives() {
        let parts = AttributeBreakdown.parts(
            of: "style",
            value: "background: url(data:image/png;base64,iVBORw0KGgo=); color: red"
        )
        #expect(parts.count == 2)
        #expect(parts[0].value == "url(data:image/png;base64,iVBORw0KGgo=)")
        #expect(parts[1].key == "color")
    }

    @Test("Separators inside quotes are left alone")
    func quotedSeparators() {
        let parts = AttributeBreakdown.parts(
            of: "style", value: "content: 'a;b'; color: blue"
        )
        #expect(parts.count == 2)
        #expect(parts[0].value == "'a;b'")
    }

    @Test("A srcset splits into its candidates")
    func candidateList() {
        let parts = AttributeBreakdown.parts(
            of: "srcset", value: "small.png 480w, medium.png 800w, large.png 1200w"
        )
        #expect(parts.count == 3)
        #expect(parts[1].text == "medium.png 800w")
    }

    @Test("A JSON data attribute breaks into its keys, sorted")
    func jsonAttribute() {
        let parts = AttributeBreakdown.parts(
            of: "data-config", value: #"{"zebra": 1, "alpha": "two", "nested": {"a": 1}}"#
        )
        #expect(parts.map(\.key) == ["alpha", "nested", "zebra"])
        #expect(parts[0].value == "two")
        // Nested structures are summarised rather than flattened — the point is
        // to see the shape, not to reprint the whole document.
        #expect(parts[1].value == "{1 keys}")
    }

    @Test("A JSON array breaks into indexed entries")
    func jsonArray() {
        let parts = AttributeBreakdown.parts(of: "data-items", value: #"["a","b"]"#)
        #expect(parts.map(\.key) == ["0", "1"])
    }

    /// Anything that merely starts with a brace is not JSON, and guessing
    /// wrong would mangle a perfectly ordinary value.
    @Test("A value that only looks like JSON is left whole")
    func notJSON() {
        #expect(AttributeBreakdown.kind(of: "data-x", value: "{not json") == .plain)
        #expect(AttributeBreakdown.parts(of: "data-x", value: "{not json").count == 1)
    }

    @Test("An ordinary value stays in one piece")
    func plainValue() {
        let parts = AttributeBreakdown.parts(of: "id", value: "main-content")
        #expect(parts.count == 1)
        #expect(parts[0].text == "main-content")
        #expect(!AttributeBreakdown.isExpandable(name: "id", value: "main-content"))
    }

    @Test("Links are recognised so they can be shown as links")
    func urls() {
        #expect(AttributeBreakdown.kind(of: "href", value: "https://example.com") == .url)
        #expect(AttributeBreakdown.kind(of: "src", value: "/a.png") == .url)
    }

    /// The collapsed row has to say something useful about what's inside
    /// without showing an unreadable line.
    @Test("A summary counts the pieces rather than reprinting the value")
    func summaries() {
        #expect(AttributeBreakdown.summary(of: "class", value: "a b c") == "3 classes")
        #expect(AttributeBreakdown.summary(of: "style", value: "a: 1; b: 2") == "2 declarations")
        #expect(AttributeBreakdown.summary(of: "srcset", value: "a 1x, b 2x") == "2 candidates")
        // Nothing to count: show the value itself.
        #expect(AttributeBreakdown.summary(of: "id", value: "main") == "main")
    }

    @Test("Empty and whitespace-only values don't produce empty pieces")
    func emptyValues() {
        #expect(AttributeBreakdown.parts(of: "class", value: "   ").count == 1)
        #expect(AttributeBreakdown.splitTokens("  a   b  ") == ["a", "b"])
        #expect(AttributeBreakdown.splitDeclarations("color: red;;;").count == 1)
    }

    /// A realistic Tailwind attribute, end to end.
    @Test("A real Tailwind class list breaks up and groups correctly")
    func realWorldTailwind() {
        let value = """
        flex items-center justify-between gap-2 rounded-lg border border-gray-200 \
        bg-white px-4 py-2 text-sm font-medium shadow-sm hover:bg-gray-50 \
        hover:text-gray-900 focus:outline-none focus:ring-2 md:px-6 md:py-3 \
        dark:border-gray-700 dark:bg-gray-800
        """
        let parts = AttributeBreakdown.parts(of: "class", value: value)
        #expect(parts.count == 21)

        let groups = Set(parts.compactMap(\.group))
        #expect(groups == ["hover", "focus", "md", "dark"])
        #expect(parts.filter { $0.group == nil }.count == 13)
    }
}
