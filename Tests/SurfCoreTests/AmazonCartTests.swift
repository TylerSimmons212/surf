import Foundation
import Testing

@testable import SurfCore

@Suite("Amazon cart")
struct AmazonCartTests {

    /// The attributes exactly as a live cart line carried them.
    static func measuredLine(
        quantity: String = "1", min: String = "1", oos: String = "0", prime: String = "0"
    ) -> AmazonCartItem? {
        AmazonCartParse.item(
            id: "ecd26f38-6d33-4ce4-8f86-98d18363f6c0",
            asin: "B088NRLMPV",
            title: "Anker USB C to USB C Cable, 60W Fast Charging Cable",
            price: "9.99",
            quantity: quantity, minQuantity: min, outOfStock: oos, prime: prime,
            image: "https://m.media-amazon.com/images/I/abc._AC_UY218_.jpg"
        )
    }

    // MARK: - Reading a line

    @Test("A line is read from the attributes Amazon already put on it")
    func readsAMeasuredLine() throws {
        let item = try #require(Self.measuredLine(quantity: "2"))
        #expect(item.id == "ecd26f38-6d33-4ce4-8f86-98d18363f6c0")
        #expect(item.asin == "B088NRLMPV")
        #expect(item.quantity == 2)
        #expect(item.price?.amount == Decimal(string: "9.99"))
        #expect(item.price?.display == "$9.99")
        #expect(!item.isPrime)
        #expect(!item.isOutOfStock)
    }

    /// A line no write can reach is worse than no line: it would render a
    /// stepper next to something nothing can change.
    @Test("A line with no item id is dropped rather than shown")
    func dropsAnUnaddressableLine() {
        #expect(
            AmazonCartParse.item(
                id: nil, asin: "B0", title: "A thing", price: "1.00",
                quantity: "1", minQuantity: "1", outOfStock: "0", prime: "0", image: ""
            ) == nil
        )
        #expect(
            AmazonCartParse.item(
                id: "  ", asin: "B0", title: "A thing", price: "1.00",
                quantity: "1", minQuantity: "1", outOfStock: "0", prime: "0", image: ""
            ) == nil
        )
    }

    @Test("Amazon's string flags are read as flags", arguments: [
        ("1", true), ("0", false), ("true", true), ("", false), ("no", false),
    ])
    func readsFlags(raw: String, expected: Bool) {
        #expect(AmazonCartParse.flag(raw) == expected)
    }

    @Test("A missing quantity is not a quantity of none")
    func missingQuantityIsNotZero() throws {
        let item = try #require(Self.measuredLine(quantity: ""))
        #expect(item.quantity == 1)
        #expect(AmazonCartParse.number("") == nil)
        #expect(AmazonCartParse.number("3") == 3)
    }

    // MARK: - The decrement trap

    /// Amazon's own stepper turns its minus into a delete at the floor. A
    /// control wired straight through would silently remove the line.
    @Test("Minus is refused at the floor, where Amazon's own control deletes")
    func refusesToDecrementAtTheFloor() throws {
        #expect(try #require(Self.measuredLine(quantity: "1")).canDecrement == false)
        #expect(try #require(Self.measuredLine(quantity: "2")).canDecrement == true)
    }

    /// The floor is not always one — a multipack or a subscription can set it
    /// higher, and the trap is the same at three as it is at one.
    @Test("A line with a floor above one is refused at its own floor")
    func respectsAHigherFloor() throws {
        #expect(try #require(Self.measuredLine(quantity: "3", min: "3")).canDecrement == false)
        #expect(try #require(Self.measuredLine(quantity: "4", min: "3")).canDecrement == true)
    }

    // MARK: - Money

    @Test("A line total is quantity times price, to the penny")
    func computesALineTotal() throws {
        let item = try #require(Self.measuredLine(quantity: "3"))
        #expect(item.lineTotal?.amount == Decimal(string: "29.97"))
        #expect(item.lineTotal?.display == "$29.97")
    }

    /// The case a `Double` would get wrong, and the reason money is `Decimal`
    /// everywhere in this lens.
    @Test("Money that a binary fraction would round wrong stays exact")
    func decimalNotDouble() throws {
        let item = try #require(
            AmazonCartParse.item(
                id: "x", asin: "B0", title: "t", price: "0.10", quantity: "3",
                minQuantity: "1", outOfStock: "0", prime: "0", image: ""
            )
        )
        #expect(item.lineTotal?.amount == Decimal(string: "0.30"))
        #expect(item.lineTotal?.display == "$0.30")
    }

    @Test("A whole number of dollars is still written as money")
    func padsWholeAmounts() {
        #expect(AmazonPrice.format(Decimal(20), currency: "$") == "$20.00")
        #expect(AmazonPrice.format(Decimal(string: "1299")!, currency: "$") == "$1,299.00")
    }

    @Test("A range has no single total to compute")
    func rangesHaveNoLineTotal() {
        let item = AmazonCartItem(
            id: "x", price: AmazonPrice(display: "$9 - $12", amount: 9, isRange: true),
            quantity: 2
        )
        #expect(item.lineTotal == nil)
    }

    // MARK: - The cart

    @Test("A cart counts units, not lines")
    func countsUnits() throws {
        let cart = AmazonCart(items: [
            try #require(Self.measuredLine(quantity: "2")),
            AmazonCartItem(id: "b", quantity: 3),
        ])
        #expect(cart.items.count == 2)
        #expect(cart.countedUnits == 5)
        #expect(!cart.isEmpty)
    }

    /// Every write addresses a line by Amazon's id, never by ASIN: one product
    /// in two variations is two lines sharing an ASIN, and a quantity change
    /// addressed by ASIN would change whichever came back first.
    @Test("Two lines can share an ASIN and still be told apart")
    func findsALineByItsOwnID() {
        let cart = AmazonCart(items: [
            AmazonCartItem(id: "line-1", asin: "B088NRLMPV", quantity: 1),
            AmazonCartItem(id: "line-2", asin: "B088NRLMPV", quantity: 4),
        ])
        #expect(cart.item(id: "line-2")?.quantity == 4)
        #expect(cart.item(id: "nope") == nil)
    }

    /// Amazon's subtotal carries promotions and coupons that are on no line.
    /// Summing the lines would produce a number that is confidently wrong.
    @Test("The subtotal is Amazon's, never ours")
    func subtotalIsNeverComputed() {
        let cart = AmazonCart(
            items: [AmazonCartItem(id: "a", price: AmazonPrice(display: "$9.99", amount: 9.99), quantity: 2)],
            subtotal: AmazonPrice(display: "$14.99", amount: Decimal(string: "14.99"))
        )
        // A coupon took five dollars off. The cart reports what the page said.
        #expect(cart.subtotal?.display == "$14.99")
    }

    @Test("An empty cart is empty")
    func emptyCart() {
        #expect(AmazonCart().isEmpty)
        #expect(AmazonCart().countedUnits == 0)
    }
}

@Suite("Amazon cart subtotal label")
struct AmazonCartLabelTests {

    /// The header said three million. `AmazonRating.count` scales by a K or an
    /// M found anywhere in the string, and "items" has an M in it.
    @Test("Amazon's own subtotal label is read as a count")
    func readsTheLabel() {
        #expect(AmazonCartParse.unitCount(fromLabel: "Subtotal (3 items):") == 3)
        #expect(AmazonCartParse.unitCount(fromLabel: "Subtotal (1 item):") == 1)
        #expect(AmazonCartParse.unitCount(fromLabel: "Subtotal (1,204 items):") == 1204)
        #expect(AmazonCartParse.unitCount(fromLabel: "Subtotal:") == nil)
        #expect(AmazonCartParse.unitCount(fromLabel: "") == nil)
    }

    /// The tightening that stops the same collision happening anywhere else: a
    /// K or an M only multiplies when it is attached to the number.
    @Test("A compact suffix has to belong to the number it scales")
    func suffixMustBeAttached() {
        #expect(AmazonRating.count("16.1K ratings") == 16_100)
        #expect(AmazonRating.count("10K+ bought in past month") == 10_000)
        #expect(AmazonRating.count("2.3M ratings") == 2_300_000)
        #expect(AmazonRating.count("87,229 ratings") == 87_229)
        // The one that was wrong: an M in a word, nowhere near the number.
        #expect(AmazonRating.count("Subtotal (3 items):") == 3)
        #expect(AmazonRating.count("3 monthly payments") == 3)
    }
}

@Suite("Amazon cart write confirmation")
struct AmazonCartConfirmationTests {

    static let line = AmazonCartItem(id: "line-1", asin: "B0", quantity: 2)
    static let other = AmazonCartItem(id: "line-2", asin: "B1", quantity: 1)

    /// The bug this replaced: "the cart changed" was taken as evidence, and a
    /// remove that did nothing reported that it had landed, because Amazon had
    /// re-rendered something else in the meantime.
    @Test("A cart that merely changed is not a write that took effect")
    func changeIsNotEvidence() {
        // Same line, still there, but the rest of the cart moved.
        let after = AmazonCart(
            items: [Self.line, Self.other],
            subtotal: AmazonPrice(display: "$40.00")
        )
        #expect(!after.reflects(.remove, on: Self.line))
        #expect(!after.reflects(.increment, on: Self.line))
        #expect(!after.reflects(.decrement, on: Self.line))
    }

    @Test("A removal is the line being gone")
    func removeIsAbsence() {
        let after = AmazonCart(items: [Self.other])
        #expect(after.reflects(.remove, on: Self.line))
        #expect(!AmazonCart(items: [Self.line, Self.other]).reflects(.remove, on: Self.line))
    }

    @Test("An increment is that line going up, not the cart going up")
    func incrementIsThatLine() {
        var raised = Self.line
        raised.quantity = 3
        #expect(AmazonCart(items: [raised]).reflects(.increment, on: Self.line))
        // Another line growing is not this line growing.
        var otherGrew = Self.other
        otherGrew.quantity = 9
        #expect(!AmazonCart(items: [Self.line, otherGrew]).reflects(.increment, on: Self.line))
    }

    @Test("A decrement is that line going down")
    func decrementIsThatLine() {
        var lowered = Self.line
        lowered.quantity = 1
        #expect(AmazonCart(items: [lowered]).reflects(.decrement, on: Self.line))
    }

    /// The failure the whole design is arranged around: Amazon's minus is a
    /// delete at the floor. If both guards ever fail, the line vanishes — and
    /// that must not read as a successful decrement.
    @Test("A decrement that removed the line is a failure, not a success")
    func vanishingUnderDecrementIsNotSuccess() {
        let after = AmazonCart(items: [Self.other])
        #expect(!after.reflects(.decrement, on: Self.line))
        #expect(after.lostLine(Self.line, underDecrement: true))
        // The same absence under a remove is exactly what was asked for.
        #expect(!after.lostLine(Self.line, underDecrement: false))
    }
}

@Suite("Amazon removed-row ghosts")
struct AmazonCartGhostTests {

    /// The reason Remove looked broken. Amazon does not take the row out of
    /// the page — it empties it and shows "… was removed from Shopping Cart"
    /// inside it, with every attribute still on the element: still
    /// `data-itemtype="active"`, still its old quantity and price.
    @Test("A row Amazon has emptied is not a line any more")
    func dropsAGhostRow() {
        #expect(
            AmazonCartParse.item(
                id: "ecd26f38", asin: "B088NRLMPV", title: "Anker USB C",
                price: "9.99", quantity: "2", minQuantity: "1",
                outOfStock: "0", prime: "0",
                // Nothing left in it: no controls, no image.
                image: "", hasRemoveControl: false
            ) == nil
        )
    }

    /// Both signals are required. Either one alone could be a layout nobody
    /// has met, and dropping a real line is worse than briefly keeping a ghost.
    @Test("One missing signal is not enough to drop a line")
    func keepsALineWithOneSignalMissing() {
        // No remove control, but the product is still pictured.
        #expect(
            AmazonCartParse.item(
                id: "a", asin: "B0", title: "t", price: "1.00", quantity: "1",
                minQuantity: "1", outOfStock: "0", prime: "0",
                image: "https://m.media-amazon.com/images/I/x.jpg",
                hasRemoveControl: false
            ) != nil
        )
        // A control but no picture — an image that has not loaded yet.
        #expect(
            AmazonCartParse.item(
                id: "a", asin: "B0", title: "t", price: "1.00", quantity: "1",
                minQuantity: "1", outOfStock: "0", prime: "0",
                image: "", hasRemoveControl: true
            ) != nil
        )
    }

    /// A cart whose only line is a ghost is an empty cart, which is what the
    /// sidebar has to say once a removal lands.
    @Test("A cart of nothing but ghosts is empty")
    func ghostsLeaveAnEmptyCart() {
        let ghost = AmazonCartParse.item(
            id: "gone", asin: "B0", title: "t", price: "9.99", quantity: "2",
            minQuantity: "1", outOfStock: "0", prime: "0",
            image: "", hasRemoveControl: false
        )
        #expect(ghost == nil)
        #expect(AmazonCart(items: [ghost].compactMap { $0 }).isEmpty)
    }
}
