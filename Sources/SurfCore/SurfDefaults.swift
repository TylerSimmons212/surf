import Foundation

/// Where Surf keeps its preferences, and the seam that keeps a test run out
/// of yours.
///
/// `SupportDirectory` already redirects everything Surf writes to disk when
/// `SURF_STATE_DIR` is set — session, history, favicons, filter lists. User
/// defaults were the hole in that: they are keyed by application domain
/// rather than by directory, so a verification run reading and writing
/// `SurfDefaults.store` was reading and writing the same preferences as
/// the copy of Surf you have open.
///
/// The blast radius was small — a preference flag and the identifiers of
/// compiled rule sets, never browsing data — and nothing broke, because the
/// values are self-consistent. But `verify-surf` states plainly that a run
/// never touches your state, and that has to be true rather than nearly
/// true, or it is not a guarantee.
public enum SurfDefaults {

    /// The defaults this process should read and write.
    ///
    /// A scratch run gets its own suite, derived from the state directory so
    /// that a run which restarts finds what it left behind. Everything else
    /// gets the standard domain, which is the real one.
    /// `nonisolated(unsafe)` because `UserDefaults` is not `Sendable` and is
    /// documented thread-safe — the same bargain every call site was already
    /// making with `UserDefaults.standard`, now stated once instead of
    /// twenty-five times.
    nonisolated(unsafe) public static let store: UserDefaults = {
        guard let directory = scratchDirectory else { return .standard }
        let suite = suiteName(forStateDirectory: directory)
        guard let scratch = UserDefaults(suiteName: suite) else { return .standard }
        // A suite outlives the process it was made for — it is a plist in
        // Preferences like any other. Leaving its name in the scratch
        // directory is what lets teardown remove it, and the scratch
        // directory is exactly where a side effect of scratch-ness belongs.
        try? suite.write(
            to: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("defaults-suite"),
            atomically: true, encoding: .utf8
        )
        return scratch
    }()

    /// Whether this process is running against a scratch state directory.
    public static var isScratch: Bool { scratchDirectory != nil }

    /// The cookie jar a scratch run's home island browses with, or nil outside
    /// one.
    ///
    /// The second hole of exactly the kind this file was written for, and a
    /// worse one. The home island names WebKit's *default* data store on
    /// purpose — it is the jar Surf has been filling since before islands
    /// existed, and there is no supported way to move cookies out of it. But
    /// `SURF_STATE_DIR` cannot redirect that store, because it is WebKit's own
    /// container rather than one of our files. So a scratch run's home island
    /// was the real one: it read the user's cookies, and anything offering to
    /// delete them was offering to delete theirs.
    ///
    /// Naming an identified store instead costs nothing. Nothing persisted
    /// changes — `PersistedIsland.dataStoreID` stays nil for home, as it must
    /// — and the redirection is entirely at runtime, in `IslandStores`.
    public static var scratchDataStoreID: UUID? {
        scratchDirectory.map(dataStoreID(forStateDirectory:))
    }

    /// A data store identifier of this state directory's own.
    ///
    /// Derived rather than random, for the same reason `suiteName` is: a run
    /// that restarts has to find the jar it left behind, or no test can sign in
    /// and then check it is still signed in.
    public static func dataStoreID(forStateDirectory path: String) -> UUID {
        // Sixty-four bits of digest, repeated to fill the hundred and
        // twenty-eight a UUID wants. Not a version-4 UUID and it does not need
        // to be: WebKit treats the identifier as a name, and the only
        // properties required are that it parses and that it is stable.
        let digest = Self.digest(path)
        let half = String(repeating: "0", count: max(0, 16 - digest.count))
            + digest.suffix(16)
        let hex = Array(half + half)
        func group(_ start: Int, _ length: Int) -> String {
            String(hex[start..<(start + length)])
        }
        let text = [
            group(0, 8), group(8, 4), group(12, 4), group(16, 4), group(20, 12),
        ].joined(separator: "-")
        // An all-zero identifier makes `WKWebsiteDataStore(forIdentifier:)`
        // raise rather than return nil, so it is refused upstream and would
        // degrade the run to a non-persistent store. Still isolated, but
        // silently forgetful, so the sentinel keeps it persistent.
        guard let id = UUID(uuidString: text), id != zeroStoreID else { return fallbackStoreID }
        return id
    }

    static let zeroStoreID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Only reachable from a digest of all zeros, which no real path produces.
    static let fallbackStoreID = UUID(
        uuidString: "5c7a7c40-0000-4000-8000-000000000001"
    )!

    private static var scratchDirectory: String? {
        guard let override = ProcessInfo.processInfo.environment["SURF_STATE_DIR"],
              !override.isEmpty
        else { return nil }
        return override
    }

    /// A defaults domain of this state directory's own.
    ///
    /// Derived rather than random so a run is reproducible, and hashed
    /// rather than spelled out because a defaults domain is a filename and a
    /// path is full of characters a filename should not contain.
    public static func suiteName(forStateDirectory path: String) -> String {
        "surf.scratch.\(digest(path))"
    }

    /// FNV-1a, 64-bit. Not a security property — this only has to be stable
    /// across launches and unlikely to collide between two scratch
    /// directories on one machine.
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(text.utf8) {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
