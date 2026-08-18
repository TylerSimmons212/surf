import SurfCore
import SwiftUI

/// Edit a request, then send it again.
///
/// The editing is the point. "Send that exact request once more" answers only
/// whether the endpoint still answers; changing a header or a field and sending
/// it is how you find out *why* it answered the way it did — and doing that
/// from the browser, with the session already attached, is otherwise a trip
/// through curl and a hand-copied cookie.
struct ReplayEditor: View {
    @Bindable var session: DevToolsSession
    @Binding var draft: ReplayRequest

    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    target
                    headersSection
                    if !draft.isIdempotent || !draft.body.isEmpty { bodySection }
                    cookieToggle
                }
                .padding(DevToolsTheme.barInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(width: 520, height: 480)
        .background(.background)
    }

    private var header: some View {
        HStack {
            Text("Replay request")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                session.cancelReplay()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, 10)
    }

    private var target: some View {
        HStack(spacing: 6) {
            Picker("", selection: $draft.method) {
                ForEach(Self.methods, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 96)

            TextField("URL", text: $draft.url)
                .textFieldStyle(.roundedBorder)
                .font(DevToolsTheme.mono)
        }
    }

    private var headersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Headers")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    draft.headers.append(ReplayHeader(name: "", value: ""))
                } label: {
                    Image(systemName: "plus").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .help("Add a header")
            }

            ForEach($draft.headers) { $header in
                HStack(spacing: 5) {
                    Toggle("", isOn: $header.isEnabled)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    TextField("Name", text: $header.name)
                        .textFieldStyle(.roundedBorder)
                        .font(DevToolsTheme.mono)
                        .frame(width: 150)
                    TextField("Value", text: $header.value)
                        .textFieldStyle(.roundedBorder)
                        .font(DevToolsTheme.mono)
                    Button {
                        draft.headers.removeAll { $0.id == header.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Body")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $draft.body)
                .font(DevToolsTheme.mono)
                .frame(height: 110)
                .padding(4)
                .background {
                    RoundedRectangle(cornerRadius: DevToolsTheme.corner, style: .continuous)
                        .fill(DevToolsTheme.inputFill)
                }
        }
    }

    private var cookieToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Send this tab's cookies", isOn: $draft.includesCookies)
                .toggleStyle(.checkbox)
                .font(DevToolsTheme.chrome)
            Text(
                "Includes HttpOnly cookies, which page scripts are forbidden to "
                + "read — so this carries the real session."
            )
            .font(DevToolsTheme.caption)
            .foregroundStyle(.tertiary)
            .padding(.leading, 18)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !draft.isIdempotent {
                // Said before sending, not after: a replayed POST does whatever
                // it did the first time, again.
                Label(
                    "\(draft.method) isn't safe to repeat — this will run again for real",
                    systemImage: "exclamationmark.triangle"
                )
                .font(DevToolsTheme.caption)
                .foregroundStyle(.orange)
            }

            Spacer(minLength: 8)

            Button("Cancel") { session.cancelReplay() }
                .keyboardShortcut(.cancelAction)

            Button(session.isReplaying ? "Sending…" : "Send") {
                let request = draft
                let origin = session.replayDraftOrigin
                Task { @MainActor in await session.replay(request, of: origin) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(session.isReplaying || draft.url.isEmpty)
        }
        .padding(.horizontal, DevToolsTheme.barInset)
        .padding(.vertical, 10)
    }
}
