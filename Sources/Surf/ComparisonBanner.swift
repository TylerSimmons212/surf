import SurfCore
import SwiftUI

/// What changed between a replay and the request it came from.
///
/// A replay you can't compare only tells you the endpoint still answers. The
/// question people actually have — after a deploy, a token refresh, a header
/// they just changed — is whether it answers *differently*, and that is a
/// comparison rather than a response.
struct ComparisonBanner: View {
    let comparison: ReplayComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: comparison.isIdentical ? "equal.circle" : "arrow.triangle.branch")
                    .font(.system(size: 10))
                Text(comparison.isIdentical ? "Identical to the original" : "Differs from the original")
                    .font(DevToolsTheme.chrome.weight(.medium))
            }
            .foregroundStyle(comparison.isIdentical ? Color.secondary : Color.accentColor)

            if comparison.statusChanged {
                line(
                    "Status",
                    "\(comparison.originalStatus.map(String.init) ?? "—")"
                    + " → \(comparison.replayedStatus.map(String.init) ?? "—")"
                )
            }
            if comparison.bodyChanged { line("Body", "changed") }
            if !comparison.changedHeaders.isEmpty {
                line("Headers", comparison.changedHeaders.joined(separator: ", "))
            }
            if comparison.durationDelta != 0 {
                line(
                    "Time",
                    String(
                        format: "%@%.0f ms",
                        comparison.durationDelta > 0 ? "+" : "", comparison.durationDelta
                    )
                )
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .fill(
                    comparison.isIdentical
                        ? DevToolsTheme.inputFill : Color.accentColor.opacity(0.10)
                )
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(DevToolsTheme.caption)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(DevToolsTheme.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 2)
        }
    }
}
