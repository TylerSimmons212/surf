import SurfCore
import SwiftUI

/// The box model as concentric boxes, every number editable in place.
///
/// Same palette as the page highlight — orange margin, green padding, blue
/// content — so the diagram and the overlay read as two views of one thing,
/// which they are. Click a number, type, return; the write lands as an inline
/// style through the same paths every other edit uses, and the diagram
/// re-reads the engine's answer rather than assuming the ask worked: type
/// `width: 12px` on a span and the numbers stay honest about it having done
/// nothing.
struct BoxModelView: View {
    let session: DevToolsSession
    let box: BoxModel

    private enum Palette {
        static let margin = Color(red: 0.96, green: 0.76, blue: 0.42)
        static let border = Color(red: 0.85, green: 0.80, blue: 0.60)
        static let padding = Color(red: 0.60, green: 0.83, blue: 0.53)
        static let content = Color(red: 0.45, green: 0.68, blue: 0.94)
    }

    var body: some View {
        ring(
            label: "margin", tint: Palette.margin,
            values: box.margin, prefix: "margin-", suffix: ""
        ) {
            ring(
                label: "border", tint: Palette.border,
                values: box.border, prefix: "border-", suffix: "-width"
            ) {
                ring(
                    label: "padding", tint: Palette.padding,
                    values: box.padding, prefix: "padding-", suffix: ""
                ) {
                    content
                }
            }
        }
        .padding(6)
    }

    /// One layer of the onion: a colored surface with its four numbers on
    /// its edges and the next layer nested inside.
    private func ring(
        label: String,
        tint: Color,
        values: [CGFloat],
        prefix: String,
        suffix: String,
        @ViewBuilder inner: () -> some View
    ) -> some View {
        VStack(spacing: 1) {
            BoxNumber(session: session, property: prefix + "top" + suffix, value: values[0])
            HStack(spacing: 1) {
                BoxNumber(session: session, property: prefix + "left" + suffix, value: values[3])
                inner()
                    .frame(maxWidth: .infinity)
                BoxNumber(session: session, property: prefix + "right" + suffix, value: values[1])
            }
            BoxNumber(session: session, property: prefix + "bottom" + suffix, value: values[2])
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tint.opacity(0.28))
        }
        .overlay(alignment: .topLeading) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.top, 1)
        }
    }

    private var content: some View {
        HStack(spacing: 3) {
            BoxNumber(
                session: session, property: "width",
                value: box.contentFrame.width, alwaysUnit: true
            )
            Text("×")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            BoxNumber(
                session: session, property: "height",
                value: box.contentFrame.height, alwaysUnit: true
            )
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Palette.content.opacity(0.35))
        }
    }
}

/// One measurement: a number at rest, a field when clicked.
private struct BoxNumber: View {
    let session: DevToolsSession
    let property: String
    let value: CGFloat
    var alwaysUnit = false

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 9.5).monospacedDigit())
                .multilineTextAlignment(.center)
                .focused($isFocused)
                .frame(width: 44)
                .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { nudge($0) }
                .onSubmit { commit() }
                .onExitCommand { isEditing = false }
                .background {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(DevToolsTheme.inputFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 0.5)
                }
        } else {
            Text(display)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.10) : .clear)
                }
                .onHover { isHovering = $0 }
                .onTapGesture { begin() }
                .help("\(property) — click to edit")
        }
    }

    private var display: String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    private func begin() {
        draft = display
        isEditing = true
        isFocused = true
    }

    /// Arrow keys step like every other number in the panel.
    private func nudge(_ press: KeyPress) -> KeyPress.Result {
        guard let number = CSSValueScrub.numbers(in: draft).first else { return .ignored }
        let step = CSSValueScrub.step(
            for: number.unit.isEmpty ? "px" : number.unit,
            coarse: press.modifiers.contains(.shift),
            fine: press.modifiers.contains(.option)
        )
        draft = CSSValueScrub.replacing(
            draft, number: number,
            with: CSSValueScrub.adjusted(
                number, by: press.key == .upArrow ? 1 : -1, unit: step
            )
        )
        write(draft)
        return .handled
    }

    private func commit() {
        write(draft)
        isEditing = false
    }

    private func write(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        // A bare number means pixels here — nobody types the unit into a
        // box-model diagram, and the engine would drop a unitless length.
        if Double(value) != nil, Double(value) != 0 || alwaysUnit {
            value += "px"
        }
        let property = property
        Task { @MainActor in await session.setBoxValue(property, value) }
    }
}
