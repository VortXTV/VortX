import SwiftUI

/// Configure which Stremio streaming server the app uses, the embedded on-device one, or a
/// remote/dedicated server (point the Apple TV at a box you run elsewhere). Mirrors the
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
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                Text("Streaming Server").font(.system(size: 48, weight: .heavy))
                Text("Use the server embedded on this device, or point StremioX at a remote / dedicated Stremio server (e.g. one you run at home).")
                    .font(.title3).foregroundStyle(.secondary).frame(maxWidth: 1100, alignment: .leading)

                TextField("http://192.168.1.50:11470", text: $url)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(width: 1000)

                HStack(spacing: 20) {
                    Button { save() } label: { Text("Save & Use").frame(width: 240) }
                        .buttonStyle(.borderedProminent).tint(.cyan).disabled(trimmed.isEmpty)
                    Button { test() } label: { Text(testing ? "Testing…" : "Test").frame(width: 160) }
                        .disabled(trimmed.isEmpty || testing)
                    Button(role: .destructive) { useEmbedded() } label: { Text("Use Embedded").frame(width: 260) }
                }

                if let testResult {
                    Label(testResult ? "Reachable" : "Couldn't reach that server",
                          systemImage: testResult ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.title3).foregroundStyle(testResult ? .green : .red)
                }

                Text("Currently using: \(StremioServer.base)\(StremioServer.isCustom ? "" : "  (embedded)")")
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            .padding(60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func save() {
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
        testing = true; testResult = nil
        Task {
            let ok = await StremioServer.reachable(trimmed)
            testing = false; testResult = ok
        }
    }
}
