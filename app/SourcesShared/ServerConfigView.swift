import SwiftUI

/// Configure which Stremio streaming server the app uses, the embedded on-device one, or a
/// remote / dedicated server (point the Apple TV at a box you run elsewhere). Mirrors the
/// "Add server URL" option in the web/desktop apps.
struct ServerConfigView: View {
    var onChange: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var url: String = StremioServer.isCustom ? StremioServer.base : ""
    @State private var testResult: Bool?
    @State private var testing = false

    private var trimmed: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Streaming Server").screenTitleStyle()
                Text("Use the server embedded on this device, or point VortX at a remote / dedicated Stremio server (for example one you run at home).")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)

                urlField

                // NOTE: never use `.disabled` on tvOS buttons, a disabled button is not focusable, so
                // the remote can't move onto it and focus gets stuck on the only enabled control. Keep all
                // three reachable and validate inside the actions instead.
                HStack(spacing: Theme.Space.md) {
                    Button { save() } label: { Text("Save & Use") }
                        .buttonStyle(PrimaryActionStyle())
                    Button { test() } label: { Text(testing ? "Testing…" : "Test") }
                        .buttonStyle(ChipButtonStyle())
                    Button { useEmbedded() } label: { Text("Use Embedded") }
                        .buttonStyle(ChipButtonStyle(selected: true, accent: Theme.Palette.danger, accentText: Theme.Palette.danger))
                }

                if let testResult {
                    Label(testResult ? "Reachable" : "Couldn't reach that server",
                          systemImage: testResult ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(Theme.Typography.body)
                        .foregroundStyle(testResult ? Color(.sRGB, red: 0.45, green: 0.72, blue: 0.42) : Theme.Palette.danger)
                }

                Text("Currently using: \(StremioServer.base)\(StremioServer.isCustom ? "" : "  (embedded)")")
                    .font(.system(size: 18, design: .monospaced)).foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // `.textInputAutocapitalization(_:)` and `.textContentType(_:)` are UIKit-backed (iOS / tvOS
    // only); macOS SwiftUI does not expose them. Gate so this view compiles on the Mac target while
    // keeping the iOS / tvOS keyboard behaviour identical. `.autocorrectionDisabled()` is fine on all.
    @ViewBuilder private var urlField: some View {
        #if os(macOS)
        TextField("http://192.168.1.50:11470", text: $url)
            .autocorrectionDisabled()
            .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
            .vortxGlassField(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .frame(maxWidth: 1000)
            .onSubmit { save() }   // Return submits (the primary interaction on Mac's hardware keyboard)
        #else
        TextField("http://192.168.1.50:11470", text: $url)
            .textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
            .vortxGlassField(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .frame(maxWidth: 1000)
            .onSubmit { save() }   // Return submits (the primary interaction on Mac's hardware keyboard)
        #endif
    }

    private func save() {
        guard !trimmed.isEmpty else { testResult = false; return }   // need a URL to save
        StremioServer.setBase(trimmed)
        onChange()
        dismiss()
    }

    private func useEmbedded() {
        StremioServer.useEmbedded()
        onChange()
        dismiss()
    }

    private func test() {
        guard !testing else { return }
        // Test the entered URL; if the field is empty, test the currently-active server so the button
        // always gives feedback (it silently did nothing before when the field was empty).
        let target = trimmed.isEmpty ? StremioServer.base : trimmed
        testing = true; testResult = nil
        Task {
            let ok = await StremioServer.reachable(target)
            testing = false; testResult = ok
        }
    }
}
