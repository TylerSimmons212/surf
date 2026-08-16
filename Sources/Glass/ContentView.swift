import SwiftUI

/// Switches between the home search screen and the browsing view.
struct ContentView: View {
    @State private var engine = BrowserEngine()

    var body: some View {
        Group {
            switch engine.mode {
            case .home:
                SearchView(engine: engine)
            case .browsing:
                VStack(spacing: 0) {
                    BrowserChrome(engine: engine)
                    ZStack {
                        WebView(webView: engine.webView)
                        if let error = engine.lastError {
                            ErrorOverlay(message: error) { engine.reload() }
                        }
                    }
                }
                .ignoresSafeArea()
                .navigationTitle(engine.pageTitle.isEmpty ? "Glass" : engine.pageTitle)
            }
        }
        // Dev affordance: `GLASS_URL=example.com swift run` opens straight to a
        // page, so navigation can be exercised without driving the UI by hand.
        .onAppear {
            if let start = ProcessInfo.processInfo.environment["GLASS_URL"], !start.isEmpty {
                engine.submit(start)
            }
        }
    }
}

/// Shown when a navigation fails outright, so the user isn't left staring at a
/// blank white web view with no explanation.
private struct ErrorOverlay: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Couldn't load that page")
                .font(.title3.weight(.medium))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}
