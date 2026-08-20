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
/// Name, flag and colour land on Done — see `close()`. The two switches under
/// them do not: what they choose is which cookie jar the island browses with,
/// and that is settled by its first page load rather than by a button. So they
/// apply as you flip them, which is safe for the one reason it needs to be —
/// they only ever appear on an island this sheet just made, and cancelling
/// takes that island with it.
struct IslandEditorSheet: View {
    let session: BrowserSession
    let island: Island

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var symbolText: String = ""
    @State private var tint: Color = .blue
    /// Whether this sheet opened as part of *making* the island, which decides
    /// what cancelling means: undoing an edit, or undoing the island.
    @State private var isNew = false
    /// Whether the sheet was finished rather than abandoned. Escape dismisses a
    /// sheet without running any button's action, so "was this cancelled?" can
    /// only be answered by what *didn't* happen.
    @State private var committed = false

    /// The two things a new island can be given rather than start without.
    ///
    /// These apply the moment they're flipped, unlike the name and the colour
    /// below them — and they have to. What they change is which cookie jar the
    /// island browses with, which is settled by its first page load, not by a
    /// button labelled Done. Backing out is still whole: cancelling a new
    /// island deletes it, jar and all.
    @State private var keepsLogins = false
    @State private var keepsStickers = false

    @FocusState private var focus: Field?
    private enum Field { case name, symbol }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 12) {
                labelled("Name") {
                    TextField("Name this island", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($focus, equals: .name)
                        .onSubmit { close() }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))

                }

                labelled("Flag") { symbolPicker }

                labelled("Water") { tintPicker }

                if let source { labelled("Brings over from \(source.name)") { carryOver(source) } }
            }

            footer
        }
        .padding(20)
        .frame(width: 380)
        .onAppear(perform: load)
        .onDisappear {
            // The colour panel is a shared, app-wide window. Leaving it up
            // after the sheet closes strands a picker wired to nothing.
            NSColorPanel.shared.close()
            // Backing out of a new island takes the island with it. Hung off
            // the sheet going away rather than off Cancel, because Escape and
            // clicking outside never reach the button.
            if isNew, !committed { session.deleteIsland(island) }
        }
    }

    // MARK: - Pieces

    /// The island this one was made from, and only while this sheet is the one
    /// making it.
    ///
    /// Read from the session in `body` rather than copied in `onAppear`, so the
    /// switches are there in the sheet's first frame instead of appearing a
    /// moment later and shoving everything below them down.
    ///
    /// Nil when revisiting an existing island: by then it has browsed, and a
    /// jar cannot be swapped under pages that have already used it.
    private var source: Island? {
        guard session.islandEditorIsForNewIsland, !island.isHome else { return nil }
        return session.islandEditorSource.flatMap { $0 === island ? nil : $0 }
    }

    /// The chip exactly as the sidebar draws it, so the thing being edited and
    /// the thing being previewed can't drift apart.
    private var header: some View {
        HStack(spacing: 10) {
            Text(symbolText.isEmpty ? IslandSymbols.fallback : symbolText)
                .font(.system(size: 22))
            VStack(alignment: .leading, spacing: 1) {
                Text(name.isEmpty ? "Uncharted" : name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// What the chip says it is, which has to follow the switches: an island
    /// sharing a jar is not "its own shore", and saying so where the user can
    /// see both at once is the cheapest possible way to be honest about it.
    private var subtitle: String {
        if island.isHome {
            return "Your home break — everything you were already signed in to"
        }
        if keepsLogins, let source {
            return "Signed in as \(source.name). Its own tabs, its own shelf."
        }
        return "Its own shore. Nothing washes over from the others."
    }

    /// The two switches, and the whole point of them: a new island is either a
    /// new desk for the same accounts, or a different person entirely, and
    /// which one you meant is not something the app can guess.
    private func carryOver(_ source: Island) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            carryToggle(
                "Stay signed in",
                detail: "Goes on sharing \(source.name)'s logins — sign out on one, "
                    + "you're out on both.",
                isOn: $keepsLogins
            )
            .onChange(of: keepsLogins) { _, keeps in
                session.setIslandKeepsLogins(keeps, for: island)
            }

            carryToggle(
                "Bring the pinned sites",
                detail: "Copies \(source.name)'s shelf. The copies are yours.",
                isOn: $keepsStickers
            )
            .onChange(of: keepsStickers) { _, keeps in
                session.setIslandKeepsStickers(keeps, for: island)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }

    private func carryToggle(
        _ title: String, detail: String, isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(tint)
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
                        guard let symbol = IslandSymbols.firstSymbol(in: new), symbol != new
                        else { return }
                        symbolText = symbol
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
        VStack(alignment: .leading, spacing: 14) {
            explainer

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                // Cancel rather than Revert, and it does both jobs: edits here
                // apply as you make them, so backing out has to put the island
                // back as well as close the sheet. Escape reaches it.
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)

                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        }
    }

    /// What an island actually is, in the app's own voice.
    ///
    /// The last line is not decoration. Keychain passwords and passkeys live
    /// with macOS rather than with us, so they genuinely are shared across
    /// islands — and someone who assumed otherwise would find out by being
    /// recognised on a site they expected to be a stranger on. Better said
    /// here, quietly, than discovered.
    private var explainer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if island.isDegraded {
                Label(
                    "This island's storage went missing, so it'll forget you when Surf quits.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            } else if island.isHome {
                Text("Your first island, and the one your old cookies washed up on. "
                     + "Everything you were signed in to before islands existed is still here.")
            } else if source == nil {
                // Only where nothing above has already said it. On the sheet
                // that makes an island, the switches and the chip under them
                // cover this ground twice over, and a third telling is the
                // difference between a sheet that fits and one that doesn't.
                Text("Sign in to the same site on two islands and it'll swear you're "
                     + "two different people. Logins, cookies and site data never drift "
                     + "between them.")
            }

            Text("Passwords and passkeys in your keychain belong to macOS rather "
                 + "than to an island, so every island can reach them.")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
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

    private func load() {
        name = island.name
        symbolText = island.symbol
        tint = island.tint.color
        isNew = session.islandEditorIsForNewIsland
        // Read from the island rather than assumed, so the switch and the jar
        // can't start out disagreeing about which one the user is on.
        keepsLogins = session.islandKeepsLogins(island)
        focus = .name
    }

    /// Cancelling an edit changes nothing, because nothing was changed yet —
    /// which is the entire reason the fields aren't wired straight to the
    /// island. Reverting after the fact was the obvious design and it does not
    /// survive contact with SwiftUI: Escape dismisses a sheet *itself*, so the
    /// Cancel button's action never runs, and hanging the undo off `onDisappear`
    /// instead didn't fire either. Not writing until Done has no such seam.
    ///
    /// Cancelling a *new* island undoes the island too — see `onDisappear`. It
    /// was created before the sheet opened so it could be previewed and
    /// switched to, and leaving a half-named one behind is not what Cancel
    /// says.
    private func cancel() { dismiss() }

    private func close() {
        committed = true
        // Everything lands here, at once, or not at all.
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // An island with no name is a chip you can't tell from the next one.
        if !trimmed.isEmpty { island.name = trimmed }
        island.symbol = IslandSymbols.firstSymbol(in: symbolText) ?? island.symbol
        island.tint = IslandTint(tint)

        // Last, and only now: this is the moment a new island stops being a
        // preview and becomes the user's, so it is also the first moment it is
        // worth writing down. Named before it is saved, rather than saved twice.
        if isNew {
            session.finishCreatingIsland(island)
        } else {
            session.saveNow()
        }
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
            // Identified by the island, so opening the editor for a second one
            // builds a fresh view rather than reusing the first one's `@State`.
            // Without this, making a new island showed the previously edited
            // island's name and flag in the fields — and Done would then have
            // written them onto the new island.
            IslandEditorSheet(session: session, island: island)
                .id(island.id)
        }
    }
}

extension View {
    func islandEditor(session: BrowserSession) -> some View {
        modifier(IslandEditorPresenter(session: session))
    }
}
