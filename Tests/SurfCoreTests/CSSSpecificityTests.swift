import Testing

@testable import SurfCore

@Suite("CSS specificity")
struct CSSSpecificityTests {

    /// The canonical table. Every one of these is something a Styles pane has
    /// to get right before any of its ordering can be trusted.
    @Test("The textbook cases count correctly")
    func canonical() {
        #expect(CSSSpecificity.calculate("*") == Specificity(0, 0, 0))
        #expect(CSSSpecificity.calculate("li") == Specificity(0, 0, 1))
        #expect(CSSSpecificity.calculate("ul li") == Specificity(0, 0, 2))
        #expect(CSSSpecificity.calculate("ul > li + li") == Specificity(0, 0, 3))
        #expect(CSSSpecificity.calculate(".row") == Specificity(0, 1, 0))
        #expect(CSSSpecificity.calculate("a.row.wide") == Specificity(0, 2, 1))
        #expect(CSSSpecificity.calculate("#main") == Specificity(1, 0, 0))
        #expect(CSSSpecificity.calculate("#main .row a") == Specificity(1, 1, 1))
        #expect(CSSSpecificity.calculate("[type=\"text\"]") == Specificity(0, 1, 0))
        #expect(CSSSpecificity.calculate("input[type=\"text\"]:checked") == Specificity(0, 2, 1))
    }

    /// The comparison is lexicographic, not a sum. This is the single most
    /// misremembered rule in CSS, and the reason showing the numbers is worth
    /// the pane space at all.
    @Test("Eleven classes still lose to one id")
    func lexicographic() {
        let classes = CSSSpecificity.calculate(".a.b.c.d.e.f.g.h.i.j.k")
        #expect(classes == Specificity(0, 11, 0))
        #expect(classes < CSSSpecificity.calculate("#x"))
    }

    /// A reset stylesheet built on `:where()` is supposed to be trivially
    /// overridable. Counting it as a class would make it look like it should be
    /// winning fights it cannot win.
    @Test(":where contributes nothing at all")
    func whereIsWeightless() {
        #expect(CSSSpecificity.calculate(":where(#a, .b, c)") == Specificity(0, 0, 0))
        #expect(CSSSpecificity.calculate("a:where(.b)") == Specificity(0, 0, 1))
    }

    @Test(":is, :not and :has take the weight of their heaviest argument")
    func transparentPseudos() {
        #expect(CSSSpecificity.calculate(":is(.a, #b)") == Specificity(1, 0, 0))
        #expect(CSSSpecificity.calculate(":not(.a)") == Specificity(0, 1, 0))
        #expect(CSSSpecificity.calculate("a:has(> img)") == Specificity(0, 0, 2))
        // Nesting has to recurse, not stop at the first level.
        #expect(CSSSpecificity.calculate(":is(:is(#deep))") == Specificity(1, 0, 0))
        // …and the argument of a :where inside an :is is still weightless.
        #expect(CSSSpecificity.calculate(":is(:where(#a), .b)") == Specificity(0, 1, 0))
    }

    /// A selector list reports its heaviest branch, because that's the branch
    /// that matched when the rule applied.
    @Test("A selector list takes its maximum")
    func selectorList() {
        #expect(CSSSpecificity.calculate("p, #main, .row") == Specificity(1, 0, 0))
    }

    /// Splitting on every comma would turn one selector into fragments that
    /// parse as heavier selectors than what was written.
    @Test("Commas inside brackets and parentheses are not separators")
    func splitting() {
        #expect(CSSSpecificity.splitList(":is(a, b), c") == [":is(a, b)", "c"])
        #expect(CSSSpecificity.splitList("[title=\"a,b\"], p") == ["[title=\"a,b\"]", "p"])
    }

    /// Tailwind escapes almost every class it generates. Reading `\\#` as an id
    /// would make an ordinary utility class outrank a real id selector.
    @Test("An escaped hash inside a class name is not an id")
    func escapes() {
        #expect(CSSSpecificity.calculate(".w-1\\/2") == Specificity(0, 1, 0))
        #expect(CSSSpecificity.calculate(".text-\\#fff") == Specificity(0, 1, 0))
        #expect(CSSSpecificity.calculate(".md\\:flex") == Specificity(0, 1, 0))
    }

    @Test("Pseudo-elements count as elements, however they're spelled")
    func pseudoElements() {
        #expect(CSSSpecificity.calculate("p::before") == Specificity(0, 0, 2))
        // The single-colon spelling is legacy but still valid, and still an
        // element rather than the class a naive scanner would count.
        #expect(CSSSpecificity.calculate("p:before") == Specificity(0, 0, 2))
        #expect(CSSSpecificity.calculate("::slotted(.a.b)") == Specificity(0, 0, 1))
    }

    @Test(":nth-child adds its own weight plus any selector after `of`")
    func nthChild() {
        #expect(CSSSpecificity.calculate("li:nth-child(2n)") == Specificity(0, 1, 1))
        #expect(CSSSpecificity.calculate("li:nth-child(2n of .item)") == Specificity(0, 2, 1))
    }

    /// A namespace prefix is not an element name; counting it as one would
    /// inflate every selector in an SVG or XHTML stylesheet.
    @Test("A namespace prefix isn't a second element")
    func namespaces() {
        #expect(CSSSpecificity.calculate("svg|circle") == Specificity(0, 0, 1))
        #expect(CSSSpecificity.calculate("*|div") == Specificity(0, 0, 1))
    }

    /// Nothing here may hang or crash on input that isn't a selector at all —
    /// this runs on whatever a page's stylesheet happens to contain.
    @Test("Malformed input terminates instead of hanging")
    func malformed() {
        #expect(CSSSpecificity.calculate("") == Specificity(0, 0, 0))
        #expect(CSSSpecificity.calculate(":is(") == Specificity(0, 0, 0))
        #expect(CSSSpecificity.calculate("[unclosed") == Specificity(0, 1, 0))
        #expect(CSSSpecificity.calculate("a\\") == Specificity(0, 0, 1))
    }
}
