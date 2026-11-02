import SwiftUI
#if os(iOS) || os(macOS)
import UniformTypeIdentifiers
#endif

/// One main-picker destination. Authentication stays on the main picker, outside this view.
@MainActor
struct ProfilePickerToolsView: View {
    let route: ProfilePickerToolsRoute
    let onClose: () -> Void
    #if os(iOS) || os(macOS)
    let services: ProfilePickerToolsController.Services
    @ObservedObject private var controller = ProfilePickerToolsController.shared
    @StateObject private var lifetime: ProfilePickerToolsLease
    #endif
    #if os(tvOS)
    private enum Focus: Hashable { case diagnostics, back }
    @FocusState private var focused: Focus?
    #endif

    #if os(iOS) || os(macOS)
    init(route: ProfilePickerToolsRoute, services: ProfilePickerToolsController.Services,
         onClose: @escaping () -> Void) {
        self.route = route; self.services = services; self.onClose = onClose
        _lifetime = StateObject(wrappedValue: ProfilePickerToolsLease(
            routeID: route.id, controller: ProfilePickerToolsController.shared))
    }
    #else
    init(route: ProfilePickerToolsRoute, onClose: @escaping () -> Void) {
        self.route = route; self.onClose = onClose
    }
    #endif

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("Tools")
                        .font(Theme.Typography.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Backups and troubleshooting, without opening a profile.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    #if os(tvOS)
                    companionGuidance
                    #else
                    accountFileActions
                    #endif
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text("Export diagnostic logs").font(Theme.Typography.eyebrow)
                        DiagnosticLogExportButton(grant: route.diagnostics)
                            .disabled(!route.diagnostics.permitsExport)
                            #if os(tvOS)
                            .focused($focused, equals: .diagnostics)
                            #endif
                        Text(route.diagnostics.permitsExport
                            ? "Save a troubleshooting log to share with support. Review the file before sharing."
                            : "Unlock a profile to export logs. This remains available when profiles fail to open.")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .toolsFocusSection()
                    Button("Back") { close() }
                        .buttonStyle(ChipButtonStyle())
                        .accessibilityIdentifier("profile-tools-back")
                        .accessibilityHint("Return to the profile picker. Any pending file action is cancelled.")
                        #if os(macOS)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        #if os(tvOS)
                        .focused($focused, equals: .back)
                        #endif
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        // Explicit Back always remains available, including while a provider ignores cancellation.
        .interactiveDismissDisabled(true)
        #if os(iOS) || os(macOS)
        .background {
            if let request = controller.picker, request.routeID == route.id {
                ProfilePickerToolsFilePicker(request: request) { original, result in
                    controller.picked(original, result: result)
                }
                .id(request.id)
            }
        }
        .onAppear { controller.present(route.id, services: services) }
        .onReceive(NotificationCenter.default.publisher(for: VortXSyncManager.credentialScopeDidChangeNote)) { _ in
            controller.credentialDidChange()
        }
        #else
        .onAppear {
            focused = route.focusDiagnostics && route.diagnostics.permitsExport ? .diagnostics : .back
        }
        .onExitCommand { close() }
        #endif
    }

    #if os(iOS) || os(macOS)
    private var accountFileActions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if !controller.accountActionsAvailable {
                Text("Sign in from the profile picker to download, repair or restore an account backup.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            }
            Button { controller.begin(.download, route: route.id) } label: {
                Label("Download backup", systemImage: "arrow.down.doc")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ChipButtonStyle())
            .disabled(!controller.accountActionsAvailable || controller.isBusy)
            .accessibilityIdentifier("profile-tools-download-backup")
            Text("Choose a destination folder. A new encrypted account-backup file is created and checked after saving.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            Button { controller.begin(.repair, route: route.id) } label: {
                Label("Repair backup", systemImage: "wrench.and.screwdriver")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ChipButtonStyle())
            .disabled(!controller.accountActionsAvailable || controller.isBusy)
            .accessibilityIdentifier("profile-tools-repair-backup")
            Text("Choose a backup of 10 MiB or less. A supported repair is saved separately; selecting or repairing a file does not restore it.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            Button { controller.begin(.restore, route: route.id) } label: {
                Label("Restore backup", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ChipButtonStyle())
            .disabled(!controller.canRestore)
            .accessibilityIdentifier("profile-tools-restore-backup")
            Text(controller.restoreNeedsVerification
                ? "The previous restore needs verification or local recovery. Do not upload it again."
                : "Choose a backup, review it, then confirm replacing the backup stored for the signed-in account.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            if let name = controller.status.selectedFilename {
                Text(name).font(Theme.Typography.label).textSelection(.enabled)
            }
            if let bytes = controller.status.fileBytes {
                Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            }
            if let profiles = controller.status.profiles {
                Text("\(profiles) profiles in the prepared copy.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            }
            if let message = controller.status.message {
                Text(message).font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .accessibilityIdentifier("profile-tools-result")
            }
            switch controller.status.stage {
            case .reading, .downloading, .preparing, .saving, .restoring, .draining:
                ProgressView(progressLabel).tint(Theme.Palette.accent)
            case .reviewRepair:
                Button("Save repaired copy") { controller.saveRepair(route: route.id) }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityIdentifier("profile-tools-save-repaired-copy")
            case .confirmRestore:
                Button("Replace account backup", role: .destructive) {
                    controller.confirmRestore(route: route.id)
                }
                .buttonStyle(ChipButtonStyle())
                .accessibilityIdentifier("profile-tools-confirm-restore")
                .accessibilityHint("Uploads this selected file to replace the account backup. Local profiles are not applied by this tool.")
            default: EmptyView()
            }
            if controller.canVerifyRestore, !controller.isBusy {
                Button("Verify restore") { controller.verifyRestore(route: route.id) }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityIdentifier("profile-tools-verify-restore")
                    .accessibilityHint("Checks the stored backup without uploading the selected file again.")
            }
            if controller.isBusy {
                Button("Cancel file action", role: .cancel) { controller.cancel() }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityIdentifier("profile-tools-cancel-file-action")
            }
        }
        .toolsFocusSection()
    }
    private var progressLabel: String {
        switch controller.status.stage {
        case .reading: "Reading selected file…"
        case .downloading: "Downloading account backup…"
        case .preparing: "Preparing backup copy…"
        case .saving: "Saving and checking the new copy…"
        case .restoring: "Submitting the confirmed restore…"
        default: "Waiting for the previous operation to finish…"
        }
    }
    #else
    private var companionGuidance: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Download backup").font(Theme.Typography.body)
            Text("Use Tools on your Mac, iPhone or iPad, signed into the same VortX account, and choose a destination folder.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            Text("Repair backup").font(Theme.Typography.body)
            Text("Choose the file in Tools on a Mac, iPhone or iPad. Apple TV cannot select or repair backup files.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            Text("Restore backup").font(Theme.Typography.body)
            Text("Review and confirm the account-file restore from Tools on a Mac, iPhone or iPad. This TV screen does not upload or convert a backup.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
        .toolsFocusSection()
    }
    #endif

    private func close() {
        #if os(iOS) || os(macOS)
        controller.dismiss(route.id)
        #endif
        onClose()
    }
}

#if os(iOS) || os(macOS)
/// A distinct view identity owns each system picker callback. It never looks up a newer request
/// when a provider returns late. Directory selection creates no bytes until the worker's fenced save.
private struct ProfilePickerToolsFilePicker: View {
    let request: ProfilePickerToolsController.Picker
    let completion: (ProfilePickerToolsController.Picker, Result<[URL], Error>) -> Void
    @State private var isPresented = true
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .fileImporter(isPresented: $isPresented,
                allowedContentTypes: request.purpose == .destination ? [.folder] : [.json, .data],
                allowsMultipleSelection: false) { result in
                    completion(request, result)
                }
    }
}
#endif

private extension View {
    @ViewBuilder func toolsFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }
}
