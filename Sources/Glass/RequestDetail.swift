import GlassCore
import SwiftUI

/// One request, opened up.
///
/// Headers are shown only where they were actually observed. A row that came
/// from Resource Timing has none — not an empty set, but no visibility at all —
/// and the difference matters enough to say out loud rather than render as an
/// empty list that reads like "this request sent no headers".
struct RequestDetail: View {
    let session: DevToolsSession

    private var request: NetworkRequest? { session.selectedRequestDetail }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let request {
                        summary(request)
                        if request.isDetailed {
                            bodySection(
                                "Response body", session.responseBody,
                                expected: request.hasResponseBody
                            )
                            bodySection(
                                "Request body", session.requestBody,
                                expected: request.hasRequestBody
                            )
                            headerSection("Response headers", request.responseHeaders)
                            headerSection("Request headers", request.requestHeaders)
                        } else {
                            notObserved
                        }
                    }
                }
                .padding(.horizontal, DevToolsTheme.barInset)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(request?.displayName ?? "")
                .font(DevToolsTheme.chrome.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(request?.url ?? "", forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Copy URL")

            Button {
                session.selectRequest(nil)
            } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, DevToolsTheme.barVertical)
    }

    private func summary(_ request: NetworkRequest) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            field("URL", request.url, selectable: true)
            field("Method", request.method)
            field(
                "Status",
                request.statusClass == .unknown
                    // Stated rather than left as a dash the reader has to
                    // interpret: this is a platform limit, not a missing value.
                    ? "not reported for this kind of resource"
                    : (request.statusText.isEmpty
                        ? request.statusLabel
                        : "\(request.statusLabel) \(request.statusText)")
            )
            if let failure = request.failure { field("Error", failure) }
            field("Type", request.kind.label)
            if !request.protocolName.isEmpty { field("Protocol", request.protocolName) }
            field("Size", request.sizeLabel)
            if let bodySize = request.bodySize, bodySize > 0 {
                field("Body", NetworkRequest.formatBytes(bodySize))
            }
            field("Time", request.timeLabel)
            field("Started", String(format: "%.0f ms", request.startedAt))
            if request.isOpaque {
                field("Visibility", "cross-origin — timing and size withheld")
            }
        }
    }

    private var notObserved: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Headers not observed", systemImage: "info.circle")
                .font(DevToolsTheme.chrome.weight(.medium))
                .foregroundStyle(.secondary)
            Text(
                "This request was seen through Resource Timing, which reports "
                + "timing and size but no headers or status. Only fetch and "
                + "XMLHttpRequest can be observed in full."
            )
            .font(DevToolsTheme.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                .fill(DevToolsTheme.inputFill)
        }
    }

    /// A body, or a plain statement of why there isn't one.
    ///
    /// Never a blank pane: "not captured because dev tools wasn't open" and
    /// "the response was genuinely empty" look identical as emptiness, and
    /// conflating them is how a network pane stops being believed.
    @ViewBuilder
    private func bodySection(_ title: String, _ body: NetworkBody?, expected: Bool) -> some View {
        if let body {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    if let omission = body.omission {
                        Text(omission.explanation)
                            .font(DevToolsTheme.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(body.summary)
                            .font(DevToolsTheme.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 4)

                    if !body.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(body.text, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .help("Copy \(title.lowercased())")
                    }
                }

                if !body.isEmpty {
                    // Pretty-printed for JSON only, and by re-indenting rather
                    // than re-serialising, so the server's key order survives.
                    Text(body.pretty)
                        .font(DevToolsTheme.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background {
                            RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                                .fill(DevToolsTheme.inputFill)
                        }

                    if body.isTruncated {
                        Label(
                            "Truncated at 512 kB — \(NetworkRequest.formatBytes(body.byteCount)) in total",
                            systemImage: "scissors"
                        )
                        .font(DevToolsTheme.caption)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
        } else if expected && session.isLoadingBody {
            Text("Reading \(title.lowercased())…")
                .font(DevToolsTheme.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func headerSection(_ title: String, _ headers: [String: String]) -> some View {
        if !headers.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(headers.keys.sorted(), id: \.self) { key in
                    field(key, headers[key] ?? "", selectable: true)
                }
            }
        }
    }

    private func field(_ label: String, _ value: String, selectable: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(DevToolsTheme.mono)
                .foregroundStyle(ElementsStyle.attributeColor)
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            // Selectable everywhere: a header value or a URL is something you
            // copy out, and there is no tree row here whose click it could
            // swallow.
            Text(value)
                .font(DevToolsTheme.mono)
                .foregroundStyle(ElementsStyle.valueColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 2)
        }
    }
}
