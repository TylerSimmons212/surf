import SurfCore
import SwiftUI

/// The recipe lens: the dish, not the life story.
///
/// Recipe pages are the most hostile pages on the web — the recipe itself is
/// buried under essays, adverts, and retellings. This renders what the
/// page's own structured data says the recipe *is*: ingredients that check
/// off and scale, steps that read step by step, and a cook mode that keeps
/// the screen awake with wet hands hovering over it.
struct RecipeLensView: View {
    let tab: Tab
    let recipe: FocusRecipe

    /// Ingredient lines already gathered, by id. View state, deliberately:
    /// leaving Focus resets the mise en place.
    @State private var gathered: Set<Int> = []
    /// The serving multiplier the ingredient quantities are shown at.
    @State private var scale = 1.0
    /// Cook mode: bigger steps, tappable progress, and a screen that stays
    /// awake — flour on the trackpad is how this earns its place.
    @State private var isCooking = false
    @State private var currentStep = 0
    /// The system's permission to keep the display on, held only while cook
    /// mode is. Ending it on disappear is what keeps a closed tab from
    /// pinning the screen awake forever.
    @State private var wakeToken: NSObjectProtocol?

    /// Where the grocery hand-off stands, for the one row that shows it.
    enum GroceryPhase: Equatable {
        case idle
        case adding
        case done(String)
        case failed(String)
    }
    @State private var groceryPhase: GroceryPhase = .idle

    private static let scales: [Double] = [0.5, 1, 2, 3]

    private var ingredients: [RecipeIngredient] {
        // Identity by position, stamped here so checkboxes survive re-renders.
        recipe.ingredients.enumerated().map { index, ingredient in
            var stamped = ingredient
            stamped.id = index
            return stamped
        }
    }

    private var steps: [RecipeStep] {
        recipe.steps.enumerated().map { index, step in
            var stamped = step
            stamped.id = index
            return stamped
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                ingredientsSection
                stepsSection
            }
            .frame(maxWidth: 660)
            .padding(.horizontal, 32)
            .padding(.top, 72)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .topTrailing) { controls }
        .onChange(of: isCooking) { _, cooking in
            setScreenAwake(cooking)
        }
        .onDisappear { setScreenAwake(false) }
    }

    // MARK: - Chrome

    private var controls: some View {
        HStack(spacing: 8) {
            FocusShareLink(tab: tab, title: recipe.title)

            Divider().frame(height: 16)

            IconButton(
                systemName: "text.page",
                size: 12, width: 24, height: 24, cornerRadius: 7,
                help: "Read as Article"
            ) { tab.focusPrefersArticle = true }

            Divider().frame(height: 16)

            IconButton(
                systemName: "xmark",
                size: 11, weight: .bold, width: 24, height: 24, cornerRadius: 7,
                help: "Leave Focus (⇧⌘F)"
            ) { tab.exitFocus() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .padding(.top, 14)
        .padding(.trailing, 14)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recipe.title)
                .font(.system(size: 32, weight: .bold, design: .serif))
                .lineSpacing(4)
                .textSelection(.enabled)

            if !recipe.author.isEmpty {
                Text("By \(recipe.author)")
                    .font(Typeface.figtree(size: 13, weight: 500))
                    .foregroundStyle(.secondary)
            }

            if !recipe.summary.isEmpty {
                Text(recipe.summary)
                    .font(.system(size: 15, design: .serif))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }

            metaChips
                .padding(.top, 2)

            if !recipe.image.isEmpty {
                AsyncImage(url: URL(string: recipe.image)) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                            .frame(maxHeight: 300, alignment: .leading)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 8)
            }

            Divider().padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaChips: some View {
        HStack(spacing: 8) {
            if !recipe.yieldText.isEmpty {
                chip("person.2", scaledYield)
            }
            if let prep = recipe.prepMinutes {
                chip("knife", "Prep \(FocusRecipe.label(forMinutes: prep))")
            }
            if let cook = recipe.cookMinutes {
                chip("flame", "Cook \(FocusRecipe.label(forMinutes: cook))")
            }
            if let total = recipe.totalMinutes {
                chip("clock", FocusRecipe.label(forMinutes: total))
            }
        }
    }

    /// The yield follows the scaler: doubled ingredients feed doubled people,
    /// and a chip still saying "4 servings" would be the one lying number on
    /// the page.
    private var scaledYield: String {
        guard scale != 1, let servings = recipe.servings else { return recipe.yieldText }
        return "\(RecipeIngredient.format(servings * scale)) servings"
    }

    private func chip(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(label)
                .font(Typeface.figtree(size: 11.5, weight: 500))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }

    // MARK: - Ingredients

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Ingredients")
                    .font(.system(size: 21, weight: .semibold, design: .serif))
                Spacer()
                scalePicker
            }

            ForEach(ingredients) { ingredient in
                ingredientRow(ingredient)
            }

            groceryRow
                .padding(.top, 6)

            Divider().padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scalePicker: some View {
        Picker("Scale", selection: $scale) {
            ForEach(Self.scales, id: \.self) { value in
                Text(value == 0.5 ? "½×" : "\(Int(value))×").tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 160)
        .help("Scale the ingredient quantities")
        // No numeric quantities means nothing to scale, and a control that
        // changes nothing shouldn't offer itself.
        .opacity(ingredients.contains { $0.quantity != nil } ? 1 : 0)
    }

    private func ingredientRow(_ ingredient: RecipeIngredient) -> some View {
        let isGathered = gathered.contains(ingredient.id)
        return Button {
            if isGathered { gathered.remove(ingredient.id) }
            else { gathered.insert(ingredient.id) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isGathered ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isGathered ? Color.accentColor : .secondary)
                Text(ingredient.scaled(by: scale))
                    .font(.system(size: 15, design: .serif))
                    .strikethrough(isGathered, color: .secondary)
                    .foregroundStyle(isGathered ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Groceries

    /// What still needs buying: the unchecked lines, at the current scale.
    /// The checkboxes are the pantry check; this carries the rest out.
    private var neededItems: [String] {
        ingredients
            .filter { !gathered.contains($0.id) }
            .map { $0.scaled(by: scale) }
    }

    @ViewBuilder
    private var groceryRow: some View {
        switch groceryPhase {
        case .idle:
            Button {
                addToGroceries()
            } label: {
                Label(
                    gathered.isEmpty
                        ? "Add Ingredients to Groceries"
                        : "Add Remaining \(neededItems.count) to Groceries",
                    systemImage: "cart.badge.plus"
                )
                .font(Typeface.figtree(size: 12, weight: 600))
            }
            .buttonStyle(.bordered)
            .disabled(neededItems.isEmpty)
            .help("""
                Sends the unchecked ingredients to your Groceries list in \
                Reminders — check off what you already have first.
                """)

        case .adding:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Adding to Reminders…")
                    .font(Typeface.figtree(size: 12))
                    .foregroundStyle(.secondary)
            }

        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(Typeface.figtree(size: 12, weight: 500))
                .foregroundStyle(.secondary)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(Typeface.figtree(size: 12))
                .foregroundStyle(.orange)
        }
    }

    private func addToGroceries() {
        let items = neededItems
        guard !items.isEmpty else { return }
        groceryPhase = .adding
        let note = [recipe.title.isEmpty ? "a recipe" : "For \(recipe.title)",
                    tab.currentURL ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        Task { @MainActor in
            let outcome = await GroceryList.shared.add(items: items, note: note)
            switch outcome {
            case .added(let count, let list):
                groceryPhase = .done("Added \(count) to \(list)")
            case .denied:
                groceryPhase = .failed(
                    "Reminders access is off — allow it in System Settings › Privacy."
                )
            case .failed:
                groceryPhase = .failed("Couldn't add to Reminders.")
            }
            // The row goes back to being a button: the list may change —
            // more boxes ticked, the scale moved — and the message has been
            // read by then.
            try? await Task.sleep(for: .seconds(5))
            if groceryPhase != .adding { groceryPhase = .idle }
        }
    }

    // MARK: - Steps

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Method")
                    .font(.system(size: 21, weight: .semibold, design: .serif))
                Spacer()
                Button {
                    isCooking.toggle()
                } label: {
                    Label(
                        isCooking ? "End Cook Mode" : "Cook Mode",
                        systemImage: isCooking ? "stove.fill" : "stove"
                    )
                    .font(Typeface.figtree(size: 12, weight: 600))
                }
                .buttonStyle(.bordered)
                .help(isCooking
                    ? "Back to reading size; the screen may sleep again"
                    : "Large steps, and the screen stays awake")
            }

            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                // Section names arrive on the steps; a change of name is
                // where the subheading goes.
                if !step.section.isEmpty,
                   index == 0 || steps[index - 1].section != step.section {
                    Text(step.section)
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .padding(.top, 6)
                }
                stepRow(step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepRow(_ step: RecipeStep) -> some View {
        let isCurrent = isCooking && step.id == currentStep
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(step.id + 1)")
                .font(.system(size: isCooking ? 16 : 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(minWidth: 22, alignment: .trailing)
            Text(step.text)
                .font(.system(size: isCooking ? 19 : 15, design: .serif))
                .lineSpacing(isCooking ? 7 : 5)
                .textSelection(.enabled)
                // Cook mode dims everything but the step being cooked, so a
                // glance from across the counter finds the place.
                .foregroundStyle(!isCooking || isCurrent ? .primary : .secondary)
        }
        .padding(.vertical, isCooking ? 8 : 2)
        .padding(.horizontal, 10)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isCooking else { return }
            currentStep = step.id
        }
        .animation(.easeOut(duration: 0.15), value: isCurrent)
    }

    // MARK: - Wake lock

    private func setScreenAwake(_ awake: Bool) {
        if awake, wakeToken == nil {
            wakeToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Cook mode is following a recipe"
            )
        } else if !awake, let wakeToken {
            ProcessInfo.processInfo.endActivity(wakeToken)
            self.wakeToken = nil
        }
    }
}
