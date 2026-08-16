import SwiftUI

@main
struct GlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Glass") {
            ContentView()
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 640)
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
