import SwiftUI

/// Touch Settings: account, app text size, subtitle size, and the engine status (the FFI smoke
/// check kept here off the Home page). Mirrors the tvOS Settings sections that apply to iOS;
/// more land as the surfaces fill in.
struct iOSSettingsView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @AppStorage(SubtitleStyle.Key.size) private var subSize = SubtitleStyle.defaultSize
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if account.isSignedIn {
                        LabeledContent("Signed in", value: account.email ?? "Stremio account")
                        Button("Sign Out", role: .destructive) { account.signOut(); core.logOut() }
                    } else {
                        Button("Sign In") { showSignIn = true }
                    }
                }
                Section("Appearance") {
                    Stepper(value: $theme.textScale, in: ThemeManager.textScaleRange, step: ThemeManager.textScaleStep) {
                        Text("App text size  ·  \(Int((theme.textScale * 100).rounded()))%")
                    }
                }
                Section("Subtitles") {
                    Picker("Size", selection: $subSize) {
                        ForEach(SubtitleStyle.sizes, id: \.id) { Text($0.label).tag($0.id) }
                    }
                }
                Section("Engine") {
                    LabeledContent("stremio-core schema", value: "\(core.schemaVersion)")
                    LabeledContent("Home rows", value: "\(core.boardRows.count)")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showSignIn) { iOSSignInView() }
            // Text size is per-profile (mirrored into ThemeManager); fold the stepper's change back
            // into the active profile so it survives a switch/relaunch, same as tvOS RootTabView.
            // Single-param onChange: the zero-/two-param forms are iOS 17+, target here is iOS 16.
            .onChange(of: theme.textScale) { _ in ProfileStore.shared.captureTheme() }
        }
    }
}
