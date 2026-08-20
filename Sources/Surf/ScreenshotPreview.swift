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
        let chrome: CGFloat = 64
        let maxContent = CGSize(
            width: min(960, screen.width * 0.7),
            height: min(800, screen.height * 0.8)
        )
        let fit = min(
            1,
            (maxContent.width - 48) / max(image.size.width, 1),
            (maxContent.height - chrome - 48) / max(image.size.height, 1)
        )
        let content = CGSize(
            width: max(380, image.size.width * fit + 48),
            height: max(240, image.size.height * fit + chrome + 48)
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
            stage
            footer
        }
        .frame(minWidth: 380, minHeight: 240)
        .onExitCommand { onClose() }
    }

    /// The shot as an object on a surface, not wallpaper filling a frame —
    /// and draggable, because the fastest export is dropping it straight
    /// into Slack or an email.
    private var stage: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)

            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
                .padding(24)
                .onDrag { NSItemProvider(object: image) }
                .help("Drag me into any app")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

            if let flash {
                Label(flash, systemImage: "checkmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            Spacer(minLength: 12)

            SharePickerButton(image: image)

            Button {
                copy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)
            .help("Copy to the clipboard (⌘C)")

            Button("Save As…") { saveAs() }

            // The headline action: what the old flow did unconditionally is
            // now the default button rather than the only outcome.
            Button {
                saveToDownloads()
            } label: {
                Label("Save to Downloads", systemImage: "arrow.down.circle")
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
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

/// The system share sheet, from a real anchor.
///
/// `NSSharingServicePicker` insists on an NSView to point its popover at, so
/// the button is a small representable rather than a SwiftUI Button — the
/// price of the native sheet, which is worth paying: AirDrop, Messages, and
/// whatever the user has installed, none of it reimplemented.
private struct SharePickerButton: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "Share",
            image: NSImage(
                systemSymbolName: "square.and.arrow.up",
                accessibilityDescription: "Share"
            ) ?? NSImage(),
            target: context.coordinator,
            action: #selector(Coordinator.share(_:))
        )
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.imagePosition = .imageLeading
        return button
    }

    func updateNSView(_ view: NSButton, context: Context) {
        context.coordinator.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator(image: image) }

    @MainActor
    final class Coordinator: NSObject {
        var image: NSImage

        init(image: NSImage) {
            self.image = image
        }

        @objc func share(_ sender: NSButton) {
            let picker = NSSharingServicePicker(items: [image])
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
