import AppKit
import CoreText
import SwiftUI

/// A string as its actual glyph outlines, scaled to fill whatever it's given.
///
/// SwiftUI can't stroke a `Text`. The usual workaround — a filled copy behind a
/// clear one — draws a fake: it thickens the letterforms outward instead of
/// tracing them, and at the size this is used the difference is the whole
/// effect. So the glyphs are pulled out of the font as paths and stroked like
/// any other shape.
///
/// It's a `Shape`, which means the size it draws at comes from its frame rather
/// than from a font size anyone has to keep in sync with the window.
struct GlyphOutline: Shape {
    var text: String
    var family: String
    var weight: CGFloat = 500
    var tracking: CGFloat = 0

    /// Width over height of the ink itself.
    ///
    /// A caller that wants the word somewhere specific — half in the water,
    /// say — needs to know how tall it will end up once it has been fitted to a
    /// width, and only the outlines know that.
    func aspect() -> CGFloat {
        let probe = path(in: CGRect(x: 0, y: 0, width: 10_000, height: 10_000)).boundingRect
        return probe.height > 0 ? probe.width / probe.height : 1
    }

    func path(in rect: CGRect) -> Path {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return Path() }

        // Any size will do — the outlines are scaled to the rect afterwards, so
        // this one only has to be large enough that rounding in the font's grid
        // doesn't show once it's blown up.
        // The variation is asked for, not required: Bungee Outline is a single
        // static weight, and a descriptor naming an axis it hasn't got is not
        // something to fail over.
        let varied = NSFontDescriptor(fontAttributes: [
            .family: family,
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): [0x77676874: weight],
        ])
        let base = NSFont(descriptor: varied, size: 256)
            ?? NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: 256)
            ?? .systemFont(ofSize: 256)

        let attributed = NSAttributedString(string: text, attributes: [
            .font: base, .kern: tracking * 256 / 100,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let combined = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = attrs[kCTFontAttributeName as String] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                combined.addPath(glyph, transform: .init(translationX: positions[i].x, y: positions[i].y))
            }
        }

        // The ink, not the typographic line: leading and descender space would
        // centre the word against room no letter here occupies.
        let bounds = combined.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return Path() }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)

        var transform = CGAffineTransform.identity
            .translatedBy(x: rect.midX, y: rect.midY)
            // Flipped: CoreText builds glyphs y-up and every SwiftUI rect is
            // y-down, so without this the word arrives upside down.
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        return Path(combined.copy(using: &transform) ?? combined)
    }
}
