import SurfCore
import SwiftUI

/// The colour a value actually is, drawn next to it.
///
/// `oklch(0.65 0.19 24)` and `--brand` and `rgb(102 51 153)` all mean something
/// precise that nobody reads off the page. A six-point square answers it before
/// the text has been parsed by eye, which is most of why it's worth the space.
struct ColorSwatch: View {
    let color: ResolvedColor
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
    var onPick: ((Int, ResolvedColor) -> Void)?
    /// Drag on a number. Reports the offset of the number grabbed and the
    /// replacement text, so the rest of a compound value is untouched.
    var onScrub: ((Int, String) -> Void)?
    /// Called when a drag ends, so one read settles what a gesture changed.
    var onScrubEnd: (() -> Void)?
    /// The text, as opposed to the swatches, starts a text edit.
    var onEditText: (() -> Void)?

    /// Segments split again around their numbers, so each number can carry its
    /// own gesture while the text between them stays ordinary text.
    private var pieces: [ValuePiece] {
        var out: [ValuePiece] = []
        var index = 0
        for segment in declaration.valueSegments {
            if let swatch = segment.color {
                out.append(ValuePiece(id: index, text: segment.text, color: swatch,
                                      number: nil, segment: segment.index))
                index += 1
                continue
            }
            let numbers = CSSValueScrub.numbers(in: segment.text)
            guard !numbers.isEmpty else {
                out.append(ValuePiece(id: index, text: segment.text, color: nil,
                                      number: nil, segment: segment.index))
                index += 1
                continue
            }
            var cursor = 0
            let characters = Array(segment.text)
            for number in numbers {
                if number.offset > cursor {
                    out.append(ValuePiece(
                        id: index, text: String(characters[cursor..<number.offset]),
                        color: nil, number: nil, segment: segment.index
                    ))
                    index += 1
                }
                out.append(ValuePiece(id: index, text: number.text, color: nil,
                                      number: number, segment: segment.index))
                index += 1
                cursor = number.offset + number.text.count
            }
            if cursor < characters.count {
                out.append(ValuePiece(
                    id: index, text: String(characters[cursor...]),
                    color: nil, number: nil, segment: segment.index
                ))
                index += 1
            }
        }
        return out
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(pieces) { piece in
                if let swatch = piece.color {
                    ColorSwatch(
                        color: swatch,
                        // The tap has to belong to the swatch alone: the text
                        // beside it opens a text field, and one gesture on the
                        // pair would have to guess which was meant.
                        action: onPick.map { pick in { pick(piece.segment, swatch) } }
                    )
                    .padding(.trailing, 3)
                    Text(piece.text)
                        .foregroundStyle(self.color)
                        .strikethrough(isStruck, color: .secondary)
                        .onTapGesture { onEditText?() }
                } else if let number = piece.number, let onScrub {
                    ScrubbableNumber(
                        number: number,
                        color: self.color,
                        isStruck: isStruck,
                        onScrub: { onScrub(number.offset, $0) },
                        onEnd: { onScrubEnd?() },
                        onEditText: { onEditText?() }
                    )
                } else {
                    Text(piece.text)
                        .foregroundStyle(self.color)
                        .strikethrough(isStruck, color: .secondary)
                        .onTapGesture { onEditText?() }
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

private struct ValuePiece: Identifiable {
    let id: Int
    let text: String
    let color: ResolvedColor?
    let number: CSSNumber?
    let segment: Int
}

/// A number you can drag.
///
/// The interaction a design tool has and a devtools pane usually doesn't:
/// `padding: 12px` is a value you want to feel rather than retype, and every
/// retype costs a round trip through the keyboard to discover you wanted 14.
private struct ScrubbableNumber: View {
    let number: CSSNumber
    let color: Color
    let isStruck: Bool
    let onScrub: (String) -> Void
    let onEnd: () -> Void
    let onEditText: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        Text(number.text)
            .foregroundStyle(color)
            .strikethrough(isStruck, color: .secondary)
            .background(alignment: .bottom) {
                // A dotted underline rather than a control: the affordance has
                // to be discoverable without turning a dense list of text into
                // a row of widgets.
                Rectangle()
                    .fill(Color.accentColor.opacity(isHovering || isDragging ? 0.8 : 0.25))
                    .frame(height: 1)
                    .offset(y: 1)
            }
            .onHover { hovering in
                isHovering = hovering
                // Says "you can drag this" before you try.
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        isDragging = true
                        let modifiers = NSEvent.modifierFlags
                        let step = CSSValueScrub.step(
                            for: number.unit,
                            coarse: modifiers.contains(.shift),
                            fine: modifiers.contains(.option)
                        )
                        // Two points per step: fine enough to land on a value,
                        // coarse enough to cross a range without flinging.
                        let steps = (value.translation.width / 2).rounded()
                        guard steps != 0 else { return }
                        onScrub(CSSValueScrub.adjusted(number, by: steps, unit: step))
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEnd()
                    }
            )
            .onTapGesture { onEditText() }
    }
}
