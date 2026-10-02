import Foundation

/// What the sidebar's address pill says you are looking at.
///
/// The pill is a label, not a field — clicking it opens the palette, which is
/// where typing and completion already live. So this answers a narrower
/// question than a URL bar does: given wherever the page is, what is the
/// shortest honest name for it?
///
/// The answer is the host, bare. A path adds length in exchange for detail
/// nobody reads at a glance, and the pill is 250 points wide inside a sidebar
/// — `github.com/owner/repo/pull/1482/files` truncates to something that
/// *looks* like a different site. The full address is still on the tooltip and
/// one click away in the palette.
public struct SiteAddress: Equatable, Sendable {

    /// The short name, for the pill.
    public var display: String
    /// Everything, for the tooltip.
    public var full: String
    /// Whether the transport is one that can't be read off the wire.
    ///
    /// Carried rather than derived at the call site because "secure" is not
    /// the same question as "is https": a local file has no wire to read, and
    /// treating it as insecure would decorate every page you open from disk
    /// with a warning about an attacker who would have to already be inside
    /// the machine.
    public var isSecure: Bool

    public init(display: String, full: String, isSecure: Bool) {
        self.display = display
        self.full = full
        self.isSecure = isSecure
    }

    /// Reads an address, or nil when there is nothing to name yet.
    ///
    /// Nil is a real answer and the pill wants it: a new tab has no address,
    /// and a pill reading `about:blank` is worse than a pill reading
    /// "Search or enter address".
    public static func reading(_ raw: String?) -> SiteAddress? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }

        guard let parts = URLComponents(string: trimmed) else {
            // Unparseable, but somebody is looking at it, so say what it is
            // rather than nothing.
            return SiteAddress(display: trimmed, full: trimmed, isSecure: false)
        }

        let scheme = parts.scheme?.lowercased()

        // A blank page is a tab that hasn't gone anywhere. Nothing to name.
        if scheme == "about" || trimmed == "about:blank" { return nil }

        if scheme == "file" {
            // The file name, because the directory above it is usually a path
            // through somebody's home folder and is never the point.
            let name = parts.path.split(separator: "/").last.map(String.init)
            return SiteAddress(
                display: name?.removingPercentEncoding ?? name ?? "Local file",
                full: trimmed,
                isSecure: true
            )
        }

        guard let host = parts.host?.lowercased(), !host.isEmpty else {
            return SiteAddress(display: trimmed, full: trimmed, isSecure: false)
        }

        // `www.` is noise on every site that still uses it, and its absence
        // means nothing on the ones that don't.
        var name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        // A port is part of the identity — localhost:3000 and localhost:8080
        // are different sites, and the one thing you need to tell them apart
        // is exactly the bit a host-only reading would drop.
        if let port = parts.port, !isDefault(port, for: scheme) {
            name += ":\(port)"
        }

        return SiteAddress(display: name, full: trimmed, isSecure: scheme == "https")
    }

    private static func isDefault(_ port: Int, for scheme: String?) -> Bool {
        switch scheme {
        case "https": port == 443
        case "http": port == 80
        default: false
        }
    }
}
