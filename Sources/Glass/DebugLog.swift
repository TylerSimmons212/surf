import Foundation

/// stderr, so it survives output redirection unbuffered. Gated on the dev
/// `GLASS_URL` env var, which is how Glass is run when anyone is watching its
/// output at all — the app itself never writes a log.
func debugLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["GLASS_URL"] != nil else { return }
    fputs("[glass] \(message)\n", stderr)
}
