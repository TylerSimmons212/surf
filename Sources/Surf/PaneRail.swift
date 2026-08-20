import SurfCore
import SwiftUI

/// The pane switcher: a vertical rail of icons, in groups.
///
/// This replaced a seven-segment `Picker`, and the reason is structural rather
/// than stylistic. A segmented control gives every segment the same weight and
/// the same width, which is a claim that the seven panes are peers. They are
/// not — see `Pane.groups` for what they actually are. The rail states that
/// grouping in the one way a horizontal strip cannot: by putting space between
/// the groups.
///
/// It also returns the whole top of the window. The header this replaced spent
/// its full width on a pane picker and the page's URL, both of which are now
/// carried by the title bar, so each pane's own toolbar is the first thing
/// under the chrome instead of the second.
struct PaneRail: View {
    @Bindable var session: DevToolsSession

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(DevToolsSession.Pane.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { separator }
                ForEach(group) { pane in
                    PaneRailItem(pane: pane, isSelected: session.pane == pane) {
                        session.pane = pane
                    }
                }
            }
            Spacer(minLength: 0)

            // Page-wide testing conditions live at the foot of the rail —
            // they belong to no pane, and the rail is the one piece of
            // chrome every pane shares. First resident: the colour-scheme
            // emulation.
            if let tab = session.tab {
                ViewportEmulationMenu(tab: tab)
                AppearanceEmulationMenu(tab: tab)
            }
        }
        .padding(.vertical, DevToolsTheme.unit * 2)
        .frame(width: DevToolsTheme.railWidth)
        // One element to VoiceOver's container navigation, named for what it
        // switches rather than leaving seven loose buttons in the rotor.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panes")
    }

    /// Short of the rail's width, so it reads as a gap between groups rather
    /// than as a border between two regions.
    private var separator: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: DevToolsTheme.unit * 5, height: 1)
            .padding(.vertical, DevToolsTheme.unit * 1.5)
    }
}

/// One pane's icon: a target, a selected state, and a name on hover.
private struct PaneRailItem: View {
    let pane: DevToolsSession.Pane
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // A `Label` rather than a bare `Image`, and the reason is
            // accessibility rather than tidiness: an `Image(systemName:)` is
            // decorative, so a button wrapping one announces itself as
            // "button" and nothing else. `.iconOnly` hides the text visually
            // while keeping it as the button's name — which is what the
            // segmented control this replaced gave for free.
            Label(pane.label, systemImage: pane.symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .regular))
                // The selected glyph carries the accent too. Tinting only the
                // background leaves a grey icon sitting in a coloured well,
                // which reads as disabled-on-a-highlight rather than chosen.
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(
                    width: DevToolsTheme.railItemWidth,
                    height: DevToolsTheme.railItemHeight
                )
                .background {
                    RoundedRectangle(cornerRadius: DevToolsTheme.railCorner, style: .continuous)
                        .fill(fill)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // The label is the only place the pane's name appears now, so this is
        // load-bearing rather than a nicety.
        .help(pane.label)
        // Belt and braces with the `Label` above. Probing the live panel
        // through the accessibility API, an icon-only button still reported
        // no `AXDescription` — only the `AXHelp` that `.help` sets, which
        // VoiceOver does read but as a hint rather than a name. Stating the
        // label explicitly costs nothing and does not depend on which of the
        // two SwiftUI decides to honour.
        .accessibilityLabel(pane.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        if isSelected { return DevToolsTheme.selectedFill }
        return isHovering ? DevToolsTheme.hoverFill : .clear
    }
}

/// The "what does this page look like in dark mode" switch: a native menu
/// with the three schemes, wearing the current one as its icon.
///
/// A menu rather than a cycle-on-click button because a cycling control
/// shows its state only after you've changed it — and the wrong answer to
/// "is this page being emulated right now" costs a confused bug hunt on a
/// page that looks dark for no visible reason. Amber when overriding, so an
/// active emulation is one glance from anywhere.
private struct AppearanceEmulationMenu: View {
    @Bindable var tab: Tab

    var body: some View {
        Menu {
            Picker("Appearance", selection: $tab.emulatedAppearance) {
                Text("System").tag(AppearanceMode.system)
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(
                    tab.emulatedAppearance == .system ? Color.secondary : Color.orange
                )
                .frame(
                    width: DevToolsTheme.railItemWidth,
                    height: DevToolsTheme.railItemHeight
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }

    private var symbol: String {
        switch tab.emulatedAppearance {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    private var help: String {
        switch tab.emulatedAppearance {
        case .system: "Emulate light or dark mode for this page"
        case .light: "This page is emulating light mode"
        case .dark: "This page is emulating dark mode"
        }
    }
}

/// The page at a phone's size, or a tablet's — the second resident of the
/// rail's foot. Same contract as the appearance menu: native menu, amber
/// while overriding, per tab, gone when the tab goes.
private struct ViewportEmulationMenu: View {
    @Bindable var tab: Tab

    var body: some View {
        Menu {
            Picker("Viewport", selection: $tab.emulatedViewport) {
                Text("Fill window").tag(CGSize?.none)
                ForEach(ViewportEmulation.presets) { preset in
                    Text(preset.label).tag(CGSize?.some(preset.size))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: tab.emulatedViewport == nil
                ? "rectangle.expand.vertical" : "iphone")
                .font(.system(size: 13))
                .foregroundStyle(
                    tab.emulatedViewport == nil ? Color.secondary : Color.orange
                )
                .frame(
                    width: DevToolsTheme.railItemWidth,
                    height: DevToolsTheme.railItemHeight
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }

    private var help: String {
        guard let size = tab.emulatedViewport else {
            return "Lay the page out at a phone or tablet size"
        }
        return "Emulating a \(Int(size.width)) × \(Int(size.height)) viewport"
    }
}
