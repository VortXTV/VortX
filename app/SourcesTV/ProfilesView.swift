import SwiftUI

/// Full-screen "Who's watching?" profile picker, shown at cold launch when more than one profile
/// exists and from Settings as the switcher. Picking a profile applies its theme instantly; when
/// it binds a different Stremio account the engine session switches in place (never Logout, that
/// would kill the old profile's key server-side).
struct ProfilePickerView: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager

    @State private var pinTarget: UserProfile?
    @State private var pinInput = ""
    @State private var pinWrong = false
    @State private var editorProfile: UserProfile?
    @State private var signInNeeded = false

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            VStack(spacing: Theme.Space.xxl) {
                Text("Who's watching?")
                    .font(Theme.Typography.hero)
                    .foregroundStyle(Theme.Palette.textPrimary)
                HStack(alignment: .top, spacing: Theme.Space.xl) {
                    ForEach(store.profiles) { profile in
                        ProfileCard(profile: profile) { pick(profile) }
                    }
                    AddProfileCard {
                        editorProfile = UserProfile(name: "", avatar: "🎬",
                                                    accentID: theme.accentID)
                    }
                }
            }
            .padding(Theme.Space.screenEdge)

            if pinTarget != nil { pinGate }
        }
        .fullScreenCover(item: $editorProfile) { profile in
            ProfileEditorView(original: profile)
        }
        .fullScreenCover(isPresented: $signInNeeded) {
            LoginView(account: account)
        }
    }

    private func pick(_ profile: UserProfile) {
        if profile.hasPin {
            pinInput = ""; pinWrong = false; pinTarget = profile
        } else {
            commit(profile)
        }
    }

    private func commit(_ profile: UserProfile) {
        pinTarget = nil
        switch store.select(profile) {
        case .sameAccount:
            break
        case .switchAccount(let token):
            account.reloadForActiveProfile()
            core.switchAccount(token: token)
        case .needsSignIn:
            account.reloadForActiveProfile()
            signInNeeded = true
        }
    }

    /// Centered 4-digit gate over a dimmed picker.
    private var pinGate: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                Text("Enter PIN for \(pinTarget?.name ?? "")")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                SecureField("PIN", text: $pinInput)
                    .font(Theme.Typography.body)
                    .frame(width: 360)
                    .onChange(of: pinInput) {
                        pinInput = String(pinInput.filter(\.isNumber).prefix(4))
                        pinWrong = false
                    }
                if pinWrong {
                    Text("Wrong PIN").font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
                }
                HStack(spacing: Theme.Space.md) {
                    Button("Unlock") {
                        guard let target = pinTarget else { return }
                        if pinInput == target.pin { commit(target) } else { pinWrong = true }
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(pinInput.count != 4)
                    Button("Cancel") { pinTarget = nil }
                        .buttonStyle(ChipButtonStyle(selected: false))
                }
            }
            .padding(Theme.Space.xxl)
            .background(Theme.Palette.surface1,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }
}

/// One profile in the picker: a flat accent disc with the avatar, name underneath, focus = lift.
private struct ProfileCard: View {
    let profile: UserProfile
    let action: () -> Void
    @EnvironmentObject private var theme: ThemeManager

    private var accent: Color {
        ThemeManager.accents.first { $0.id == profile.accentID }?.base ?? Theme.Palette.accent
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.md) {
                ZStack {
                    Circle().fill(accent.opacity(0.28))
                    Circle().strokeBorder(accent, lineWidth: 3)
                    Text(profile.avatar).font(.system(size: 88))
                    if profile.hasPin {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .padding(10)
                            .background(Theme.Palette.surface2, in: Circle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .bottomTrailing)
                    }
                }
                .frame(width: 200, height: 200)
                Text(profile.name)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 230)
        }
        .buttonStyle(CardFocusStyle())
    }
}

private struct AddProfileCard: View {
    let action: () -> Void
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.md) {
                ZStack {
                    Circle().fill(Theme.Palette.surface1)
                    Image(systemName: "plus")
                        .font(.system(size: 64, weight: .medium))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .frame(width: 200, height: 200)
                Text("Add Profile")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(width: 230)
        }
        .buttonStyle(CardFocusStyle())
    }
}

/// Create or edit a profile: name, avatar, theme, an optional own Stremio account, and an optional
/// 4-digit PIN. Works on a draft; nothing persists until Save.
struct ProfileEditorView: View {
    let original: UserProfile
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var draft: UserProfile
    @State private var pinText: String
    @State private var confirmDelete = false

    private var isNew: Bool { !store.profiles.contains { $0.id == original.id } }
    private static let avatars = ["🍿", "🎬", "👑", "🦊", "🐼", "🚀", "🌊", "🔥",
                                  "🎮", "🐉", "👻", "🤖", "🎧", "🌸", "🦁", "⚡️"]

    init(original: UserProfile) {
        self.original = original
        _draft = State(initialValue: original)
        _pinText = State(initialValue: original.pin ?? "")
    }

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    Text(isNew ? "New Profile" : "Edit \(original.name)")
                        .font(Theme.Typography.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)

                    row("Name") {
                        TextField("Name", text: $draft.name)
                            .font(Theme.Typography.body)
                            .frame(width: 600)
                    }

                    row("Avatar") {
                        ForEach(Self.avatars, id: \.self) { emoji in
                            Button(emoji) { draft.avatar = emoji }
                                .buttonStyle(ChipButtonStyle(selected: draft.avatar == emoji))
                        }
                    }

                    row("Accent") {
                        ForEach(ThemeManager.accents) { option in
                            Button(option.label) { draft.accentID = option.id }
                                .buttonStyle(ChipButtonStyle(selected: draft.accentID == option.id,
                                                             accent: option.base))
                        }
                    }

                    row("Background") {
                        Button("Warm") { draft.oled = false }
                            .buttonStyle(ChipButtonStyle(selected: !draft.oled))
                        Button("OLED Black") { draft.oled = true }
                            .buttonStyle(ChipButtonStyle(selected: draft.oled))
                    }

                    row("Account") {
                        Button("Shared account") { draft.usesOwnAccount = false }
                            .buttonStyle(ChipButtonStyle(selected: !draft.usesOwnAccount))
                        Button("Its own account") { draft.usesOwnAccount = true }
                            .buttonStyle(ChipButtonStyle(selected: draft.usesOwnAccount))
                    }
                    if draft.usesOwnAccount {
                        Text(draft.email.map { "Signed in as \($0)" }
                             ?? "You'll be asked to sign in when this profile is first opened.")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }

                    row("PIN") {
                        TextField("4 digits, empty for none", text: $pinText)
                            .font(Theme.Typography.body)
                            .frame(width: 600)
                            .onChange(of: pinText) {
                                pinText = String(pinText.filter(\.isNumber).prefix(4))
                            }
                    }

                    HStack(spacing: Theme.Space.md) {
                        Button("Save") { save() }
                            .buttonStyle(PrimaryActionStyle())
                            .disabled(!canSave)
                        Button("Cancel") { dismiss() }
                            .buttonStyle(ChipButtonStyle(selected: false))
                        if !isNew && store.profiles.count > 1 {
                            Button("Delete Profile", role: .destructive) { confirmDelete = true }
                                .buttonStyle(ChipButtonStyle(selected: false))
                        }
                    }
                    .padding(.top, Theme.Space.md)
                }
                .padding(Theme.Space.screenEdge)
            }
        }
        .confirmationDialog("Delete \(original.name)? Its settings and sign-in are removed.",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.remove(original)
                dismiss()
            }
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && (pinText.isEmpty || pinText.count == 4)
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        draft.pin = pinText.isEmpty ? nil : pinText
        if isNew { store.add(draft) } else { store.update(draft) }
        dismiss()
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(label.uppercased())
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Palette.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) { content() }
                    .padding(.vertical, Theme.Space.xs / 2)
            }
        }
    }
}
