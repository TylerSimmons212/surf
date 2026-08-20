import AppKit
import SurfCore
import WebKit

/// Screenshots: a browser feature, not a dev-tools one.
///
/// Everyone screenshots pages — to file a bug, to keep a receipt, to send a
/// recipe — so capture lives on `Tab` beside navigation, and the entry points
/// are the sidebar and the File menu. Dev tools can call the same methods if
/// it ever wants a button; the feature doesn't live there.
extension Tab {

    /// The viewport as it stands.
    func captureVisibleArea() async -> NSImage? {
        guard mode == .browsing else { return nil }
        return try? await webView.takeSnapshot(configuration: nil)
    }

    /// The whole document, top to bottom.
    ///
    /// WebKit only rasterises what has a frame, so the capture is: ask the
    /// page its scrollable extent, let the container lay the web view out at
    /// that full size for one moment, snapshot it, and put everything back.
    /// The override rides the same `layout()` choke point viewport emulation
    /// uses, so there is exactly one place a web view's frame ever comes from.
    ///
    /// Height is capped: a 100 000px feed page would otherwise ask for a
    /// texture no GPU enjoys. The cap is stated in points and generous —
    /// sixteen thousand is ten breakpoints of laptop, and past it the capture
    /// is honest about being a crop rather than failing or lying.
    func captureFullPage() async -> NSImage? {
        guard mode == .browsing,
              let container = webView.superview as? WebViewContainer
        else { return nil }

        struct Metrics: Decodable {
            var width: Double
            var height: Double
        }
        // The isolated world, as the protocol declares — the world mapping
        // is the failure that looks like the page simply not answering.
        guard let metrics = await isolatedAgent.value(
            .pageMetrics, [:], as: Metrics.self
        ) else { return nil }

        let size = CGSize(
            width: webView.bounds.width,
            height: min(CGFloat(metrics.height), 16000)
        )
        guard size.height > 0, size.width > 0 else { return nil }

        container.captureOverride = size
        defer { container.captureOverride = nil }
        // The frame change has to reach WebKit's layout before the snapshot
        // asks for pixels that now exist.
        container.layoutSubtreeIfNeeded()

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        return try? await webView.takeSnapshot(configuration: configuration)
    }
}

extension Tab {

    // MARK: - Element-pick capture

    /// Arms the pick: veil up, agent listening, next click captures.
    ///
    /// The capture methods install here, not at page load — they are the one
    /// agent domain that is lazy, because a per-page parse cost for a
    /// few-times-a-day feature is exactly what the injected-script budget
    /// exists to refuse. The install is idempotent per document.
    func beginAreaCapture() {
        guard mode == .browsing, captureOverlay == nil else { return }
        let overlay = CaptureOverlayView(frame: webView.bounds)
        overlay.autoresizingMask = [.width, .height]
        webView.addSubview(overlay)
        captureOverlay = overlay
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                CaptureDomain.installScript,
                arguments: [:],
                contentWorld: PageProtocol.World.isolated.contentWorld
            )
            isolatedAgent.send(.captureBegin)
        }
    }

    func cancelAreaCapture() {
        guard captureOverlay != nil else { return }
        isolatedAgent.send(.captureEnd)
        captureOverlay?.removeFromSuperview()
        captureOverlay = nil
    }

    func handleCaptureEvent(_ event: String, _ data: Data) {
        switch event {
        case "hover":
            guard let hover = try? JSONDecoder().decode(
                PageProtocol.Event<CaptureEvent.Hover>.self, from: data
            ) else { return }
            captureOverlay?.show(hover.payload)

        case "picked":
            guard let pick = try? JSONDecoder().decode(
                PageProtocol.Event<CaptureEvent.Pick>.self, from: data
            ) else { return }
            cancelAreaCapture()
            Task { @MainActor in
                await self.capturePicked(pick.payload)
            }

        case "cancelled":
            cancelAreaCapture()

        default:
            break
        }
    }

    /// The picked element, by whichever path tells the truth about it.
    ///
    /// Two paths, because the full-page trick has a cost the first version
    /// paid in wrong screenshots: laying the document out at another
    /// viewport size makes the page *reflow* — vh heroes, centred columns,
    /// responsive grids all move — so a rect measured at pick time addresses
    /// a layout that no longer exists under the snapshot. An element fully
    /// in view is therefore captured from the viewport as it stands, zero
    /// relayout; only an element that outruns the window takes the resize,
    /// and then the agent re-measures the *element* after the reflow, so
    /// the crop follows wherever the new layout put it.
    private func capturePicked(_ pick: CaptureEvent.Pick) async {
        let viewport = webView.bounds.size
        let viewportRect = CGRect(x: pick.x, y: pick.y, width: pick.width, height: pick.height)

        let image: NSImage?
        let target: CGRect
        let capturedSize: CGSize

        if CGRect(origin: .zero, size: viewport)
            .insetBy(dx: -1, dy: -1)
            .contains(viewportRect) {
            image = try? await webView.takeSnapshot(configuration: nil)
            target = viewportRect
            capturedSize = image?.size ?? viewport
        } else {
            guard let container = webView.superview as? WebViewContainer else { return }
            struct Metrics: Decodable {
                var height: Double
            }
            guard let metrics = await isolatedAgent.value(
                .pageMetrics, [:], as: Metrics.self
            ) else { return }

            let size = CGSize(
                width: viewport.width,
                height: min(CGFloat(metrics.height), 16000)
            )
            container.captureOverride = size
            container.layoutSubtreeIfNeeded()
            // Let the reflow — and anything lazy it woke — settle before
            // asking where the element ended up.
            try? await Task.sleep(for: .milliseconds(80))

            let fresh = await isolatedAgent.value(
                .captureRect, [:], as: CaptureEvent.Pick.self
            )

            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: size)
            image = try? await webView.takeSnapshot(configuration: configuration)
            container.captureOverride = nil

            target = (fresh ?? pick).pageRect
            capturedSize = image?.size ?? size
        }

        guard let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let pixelRect = ScreenshotCrop.pixelRect(
                  for: target,
                  capturedSize: capturedSize,
                  imageSize: CGSize(width: cg.width, height: cg.height)
              ),
              let cropped = cg.cropping(to: pixelRect)
        else {
            debugLog("screenshot: region crop failed")
            return
        }

        let scale = CGFloat(cg.width) / max(capturedSize.width, 1)
        ScreenshotPreviewController.shared.show(
            NSImage(
                cgImage: cropped,
                size: CGSize(
                    width: pixelRect.width / scale,
                    height: pixelRect.height / scale
                )
            ),
            title: displayTitle
        )
    }
}

/// Writes a capture where downloads go, named for the page.
@MainActor
enum ScreenshotSaver {

    /// Returns where it landed, or nil with a log — a failed save must not
    /// look like a successful one.
    static func save(_ image: NSImage, title: String) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            debugLog("screenshot: could not encode PNG")
            return nil
        }

        guard let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
        else {
            debugLog("screenshot: no Downloads directory")
            return nil
        }

        let url = downloads.appendingPathComponent(
            ScreenshotNaming.filename(title: title, date: Date())
        )
        do {
            try png.write(to: url)
            return url
        } catch {
            debugLog("screenshot: save failed — \(error.localizedDescription)")
            return nil
        }
    }
}
