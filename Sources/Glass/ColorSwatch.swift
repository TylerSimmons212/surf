import GlassCore
import SwiftUI

/// The colour a value actually is, drawn next to it.
///
/// `oklch(0.65 0.19 24)` and `--brand` and `rgb(102 51 153)` all mean something
/// precise that nobody reads off the page. A six-point square answers it before
/// the text has been parsed by eye, which is most of why it's worth the space.
struct ColorSwatch: View {
    let color: CSSColor
    var size: CGFloat = 9
    /// When present the swatch becomes a control that opens the picker.
    var action: (() -> Void)?

    @State private var isHovering = false

    private var fill: Color {
        Color(
            .sRGB,
            red: Double(color.red) / 255,
            green: Double(color.green) / 255,
            blue: Double(color.blue) / 255,
            opacity: color.opacity
        )
    }

    var body: some View {
        if let action {
            Button(action: action) { square }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .help("\(color.hex) — click to pick a colour")
        } else {
            square.help(color.hex)
        }
    }

    private var square: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(fill)
            .background {
                // A transparent colour drawn straight onto the pane would read
                // as whatever is behind it — which for `rgba(0,0,0,0.05)` means
                // reading as "nothing at all".
                if !color.isOpaque {
                    Checkerboard()
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                }
            }
            .overlay {
                // Without an outline, white on a light pane is an invisible
                // swatch — and white is a colour people look for.
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(
                        isHovering ? Color.accentColor : Color.primary.opacity(0.25),
                        lineWidth: isHovering ? 1 : 0.5
                    )
            }
            .frame(width: size, height: size)
            // A nine-point square is a small target, so it grows a little under
            // the pointer rather than relying on aim.
            .scaleEffect(isHovering ? 1.25 : 1, anchor: .center)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .contentShape(Rectangle())
            // Sits on the text baseline rather than the line box, so a row of
            // declarations keeps one optical line.
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
    }
}

private struct Checkerboard: View {
    var body: some View {
        GeometryReader { geometry in
            let half = geometry.size.width / 2
            ZStack(alignment: .topLeading) {
                Color.white
                Path { path in
                    path.addRect(CGRect(x: 0, y: 0, width: half, height: half))
                    path.addRect(CGRect(x: half, y: half, width: half, height: half))
                }
                .fill(Color.black.opacity(0.28))
            }
        }
    }
}

/// A declaration's value with a swatch in front of every colour in it.
struct ColoredValue: View {
    let declaration: CSSDeclaration
    var color: Color = .primary
    var isStruck = false
    /// Opens the picker for one colour in the value. Absent where the value
    /// isn't editable — a computed value has no declaration to write back to.
    var onPick: ((Int, CSSColor) -> Void)?
    /// The text, as opposed to the swatches, starts a text edit.
    var onEditText: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(declaration.valueSegments) { segment in
                if let swatch = segment.color {
                    ColorSwatch(
                        color: swatch,
                        // The tap has to belong to the swatch alone: the text
                        // beside it opens a text field, and one gesture on the
                        // pair would have to guess which was meant.
                        action: onPick.map { pick in { pick(segment.index, swatch) } }
                    )
                    .padding(.trailing, 3)
                }
                Text(segment.text)
                    .foregroundStyle(self.color)
                    .strikethrough(isStruck, color: .secondary)
                    .onTapGesture { onEditText?() }
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }
}
