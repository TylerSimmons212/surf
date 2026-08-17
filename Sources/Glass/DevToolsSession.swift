import GlassCore
import Observation
import SwiftUI

/// One tab's dev tools state — everything the panel's views read.
///
/// Per-tab rather than per-window, and that's the whole reason panels aren't
/// shared: node ids, console history, REPL scope and expanded subtrees all
/// belong to a *document*. A single panel that followed the selection would
/// either throw that away on every tab switch or keep every session alive
/// behind one window, which is the memory cost of per-tab panels without the
/// ability to look at two pages side by side.
@Observable
@MainActor
final class DevToolsSession: Identifiable {

    enum Pane: String, CaseIterable, Identifiable {
        case elements, console

        var id: String { rawValue }

        var label: String {
            switch self {
            case .elements: "Elements"
            case .console: "Console"
            }
        }

        var symbol: String {
            switch self {
            case .elements: "chevron.left.forwardslash.chevron.right"
            case .console: "terminal"
            }
        }
    }

    enum Status: Equatable {
        case connecting
        case connected(nodeCount: Int)
        /// The page can't be inspected at all — `about:blank`, a PDF view, a
        /// sandboxed document. Worth saying plainly instead of showing an inert
        /// UI that looks broken.
        case unavailable(String)
    }

    nonisolated let id: UUID
    private(set) weak var tab: Tab?

    var pane: Pane = .console
    private(set) var status: Status = .connecting

    /// Bumped on every committed navigation. Replies are stamped with the
    /// generation they were issued in and dropped if it has moved on — without
    /// this, a style or DOM read still in flight across a navigation paints the
    /// new page with the old page's answers.
    private(set) var generation = 0

    @ObservationIgnored private let bridge: DevToolsBridge

    init(tab: Tab) {
        self.id = tab.id
        self.tab = tab
        self.bridge = DevToolsBridge(tab: tab)

        bridge.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    var pageURL: String { tab?.webView.url?.absoluteString ?? "" }

    // MARK: - Lifecycle

    func start() {
        Task { @MainActor in
            do {
                try await bridge.attach()
                await refreshStatus()
            } catch {
                status = .unavailable(error.localizedDescription)
            }
        }
    }

    func stop() {
        bridge.detach()
    }

    /// A committed navigation replaces the document: every id the agent handed
    /// out is now meaningless.
    func documentDidChange() {
        generation += 1
        status = .connecting
        Task { @MainActor in await refreshStatus() }
    }

    private func handle(_ event: DevToolsEvent) {
        switch event {
        case .bootstrapped:
            documentDidChange()
        case .overflowed:
            // Resync, never replay — a replay would double-apply mutations that
            // did land before the agent gave up.
            documentDidChange()
        }
    }

    private func refreshStatus() async {
        let issued = generation
        do {
            let reply = try await bridge.call(.runtimePing)
            // Dropped if the page moved on while this was in flight.
            guard issued == generation else { return }
            status = .connected(nodeCount: reply["nodeCount"] as? Int ?? 0)
        } catch {
            guard issued == generation else { return }
            status = .unavailable(error.localizedDescription)
        }
    }
}
