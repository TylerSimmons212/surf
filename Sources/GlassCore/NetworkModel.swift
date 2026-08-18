import Foundation

/// What kind of thing was fetched. Drives the filter chips and the icon, and
/// is worth its own vocabulary because `initiatorType` alone conflates
/// `<link rel=stylesheet>` with `<link rel=preload as=font>`.
public enum NetworkKind: String, Sendable, CaseIterable, Identifiable {
    case document, fetch, xhr, script, stylesheet, image, font, media, beacon, other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .document: "Doc"
        case .fetch: "Fetch"
        case .xhr: "XHR"
        case .script: "JS"
        case .stylesheet: "CSS"
        case .image: "Img"
        case .font: "Font"
        case .media: "Media"
        case .beacon: "Beacon"
        case .other: "Other"
        }
    }

    /// Everything the page asked for by script, which is what people mean when
    /// they say "just show me the API calls".
    public var isScripted: Bool { self == .fetch || self == .xhr || self == .beacon }

    /// Resource Timing's `initiatorType`, plus the MIME type where one is known
    /// — `initiatorType` says `link` for a stylesheet, a preloaded font and an
    /// icon alike.
    public static func from(initiator: String, mime: String = "", url: String = "") -> NetworkKind {
        switch initiator {
        case "fetch": return .fetch
        case "xmlhttprequest": return .xhr
        case "beacon", "ping": return .beacon
        case "script": return .script
        case "img", "image", "imageset", "input": return .image
        case "css": return .image
        case "video", "audio", "track": return .media
        case "navigation", "document", "iframe", "frame": return .document
        default: break
        }

        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("font/") || mime.contains("woff") { return .font }
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/") { return .media }
        if mime.contains("javascript") { return .script }
        if mime.contains("css") { return .stylesheet }
        if mime.contains("html") { return .document }

        // `link` covers stylesheets, preloads and icons, so the extension is
        // the only thing left to go on.
        let path = url.split(separator: "?").first.map(String.init) ?? url
        switch path.split(separator: ".").last?.lowercased() {
        case "css": return .stylesheet
        case "js", "mjs": return .script
        case "woff", "woff2", "ttf", "otf", "eot": return .font
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "ico": return .image
        case "mp4", "webm", "mp3", "m4a", "mov": return .media
        default: return initiator == "link" ? .stylesheet : .other
        }
    }
}

/// How a request ended up.
public enum NetworkStatusClass: Sendable, Equatable {
    case pending
    case informational, success, redirect, clientError, serverError
    case failed
    /// WebKit reports no status for anything that isn't fetch or XHR, so an
    /// image that 404s is indistinguishable from one that loaded. Saying
    /// "unknown" is the only honest rendering; showing 200 would be a guess and
    /// showing 0 would be a lie.
    case unknown

    public var isProblem: Bool {
        self == .clientError || self == .serverError || self == .failed
    }
}

/// One request, however it was observed.
public struct NetworkRequest: Sendable, Identifiable, Equatable {
    public var id: String
    public var url: String
    public var method: String
    public var kind: NetworkKind

    /// Nil where no status is available — see `NetworkStatusClass.unknown`.
    public var status: Int?
    public var statusText: String
    public var failure: String?

    /// Nil when the response is opaque: a cross-origin resource served without
    /// `Timing-Allow-Origin` withholds every size and phase. Rendering that as
    /// zero would read as "an empty response", which is a different fact.
    public var transferSize: Int?
    public var bodySize: Int?

    /// Milliseconds since the document started loading, so rows can be laid out
    /// against each other.
    public var startedAt: Double
    /// Nil while still in flight.
    public var duration: Double?

    public var isFromCache: Bool
    public var isOpaque: Bool
    public var protocolName: String
    public var initiator: String

    public var requestHeaders: [String: String]
    public var responseHeaders: [String: String]

    /// True for a record the fetch/XHR patch produced, which carries a real
    /// status and headers. Resource Timing records never do.
    public var isDetailed: Bool

    public init(
        id: String,
        url: String,
        method: String = "GET",
        kind: NetworkKind = .other,
        status: Int? = nil,
        statusText: String = "",
        failure: String? = nil,
        transferSize: Int? = nil,
        bodySize: Int? = nil,
        startedAt: Double = 0,
        duration: Double? = nil,
        isFromCache: Bool = false,
        isOpaque: Bool = false,
        protocolName: String = "",
        initiator: String = "",
        requestHeaders: [String: String] = [:],
        responseHeaders: [String: String] = [:],
        isDetailed: Bool = false
    ) {
        self.id = id
        self.url = url
        self.method = method
        self.kind = kind
        self.status = status
        self.statusText = statusText
        self.failure = failure
        self.transferSize = transferSize
        self.bodySize = bodySize
        self.startedAt = startedAt
        self.duration = duration
        self.isFromCache = isFromCache
        self.isOpaque = isOpaque
        self.protocolName = protocolName
        self.initiator = initiator
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.isDetailed = isDetailed
    }

    public var statusClass: NetworkStatusClass {
        if failure != nil { return .failed }
        guard let status else { return duration == nil ? .pending : .unknown }
        switch status {
        case 100..<200: return .informational
        case 200..<300: return .success
        case 300..<400: return .redirect
        case 400..<500: return .clientError
        case 500..<600: return .serverError
        default: return .unknown
        }
    }

    /// `api/users`, or the host for a bare origin — the column is narrow and
    /// the last path component is what identifies a request in practice.
    public var displayName: String {
        guard let components = URLComponents(string: url) else { return url }
        let path = components.path
        if path.isEmpty || path == "/" { return components.host ?? url }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return components.query == nil ? name : name + "?"
    }

    public var domain: String {
        URLComponents(string: url)?.host ?? ""
    }

    /// What to print in the status column.
    public var statusLabel: String {
        if failure != nil { return "failed" }
        if let status { return String(status) }
        return duration == nil ? "pending" : "—"
    }

    public var sizeLabel: String {
        if isFromCache { return "cache" }
        // Distinguished from zero deliberately: unknown is not empty.
        guard let transferSize else { return "—" }
        return NetworkRequest.formatBytes(transferSize)
    }

    public var timeLabel: String {
        guard let duration else { return "—" }
        if duration < 1 { return "<1 ms" }
        if duration < 1000 { return "\(Int(duration.rounded())) ms" }
        return String(format: "%.2f s", duration / 1000)
    }

    public var endedAt: Double { startedAt + (duration ?? 0) }

    public static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kilobytes = Double(bytes) / 1024
        if kilobytes < 1024 { return String(format: "%.1f kB", kilobytes) }
        return String(format: "%.2f MB", kilobytes / 1024)
    }
}

/// The recorded requests for one document.
///
/// Bounded like the console's buffer, and for the same reason: a page that
/// polls in a loop must not be able to grow this without limit just because a
/// panel is open somewhere.
public struct NetworkBuffer: Sendable, Equatable {
    public private(set) var requests: [NetworkRequest] = []
    private var index: [String: Int] = [:]
    public let capacity: Int

    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    public var isEmpty: Bool { requests.isEmpty }
    public var count: Int { requests.count }

    /// Adds a request, or updates the one already recorded under that id.
    public mutating func record(_ request: NetworkRequest) {
        if let position = index[request.id] {
            requests[position] = request
            return
        }
        requests.append(request)
        index[request.id] = requests.count - 1
        trim()
    }

    /// Folds a Resource Timing observation into whatever is already known.
    ///
    /// The two sources see overlapping sets: the fetch patch knows the status
    /// and headers of an API call, while Resource Timing knows its transfer
    /// size and how long each phase took. Recording both as separate rows would
    /// show every API call twice, which is the obvious failure — so a timing
    /// observation enriches a matching record rather than adding one, and only
    /// becomes a row of its own for the images and stylesheets no patch sees.
    ///
    /// Matched on URL and start time together: a page that polls the same
    /// endpoint every second produces many records with identical URLs, and
    /// matching on URL alone would fold them all into the first.
    public mutating func merge(timing: NetworkRequest, tolerance: Double = 50) {
        let match = requests.firstIndex { existing in
            existing.url == timing.url
                && existing.isDetailed
                && abs(existing.startedAt - timing.startedAt) <= tolerance
        }

        guard let position = match else {
            record(timing)
            return
        }

        var merged = requests[position]
        // Timing is authoritative about sizes and duration; the patch is
        // authoritative about status, headers and method.
        merged.transferSize = timing.transferSize
        merged.bodySize = timing.bodySize
        merged.duration = timing.duration ?? merged.duration
        merged.isFromCache = timing.isFromCache
        merged.isOpaque = timing.isOpaque
        if !timing.protocolName.isEmpty { merged.protocolName = timing.protocolName }
        requests[position] = merged
    }

    public mutating func clear() {
        requests.removeAll()
        index.removeAll()
    }

    /// A navigation replaces the document, and with it every id the agent
    /// minted. Preserving is opt-in for the same reason it is in the console:
    /// yesterday's traffic is usually noise.
    public mutating func markNavigation(preserving: Bool) {
        guard !preserving else { return }
        clear()
    }

    public func filtered(kinds: Set<NetworkKind>, query: String) -> [NetworkRequest] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return requests.filter { request in
            guard kinds.contains(request.kind) else { return false }
            guard !needle.isEmpty else { return true }
            return request.url.lowercased().contains(needle)
        }
    }

    public func counts() -> [NetworkKind: Int] {
        requests.reduce(into: [:]) { totals, request in
            totals[request.kind, default: 0] += 1
        }
    }

    /// The footer line: how many, how much, how long.
    public struct Summary: Sendable, Equatable {
        public var count: Int
        public var transferred: Int
        /// Requests whose size WebKit withheld, so the total can say it is a
        /// floor rather than pretending to be exact.
        public var opaqueCount: Int
        public var finishedAt: Double
        public var problems: Int

        public init(
            count: Int = 0, transferred: Int = 0, opaqueCount: Int = 0,
            finishedAt: Double = 0, problems: Int = 0
        ) {
            self.count = count
            self.transferred = transferred
            self.opaqueCount = opaqueCount
            self.finishedAt = finishedAt
            self.problems = problems
        }
    }

    public func summary() -> Summary {
        var transferred = 0
        var opaque = 0
        var finished: Double = 0
        var problems = 0

        for request in requests {
            if let size = request.transferSize, !request.isOpaque {
                transferred += size
            } else if request.isOpaque {
                opaque += 1
            }
            finished = max(finished, request.endedAt)
            if request.statusClass.isProblem { problems += 1 }
        }
        return Summary(
            count: requests.count, transferred: transferred,
            opaqueCount: opaque, finishedAt: finished, problems: problems
        )
    }

    private mutating func trim() {
        guard requests.count > capacity else { return }
        let excess = requests.count - capacity
        requests.removeFirst(excess)
        index = Dictionary(
            uniqueKeysWithValues: requests.enumerated().map { ($0.element.id, $0.offset) }
        )
    }
}
