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

    /// The crop, in image points. Starts as the whole shot; every action
    /// exports whatever this says. Double-click puts it back.
    @State private var crop: CGRect
    @State private var activeHandle: CropGeometry.Handle?
    @State private var rectAtDragStart: CGRect?
    @State private var flash: String?

    init(image: NSImage, title: String, onClose: @escaping () -> Void) {
        self.image = image
        self.title = title
        self.onClose = onClose
        _crop = State(initialValue: CGRect(origin: .zero, size: image.size))
    }

    private var imageBounds: CGRect { CGRect(origin: .zero, size: image.size) }
    private var isCropped: Bool {
        crop.integral != imageBounds.integral
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
            footer
        }
        .frame(minWidth: 380, minHeight: 240)
        .onExitCommand { onClose() }
    }

    // MARK: - Stage

    /// The shot as an object on a surface, wearing its crop. All gesture
    /// math routes through CropGeometry — the view only converts between
    /// its fitted coordinates and image points.
    private var stage: some View {
        GeometryReader { geometry in
            let available = CGRect(origin: .zero, size: geometry.size)
                .insetBy(dx: 24, dy: 24)
            let scale = min(
                available.width / max(image.size.width, 1),
                available.height / max(image.size.height, 1),
                1
            )
            let fitted = CGSize(
                width: image.size.width * scale, height: image.size.height * scale
            )
            let origin = CGPoint(
                x: (geometry.size.width - fitted.width) / 2,
                y: (geometry.size.height - fitted.height) / 2
            )
            let frame = CGRect(origin: origin, size: fitted)

            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)

                Image(nsImage: image)
                    .resizable()
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
                    .offset(x: origin.x, y: origin.y)

                // Placed with a single offset and no clipping: the old
                // .offset-then-.frame().clipped() stack clipped against the
                // stage's origin rather than the image's, which ate every
                // handle on the right and bottom edges and let the top ones
                // float above the shot. The veil now draws at exactly the
                // fitted size, and handles are *meant* to overhang by half
                // their width — that's what makes an edge grabbable.
                CropChrome(
                    crop: viewRect(crop, in: frame, scale: scale),
                    size: fitted
                )
                .offset(x: origin.x, y: origin.y)
            }
            .contentShape(Rectangle())
            // The crop owns every drag on the stage. Drag-out lives on the
            // footer chip instead — two drag interpretations on one surface
            // meant the crop and the export fought for the same gesture,
            // and both lost.
            .gesture(cropGesture(frame: frame, scale: scale))
            .onTapGesture(count: 2) {
                crop = imageBounds
            }
            .help("Drag the edges to crop · double-click to uncrop")
        }
    }

    /// Image points → this layout's view coordinates.
    private func viewRect(_ rect: CGRect, in frame: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    private func cropGesture(frame: CGRect, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeHandle == nil {
                    // Hit-test in view space, where the tolerance is a
                    // finger's worth of pixels regardless of image size.
                    let local = CGPoint(
                        x: value.startLocation.x - frame.minX,
                        y: value.startLocation.y - frame.minY
                    )
                    activeHandle = CropGeometry.handle(
                        at: local, in: viewRect(crop, in: frame, scale: scale)
                    )
                    rectAtDragStart = crop
                }
                guard let handle = activeHandle, let start = rectAtDragStart else { return }
                crop = CropGeometry.drag(
                    start,
                    handle: handle,
                    by: CGSize(
                        width: value.translation.width / scale,
                        height: value.translation.height / scale
                    ),
                    in: imageBounds,
                    minSize: 24 / scale
                )
            }
            .onEnded { _ in
                activeHandle = nil
                rectAtDragStart = nil
            }
    }

    // MARK: - Footer

    /// Three verbs, as asked: Share, Copy to Clipboard, Save. Everything
    /// exports the crop — there is no separate "export crop" step to forget.
    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(Int(crop.width)) × \(Int(crop.height))\(isCropped ? " of \(Int(image.size.width)) × \(Int(image.size.height))" : "")")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

            if let flash {
                Label(flash, systemImage: "checkmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            Spacer(minLength: 12)

            // The drag-out handle: pick this up and drop the crop into any
            // app. A live thumbnail of the crop itself rather than an icon —
            // an abstract glyph here read as decoration and got asked about,
            // while "the picture, small, in hand" is the same learned object
            // as the system screenshot thumbnail and a titlebar proxy icon.
            // Off the stage because the stage's drags all belong to the crop.
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5)
                }
                .contentShape(Rectangle())
                .onDrag { NSItemProvider(object: croppedImage()) }
                .help("Drag into any app to export")

            SharePickerButton(imageProvider: croppedImage)
                .fixedSize()

            Button("Copy to Clipboard") { copy() }
                .keyboardShortcut("c", modifiers: .command)

            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .help("Save to Downloads")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Actions

    private func croppedImage() -> NSImage {
        guard isCropped,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let pixelRect = ScreenshotCrop.pixelRect(
                  for: crop,
                  capturedSize: image.size,
                  imageSize: CGSize(width: cg.width, height: cg.height)
              ),
              let cut = cg.cropping(to: pixelRect)
        else { return image }
        let scale = CGFloat(cg.width) / max(image.size.width, 1)
        return NSImage(
            cgImage: cut,
            size: CGSize(width: pixelRect.width / scale, height: pixelRect.height / scale)
        )
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([croppedImage()])
        note("Copied")
    }

    private func save() {
        guard let url = ScreenshotSaver.save(croppedImage(), title: title) else {
            note("Couldn't save")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        onClose()
    }

    private func note(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { flash = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.3)) { flash = nil }
        }
    }
}

/// The crop's visible parts: the veil outside it, its border, its handles.
private struct CropChrome: View {
    let crop: CGRect
    /// The fitted image's size — the veil's exact extent.
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Veil with the crop punched out.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(crop)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

            // White line, dark halo: legible on a white page and on a dark
            // one, which a bare white hairline was not.
            Rectangle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1)
                .shadow(color: .black.opacity(0.7), radius: 1)
                .frame(width: crop.width, height: crop.height)
                .offset(x: crop.minX, y: crop.minY)

            ForEach(Array(handlePoints.enumerated()), id: \.offset) { _, point in
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 7, height: 7)
                    .overlay { Rectangle().strokeBorder(Color.black.opacity(0.4), lineWidth: 0.5) }
                    .offset(x: point.x - 3.5, y: point.y - 3.5)
            }
        }
        .allowsHitTesting(false)
    }

    private var handlePoints: [CGPoint] {
        [
            CGPoint(x: crop.minX, y: crop.minY),
            CGPoint(x: crop.midX, y: crop.minY),
            CGPoint(x: crop.maxX, y: crop.minY),
            CGPoint(x: crop.minX, y: crop.midY),
            CGPoint(x: crop.maxX, y: crop.midY),
            CGPoint(x: crop.minX, y: crop.maxY),
            CGPoint(x: crop.midX, y: crop.maxY),
            CGPoint(x: crop.maxX, y: crop.maxY),
        ]
    }
}

/// The system share sheet, from a real anchor.
///
/// `NSSharingServicePicker` insists on an NSView to point its popover at, so
/// the button is a small representable rather than a SwiftUI Button — the
/// price of the native sheet, which is worth paying: AirDrop, Messages, and
/// whatever the user has installed, none of it reimplemented.
private struct SharePickerButton: NSViewRepresentable {
    let imageProvider: () -> NSImage

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
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ view: NSButton, context: Context) {
        context.coordinator.imageProvider = imageProvider
    }

    func makeCoordinator() -> Coordinator { Coordinator(imageProvider: imageProvider) }

    @MainActor
    final class Coordinator: NSObject {
        var imageProvider: () -> NSImage

        init(imageProvider: @escaping () -> NSImage) {
            self.imageProvider = imageProvider
        }

        @objc func share(_ sender: NSButton) {
            let picker = NSSharingServicePicker(items: [imageProvider()])
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
