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
    @State private var validationMessage: String?
    @State private var probeGeneration: UInt64 = 0

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

                if let validationMessage {
                    Text(validationMessage).foregroundStyle(Theme.Palette.danger)
                } else if let testResult {
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
        .onChange(of: url) { _ in
            probeGeneration &+= 1; testing = false; testResult = nil; validationMessage = nil
        }
        .onDisappear { probeGeneration &+= 1 }
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
        probe(saveIfReachable: true)
    }

    private func useEmbedded() {
        probeGeneration &+= 1
        StremioServer.useEmbedded()
        onChange()
        dismiss()
    }

    private func test() {
        probe(saveIfReachable: false)
    }

    private func probe(saveIfReachable: Bool) {
        guard !testing else { return }
        let entered = trimmed
        guard let target = StremioServer.normalize(entered) else {
            testResult = nil
            validationMessage = "Enter the Mac or remote server's HTTP address first. Use Embedded selects this device's server."
            return
        }
        testing = true; testResult = nil; validationMessage = nil
        probeGeneration &+= 1
        let generation = probeGeneration
        Task { @MainActor in
            let ok = await StremioServer.reachable(target)
            guard probeGeneration == generation else { return }
            testing = false
            // A test of an earlier URL must never mark a newly typed endpoint reachable or save it.
            guard trimmed == entered else { return }
            testResult = ok
            if ok, saveIfReachable {
                StremioServer.setBase(target)
                onChange()
                dismiss()
            }
        }
    }
}
