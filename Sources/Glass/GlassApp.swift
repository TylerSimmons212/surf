import SwiftUI

@main
struct GlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// One session for the app. Held here rather than in `ContentView` so the
    /// menu commands below can drive the same tabs the window is showing.
    @State private var session = BrowserSession()

    var body: some Scene {
        WindowGroup("Glass") {
            ContentView(session: session)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 640)
        .commands { tabCommands }
    }

    /// Standard browser shortcuts. These live in the menu bar because that's
    /// what makes ⌘-keys work app-wide, even while a web view has focus.
    @CommandsBuilder
    private var tabCommands: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { session.addTab() }
                .keyboardShortcut("t", modifiers: .command)

            Button("Close Tab") { session.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Button("Show Next Tab") { session.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(session.tabs.count < 2)

            Button("Show Previous Tab") { session.selectPreviousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(session.tabs.count < 2)

            Divider()

            Button("Open Location…") { session.requestAddressFocus() }
                .keyboardShortcut("l", modifiers: .command)

            Divider()

            // ⌘1–⌘9 jump by position; ⌘9 means "last", per convention.
            ForEach(1...9, id: \.self) { index in
                Button("Show Tab \(index)") { session.selectTab(atOneBasedIndex: index) }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index)")),
                        modifiers: .command
                    )
            }
        }
    }
}

/// Makes a SwiftPM-built executable behave like a real app:
/// shows in the Dock, takes focus, and quits when the window closes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
