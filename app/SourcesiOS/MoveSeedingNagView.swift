import SwiftUI
import UniformTypeIdentifiers

/// The Phase-0 seeding nag for iPhone / iPad / Mac (see MoveSeeding): shown once per launch while this
/// device still owes its first sync to a VortX account, and always dismissible. Primary action opens the
/// existing VortX sign-in sheet (QR pairing + typed form); the decline path offers the same settings
/// backup file export Settings > Backup & Restore uses, so even a user who never signs in can carry
/// their data across the com.vortx move by file.
struct MoveSeedingNagView: View {
    @ObservedObject private var sync = VortXSyncManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showSignIn = false
    @State private var showBackupExporter = false
    @State private var backupDocument: BackupDocument?
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.lg) {
                Image(systemName: sync.hasCompletedFirstSync ? "checkmark.icloud.fill" : "shippingbox.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .padding(.top, Theme.Space.xl)

                if sync.hasCompletedFirstSync {
                    confirmation
                } else {
                    nag
                }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .sheet(isPresented: $showSignIn) { iOSSignInView() }
        .fileExporter(isPresented: $showBackupExporter, document: backupDocument,
                      contentType: .json, defaultFilename: SettingsBackup.defaultFilename()) { _ in }
    }

    // MARK: Not seeded yet

    @ViewBuilder private var nag: some View {
        Text(MoveSeeding.headline)
            .font(Theme.Typography.screenTitle)
            .foregroundStyle(Theme.Palette.textPrimary)
            .multilineTextAlignment(.center)
        Text(MoveSeeding.message)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .multilineTextAlignment(.center)

        Button {
            showSignIn = true
        } label: {
            Text("Sign in / Create account").frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryActionStyle())

        // The decline path: the SAME settings backup file Settings > Backup & Restore exports, so data
        // still survives the move by file for someone who never wants an account.
        Button {
            do {
                backupDocument = BackupDocument(data: try SettingsBackup.makeBackup())
                showBackupExporter = true
            } catch {
                exportError = error.localizedDescription
            }
        } label: {
            Text("Export backup instead").frame(maxWidth: .infinity)
        }
        .buttonStyle(ChipButtonStyle(selected: false))

        if let exportError {
            Text(exportError)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.danger)
                .multilineTextAlignment(.center)
        }

        Button("Not now") { dismiss() }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.top, Theme.Space.sm)

        Text("This reminder returns on the next launch until this device has synced once (or you keep a file backup).")
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.textTertiary)
            .multilineTextAlignment(.center)
    }

    // MARK: Seeded (reached mid-flow when the sign-in lands and the first sync completes)

    @ViewBuilder private var confirmation: some View {
        Text(MoveSeeding.backedUpLine)
            .font(Theme.Typography.screenTitle)
            .foregroundStyle(Theme.Palette.textPrimary)
            .multilineTextAlignment(.center)
        Text(MoveSeeding.lastSyncLine(sync.lastSyncAt))
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
        Button {
            dismiss()
        } label: {
            Text("Done").frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryActionStyle())
    }
}
