import SwiftUI

/// The Phase-0 seeding nag for Apple TV (see MoveSeeding): shown once per launch while this device still
/// owes its first sync to a VortX account, always dismissible. Apple TV has no file export, so every path
/// leads through the VortX account: the primary action is the KEYBOARD-FREE QR pairing that already powers
/// tvOS sign-in (VortXAccountJoinerView, approve on a signed-in phone or vortx.tv/approve), "Back up this
/// Apple TV" is the existing BackupExportView QR flow that keeps THIS device's data, and the typed
/// email/password form (SyncSettingsView, tvOS keyboard) stays available for a first-ever account.
struct MoveSeedingNagTV: View {
    @ObservedObject private var sync = VortXSyncManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Space.lg) {
                    Image(systemName: sync.hasCompletedFirstSync ? "checkmark.icloud.fill" : "shippingbox.fill")
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .padding(.top, Theme.Space.xl)

                    if sync.hasCompletedFirstSync {
                        confirmation
                    } else {
                        nag
                    }
                }
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.xl)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
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
        Text("No typing needed: scan a QR code with your phone, or approve on any device already signed in to VortX.")
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.textTertiary)
            .multilineTextAlignment(.center)

        VStack(spacing: Theme.Space.md) {
            // Keyboard-free primary: the QR joiner signs this Apple TV into an EXISTING VortX account and
            // pulls its data down (the right flow for a TV joining an account the phone already seeded).
            NavigationLink {
                // onSignedIn: the pairing landed and the account's data pulled; close the whole nag (the
                // Settings banner now shows the backed-up confirmation with the last-sync time).
                VortXAccountJoinerView(onSignedIn: { dismiss() })
            } label: {
                Label("Sign in with QR code", systemImage: "qrcode").frame(width: 560)
            }
            .buttonStyle(PrimaryActionStyle())

            // Data lives on THIS Apple TV: the backup-direction QR flow keeps this device's data when the
            // account is empty or conflicted (BackupExportView defaults the conflict to "keep this device").
            NavigationLink {
                BackupExportView()
            } label: {
                Label("Back up this Apple TV", systemImage: "arrow.up.circle").frame(width: 560)
            }
            .buttonStyle(ChipButtonStyle(selected: false))

            // First-ever account (nothing signed in anywhere to approve from): the typed form on the tvOS
            // keyboard, the same SyncSettingsView that Settings > Account links.
            NavigationLink {
                SyncSettingsView()
            } label: {
                Label("Create an account with email", systemImage: "person.crop.circle.badge.plus").frame(width: 560)
            }
            .buttonStyle(ChipButtonStyle(selected: false))

            Button {
                dismiss()
            } label: {
                Text("Not now").frame(width: 560)
            }
            .buttonStyle(ChipButtonStyle(selected: false))
        }

        Text("This reminder returns on the next launch until this Apple TV has synced once.")
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.textTertiary)
            .multilineTextAlignment(.center)
    }

    // MARK: Seeded (reached mid-flow when the pairing lands and the first sync completes)

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
            Text("Done").frame(width: 560)
        }
        .buttonStyle(PrimaryActionStyle())
    }
}
