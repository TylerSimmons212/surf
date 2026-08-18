import Testing

@testable import SurfCore

@Suite("Network model")
struct NetworkModelTests {

    private func request(
        _ id: String,
        _ url: String = "https://example.com/api/users",
        status: Int? = 200,
        started: Double = 100,
        duration: Double? = 20,
        transfer: Int? = 1024,
        detailed: Bool = true,
        kind: NetworkKind = .fetch
    ) -> NetworkRequest {
        NetworkRequest(
            id: id, url: url, kind: kind, status: status,
            transferSize: transfer, startedAt: started, duration: duration,
            isDetailed: detailed
        )
    }

    // MARK: - Status

    /// WebKit exposes no status for anything that isn't fetch or XHR, so an
    /// image that 404s looks exactly like one that loaded. "Unknown" is the
    /// only honest rendering — 200 would be a guess, 0 would be a lie.
    @Test("A finished request with no status reads as unknown, not as success")
    func unknownStatus() {
        let image = request("1", status: nil, kind: .image)
        #expect(image.statusClass == .unknown)
        #expect(image.statusLabel == "—")
    }

    @Test("A request still in flight is pending rather than unknown")
    func pending() {
        let inFlight = request("1", status: nil, duration: nil)
        #expect(inFlight.statusClass == .pending)
        #expect(inFlight.statusLabel == "pending")
    }

    @Test("Status codes classify into the bands people actually filter on")
    func statusClasses() {
        #expect(request("1", status: 204).statusClass == .success)
        #expect(request("1", status: 301).statusClass == .redirect)
        #expect(request("1", status: 404).statusClass == .clientError)
        #expect(request("1", status: 503).statusClass == .serverError)
        #expect(request("1", status: 404).statusClass.isProblem)
        #expect(!request("1", status: 304).statusClass.isProblem)
    }

    @Test("A transport failure outranks whatever status was recorded")
    func failure() {
        var failed = request("1")
        failed.failure = "The network connection was lost."
        #expect(failed.statusClass == .failed)
        #expect(failed.statusLabel == "failed")
    }

    // MARK: - Sizes

    /// A cross-origin response without Timing-Allow-Origin withholds its size.
    /// Printing "0 B" would read as an empty response, which is a different
    /// fact from "we're not allowed to know".
    @Test("An opaque response shows unknown rather than zero bytes")
    func opaqueSize() {
        let opaque = request("1", transfer: nil)
        #expect(opaque.sizeLabel == "—")
    }

    @Test("A cached response says so instead of showing a transfer size")
    func cachedSize() {
        var cached = request("1", transfer: 0)
        cached.isFromCache = true
        #expect(cached.sizeLabel == "cache")
    }

    @Test("Byte counts read in the unit that suits them")
    func byteFormatting() {
        #expect(NetworkRequest.formatBytes(512) == "512 B")
        #expect(NetworkRequest.formatBytes(2048) == "2.0 kB")
        #expect(NetworkRequest.formatBytes(5 * 1024 * 1024) == "5.00 MB")
    }

    @Test("Durations read in the unit that suits them")
    func timeFormatting() {
        #expect(request("1", duration: 0.4).timeLabel == "<1 ms")
        #expect(request("1", duration: 250).timeLabel == "250 ms")
        #expect(request("1", duration: 1500).timeLabel == "1.50 s")
        #expect(request("1", duration: nil).timeLabel == "—")
    }

    // MARK: - Naming

    @Test("The name column shows what identifies a request at a glance")
    func naming() {
        #expect(request("1", "https://example.com/api/users").displayName == "users")
        #expect(request("1", "https://example.com/").displayName == "example.com")
        // A query string is what distinguishes two calls to the same endpoint.
        #expect(request("1", "https://example.com/api/users?page=2").displayName == "users?")
        #expect(request("1", "https://cdn.example.com/a.png").domain == "cdn.example.com")
    }

    // MARK: - Kinds

    @Test("Initiator types map to the categories people filter by")
    func kinds() {
        #expect(NetworkKind.from(initiator: "fetch") == .fetch)
        #expect(NetworkKind.from(initiator: "xmlhttprequest") == .xhr)
        #expect(NetworkKind.from(initiator: "img") == .image)
    }

    /// `link` covers stylesheets, preloaded fonts and icons alike, so the
    /// initiator alone puts all three in the same bucket.
    @Test("A link is disambiguated by what it actually loaded")
    func linkDisambiguation() {
        #expect(NetworkKind.from(initiator: "link", url: "/app.css") == .stylesheet)
        #expect(NetworkKind.from(initiator: "link", url: "/font.woff2") == .font)
        #expect(NetworkKind.from(initiator: "link", url: "/icon.png") == .image)
        // MIME beats the extension when there is one.
        #expect(NetworkKind.from(initiator: "link", mime: "font/woff2", url: "/x") == .font)
    }

    // MARK: - Merging the two sources

    /// The fetch patch and Resource Timing both see an API call. Recording
    /// both would show every request twice — the obvious failure of running
    /// two observers over one page.
    @Test("A timing observation enriches a patched record instead of duplicating it")
    func mergeEnriches() {
        var buffer = NetworkBuffer()
        buffer.record(request("patched", transfer: nil, detailed: true))

        var timing = request("timing", transfer: 4096, detailed: false)
        timing.duration = 35
        buffer.merge(timing: timing)

        #expect(buffer.count == 1)
        #expect(buffer.requests[0].id == "patched")
        // Timing wins on size; the patch keeps the status it alone knows.
        #expect(buffer.requests[0].transferSize == 4096)
        #expect(buffer.requests[0].duration == 35)
        #expect(buffer.requests[0].status == 200)
    }

    /// An image is seen only by Resource Timing, so it has to become a row of
    /// its own or it would never appear at all.
    @Test("A timing observation with nothing to match becomes its own row")
    func mergeAdds() {
        var buffer = NetworkBuffer()
        buffer.merge(timing: request("img", "https://x.test/a.png", detailed: false, kind: .image))
        #expect(buffer.count == 1)
        #expect(buffer.requests[0].kind == .image)
    }

    /// A page polling one endpoint produces many records with identical URLs.
    /// Matching on URL alone would fold every one of them into the first.
    @Test("Repeated calls to one endpoint stay separate")
    func mergeRespectsTime() {
        var buffer = NetworkBuffer()
        buffer.record(request("a", started: 100, detailed: true))
        buffer.record(request("b", started: 1100, detailed: true))

        buffer.merge(timing: request("t", started: 1105, transfer: 999, detailed: false))

        #expect(buffer.count == 2)
        #expect(buffer.requests[0].transferSize == 1024)
        #expect(buffer.requests[1].transferSize == 999)
    }

    // MARK: - Buffer

    @Test("Recording the same id twice updates rather than appends")
    func updateInPlace() {
        var buffer = NetworkBuffer()
        buffer.record(request("1", status: nil, duration: nil))
        buffer.record(request("1", status: 201, duration: 12))
        #expect(buffer.count == 1)
        #expect(buffer.requests[0].status == 201)
    }

    /// A page polling in a loop must not be able to grow this without bound
    /// just because a panel happens to be open.
    @Test("The buffer is bounded, keeping the newest")
    func bounded() {
        var buffer = NetworkBuffer(capacity: 3)
        for index in 0..<6 { buffer.record(request("\(index)")) }
        #expect(buffer.count == 3)
        #expect(buffer.requests.map(\.id) == ["3", "4", "5"])
        // The index has to survive trimming, or a later update lands on the
        // wrong row.
        buffer.record(request("4", status: 500))
        #expect(buffer.count == 3)
        #expect(buffer.requests[1].status == 500)
    }

    @Test("Filtering narrows by kind and by substring together")
    func filtering() {
        var buffer = NetworkBuffer()
        buffer.record(request("1", "https://x.test/api/users", kind: .fetch))
        buffer.record(request("2", "https://x.test/logo.png", kind: .image))

        #expect(buffer.filtered(kinds: [.fetch], query: "").count == 1)
        #expect(buffer.filtered(kinds: Set(NetworkKind.allCases), query: "logo").count == 1)
        #expect(buffer.filtered(kinds: [.image], query: "users").isEmpty)
    }

    @Test("Navigation clears unless preserving was asked for")
    func navigation() {
        var buffer = NetworkBuffer()
        buffer.record(request("1"))
        buffer.markNavigation(preserving: true)
        #expect(buffer.count == 1)
        buffer.markNavigation(preserving: false)
        #expect(buffer.isEmpty)
    }

    /// The total has to admit what it couldn't count, rather than quietly
    /// under-reporting by however many cross-origin responses there were.
    @Test("The summary counts opaque responses apart from the byte total")
    func summary() {
        var buffer = NetworkBuffer()
        buffer.record(request("1", started: 0, duration: 50, transfer: 1000))
        var opaque = request("2", started: 10, duration: 100, transfer: nil)
        opaque.isOpaque = true
        buffer.record(opaque)
        buffer.record(request("3", status: 404, started: 20, duration: 30, transfer: 500))

        let summary = buffer.summary()
        #expect(summary.count == 3)
        #expect(summary.transferred == 1500)
        #expect(summary.opaqueCount == 1)
        #expect(summary.problems == 1)
        #expect(summary.finishedAt == 110)
    }
}

@Suite("Network ordering")
struct NetworkOrderingTests {

    /// The two observers report at different times: a patched record is created
    /// when the request starts, while its Resource Timing counterpart arrives
    /// after it finishes. Recording order therefore puts every fetch above
    /// images that loaded before it, and a waterfall whose rows aren't in time
    /// order is worse than no waterfall at all.
    @Test("Requests sort by when they started, not when they were recorded")
    func chronological() {
        var buffer = NetworkBuffer()
        buffer.record(NetworkRequest(id: "fetch", url: "/api", startedAt: 900))
        buffer.record(NetworkRequest(id: "img", url: "/a.png", startedAt: 100))
        buffer.record(NetworkRequest(id: "doc", url: "/", startedAt: 0))

        let ordered = buffer.requests.sorted { $0.startedAt < $1.startedAt }
        #expect(ordered.map(\.id) == ["doc", "img", "fetch"])
    }
}
