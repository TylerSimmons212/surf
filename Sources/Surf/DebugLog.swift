import Foundation

/// stderr, so it survives output redirection unbuffered. Gated on the dev
/// `SURF_URL` env var, which is how Surf is run when anyone is watching its
/// output at all — the app itself never writes a log.
func debugLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["SURF_URL"] != nil else { return }
    fputs("[surf] \(message)\n", stderr)
}
