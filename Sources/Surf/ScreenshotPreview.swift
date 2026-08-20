import AppKit
import SurfCore
import SwiftUI

/// The moment between capturing and committing: the shot on screen, with
/// what-now as buttons.
///
/// This is the macOS screenshot contract — capture first, decide second —
/// and it replaced save-straight-to-Downloads for the same reason the system
/// tool works that way: half of all captures are for the clipboard, and a
/// file you never wanted is a chore you didn't ask for. Nothing touches disk
/// until Save says so.
@MainActor
final class ScreenshotPreviewController: NSObject, NSWindowDelegate {
    static let shared = ScreenshotPreviewController()

    private var panel: NSPanel?

    func show(_ image: NSImage, title: String) {
        close()

        let view = ScreenshotPreviewView(
            image: image,
            title: title,
            onClose: { [weak self] in self?.close() }
        )

        // Sized to the image within reason: a phone-width element shouldn't
        // open a desk-wide window, and a full-page tower shouldn't open one
        // taller than the screen.
        let screen = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxContent = CGSize(
            width: min(920, screen.width * 0.7),
            height: min(760, screen.height * 0.8)
        )
        let fit = min(
            1,
            maxContent.width / max(image.size.width, 1),
            (maxContent.height - 60) / max(image.size.height, 1)
        )
        let content = CGSize(
            width: max(340, image.size.width * fit),
            height: max(200, image.size.height * fit + 60)
        )

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: content),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Screenshot — \(title)"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        if panel.isVisible { panel.close() }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            panel = nil
        }
    }
}

private struct ScreenshotPreviewView: View {
    let image: NSImage
    let title: String
    let onClose: () -> Void

    @State private var flash: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView([.vertical, .horizontal]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
            }
            .background(Color(nsColor: .underPageBackgroundColor))

            Divider()

            HStack(spacing: 8) {
                Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)

                if let flash {
                    Text(flash)
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }

                Spacer(minLength: 12)

                Button("Copy") { copy() }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Save As…") { saveAs() }
                // The headline action: what the old flow did unconditionally
                // is now the default button rather than the only outcome.
                Button("Save to Downloads") { saveToDownloads() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 340, minHeight: 200)
        .onExitCommand { onClose() }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        note("Copied")
    }

    private func saveToDownloads() {
        guard let url = ScreenshotSaver.save(image, title: title) else {
            note("Couldn't save")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        onClose()
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ScreenshotNaming.filename(title: title, date: Date())
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { note("Couldn't encode"); return }
        do {
            try png.write(to: url)
            onClose()
        } catch {
            note("Couldn't save")
        }
    }

    private func note(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { flash = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.3)) { flash = nil }
        }
    }
}
