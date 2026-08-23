import Foundation
import Testing

@testable import SurfCore

/// The fixtures are captured from youtube.com rather than written here, and
/// trimmed only by the same key-copy the injected script performs. Invented
/// JSON would agree with the parser by construction; these disagree in the
/// ways the real site does — a live stream with no duration and its viewer
/// count split across runs, a premiere with neither, an hours-long runtime,
/// and a "Streamed" prefix on the date.
@Suite("YouTube results")
struct YouTubeResultTests {

    /// A live stream: no lengthText, no publishedTimeText, and a view count
    /// that arrives as runs which say "3" and " watching" separately.
    private let liveRenderer = #"""
    {"videoId":"8vaOW_2EpLc","title":{"runs":[{"text":"Build with AI | Claude Code, OpenClaw, Cursor and more | 24/7 Live"}],"accessibility":{"accessibilityData":{"label":"Build with AI | Claude Code, OpenClaw, Cursor and more | 24/7 Live"}}},"ownerText":{"runs":[{"text":"NextWork","navigationEndpoint":{"browseEndpoint":{"browseId":"UCa9FBCj_ZcKU6OBtLsQJXpg","canonicalBaseUrl":"/@itsnextwork"}}}]},"longBylineText":{"runs":[{"text":"NextWork"}]},"viewCountText":{"runs":[{"text":"3"},{"text":" watching"}]},"thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/8vaOW_2EpLc/hq720.jpg?v=69cff0b0&sqp=small","width":360,"height":202},{"url":"https://i.ytimg.com/vi/8vaOW_2EpLc/hq720.jpg?v=69cff0b0&sqp=large","width":720,"height":404}]},"badges":[{"metadataBadgeRenderer":{"icon":{"iconType":"LIVE"},"style":"BADGE_STYLE_TYPE_LIVE_NOW","label":"LIVE"}}]}
    """#

    /// A past broadcast: ten and a half hours, a verified channel, and a
    /// date wearing the "Streamed" prefix.
    private let vodRenderer = #"""
    {"videoId":"QvNzL_FmzLQ","title":{"runs":[{"text":"Live Coding A New Streaming Platform (10 Hours)"}]},"ownerText":{"runs":[{"text":"Dennis Ivy","navigationEndpoint":{"browseEndpoint":{"browseId":"UCTZRcDjjkVajGL6wd76UnGg"}}}]},"longBylineText":{"runs":[{"text":"Dennis Ivy"}]},"lengthText":{"accessibility":{"accessibilityData":{"label":"10 hours, 31 minutes, 2 seconds"}},"simpleText":"10:31:02"},"viewCountText":{"simpleText":"156,290 views"},"publishedTimeText":{"simpleText":"Streamed 4 years ago"},"thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/QvNzL_FmzLQ/hq720.jpg?sqp=small","width":360,"height":202},{"url":"https://i.ytimg.com/vi/QvNzL_FmzLQ/hq720.jpg?sqp=large","width":720,"height":404}]},"ownerBadges":[{"metadataBadgeRenderer":{"icon":{"iconType":"CHECK_CIRCLE_THICK"},"style":"BADGE_STYLE_TYPE_VERIFIED","tooltip":"Verified"}}]}
    """#

    /// An unaired premiere: a "New" badge and nothing else — no duration, no
    /// views, no date. The shape that would crash a parser expecting any of
    /// them to exist.
    private let premiereRenderer = #"""
    {"videoId":"L9ouGRiAM5A","title":{"runs":[{"text":"Coding session tonight"}]},"ownerText":{"runs":[{"text":"Some Channel"}]},"thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/L9ouGRiAM5A/hq720.jpg","width":360,"height":202}]},"badges":[{"metadataBadgeRenderer":{"style":"BADGE_STYLE_TYPE_SIMPLE","label":"New"}}]}
    """#

    @Test("A live stream keeps its viewer count and reports no duration")
    func liveStream() throws {
        let result = try #require(
            YouTubeResult.parse(fromRenderers: [liveRenderer]).first
        )
        #expect(result.id == "8vaOW_2EpLc")
        #expect(result.title == "Build with AI | Claude Code, OpenClaw, Cursor and more | 24/7 Live")
        #expect(result.channel == "NextWork")
        #expect(result.isLive)
        // A live stream has no length, which is not the same as a length of
        // zero — the card must be able to draw no duration chip at all.
        #expect(result.duration == nil)
        #expect(result.durationText == nil)
        // Both runs, joined: the first alone would say "3".
        #expect(result.viewText == "3 watching")
        #expect(result.publishedText.isEmpty)
        // LIVE is a state, not a chip to render beside 4K and CC.
        #expect(result.badges.isEmpty)
        #expect(result.thumbnailURL.hasSuffix("sqp=large"))
    }

    @Test("A past broadcast parses whole")
    func pastBroadcast() throws {
        let result = try #require(
            YouTubeResult.parse(fromRenderers: [vodRenderer]).first
        )
        #expect(result.id == "QvNzL_FmzLQ")
        #expect(result.title == "Live Coding A New Streaming Platform (10 Hours)")
        #expect(result.channel == "Dennis Ivy")
        #expect(result.isVerified)
        #expect(!result.isLive)
        #expect(result.duration == 37862)
        #expect(result.durationText == "10:31:02")
        #expect(result.viewText == "156K views")
        // The prefix is dropped: the column wants the when.
        #expect(result.publishedText == "4 years ago")
        #expect(result.watchURL?.absoluteString
            == "https://www.youtube.com/watch?v=QvNzL_FmzLQ")
    }

    @Test("A premiere with no duration, views or date still renders")
    func premiere() throws {
        let result = try #require(
            YouTubeResult.parse(fromRenderers: [premiereRenderer]).first
        )
        #expect(result.id == "L9ouGRiAM5A")
        #expect(result.title == "Coding session tonight")
        #expect(result.duration == nil)
        #expect(result.viewText.isEmpty)
        #expect(result.publishedText.isEmpty)
        #expect(!result.isVerified)
        // "New" says nothing the date doesn't; it is not kept as a chip.
        #expect(result.badges.isEmpty)
    }

    @Test("Quality and caption chips survive; LIVE and New do not")
    func chips() throws {
        let renderer = #"""
        {"videoId":"rSKMYc1CQHE","title":{"simpleText":"A talk"},
         "badges":[{"metadataBadgeRenderer":{"label":"4K"}},
                   {"metadataBadgeRenderer":{"label":"CC"}},
                   {"metadataBadgeRenderer":{"label":"New"}}]}
        """#
        let result = try #require(
            YouTubeResult.parse(fromRenderers: [renderer]).first
        )
        #expect(result.badges == ["4K", "CC"])
        // simpleText is the other shape a title arrives in.
        #expect(result.title == "A talk")
    }

    @Test("A renderer with no usable video id is dropped, not rendered")
    func unusableIDs() {
        let cases = [
            #"{"title":{"simpleText":"No id at all"}}"#,
            #"{"videoId":"tooshort","title":{"simpleText":"Bad id"}}"#,
            #"{"videoId":"has a space","title":{"simpleText":"Bad id"}}"#,
            #"not json at all"#,
        ]
        #expect(YouTubeResult.parse(fromRenderers: cases).isEmpty)
    }

    @Test("A page that repeats a video across shelves yields it once")
    func duplicates() {
        let results = YouTubeResult.parse(
            fromRenderers: [vodRenderer, liveRenderer, vodRenderer]
        )
        #expect(results.count == 2)
        #expect(results.map(\.id) == ["QvNzL_FmzLQ", "8vaOW_2EpLc"])
    }

    @Test("A payload with no thumbnails still gets a picture")
    func thumbnailFallback() throws {
        let renderer = #"{"videoId":"u2rYp8AMuSg","title":{"simpleText":"x"}}"#
        let result = try #require(
            YouTubeResult.parse(fromRenderers: [renderer]).first
        )
        // Derived rather than absent: YouTube's signed thumbnail URLs expire,
        // and this address never does.
        #expect(result.thumbnailURL
            == "https://i.ytimg.com/vi/u2rYp8AMuSg/mqdefault.jpg")
    }

    @Test("The channel falls back to the byline when there is no ownerText")
    func bylineFallback() throws {
        let renderer = #"""
        {"videoId":"u2rYp8AMuSg","title":{"simpleText":"x"},
         "longBylineText":{"runs":[{"text":"Fallback Channel"}]}}
        """#
        let result = try #require(
            YouTubeResult.parse(fromRenderers: [renderer]).first
        )
        #expect(result.channel == "Fallback Channel")
    }
}

@Suite("YouTube formatting")
struct YouTubeFormatTests {

    @Test("Clock text reads as seconds", arguments: [
        ("2:51", 171), ("10:31:02", 37862), ("28:01", 1681),
        ("0:07", 7), ("1:00:00", 3600),
    ])
    func clockParsing(text: String, expected: Int) {
        #expect(YouTubeFormat.seconds(fromClock: text) == expected)
    }

    @Test("Text that isn't a clock reads as no duration", arguments: [
        "", "   ", "LIVE", "12", "1:2:3:4", "a:b",
    ])
    func clockRefusals(text: String) {
        #expect(YouTubeFormat.seconds(fromClock: text) == nil)
    }

    @Test("Seconds render back as a clock, dropping an absent hour")
    func clockRendering() {
        #expect(YouTubeFormat.clock(171) == "2:51")
        #expect(YouTubeFormat.clock(37862) == "10:31:02")
        #expect(YouTubeFormat.clock(7) == "0:07")
        #expect(YouTubeFormat.clock(0) == "0:00")
        // A negative time is a bug upstream; it must not render as "-1:-1".
        #expect(YouTubeFormat.clock(-5) == "0:00")
    }

    /// The expectations are what youtube.com itself prints for these
    /// numbers — truncated, not rounded, which is why 743,996 is 743K.
    @Test("View counts compact the way the site prints them", arguments: [
        ("156,290 views", "156K views"),
        ("743,996 views", "743K views"),
        ("32,939 views", "32K views"),
        ("4,120,465 views", "4.1M views"),
        ("2,585,497 views", "2.5M views"),
        ("11,035,546 views", "11M views"),
        ("1,126,904 views", "1.1M views"),
        ("999 views", "999 views"),
        ("3 watching", "3 watching"),
        ("1,204 watching", "1.2K watching"),
    ])
    func compactCounts(raw: String, expected: String) {
        #expect(YouTubeFormat.compactCount(raw) == expected)
    }

    @Test("Text with no number in front passes through untouched")
    func uncountableText() {
        #expect(YouTubeFormat.compactCount("No views") == "No views")
        #expect(YouTubeFormat.compactCount("") == "")
        #expect(YouTubeFormat.compactCount("   ") == "")
    }

    @Test("A billion gets its own magnitude")
    func billions() {
        #expect(YouTubeFormat.abbreviate(1_450_000_000) == "1.4B")
        #expect(YouTubeFormat.abbreviate(12_000_000_000) == "12B")
    }

    @Test("The Streamed prefix comes off the date")
    func publishedPrefix() {
        #expect(YouTubeFormat.published("Streamed 4 years ago") == "4 years ago")
        #expect(YouTubeFormat.published("5 hours ago") == "5 hours ago")
        #expect(YouTubeFormat.published("") == "")
    }
}

@Suite("YouTube watch page")
struct YouTubeWatchTests {

    /// Captured from ytInitialPlayerResponse.videoDetails. The numbers are
    /// strings there, which is YouTube's own inconsistency.
    private let details = #"""
    {"videoId":"u2rYp8AMuSg","title":"WWDC25: Embracing Swift concurrency | Apple","author":"Apple Developer","channelId":"UCwrVwiJllwhJUKXKmjLcckQ","lengthSeconds":"1681","viewCount":"31401","isLiveContent":false}
    """#

    @Test("Video details parse, numbers-as-strings and all")
    func videoDetails() throws {
        let video = try #require(YouTubeVideo.parse(fromDetails: details))
        #expect(video.id == "u2rYp8AMuSg")
        #expect(video.title == "WWDC25: Embracing Swift concurrency | Apple")
        #expect(video.channel == "Apple Developer")
        #expect(video.channelID == "UCwrVwiJllwhJUKXKmjLcckQ")
        #expect(video.duration == 1681)
        #expect(video.viewText == "31K views")
        #expect(!video.isLive)
    }

    @Test("A live stream's zero length is no length")
    func liveHasNoDuration() throws {
        let json = #"""
        {"videoId":"8vaOW_2EpLc","title":"24/7 Live","author":"NextWork","lengthSeconds":"0","isLiveContent":true}
        """#
        let video = try #require(YouTubeVideo.parse(fromDetails: json))
        #expect(video.duration == nil)
        #expect(video.isLive)
        #expect(video.viewText.isEmpty)
    }

    @Test("Details without a usable id parse to nothing")
    func unusableDetails() {
        #expect(YouTubeVideo.parse(fromDetails: #"{"title":"x"}"#) == nil)
        #expect(YouTubeVideo.parse(fromDetails: "garbage") == nil)
    }

    /// Real chapter renderers: millisecond starts, in order.
    private let chapters = [
        #"{"title":{"simpleText":"Introduction"},"timeRangeStartMillis":0}"#,
        #"{"title":{"simpleText":"Single-threaded code"},"timeRangeStartMillis":197000}"#,
        #"{"title":{"simpleText":"Asynchronous tasks"},"timeRangeStartMillis":360000}"#,
    ]

    @Test("Chapters parse to seconds and keep playing order")
    func chapterParsing() {
        let parsed = YouTubeChapter.parse(fromRenderers: chapters)
        #expect(parsed.map(\.start) == [0, 197, 360])
        #expect(parsed.map(\.title) == [
            "Introduction", "Single-threaded code", "Asynchronous tasks",
        ])
        #expect(parsed[1].startText == "3:17")
    }

    @Test("Chapters out of order are sorted; unusable ones are dropped")
    func chapterHygiene() {
        let messy = [
            #"{"title":{"simpleText":"Later"},"timeRangeStartMillis":600000}"#,
            #"{"title":{"simpleText":"Earlier"},"timeRangeStartMillis":60000}"#,
            // No title: a seek button pretending to be information.
            #"{"timeRangeStartMillis":120000}"#,
            // No start: nowhere to seek to.
            #"{"title":{"simpleText":"Nowhere"}}"#,
            // A repeat of a start already taken.
            #"{"title":{"simpleText":"Duplicate"},"timeRangeStartMillis":60000}"#,
        ]
        let parsed = YouTubeChapter.parse(fromRenderers: messy)
        #expect(parsed.map(\.title) == ["Earlier", "Later"])
    }

    @Test("The transport can name the chapter playing now")
    func currentChapter() {
        let parsed = YouTubeChapter.parse(fromRenderers: chapters)
        #expect(YouTubeChapter.current(at: 0, in: parsed)?.title == "Introduction")
        #expect(YouTubeChapter.current(at: 196.9, in: parsed)?.title == "Introduction")
        #expect(YouTubeChapter.current(at: 197, in: parsed)?.title == "Single-threaded code")
        #expect(YouTubeChapter.current(at: 9_999, in: parsed)?.title == "Asynchronous tasks")
        #expect(YouTubeChapter.current(at: 5, in: []) == nil)
    }

    @Test("A chapter list that starts late names nothing before it")
    func beforeTheFirstChapter() {
        let late = [#"{"title":{"simpleText":"Intro"},"timeRangeStartMillis":30000}"#]
        let parsed = YouTubeChapter.parse(fromRenderers: late)
        #expect(YouTubeChapter.current(at: 10, in: parsed) == nil)
        #expect(YouTubeChapter.current(at: 30, in: parsed)?.title == "Intro")
    }

    @Test("One caption track per language, authored beating automatic")
    func captionTracks() {
        // The real shape: YouTube ships both an authored English track and
        // an auto-generated one, and a menu offering English twice can't be
        // used.
        let tracks = [
            #"{"languageCode":"en","name":{"simpleText":"English (auto-generated)"},"kind":"asr"}"#,
            #"{"languageCode":"en","name":{"simpleText":"English"}}"#,
            #"{"languageCode":"fr","name":{"runs":[{"text":"French"}]}}"#,
            #"{"languageCode":"","name":{"simpleText":"Nameless"}}"#,
        ]
        let parsed = YouTubeCaptionTrack.parse(fromTracks: tracks)
        #expect(parsed.map(\.languageCode) == ["en", "fr"])
        #expect(parsed[0].label == "English")
        #expect(!parsed[0].isAutomatic)
        #expect(parsed[1].label == "French")
    }

    @Test("A track with no name falls back to its language code")
    func namelessTrack() throws {
        let parsed = YouTubeCaptionTrack.parse(
            fromTracks: [#"{"languageCode":"es-419"}"#]
        )
        let track = try #require(parsed.first)
        #expect(track.label == "es-419")
    }
}

@Suite("Site focus routing")
struct SiteFocusTests {

    @Test("YouTube's addresses are claimed", arguments: [
        "https://www.youtube.com/watch?v=u2rYp8AMuSg",
        "https://youtube.com/",
        "https://m.youtube.com/results?search_query=x",
        "https://youtu.be/u2rYp8AMuSg",
        "https://WWW.YouTube.com/",
    ])
    func claimed(address: String) {
        #expect(SiteFocusSite.matching(URL(string: address)) == .youtube)
    }

    @Test("Everything else is not", arguments: [
        // A different application wearing the same domain; its lens would be
        // a different lens.
        "https://music.youtube.com/watch?v=u2rYp8AMuSg",
        "https://example.com/",
        // The lookalike a suffix match would have fallen for.
        "https://notyoutube.com/",
        "https://youtube.com.evil.example/",
        "about:blank",
    ])
    func unclaimed(address: String) {
        #expect(SiteFocusSite.matching(URL(string: address)) == nil)
    }

    @Test("A site lens knows when a navigation has left the site")
    func staysWithTheSite() {
        let youtube = SiteFocusSite.youtube
        #expect(youtube.claims(URL(string: "https://www.youtube.com/results?search_query=a")))
        #expect(!youtube.claims(URL(string: "https://example.com/")))
        #expect(!youtube.claims(nil))
    }

    @Test("Pages classify from the address alone")
    func pageKinds() {
        #expect(YouTubePage.of(URL(string: "https://www.youtube.com/")) == .home)
        #expect(YouTubePage.of(URL(string: "https://www.youtube.com/results?search_query=swift+concurrency"))
            == .search(query: "swift concurrency"))
        #expect(YouTubePage.of(URL(string: "https://www.youtube.com/watch?v=u2rYp8AMuSg"))
            == .watch(id: "u2rYp8AMuSg"))
        #expect(YouTubePage.of(URL(string: "https://youtu.be/u2rYp8AMuSg"))
            == .watch(id: "u2rYp8AMuSg"))
        // A results page with no query is the search box, not a search.
        #expect(YouTubePage.of(URL(string: "https://www.youtube.com/results")) == .home)
        // A watch URL whose id is junk has no video to stage.
        #expect(YouTubePage.of(URL(string: "https://www.youtube.com/watch?v=nope")) == .other)
        // Shorts and channels have no lens of their own yet.
        #expect(YouTubePage.of(URL(string: "https://www.youtube.com/shorts/u2rYp8AMuSg")) == .other)
        #expect(YouTubePage.of(URL(string: "https://www.youtube.com/@apple")) == .other)
        #expect(YouTubePage.of(nil) == .other)
    }

    @Test("The search address escapes what a query can contain")
    func searchAddress() throws {
        let url = try #require(YouTubePage.searchURL(for: "  swift concurrency  "))
        #expect(url.absoluteString
            == "https://www.youtube.com/results?search_query=swift%20concurrency")
        // Round trips: the page it builds classifies back to the query.
        #expect(YouTubePage.of(url) == .search(query: "swift concurrency"))

        // Every character that means something in a query, round-tripped:
        // the plus that means a space, the ampersand that ends a value, the
        // question mark that starts the query at all.
        for query in ["c++ & rust?", "swift 6.2 = good", "100% native", "caf\u{00E9}"] {
            let built = try #require(YouTubePage.searchURL(for: query))
            #expect(YouTubePage.of(built) == .search(query: query))
        }

        // Nothing to search for is not a navigation.
        #expect(YouTubePage.searchURL(for: "   ") == nil)
        #expect(YouTubePage.searchURL(for: "") == nil)
    }

    /// The site's own encoding, which percent-decoding alone does not undo.
    /// Caught by this suite before the search field ever showed it.
    @Test("A form-encoded query reads back as words, not as pluses")
    func formEncodedQueries() {
        #expect(YouTubePage.of(URL(string: "https://www.youtube.com/results?search_query=swift+concurrency"))
            == .search(query: "swift concurrency"))
        // A real plus arrives percent-encoded and has to survive as itself.
        #expect(YouTubePage.of(URL(string: "https://www.youtube.com/results?search_query=c%2B%2B+tutorial"))
            == .search(query: "c++ tutorial"))
        #expect(YouTubePage.of(URL(string: "https://www.youtube.com/results?search_query=caf%C3%A9"))
            == .search(query: "caf\u{00E9}"))
    }

    @Test("Video ids are checked before they become addresses")
    func videoIDs() {
        #expect(YouTubePage.isValidVideoID("u2rYp8AMuSg"))
        #expect(YouTubePage.isValidVideoID("_-aB3cD4eF5"))
        #expect(!YouTubePage.isValidVideoID("tooshort"))
        #expect(!YouTubePage.isValidVideoID("waytoolongforanid"))
        #expect(!YouTubePage.isValidVideoID("has a space"))
        #expect(!YouTubePage.isValidVideoID("emoji😀here"))
        #expect(YouTubePage.watchURL(id: "nope") == nil)
    }

    @Test("Query and id read back off a page")
    func accessors() {
        #expect(YouTubePage.search(query: "a").searchQuery == "a")
        #expect(YouTubePage.home.searchQuery == nil)
        #expect(YouTubePage.watch(id: "u2rYp8AMuSg").videoID == "u2rYp8AMuSg")
        #expect(YouTubePage.home.videoID == nil)
    }
}
