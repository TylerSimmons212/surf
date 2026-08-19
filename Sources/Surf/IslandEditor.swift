import AppKit
import SurfCore
import SwiftUI

/// Naming an island, as a sheet rather than a popover.
///
/// A popover was the wrong container for this. It dismisses on any click
/// outside itself, and two of the three controls here — the system emoji
/// viewer and the system colour panel — are separate windows, so reaching for
/// either one closed the thing you were reaching from. A sheet is modal to the
/// window and stays put while you use them.
///
/// Edits apply live to the island rather than on Done. Everything here is
/// visible in the sidebar as you change it, and watching the chip you're naming
/// change under you is worth more than the ability to back out — which is what
/// Revert is for.
struct IslandEditorSheet: View {
    let session: BrowserSession
    let island: Island

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var symbolText: String = ""
    @State private var tint: Color = .blue
    /// What it all was on arrival, so Revert has something to go back to.
    @State private var original: (name: String, symbol: String, tint: IslandTint)?

    @FocusState private var focus: Field?
    private enum Field { case name, symbol }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(alignment: .leading, spacing: 14) {
                labelled("Name") {
                    TextField("Island name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($focus, equals: .name)
                        .onSubmit { close() }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                        .onChange(of: name) { _, new in session.rename(island, to: new) }
                }

                labelled("Icon") { symbolPicker }

                labelled("Theme") { tintPicker }
            }

            footer
        }
        .padding(24)
        .frame(width: 380)
        .onAppear(perform: load)
        // The colour panel is a shared, app-wide window. Leaving it up after
        // the sheet closes strands a picker wired to nothing.
        .onDisappear { NSColorPanel.shared.close() }
    }

    // MARK: - Pieces

    /// The chip exactly as the sidebar draws it, so the thing being edited and
    /// the thing being previewed can't drift apart.
    private var header: some View {
        HStack(spacing: 10) {
            Text(symbolText.isEmpty ? IslandSymbols.fallback : symbolText)
                .font(.system(size: 22))
            VStack(alignment: .leading, spacing: 1) {
                Text(name.isEmpty ? "Untitled Island" : name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(island.isHome ? "Your original browsing data" : "Separate logins and cookies")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.16))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        }
    }

    private var symbolPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // A real text field, because that is what the system emoji
                // viewer inserts into: it types into the first responder, so
                // there has to be one and it has to be focused.
                TextField("", text: $symbolText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .multilineTextAlignment(.center)
                    .focused($focus, equals: .symbol)
                    .frame(width: 44)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: .rect(cornerRadius: 10))
                    .onChange(of: symbolText) { _, new in
                        // Whatever arrives — typed, pasted, or inserted by the
                        // viewer — is reduced to a single emoji. The viewer
                        // appends rather than replaces, so without this the
                        // field accumulates.
                        guard let symbol = IslandSymbols.firstSymbol(in: new) else { return }
                        if symbol != new { symbolText = symbol }
                        island.symbol = symbol
                        session.scheduleSave()
                    }

                Button("Emoji & Symbols…") {
                    focus = .symbol
                    // The system picker, rather than a grid of our own choosing
                    // pretending to be one.
                    NSApp.orderFrontCharacterPalette(nil)
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Spacer(minLength: 0)
            }

            FlowLayout(spacing: 6) {
                ForEach(IslandSymbols.quickPicks, id: \.self) { symbol in
                    Button { symbolText = symbol } label: {
                        Text(symbol)
                            .font(.system(size: 16))
                            .frame(width: 28, height: 28)
                            .background {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.primary.opacity(symbolText == symbol ? 0.14 : 0))
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(symbol)
                }
            }
        }
    }

    private var tintPicker: some View {
        HStack(spacing: 10) {
            // The system colour panel: wheel, sliders, palettes, eyedropper.
            ColorPicker("Island colour", selection: $tint, supportsOpacity: false)
                .labelsHidden()
                .onChange(of: tint) { _, new in
                    island.tint = IslandTint(new)
                    session.scheduleSave()
                }

            Divider().frame(height: 18)

            ForEach(Array(IslandTint.presets.enumerated()), id: \.offset) { _, preset in
                Button { tint = preset.color } label: {
                    Circle()
                        .fill(preset.color)
                        .frame(width: 18, height: 18)
                        .overlay {
                            Circle().strokeBorder(
                                Color.primary.opacity(
                                    IslandTint(tint) == preset ? 0.6 : 0.12
                                ),
                                lineWidth: IslandTint(tint) == preset ? 2 : 1
                            )
                        }
                }
                .buttonStyle(.plain)
                .help(preset.label)
            }

            Spacer(minLength: 0)

            Text(IslandTint(tint).hex)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if island.isHome {
                // The one island whose isolation isn't real, said plainly
                // rather than left to be discovered.
                Label("Uses your original cookies", systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if island.isDegraded {
                Label("Storage unavailable — this island forgets you on quit",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 12)

            Button("Revert", action: revert)
                .controlSize(.large)
                .disabled(!hasChanges)

            Button("Done", action: close)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
    }

    private func labelled(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - State

    private var hasChanges: Bool {
        guard let original else { return false }
        return original.name != name
            || original.symbol != symbolText
            || original.tint != IslandTint(tint)
    }

    private func load() {
        name = island.name
        symbolText = island.symbol
        tint = island.tint.color
        original = (island.name, island.symbol, island.tint)
        focus = .name
    }

    private func revert() {
        guard let original else { return }
        name = original.name
        symbolText = original.symbol
        tint = original.tint.color
        island.name = original.name
        island.symbol = original.symbol
        island.tint = original.tint
        session.scheduleSave()
    }

    private func close() {
        // An island with no name is a chip you can't tell from the next one.
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.rename(island, to: original?.name ?? "Island")
        }
        session.saveNow()
        dismiss()
    }
}

/// Presents the island editor over the window.
///
/// A `View` rather than a bare `.sheet(item:)` on `ContentView`, and that is
/// the difference between it appearing and not. Under `@Observable`, a
/// dependency is recorded when it is read *while a body runs* — and a
/// `Binding`'s getter closure runs later, outside anyone's body. So the sheet
/// was bound to a property nothing was watching: setting it changed no view,
/// nothing re-evaluated, and the sheet never presented. Reading it here, in a
/// body, is what registers the dependency.
private struct IslandEditorPresenter: ViewModifier {
    let session: BrowserSession

    func body(content: Content) -> some View {
        let editing = session.islandBeingEdited
        content.sheet(
            item: Binding(
                get: { editing },
                set: { session.islandBeingEdited = $0 }
            )
        ) { island in
            IslandEditorSheet(session: session, island: island)
        }
    }
}

extension View {
    func islandEditor(session: BrowserSession) -> some View {
        modifier(IslandEditorPresenter(session: session))
    }
}
