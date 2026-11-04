import SwiftUI
#if os(iOS) || os(macOS)
import UniformTypeIdentifiers
#endif

/// One main-picker destination. Authentication stays on the main picker, outside this view.
@MainActor
struct ProfilePickerToolsView: View {
    let route: ProfilePickerToolsRoute
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    let services: ProfilePickerToolsController.Services
    @ObservedObject private var controller = ProfilePickerToolsController.shared
    @StateObject private var lifetime: ProfilePickerToolsLease
    #if os(tvOS)
    private enum Focus: Hashable { case download, repair, restore, approveRepair, confirmRestore, retryOutput, retryInput, verify, finish, cancel, diagnostics, back }
    @FocusState private var focused: Focus?
    #endif

    init(route: ProfilePickerToolsRoute, services: ProfilePickerToolsController.Services,
         onClose: @escaping () -> Void) {
        self.route = route; self.services = services; self.onClose = onClose
        _lifetime = StateObject(wrappedValue: ProfilePickerToolsLease(
            routeID: route.id, controller: ProfilePickerToolsController.shared))
    }

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
                    accountFileActions
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
        #endif
        .onAppear {
            route.admission?.setForeground(scenePhase == .active)
            controller.present(route.id, services: services)
            #if os(tvOS)
            focused = route.focusDiagnostics && route.diagnostics.permitsExport ? .diagnostics
                : controller.accountActionsAvailable ? .download : .back
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: VortXSyncManager.credentialScopeDidChangeNote)) { _ in
            controller.credentialDidChange()
        }
        .onValueChange(of: scenePhase) { phase in
            route.admission?.setForeground(phase == .active)
            if phase != .active { controller.admissionDidChange(route: route.id, revoked: true) }
        }
        #if os(tvOS)
        .onValueChange(of: controller.status.stage) { stage in
            switch stage {
            case .reviewRepair: focused = .approveRepair
            case .confirmRestore: focused = .confirmRestore
            case .waitingForPhone, .outputAvailable, .localSendComplete: focused = .cancel
            default: break
            }
        }
        .onExitCommand { close() }
        #endif
    }

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
                    #if os(tvOS)
                    .focused($focused, equals: .download)
                    #endif
            #if os(tvOS)
            Text("Download the encrypted backup to a phone on the same trusted Wi-Fi. Keep this TV screen open.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            #else
            Text("Choose a destination folder. A new encrypted account-backup file is created and checked after saving.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            #endif
            Button { controller.begin(.repair, route: route.id) } label: {
                Label("Repair backup", systemImage: "wrench.and.screwdriver")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ChipButtonStyle())
            .disabled(!controller.accountActionsAvailable || controller.isBusy)
            .accessibilityIdentifier("profile-tools-repair-backup")
                    #if os(tvOS)
                    .focused($focused, equals: .repair)
                    #endif
            #if os(tvOS)
            Text("Upload a backup of 10 MiB or less from your phone. Review the repair on this TV, then download a separate repaired copy.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            #else
            Text("Choose a backup of 10 MiB or less. A supported repair is saved separately; selecting or repairing a file does not restore it.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            #endif
            Button { controller.begin(.restore, route: route.id) } label: {
                Label("Restore backup", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ChipButtonStyle())
            .disabled(!controller.canRestore)
            .accessibilityIdentifier("profile-tools-restore-backup")
                    #if os(tvOS)
                    .focused($focused, equals: .restore)
                    #endif
            Text(controller.restoreNeedsVerification
                ? "The previous restore needs verification or local recovery. Do not upload it again."
                : "Choose a backup, review it, then confirm replacing the backup stored for the signed-in account.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            #if os(tvOS)
            phoneTransfer
            #endif
            if let name = controller.status.selectedFilename {
                Text(name).font(Theme.Typography.label)
                    #if os(iOS) || os(macOS)
                    .textSelection(.enabled)
                    #endif
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
            case .reading, .downloading, .preparing, .saving, .restoring, .checkingRestore, .finishingRestore, .waitingForNetworkDrain, .draining:
                ProgressView(progressLabel).tint(Theme.Palette.accent)
            case .reviewRepair:
                Button(repairApprovalLabel) { controller.saveRepair(route: route.id) }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityIdentifier("profile-tools-save-repaired-copy")
                    #if os(tvOS)
                    .focused($focused, equals: .approveRepair)
                    #endif
            case .confirmRestore:
                Button("Replace account backup", role: .destructive) {
                    controller.confirmRestore(route: route.id)
                }
                .buttonStyle(ChipButtonStyle())
                .accessibilityIdentifier("profile-tools-confirm-restore")
                    #if os(tvOS)
                    .focused($focused, equals: .confirmRestore)
                    #endif
                .accessibilityHint("Uploads this selected file to replace the account backup. Local profiles are not applied by this tool.")
            default: EmptyView()
            }
            if controller.canVerifyRestore, !controller.isBusy {
                Button("Verify restore") { controller.verifyRestore(route: route.id) }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityIdentifier("profile-tools-verify-restore")
                    #if os(tvOS)
                    .focused($focused, equals: .verify)
                    #endif
                    .accessibilityHint("Checks the stored backup without uploading the selected file again.")
            }
            if controller.canFinishRestore, !controller.isBusy {
                Button("Finish loading backup") { controller.finishRestore(route: route.id) }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityIdentifier("profile-tools-finish-loading-backup")
                    #if os(tvOS)
                    .focused($focused, equals: .finish)
                    #endif
                    .accessibilityHint("Receives the stored backup through normal account recovery without uploading the file again.")
            }
            if controller.isBusy {
                Button("Cancel file action", role: .cancel) { controller.cancel() }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityIdentifier("profile-tools-cancel-file-action")
                    #if os(tvOS)
                    .focused($focused, equals: .cancel)
                    #endif
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
        case .restoring: "Submitting or verifying the confirmed restore…"
        case .waitingForNetworkDrain: "Closing the phone connection before TV confirmation…"
        case .checkingRestore: "Checking retained restore status…"
        case .finishingRestore: "Loading the restored backup…"
        default: "Waiting for the previous operation to finish…"
        }
    }
    private var repairApprovalLabel: String {
        #if os(tvOS)
        "Make repaired copy available"
        #else
        "Save repaired copy"
        #endif
    }

    #if os(tvOS)
    private var phoneTransfer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Use the same trusted Wi-Fi. This local HTTP transfer is not private from other people on that network. Account name, export time and any other outer file metadata may be visible. The backup contents remain encrypted.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            if let publication = controller.tvPublication {
                Image(decorative: publication.image, scale: 1)
                    .interpolation(.none).resizable().scaledToFit().frame(width: 260, height: 260)
                    .background(Color.white).accessibilityLabel("Phone backup transfer QR code")
                Text("Scan with your phone camera: " + publication.address)
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            } else if controller.status.stage == .waitingForPhone {
                ProgressView("Starting phone transfer…").tint(Theme.Palette.accent)
            }
            if controller.canRetryTVOutput {
                Button("Retry same file") { controller.retryTVOutput(route: route.id) }
                    .buttonStyle(ChipButtonStyle()).focused($focused, equals: .retryOutput)
                    .accessibilityIdentifier("profile-tools-retry-same-file")
                    .accessibilityHint("Displays a fresh QR for the exact same encrypted copy. Check and save it on your phone.")
            }
            if controller.canRetryTVInput {
                Button("Retry phone upload") { controller.retryTVInput(route: route.id) }
                    .buttonStyle(ChipButtonStyle()).focused($focused, equals: .retryInput)
                    .accessibilityIdentifier("profile-tools-retry-phone-upload")
            }
        }
    }
    #endif

    private func close() {
        route.admission?.retire()
        controller.dismiss(route.id)
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
