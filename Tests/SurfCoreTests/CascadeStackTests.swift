import Testing

@testable import SurfCore

@Suite("Cascade stack")
struct CascadeStackTests {

    // MARK: - Helpers

    private func entry(
        _ id: Int,
        _ selector: String,
        outcome: CascadeOutcome
    ) -> TraceEntry {
        TraceEntry(
            ref: DeclarationRef(ruleId: id, index: 0),
            selector: selector,
            sourceLabel: "sheet.css",
            specificity: Specificity(0, 1, 0),
            origin: .author,
            layer: nil,
            declaredName: "color",
            value: "#\(id)",
            isImportant: false,
            isStyleAttribute: false,
            inheritedLabel: nil,
            outcome: outcome
        )
    }

    /// A winner plus `losers` losers, all beaten the same way.
    private func trace(
        losers: Int,
        outcome: CascadeOutcome = .lostToSpecificity(
            mine: Specificity(0, 1, 0),
            winner: Specificity(0, 2, 0)
        )
    ) -> PropertyTrace {
        var entries = [entry(0, "a.win", outcome: .winner)]
        for index in 1...max(losers, 1) where losers > 0 {
            entries.append(entry(index, "a.lose\(index)", outcome: outcome))
        }
        return PropertyTrace(property: "color", entries: entries)
    }

    // MARK: - Shape

    @Test("An uncontested property is a staircase of one")
    func uncontested() {
        let stack = CascadeStack(trace(losers: 0))
        #expect(stack.steps.count == 1)
        #expect(stack.steps[0].depth == 0)
        #expect(stack.steps[0].isWinner)
        #expect(stack.hidden.isEmpty)
        #expect(stack.hiddenSummary == nil)
    }

    @Test("An empty trace produces nothing rather than crashing")
    func empty() {
        let stack = CascadeStack(PropertyTrace(property: "color", entries: []))
        #expect(stack.steps.isEmpty)
        #expect(stack.hidden.isEmpty)
    }

    @Test("Each loser steps one level right, in the order it lost")
    func depthsAreRanks() {
        let stack = CascadeStack(trace(losers: 3))
        #expect(stack.steps.map(\.depth) == [0, 1, 2, 3])
        #expect(stack.steps.map(\.entry.selector)
            == ["a.win", "a.lose1", "a.lose2", "a.lose3"])
        #expect(stack.hidden.isEmpty)
    }

    @Test("The staircase fills to the cap before folding anything")
    func fillsToCap() {
        let stack = CascadeStack(trace(losers: CascadeStack.maxDepth))
        #expect(stack.steps.count == CascadeStack.maxDepth + 1)
        #expect(stack.steps.last?.depth == CascadeStack.maxDepth)
        #expect(stack.hidden.isEmpty)
    }

    // MARK: - The cap

    /// The invariant the whole type exists to hold. Two cards at the same
    /// indent read as two rules of equal rank, and in a cascade nothing ties.
    @Test("No two steps ever sit at the same depth", arguments: 0...20)
    func depthsAreUnique(losers: Int) {
        let stack = CascadeStack(trace(losers: losers))
        let depths = stack.steps.map(\.depth)
        #expect(Set(depths).count == depths.count)
        #expect(depths == Array(0...(depths.count - 1)))
    }

    @Test("Depth never outruns the cap", arguments: 0...20)
    func depthIsCapped(losers: Int) {
        let stack = CascadeStack(trace(losers: losers))
        #expect(stack.steps.allSatisfy { $0.depth <= CascadeStack.maxDepth })
    }

    /// Folding must hide entries, never lose them.
    @Test("Every entry is either shown or folded, exactly once", arguments: 0...20)
    func nothingIsLost(losers: Int) {
        let source = trace(losers: losers)
        let stack = CascadeStack(source)
        let accounted = stack.steps.map(\.entry) + stack.hidden
        #expect(accounted == source.entries)
    }

    @Test("Folding begins one past the cap")
    func foldsPastCap() {
        let stack = CascadeStack(trace(losers: CascadeStack.maxDepth + 1))
        #expect(stack.steps.count == CascadeStack.maxDepth + 1)
        #expect(stack.hidden.count == 1)
    }

    // MARK: - What the fold says

    @Test("A shared reason is named, so the fold is an answer not a chore")
    func sharedReason() {
        let stack = CascadeStack(trace(losers: 9))
        #expect(stack.hidden.count == 9 - CascadeStack.maxDepth)
        #expect(stack.hiddenSummary == "5 more, all lost on specificity")
    }

    @Test("One folded loser is described in the singular")
    func singularReason() {
        let stack = CascadeStack(trace(losers: CascadeStack.maxDepth + 1))
        #expect(stack.hiddenSummary == "1 more, which lost on specificity")
    }

    /// Claiming one reason for a mixed group is the exact error this pane
    /// exists to prevent, so a mixed fold says only the count.
    @Test("Mixed reasons are counted, never generalised")
    func mixedReasons() {
        var entries = [entry(0, "a.win", outcome: .winner)]
        entries.append(entry(1, "a.l1", outcome: .lostToOrder))
        entries.append(entry(2, "a.l2", outcome: .lostToOrder))
        entries.append(entry(3, "a.l3", outcome: .lostToOrder))
        entries.append(entry(4, "a.l4", outcome: .lostToOrder))
        entries.append(entry(5, "a.l5", outcome: .lostToImportant))
        entries.append(entry(6, "a.l6", outcome: .lostToOrder))
        let stack = CascadeStack(PropertyTrace(property: "color", entries: entries))
        #expect(stack.hidden.count == 2)
        #expect(stack.hiddenSummary == "2 more")
    }

    @Test("Only the winner has no loss phrase")
    func winnerHasNoLossPhrase() {
        #expect(CascadeOutcome.winner.lossPhrase == nil)
        let losses: [CascadeOutcome] = [
            .lostToNearerElement,
            .lostToImportant,
            .lostToOrigin(.user),
            .lostToStyleAttribute,
            .lostToLayer(winner: "base", loser: "theme"),
            .lostToSpecificity(
                mine: Specificity(0, 1, 0),
                winner: Specificity(1, 0, 0)
            ),
            .lostToOrder,
            .shadowedInSameRule,
        ]
        for loss in losses {
            #expect(loss.lossPhrase != nil, "\(loss) should say how it lost")
        }
    }
}
