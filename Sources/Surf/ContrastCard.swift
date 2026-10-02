import SurfCore
import SwiftUI

/// The element's text contrast: the pair as a live sample, the ratio, the
/// verdicts, and — when AA fails — the repair, one click from applied.
///
/// The engine behind the suggestion is the theming system's contrast
/// repairer: hue held, chroma surrendered only as far as legibility demands.
/// It has shipped in SurfCore with its own test suite since before this
/// panel existed; this card is the first time the inspector lets it answer
/// for the page's own text.
struct ContrastCard: View {
    let session: DevToolsSession
    let verdict: ContrastVerdict

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sample

                Text(String(format: "%.2f", verdict.ratio))
                    .font(DevToolsTheme.prose.weight(.medium).monospacedDigit())
                    .help("Contrast ratio\(verdict.isLargeText ? " — judged as large text" : "")")

                chip("AA", passes: verdict.passesAA)
                chip("AAA", passes: verdict.passesAAA)

                Spacer(minLength: 4)
            }

            if let suggestion = verdict.suggestion {
                HStack(spacing: 6) {
                    swatch(suggestion)
                    Text("Nearest colour that reads: \(suggestion.cssText)")
                        .font(DevToolsTheme.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button("Fix") {
                        // Through the same element.style path as every other
                        // edit — so it lands in the changeset, shows in
                        // Changes, and reverts like anything else.
                        Task { @MainActor in
                            await session.setBoxValue("color", suggestion.cssText)
                        }
                    }
                    .controlSize(.small)
                    .help("Set this element's color inline — recorded in Changes like any edit")
                }
            }
        }
        .padding(DevToolsTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.cardCorner, style: .continuous)
                .fill(DevToolsTheme.cardFill)
        }
    }

    /// "Aa" in the actual pair — the judgement, visible.
    private var sample: some View {
        Text("Aa")
            .font(.system(size: 13, weight: verdict.isLargeText ? .bold : .regular))
            .foregroundStyle(color(verdict.foreground))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color(verdict.background))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            }
    }

    private func chip(_ label: String, passes: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: passes ? "checkmark" : "xmark")
                .font(.system(size: 7, weight: .bold))
            Text(label)
                .font(DevToolsTheme.badge)
        }
        .foregroundStyle(passes ? Color.green : Color.orange)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background {
            Capsule().fill((passes ? Color.green : Color.orange).opacity(0.12))
        }
        .help(passes ? "Meets WCAG \(label)" : "Fails WCAG \(label)")
    }

    private func swatch(_ srgb: SRGB) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color(srgb))
            .frame(width: 14, height: 14)
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5)
            }
    }

    private func color(_ srgb: SRGB) -> Color {
        Color(red: srgb.r, green: srgb.g, blue: srgb.b)
    }
}
