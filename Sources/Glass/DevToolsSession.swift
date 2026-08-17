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

    // MARK: - Console

    private(set) var console = ConsoleBuffer()

    var consoleLevels: Set<ConsoleLevel> = Set(ConsoleLevel.allCases)
    var consoleQuery = ""
    /// Off by default, like every browser: yesterday's output is usually noise.
    var preservesLogOnNavigation = false

    var visibleConsoleEntries: [ConsoleEntry] {
        console.filtered(levels: consoleLevels, query: consoleQuery)
    }

    var consoleCounts: [ConsoleLevel: Int] { console.counts() }

    /// True when a filter is hiding output, so the pane can say so rather than
    /// letting someone conclude their page went quiet.
    var isConsoleFiltered: Bool {
        consoleLevels.count != ConsoleLevel.allCases.count
            || !consoleQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func clearConsole() {
        console.clear()
        releaseEvictedObjects()
    }

    // MARK: - The prompt

    /// What has been typed, newest last. Memory only — a REPL history that
    /// outlived the window would be a record of what you were debugging.
    private(set) var inputHistory: [String] = []
    private static let historyDepth = 100

    /// Runs an entry, echoing both the input and what it answered.
    func evaluate(_ input: String) async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Consecutive duplicates aren't worth a second history slot.
        if inputHistory.last != trimmed { inputHistory.append(trimmed) }
        if inputHistory.count > Self.historyDepth { inputHistory.removeFirst() }

        console.append(ConsoleEntry(
            id: 0,
            kind: .input,
            arguments: [RemoteObject(type: .string, description: trimmed)]
        ))

        let wrapped = ConsoleREPL.wrap(trimmed)
        let issued = generation

        do {
            let reply = try await bridge.call(.runtimeEvaluate, [
                "source": wrapped.source,
                "usesAwait": wrapped.usesAwait,
            ])
            guard issued == generation else { return }
            guard let result = ConsoleWire.decodeEvaluation(reply) else { return }

            console.append(ConsoleEntry(
                id: 0,
                kind: .result,
                // A thrown value is an error however it was produced, and
                // colouring it like a result would hide the failure.
                level: result.thrown ? .error : .log,
                arguments: [result.value]
            ))
        } catch {
            guard issued == generation else { return }
            console.append(ConsoleEntry(
                id: 0,
                kind: .result,
                level: .error,
                arguments: [RemoteObject(type: .string, description: error.localizedDescription)]
            ))
        }
        releaseEvictedObjects()
    }

    /// One level of an object, fetched only when someone opens it.
    func properties(of objectId: String) async -> [ObjectProperty] {
        let issued = generation
        guard let reply = try? await bridge.call(.runtimeGetProperties, ["objectId": objectId]),
              issued == generation
        else { return [] }
        return ConsoleWire.decodeProperties(reply)
    }

    func toggleConsoleLevel(_ level: ConsoleLevel) {
        if consoleLevels.contains(level) {
            // Never leave zero levels selected — an empty console that looks
            // broken is worse than a filter that refuses to hide everything.
            guard consoleLevels.count > 1 else { return }
            consoleLevels.remove(level)
        } else {
            consoleLevels.insert(level)
        }
    }

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
                await drainConsoleBacklog()
                await refreshStatus()
            } catch {
                status = .unavailable(error.localizedDescription)
            }
        }
    }

    /// Collects everything the page logged before this window existed, and puts
    /// the agent into live mode. This is the payoff for capturing always: a
    /// console that opens already holding the startup errors you opened it for.
    ///
    /// Retried, because `didCommit` can land a hair before the document-start
    /// scripts are reachable. Failing silently there would be the worst kind of
    /// bug: the agent would stay in buffering mode and the console would simply
    /// show nothing, for ever, with no error to explain it.
    private func drainConsoleBacklog() async {
        let issued = generation

        for attempt in 0..<4 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(80))
                guard issued == generation else { return }
            }
            guard let reply = try? await bridge.call(.consoleDrain),
                  let batch = ConsoleWire.decodeBatch(reply)
            else { continue }

            guard issued == generation else { return }
            for entry in batch.entries { console.append(entry) }
            return
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
        console.markNavigation(url: pageURL, preservingLog: preservesLogOnNavigation)
        releaseEvictedObjects()

        Task { @MainActor in
            // The new document's console agent starts buffering rather than
            // live — it has no idea a window is open — so it has to be told,
            // and its startup logs collected, exactly as at attach time.
            await drainConsoleBacklog()
            await refreshStatus()
        }
    }

    private func handle(_ event: DevToolsEvent) {
        switch event {
        case .bootstrapped:
            // Liveness only, deliberately *not* a document reset. `didCommit`
            // is the single authority for that: this event also fires when
            // `attach()` injects the agent by hand into a document that's
            // already on screen, and treating that as a navigation would wipe
            // the backlog we just went to the trouble of collecting.
            Task { @MainActor in await refreshStatus() }

        case .overflowed:
            noteDroppedOutput(nil)

        case .consoleBatch(let entries, let sequence, let dropped):
            // Reported before the batch it preceded, so the gap appears where
            // it actually happened rather than at the end of the run.
            if dropped > 0 { noteDroppedOutput(dropped) }
            for entry in entries { console.append(entry) }
            releaseEvictedObjects()
            // Acknowledging is what lets the page keep sending: unacked batches
            // past the window stop the agent emitting, which is the whole
            // backpressure mechanism.
            bridge.send(.consoleAck, ["sequence": sequence])

        case .consoleCleared:
            // The page called console.clear() itself. Honouring it matches
            // every other browser, and a page that clears its own console is
            // usually doing it for a reason worth respecting.
            clearConsole()
        }
    }

    /// A gap in the log, said out loud.
    ///
    /// A console that silently skips output is worse than one that admits it:
    /// the whole value of the thing is that what you see is what happened.
    private func noteDroppedOutput(_ count: Int?) {
        let text = count.map {
            "\($0.formatted()) messages were dropped — the page logged faster than Glass could read."
        } ?? "Some messages were dropped — the page logged faster than Glass could read."

        console.append(ConsoleEntry(
            id: 0,
            level: .warning,
            arguments: [RemoteObject(type: .string, description: text)]
        ))
    }

    /// Handles that fell out of the buffer still pin page objects alive, so the
    /// page has to be told. A no-op until Phase 2 hands out any ids.
    private func releaseEvictedObjects() {
        let ids = console.takeEvictedObjectIds()
        guard !ids.isEmpty else { return }
        bridge.send(.runtimeReleaseObject, ["objectIds": ids])
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
