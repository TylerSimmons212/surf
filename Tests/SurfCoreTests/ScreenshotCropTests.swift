import Foundation
import Testing

@testable import SurfCore

@Suite("Screenshot crop")
struct ScreenshotCropTests {

    @Test("A 2x bitmap doubles the crop")
    func retina() {
        let rect = ScreenshotCrop.pixelRect(
            for: CGRect(x: 10, y: 20, width: 100, height: 50),
            capturedSize: CGSize(width: 800, height: 3000),
            imageSize: CGSize(width: 1600, height: 6000)
        )
        #expect(rect == CGRect(x: 20, y: 40, width: 200, height: 100))
    }

    @Test("A region past the capture cap is refused, not approximated")
    func belowTheCap() {
        let rect = ScreenshotCrop.pixelRect(
            for: CGRect(x: 0, y: 17000, width: 100, height: 100),
            capturedSize: CGSize(width: 800, height: 16000),
            imageSize: CGSize(width: 800, height: 16000)
        )
        #expect(rect == nil)
    }

    @Test("A region straddling the cap keeps its visible half")
    func straddling() {
        let rect = ScreenshotCrop.pixelRect(
            for: CGRect(x: 0, y: 15950, width: 100, height: 100),
            capturedSize: CGSize(width: 800, height: 16000),
            imageSize: CGSize(width: 800, height: 16000)
        )
        #expect(rect?.minY == 15950)
        #expect(rect?.height == 50)
    }

    @Test("The crop never leaves the bitmap")
    func clamped() {
        let rect = ScreenshotCrop.pixelRect(
            for: CGRect(x: -20, y: -10, width: 100, height: 60),
            capturedSize: CGSize(width: 800, height: 600),
            imageSize: CGSize(width: 800, height: 600)
        )
        #expect(rect == CGRect(x: 0, y: 0, width: 80, height: 50))
    }

    @Test("Degenerate regions and empty captures answer nil")
    func degenerate() {
        #expect(ScreenshotCrop.pixelRect(
            for: CGRect(x: 0, y: 0, width: 0, height: 0),
            capturedSize: CGSize(width: 800, height: 600),
            imageSize: CGSize(width: 800, height: 600)
        ) == nil)
        #expect(ScreenshotCrop.pixelRect(
            for: CGRect(x: 0, y: 0, width: 10, height: 10),
            capturedSize: .zero,
            imageSize: CGSize(width: 800, height: 600)
        ) == nil)
    }

    @Test("Fractional CSS pixels round outward, never inward")
    func fractional() {
        let rect = ScreenshotCrop.pixelRect(
            for: CGRect(x: 10.4, y: 10.6, width: 99.5, height: 40.2),
            capturedSize: CGSize(width: 800, height: 600),
            imageSize: CGSize(width: 800, height: 600)
        )
        #expect(rect != nil)
        if let rect {
            #expect(rect.minX <= 10.4)
            #expect(rect.width >= 99.5)
        }
    }
}
