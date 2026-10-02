import Testing

@testable import SurfCore

@Suite("Media caption")
struct MediaCaptionTests {

    @Test("Source and position, joined")
    func both() {
        #expect(MediaCaption.text(
            besides: "Some Song", artist: "A Band", host: "youtube.com", position: "2:14 / 10:03"
        ) == "A Band · 2:14 / 10:03")
    }

    @Test("Artist wins over host")
    func artistFirst() {
        #expect(MediaCaption.text(
            besides: "T", artist: "A Band", host: "youtube.com", position: nil
        ) == "A Band")
    }

    @Test("The caption never repeats the line above it")
    func neverRepeatsTheTitle() {
        // The bug this exists for: both lines fall through the same
        // candidates, so a video with no artist and no host printed the tab's
        // title twice — and with a time beside the second one.
        #expect(MediaCaption.text(
            besides: "Flower", artist: "", host: nil, position: "2:14 / 10:03"
        ) == "2:14 / 10:03")
        #expect(MediaCaption.text(
            besides: "Flower", artist: "Flower", host: nil, position: nil
        ) == "")
    }

    @Test("Matching the title is judged without caring about case")
    func caseInsensitive() {
        #expect(MediaCaption.text(
            besides: "YouTube.com", artist: "", host: "youtube.com", position: nil
        ) == "")
    }

    @Test("Nothing to add means an empty line, not a blank one")
    func nothing() {
        // Empty rather than " · " or a stray separator, so the caller can drop
        // the line instead of reserving space for it.
        #expect(MediaCaption.text(besides: "T", artist: "", host: nil, position: nil) == "")
        #expect(MediaCaption.text(besides: "T", artist: "  ", host: "  ", position: nil) == "")
    }

    @Test("A live stream has a host but no position")
    func liveStream() {
        #expect(MediaCaption.text(
            besides: "Live", artist: "", host: "twitch.tv", position: nil
        ) == "twitch.tv")
    }
}
