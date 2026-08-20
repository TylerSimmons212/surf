import Testing

@testable import SurfCore

@Suite("Inactive CSS")
struct CSSInactiveTests {

    private func context(
        display: String = "block",
        position: String = "static",
        parent: String = "block",
        replaced: Bool = false
    ) -> StyleContext {
        StyleContext(
            display: display, position: position,
            parentDisplay: parent, isReplaced: replaced
        )
    }

    // MARK: - Sizing

    @Test("width on an inline span is inactive")
    func inlineWidth() {
        #expect(CSSInactive.reason(for: "width", in: context(display: "inline")) != nil)
    }

    @Test("width on an inline replaced element works — img takes a size")
    func replacedException() {
        let ctx = context(display: "inline", replaced: true)
        #expect(CSSInactive.reason(for: "width", in: ctx) == nil)
    }

    @Test("width on a block works")
    func blockWidth() {
        #expect(CSSInactive.reason(for: "width", in: context(display: "block")) == nil)
    }

    // MARK: - Position

    @Test("top on a static element is inactive; on absolute it works")
    func offsets() {
        #expect(CSSInactive.reason(for: "top", in: context(position: "static")) != nil)
        #expect(CSSInactive.reason(for: "top", in: context(position: "absolute")) == nil)
        #expect(CSSInactive.reason(for: "top", in: context(position: "sticky")) == nil)
    }

    @Test("z-index on a static block child is inactive, but a static flex item stacks")
    func zIndexFlexItemException() {
        #expect(CSSInactive.reason(for: "z-index", in: context(parent: "block")) != nil)
        // The spec exception: flex and grid items honour z-index unpositioned.
        #expect(CSSInactive.reason(for: "z-index", in: context(parent: "flex")) == nil)
        #expect(CSSInactive.reason(for: "z-index", in: context(parent: "grid")) == nil)
    }

    // MARK: - Containers

    @Test("flex-direction off a flex container is inactive")
    func flexDirection() {
        #expect(CSSInactive.reason(for: "flex-direction", in: context(display: "block")) != nil)
        #expect(CSSInactive.reason(for: "flex-direction", in: context(display: "flex")) == nil)
        #expect(CSSInactive.reason(for: "flex-direction", in: context(display: "inline-flex")) == nil)
    }

    @Test("justify-content works on grid as well as flex")
    func justifyContent() {
        #expect(CSSInactive.reason(for: "justify-content", in: context(display: "grid")) == nil)
        #expect(CSSInactive.reason(for: "justify-content", in: context(display: "flex")) == nil)
        #expect(CSSInactive.reason(for: "justify-content", in: context(display: "block")) != nil)
    }

    @Test("grid-template-columns needs a grid")
    func gridTemplate() {
        #expect(CSSInactive.reason(for: "grid-template-columns", in: context(display: "flex")) != nil)
        #expect(CSSInactive.reason(for: "grid-template-columns", in: context(display: "inline-grid")) == nil)
    }

    // MARK: - Items

    @Test("flex-grow needs a flex parent")
    func flexGrow() {
        #expect(CSSInactive.reason(for: "flex-grow", in: context(parent: "block")) != nil)
        #expect(CSSInactive.reason(for: "flex-grow", in: context(parent: "flex")) == nil)
    }

    @Test("grid-area needs a grid parent")
    func gridArea() {
        #expect(CSSInactive.reason(for: "grid-area", in: context(parent: "flex")) != nil)
        #expect(CSSInactive.reason(for: "grid-area", in: context(parent: "grid")) == nil)
    }

    @Test("order works under both flex and grid, and nowhere else")
    func order() {
        #expect(CSSInactive.reason(for: "order", in: context(parent: "flex")) == nil)
        #expect(CSSInactive.reason(for: "order", in: context(parent: "grid")) == nil)
        #expect(CSSInactive.reason(for: "order", in: context(parent: "block")) != nil)
    }

    @Test("float dies inside a flex container")
    func floatInFlex() {
        #expect(CSSInactive.reason(for: "float", in: context(parent: "flex")) != nil)
        #expect(CSSInactive.reason(for: "float", in: context(parent: "block")) == nil)
    }

    // MARK: - Silence discipline

    @Test("Unknown context stays silent rather than guessing")
    func emptyContext() {
        let empty = StyleContext()
        for property in ["width", "flex-direction", "grid-area", "order", "vertical-align"] {
            #expect(CSSInactive.reason(for: property, in: empty) == nil)
        }
    }

    @Test("Properties with no rule never fire")
    func uncoveredProperties() {
        let ctx = context(display: "inline", parent: "block")
        for property in ["color", "font-size", "gap", "align-content", "overflow"] {
            #expect(CSSInactive.reason(for: property, in: ctx) == nil)
        }
    }

    @Test("vertical-align moves inline boxes and table cells only")
    func verticalAlign() {
        #expect(CSSInactive.reason(for: "vertical-align", in: context(display: "block")) != nil)
        #expect(CSSInactive.reason(for: "vertical-align", in: context(display: "inline")) == nil)
        #expect(CSSInactive.reason(for: "vertical-align", in: context(display: "inline-block")) == nil)
        #expect(CSSInactive.reason(for: "vertical-align", in: context(display: "table-cell")) == nil)
    }
}
