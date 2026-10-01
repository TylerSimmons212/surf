import Testing

@testable import SurfCore

@Suite("Site address")
struct SiteAddressTests {

    @Test("The pill says the host and nothing else", arguments: [
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "youtube.com"),
        ("https://github.com/owner/repo/pull/1482/files", "github.com"),
        ("https://docs.swift.org/swift-book/", "docs.swift.org"),
        ("https://WWW.Apple.COM", "apple.com"),
    ])
    func hostOnly(address: String, expected: String) throws {
        let read = try #require(SiteAddress.reading(address))
        #expect(read.display == expected)
        // The detail isn't thrown away, it just isn't on the pill.
        #expect(read.full == address)
    }

    @Test("A port survives, because it is part of which site this is")
    func port() throws {
        #expect(try #require(SiteAddress.reading("http://localhost:3000/app")).display
            == "localhost:3000")
        #expect(try #require(SiteAddress.reading("http://localhost:8080/app")).display
            == "localhost:8080")
    }

    @Test("A default port is not part of the name")
    func defaultPort() throws {
        #expect(try #require(SiteAddress.reading("https://example.com:443/")).display
            == "example.com")
        #expect(try #require(SiteAddress.reading("http://example.com:80/")).display
            == "example.com")
    }

    @Test("A file is named by its file, not by the path to it")
    func localFile() throws {
        let read = try #require(
            SiteAddress.reading("file:///Users/someone/Developer/testpages/popup-demo.html")
        )
        #expect(read.display == "popup-demo.html")
        // Nothing can read a local file off the wire, so warning about the wire
        // would be theatre.
        #expect(read.isSecure)
    }

    @Test("A percent-escaped file name is shown the way it is spelled")
    func escapedFileName() throws {
        #expect(try #require(SiteAddress.reading("file:///tmp/my%20page.html")).display
            == "my page.html")
    }

    @Test("Nothing to show is a real answer")
    func nothing() {
        #expect(SiteAddress.reading(nil) == nil)
        #expect(SiteAddress.reading("") == nil)
        #expect(SiteAddress.reading("   ") == nil)
        // A tab that hasn't gone anywhere. "about:blank" on the pill is worse
        // than the placeholder it would be covering up.
        #expect(SiteAddress.reading("about:blank") == nil)
    }

    @Test("Only https is reported secure")
    func security() throws {
        #expect(try #require(SiteAddress.reading("https://example.com")).isSecure)
        #expect(try #require(SiteAddress.reading("http://example.com")).isSecure == false)
    }

    @Test("Something unparseable is still shown rather than hidden")
    func gibberish() throws {
        // Somebody is looking at this. Saying nothing is not better than
        // saying what it is.
        let read = try #require(SiteAddress.reading("not a url at all"))
        #expect(read.display == "not a url at all")
        #expect(read.isSecure == false)
    }
}
