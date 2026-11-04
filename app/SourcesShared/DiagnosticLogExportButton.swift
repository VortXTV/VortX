import SwiftUI
#if !os(tvOS)
import CoreTransferable
import UniformTypeIdentifiers
#endif

/// Account-independent help: keep this outside profile/authentication admission and busy-state gates.
/// Preparing a share copy or a LAN listener is user initiated, never work performed by a view body.
@MainActor
struct DiagnosticLogExportButton: View {
    /// Nil keeps the account-independent component's existing unlocked-settings behavior.
    /// Pre-profile routes pass their original credential and live PIN/failure admission.
    var grant: ProfilePickerToolsDiagnosticGrant? = nil
    #if os(tvOS)
    @State private var showingExport = false
    #endif

    var body: some View {
        #if os(tvOS)
        Button { showingExport = true } label: {
            Label("Export diagnostic log", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityIdentifier("pre-profile-diagnostic-export")
        .disabled(grant?.permitsExport == false)
        .fullScreenCover(isPresented: $showingExport) { DiagnosticLogExportSheet(grant: grant) }

        #else
        ShareLink(item: PreProfileDiagnosticLogTransfer(grant: grant),
                  preview: SharePreview("VortX diagnostic log")) {
            Label("Export diagnostic log", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityIdentifier("pre-profile-diagnostic-export")
        .accessibilityHint("Save or share a troubleshooting log without signing in. Review the file before sharing.")
        .disabled(grant?.permitsExport == false)
        #endif
    }
}

#if !os(tvOS)
/// The existing exporter re-scrubs probe, always-on and optional server diagnostics at export time.
/// Never share the live cache file, consume its history, require logging to be enabled, or collect
/// Keychain/account documents. Unique destinations prevent simultaneous shares replacing one another.
private struct PreProfileDiagnosticLogTransfer: Transferable {
    let grant: ProfilePickerToolsDiagnosticGrant?
    private enum Failure: Error { case permissionChanged }
    private static func require(_ grant: ProfilePickerToolsDiagnosticGrant?) async throws {
        try Task.checkCancellation()
        if let grant { try await grant.requireForExport() }
    }
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { transfer in
            try await require(transfer.grant)
            let bytes = VXDiagExport.exportBody()
            try await require(transfer.grant)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("vortx-diag-\(UUID().uuidString.lowercased())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let destination = directory.appendingPathComponent("vortx-diag.log")
            do {
                try bytes.write(to: destination, options: .atomic)
                try await require(transfer.grant)
                return SentTransferredFile(destination)
            } catch {
                // Only this unique export directory and its own staged file are touched.
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
    }
}
#else
@MainActor
private final class DiagnosticLogExportSession: ObservableObject {
    @Published private(set) var payload: (url: String, qr: Image)?
    @Published private(set) var preparing = true
    private var exporter: VXDiagExport?

    func prepare(grant: ProfilePickerToolsDiagnosticGrant?) async {
        guard grant?.permitsExport != false else { stop(); return }
        let owned = VXDiagExport.makeSession(deliveryAuthorization: { grant?.permitsExport != false })
        exporter?.stopOwnedSession()
        exporter = owned
        payload = nil
        preparing = true
        let result = await owned.startAsync()
        guard !Task.isCancelled, exporter === owned, grant?.permitsExport != false else {
            owned.stopOwnedSession()
            if exporter === owned { exporter = nil; preparing = false }
            return
        }
        payload = result
        preparing = false
        if result == nil { owned.stopOwnedSession(); exporter = nil }
    }

    func stop() {
        exporter?.stopOwnedSession()
        exporter = nil
        payload = nil
        preparing = false
    }
}

private struct DiagnosticLogExportSheet: View {
    let grant: ProfilePickerToolsDiagnosticGrant?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = DiagnosticLogExportSession()
    @State private var retry = 0
    @FocusState private var closeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.lg) {
                Text("Export diagnostic log")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let export = session.payload, grant?.permitsExport != false {
                    export.qr.resizable().interpolation(.none).scaledToFit()
                        .frame(width: 360, height: 360)
                        .padding(12).background(.white)
                        .accessibilityHidden(true)
                    Text(export.url)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Text("Scan with your phone on the same Wi-Fi to download the log, then share the file.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                } else if session.preparing {
                    ProgressView("Preparing the download link…")
                        .tint(Theme.Palette.accent)
                } else {
                    Text("Couldn't create the download link. Check Wi-Fi and local network access, then try again.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Button("Try again") { retry += 1 }
                        .disabled(grant?.permitsExport == false)
                        .buttonStyle(ChipButtonStyle())
                }
                Text("Includes recent troubleshooting activity, even if Diagnostic logging was off. Review the file before sharing it.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Button("Done") { dismiss() }
                    .buttonStyle(ChipButtonStyle())
                    .focused($closeFocused)
            }
            .multilineTextAlignment(.center)
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .task(id: retry) { await session.prepare(grant: grant) }
        .task {
            guard grant != nil else { return }
            while !Task.isCancelled {
                guard grant?.permitsExport != false else { session.stop(); return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        .onAppear { closeFocused = true }
        .onExitCommand { dismiss() }
        .onDisappear { session.stop() }
    }
}
#endif
