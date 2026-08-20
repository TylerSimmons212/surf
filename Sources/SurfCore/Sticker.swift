import Foundation

/// One pinned site: a saved URL rendered as a die-cut sticker in the sidebar.
///
/// A sticker is a *launcher*, not a tab. It holds no web view, never sleeps or
/// wakes, and survives every tab in its island closing — which is the whole
/// point: the sites you return to daily shouldn't depend on a tab you might
/// tidy away.
///
/// Per-island, like everything else with an identity. A work sticker in a
/// personal island would open the site in the wrong cookie jar — the same
/// category of leak `recentlyClosed` is per-island to prevent.
public struct Sticker: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var url: String
    public var title: String
    /// Cached at pin time so the favicon lookup never re-parses the URL.
    public var host: String

    public init(id: UUID = UUID(), url: String, title: String, host: String) {
        self.id = id
        self.url = url
        self.title = title
        self.host = host
    }

    /// Builds a sticker from a page, deriving the host. Nil when the URL is
    /// empty or hostless — a sticker for `about:blank` opens nothing worth
    /// keeping.
    public init?(url: String, title: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let host = URL(string: trimmed)?.host, !host.isEmpty else {
            return nil
        }
        self.init(url: trimmed, title: title, host: host)
    }

    /// The scheme-and-host prefix of the sticker's URL, for the implicit
    /// `/favicon.ico` fallback when the host was never visited.
    public var origin: String? {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme, let host = components.host
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// A real sticker sheet never lays perfectly straight, so each tile leans a
    /// little — deterministically, from the id, so a sticker keeps its lean
    /// across launches instead of shuffling every time the sidebar redraws.
    ///
    /// Between ±1.5° and ±4°: enough to read as hand-placed, never enough to
    /// look broken. Zero is deliberately unreachable — a straight sticker among
    /// tilted ones looks like the bug.
    public var tiltDegrees: Double {
        let hash = hash(salt: 5381)
        let magnitude = 1.5 + Double(hash % 26) / 10 // 1.5...4.0
        return (hash / 26) % 2 == 0 ? magnitude : -magnitude
    }

    /// The lean of the gloss streak laying across the sticker.
    ///
    /// Varied per sticker, and salted separately from the tilt so the two don't
    /// move together — a shelf where the shallowest tilt always carried the
    /// shallowest shine would read as one printed sheet rather than a handful
    /// of stickers that arrived from different places.
    ///
    /// Kept in a narrow band around the diagonal: the streak is a reflection of
    /// the same room every sticker is sitting in, so wildly different angles
    /// would read as a lighting error rather than variety.
    public var shineAngleDegrees: Double {
        14 + Double(hash(salt: 7919) % 25) // 14...38
    }

    /// Where along the sticker the streak falls, 0...1. A little variety in
    /// placement as well as angle, so two stickers side by side don't line up.
    public var shineOffset: Double {
        Double(hash(salt: 104_729) % 21) / 20 // 0...1
    }

    /// djb2 over the id's bytes, seeded so each visual property can vary
    /// independently of the others.
    private func hash(salt: UInt64) -> UInt64 {
        var hash = salt
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes { hash = hash &* 33 &+ UInt64(byte) }
        }
        return hash
    }

    /// A stable hue in 0..<1 derived from the host, for the lettered fallback
    /// tile shown before a favicon exists. Per-host, so two stickers for the
    /// same site agree on their colour.
    public var fallbackHue: Double {
        var hash: UInt64 = 5381
        for byte in host.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Double(hash % 360) / 360
    }

    /// The capital letter the fallback tile wears: the first character of the
    /// host with any `www.` stripped, since a shelf of stickers all lettered
    /// "W" tells nobody anything.
    public var fallbackInitial: String {
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return bare.first.map { String($0).uppercased() } ?? "?"
    }

    // MARK: - List logic

    /// Appends, unless a sticker for the same URL is already on the shelf —
    /// pinning twice should be a no-op, not a growing row of duplicates.
    public static func adding(_ sticker: Sticker, to list: [Sticker]) -> [Sticker] {
        guard !list.contains(where: { $0.url == sticker.url }) else { return list }
        return list + [sticker]
    }

    public static func removing(_ id: UUID, from list: [Sticker]) -> [Sticker] {
        list.filter { $0.id != id }
    }
}
