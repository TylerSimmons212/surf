import AppKit
import CryptoKit
import Foundation
import SurfCore

/// Fetches and caches favicons, keyed by host.
///
/// Two levels: memory for the session, disk so a restored tab can show its icon
/// at launch without waiting for the page to load. Keying by host (not URL)
/// means every page on a site shares one icon and one fetch.
@MainActor
final class FaviconStore {
    static let shared = FaviconStore()

    private var memory: [String: NSImage] = [:]
    /// Hosts whose fetch failed, so a site with no icon isn't retried on every
    /// navigation for the rest of the session.
    private var failed: Set<String> = []
    private var inFlight: Set<String> = []

    private let directory: URL = SupportDirectory.subdirectory("Favicons")

    /// Hosts already looked for on disk and not found.
    ///
    /// Without this a miss cached nothing, so every call re-hashed the host and
    /// went back to the filesystem for a file that wasn't there last time
    /// either. This is called from view bodies — once per suggestion row, per
    /// keystroke, in the address bar — so a miss is the *common* case and it
    /// was the one doing synchronous I/O on the main thread.
    private var absent: Set<String> = []

    /// Synchronous lookup — memory, then disk. Returns nil if not yet fetched.
    func cachedIcon(forHost host: String) -> NSImage? {
        if let image = memory[host] { return image }
        guard !absent.contains(host) else { return nil }
        guard let data = try? Data(contentsOf: fileURL(for: host)),
              let image = NSImage(data: data)
        else {
            absent.insert(host)
            return nil
        }
        image.size = NSSize(width: 16, height: 16)
        memory[host] = image
        return image
    }

    func shouldFetch(forHost host: String) -> Bool {
        !failed.contains(host) && !inFlight.contains(host) && memory[host] == nil
    }

    /// Downloads `href` and caches the result under `host`.
    func fetchIcon(from href: String, host: String) async -> NSImage? {
        guard shouldFetch(forHost: host) else { return cachedIcon(forHost: host) }
        inFlight.insert(host)
        defer { inFlight.remove(host) }

        guard let data = await download(href), let image = NSImage(data: data) else {
            failed.insert(host)
            return nil
        }

        image.size = NSSize(width: 16, height: 16)
        memory[host] = image
        // There's a file for this host now, so a previous miss no longer holds.
        absent.remove(host)
        // Best-effort: a failed disk write just means refetching next launch.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: host), options: .atomic)
        return image
    }

    private func download(_ href: String) async -> Data? {
        // Inline data: URIs are common for small icons and URLSession won't
        // load them, so decode by hand.
        if href.hasPrefix("data:") {
            guard let comma = href.firstIndex(of: ",") else { return nil }
            let payload = String(href[href.index(after: comma)...])
            if href[..<comma].hasSuffix("base64") {
                return Data(base64Encoded: payload)
            }
            return payload.removingPercentEncoding.map { Data($0.utf8) }
        }

        guard let url = URL(string: href), url.scheme?.hasPrefix("http") == true else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              !data.isEmpty,
              (response as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true
        else { return nil }
        return data
    }

    /// Hashed, because hosts can contain characters that are illegal in a path.
    private func fileURL(for host: String) -> URL {
        let digest = SHA256.hash(data: Data(host.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }
}
