import Testing

@testable import SurfCore

@Suite("Media time")
struct MediaTimeTests {

    @Test("Minutes and seconds, with no hours in the way", arguments: [
        (0.0, "0:00"), (9.0, "0:09"), (65.0, "1:05"), (134.0, "2:14"), (3599.0, "59:59"),
    ])
    func shortDurations(seconds: Double, expected: String) {
        #expect(MediaTime.display(seconds) == expected)
    }

    @Test("Hours appear only when there are some", arguments: [
        (3600.0, "1:00:00"), (3725.0, "1:02:05"), (7384.0, "2:03:04"),
    ])
    func longDurations(seconds: Double, expected: String) {
        #expect(MediaTime.display(seconds) == expected)
    }

    @Test("A live stream reports infinity, which must not reach Int")
    func infinite() {
        // `Int(Double.infinity)` traps. This is the value a live stream
        // actually reports, so it is the one that matters most.
        #expect(MediaTime.display(.infinity) == "0:00")
        #expect(MediaTime.display(.nan) == "0:00")
        #expect(MediaTime.display(-5) == "0:00")
    }

    @Test("Position reads as a place in something")
    func position() {
        #expect(MediaTime.position(134, of: 603) == "2:14 / 10:03")
    }

    @Test("Nothing to be out of means nothing to say")
    func noDuration() {
        // A live stream has no end; "2:14 / 0:00" would claim it does.
        #expect(MediaTime.position(134, of: 0) == nil)
        #expect(MediaTime.position(134, of: .infinity) == nil)
    }
}
