import GlassCore
import SwiftUI

/// How fast the page was, and how much of that we actually know.
///
/// The pane is organised around a fact established by measurement rather than
/// assumption: WebKit implements paint timing, Largest Contentful Paint and
/// event timing, and implements neither `layout-shift` nor `longtask`. So CLS
/// and blocking time are computed here — which makes this the only WebKit
/// browser that reports them at all, and also means they must never be dressed
/// up as the engine's own numbers. Every card says where its number came from.
struct PerformancePane: View {
    @Bindable var session: DevToolsSession

    private let columns = [GridItem(.adaptive(minimum: 148), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    metrics
                    if !session.performance.phases.isEmpty { timeline }
                    if !session.performance.blocking.isEmpty { blocking }
                    if !session.performance.shifts.isEmpty { shifts }
                }
                .padding(DevToolsTheme.barInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            session.startPerformanceUpdates()
            // Layout watching begins with the pane, since it is the one metric
            // that can only be gathered while someone is looking.
            await session.setLayoutWatching(true)
        }
        .onDisappear {
            session.stopPerformanceUpdates()
            Task { @MainActor in await session.setLayoutWatching(false) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("Reload and measure") {
                Task { @MainActor in await session.reloadAndMeasure() }
            }
            .buttonStyle(.borderless)
            .font(DevToolsTheme.chrome)
            // Said plainly, because the difference is real: shifts and blocked
            // frames that happened before you opened this can't be recovered.
            .help("A complete run — layout shifts and blocked frames only count from page load")

            if session.isMeasuringLayout {
                HStack(spacing: 4) {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                    Text("watching for movement")
                        .font(DevToolsTheme.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Text("Thresholds match Core Web Vitals")
                .font(DevToolsTheme.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, DevToolsTheme.barVertical)
    }

    private var metrics: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(session.performance.metrics) { metric in
                MetricCard(metric: metric)
            }
        }
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Navigation", detail: "measured")

            let span = max(session.performance.span, 1)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(session.performance.phases) { phase in
                    HStack(spacing: 6) {
                        Text(phase.name)
                            .font(DevToolsTheme.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)

                        GeometryReader { geometry in
                            let width = geometry.size.width
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(
                                    width: max(2, CGFloat(phase.duration / span) * width),
                                    height: 8
                                )
                                .offset(x: CGFloat(phase.start / span) * width, y: 3)
                        }
                        .frame(height: 14)

                        Text("\(Int(phase.duration.rounded())) ms")
                            .font(DevToolsTheme.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 58, alignment: .trailing)
                    }
                }
            }

            FlowLayout(spacing: 8, rowSpacing: 4) {
                ForEach(session.performance.markers.sorted { $0.at < $1.at }) { marker in
                    HStack(spacing: 3) {
                        Text(marker.name)
                            .foregroundStyle(.secondary)
                        Text("\(Int(marker.at.rounded())) ms")
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                    .font(DevToolsTheme.caption)
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Blocking

    private var blocking: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(
                "Main thread blocked",
                detail: "approximated — WebKit reports no long tasks"
            )
            ForEach(session.performance.blocking.sorted { $0.duration > $1.duration }.prefix(8)) {
                event in
                HStack(spacing: 6) {
                    Text("\(Int(event.duration.rounded())) ms")
                        .font(DevToolsTheme.mono)
                        .foregroundStyle(event.duration > 200 ? NetworkStyle.error : .primary)
                        .frame(width: 62, alignment: .trailing)
                    Text("at \(Int(event.at.rounded())) ms")
                        .font(DevToolsTheme.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 2)
                }
            }
        }
    }

    // MARK: - Shifts

    private var shifts: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(
                "Layout shifts",
                detail: "approximated — WebKit reports no layout shifts"
            )
            ForEach(session.performance.shifts.sorted { $0.value > $1.value }.prefix(8)) { shift in
                HStack(spacing: 6) {
                    Text(String(format: "%.4f", shift.value))
                        .font(DevToolsTheme.mono)
                        .frame(width: 62, alignment: .trailing)
                    Text(shift.describedBy)
                        .font(DevToolsTheme.caption)
                        .foregroundStyle(.secondary)
                    Text("at \(Int(shift.at.rounded())) ms")
                        .font(DevToolsTheme.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 2)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(DevToolsTheme.caption)
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }
}

private struct MetricCard: View {
    let metric: PerformanceMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(metric.kind.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                // The badge is the point of the pane: a number Glass worked out
                // is a different kind of fact from one the engine reported.
                if case .approximated = metric.source {
                    Text("approx")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.orange.opacity(0.15))
                        }
                }

                Spacer(minLength: 2)

                if metric.rating != .unrated {
                    Circle()
                        .fill(ratingColor)
                        .frame(width: 6, height: 6)
                        .help(metric.rating.label)
                }
            }

            Text(metric.display)
                .font(.system(size: 19, weight: .medium).monospacedDigit())
                .foregroundStyle(metric.value == nil ? .tertiary : .primary)

            Text(metric.kind.title)
                .font(DevToolsTheme.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            if let note = metric.source.note {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !metric.detail.isEmpty {
                Text(metric.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .fill(DevToolsTheme.inputFill)
        }
    }

    private var ratingColor: Color {
        switch metric.rating {
        case .good: NetworkStyle.success
        case .needsWork: NetworkStyle.redirect
        case .poor: NetworkStyle.error
        case .unrated: .secondary
        }
    }
}
