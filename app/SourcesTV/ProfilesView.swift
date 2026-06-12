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
                        ProfileCard(profile: profile, isCurrent: profile.id == store.activeID) {
                            pick(profile)
                        }
                    }
                    AddProfileCard {
                        editorProfile = UserProfile(name: "", avatar: "🎬",
                                                    accentID: theme.accentID)
                    }
                }
            }
            .padding(Theme.Space.screenEdge)
            // Unfocusable while the PIN gate is up, so focus must move into the gate (on a real
            // remote, focus will not enter an overlay while anything beneath stays focusable).
            .disabled(pinTarget != nil)

            if let target = pinTarget {
                PinGateOverlay(profile: target,
                               onUnlock: { commit(target) },
                               onCancel: { pinTarget = nil })
            }
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
            pinTarget = profile
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

}

/// Centered 4-digit gate over dimmed content. Owns its own input state; the caller decides
/// what unlocking means (switch profiles in the picker, unlock the editor). The content
/// underneath must be `.disabled` while this shows, so the focus engine enters the overlay.
struct PinGateOverlay: View {
    let profile: UserProfile
    let onUnlock: () -> Void
    let onCancel: () -> Void
    @State private var input = ""
    @State private var wrong = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                Text("Enter PIN for \(profile.name)")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                SecureField("PIN", text: $input)
                    .font(Theme.Typography.body)
                    .keyboardType(.numberPad)
                    .frame(width: 360)
                    .onChange(of: input) {
                        input = String(input.filter(\.isNumber).prefix(4))
                        wrong = false
                    }
                if wrong {
                    Text("Wrong PIN").font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
                }
                HStack(spacing: Theme.Space.md) {
                    Button("Unlock") {
                        if profile.pinMatches(input) { onUnlock() } else { wrong = true }
                    }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(input.count != 4)
                    Button("Cancel", action: onCancel)
                        .buttonStyle(ChipButtonStyle(selected: false))
                }
            }
            .padding(Theme.Space.xxl)
            .background(Theme.Palette.surface1,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }
}

/// One profile in the picker: a flat accent disc with the avatar, name underneath. Focus is
/// unmistakable at ten feet: a thick warm-white ring, a brighter fill, a soft glow, and the name
/// lights up, on top of the card lift. The profile you're currently using carries a check badge.
private struct ProfileCard: View {
    let profile: UserProfile
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProfileCardContent(profile: profile, isCurrent: isCurrent)
        }
        .buttonStyle(CardFocusStyle())
    }
}

private struct ProfileCardContent: View {
    let profile: UserProfile
    let isCurrent: Bool
    @Environment(\.isFocused) private var focused
    @EnvironmentObject private var theme: ThemeManager

    private var accent: Color {
        ThemeManager.accents.first { $0.id == profile.accentID }?.base ?? Theme.Palette.accent
    }

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            ZStack {
                Circle().fill(accent.opacity(focused ? 0.5 : 0.24))
                Circle().strokeBorder(focused ? Theme.Palette.textPrimary : accent.opacity(0.7),
                                      lineWidth: focused ? 6 : 3)
                Text(profile.avatar).font(.system(size: 88, weight: .bold))
                if profile.hasPin {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(10)
                        .background(Theme.Palette.surface2, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(Theme.Palette.onAccent)
                        .padding(9)
                        .background(accent, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: 200, height: 200)
            .shadow(color: focused ? accent.opacity(0.55) : .clear, radius: 34, y: 6)
            Text(profile.name)
                .font(focused ? Theme.Typography.cardTitle : Theme.Typography.label)
                .foregroundStyle(focused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 230)
        .animation(Theme.Motion.focus, value: focused)
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
    @State private var customAvatar = ""
    @State private var confirmDelete = false
    @State private var unlocked = false

    private var isNew: Bool { !store.profiles.contains { $0.id == original.id } }

    /// The guardrail: editing someone ELSE's PIN-protected profile requires that profile's PIN
    /// first. Your own profile and PIN-less profiles open freely (a parent edits the kids
    /// profile without friction; the kids profile cannot strip the parent's PIN).
    private var isLocked: Bool {
        !isNew && original.id != store.activeID && original.hasPin && !unlocked
    }
    private static let avatars = ["🍿", "🎬", "👑", "🦊", "🐼", "🚀", "🌊", "🔥",
                                  "🎮", "🐉", "👻", "🤖", "🎧", "🌸", "🦁", "⚡️"]

    init(original: UserProfile) {
        self.original = original
        _draft = State(initialValue: original)
        _pinText = State(initialValue: "")   // stored PINs are hashes; the field only ever takes a NEW pin
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
                            Button(emoji) { draft.avatar = emoji; customAvatar = "" }
                                .buttonStyle(ChipButtonStyle(selected: draft.avatar == emoji))
                        }
                    }
                    HStack(spacing: Theme.Space.md) {
                        TextField("Or type your own: any emoji or a letter", text: $customAvatar)
                            .font(Theme.Typography.body)
                            .frame(width: 600)
                            .onChange(of: customAvatar) {
                                // One grapheme (emoji-safe); single letters display uppercased.
                                guard let first = customAvatar.first else { return }
                                let avatar = String(first)
                                draft.avatar = avatar.count == avatar.uppercased().count
                                    ? avatar.uppercased() : avatar
                            }
                        ZStack {
                            Circle().fill(Theme.Palette.surface2)
                            Text(draft.avatar).font(.system(size: 34, weight: .bold))
                                .foregroundStyle(Theme.Palette.textPrimary)
                        }
                        .frame(width: 64, height: 64)
                    }
                    .focusSection()

                    ThemeAccentPicker(selection: $draft.accentID).focusSection()
                    ThemeBackgroundPicker(oled: $draft.oled).focusSection()

                    if draft.isOwner {
                        // The owner IS the main account; offering "its own account" here once
                        // pointed sign-in at an empty token slot and signed out every device.
                        Text("The main profile. It uses your Stremio account's own watch history, like before profiles existed.")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    } else {
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
                        } else {
                            Text("Keeps its own watch history, synced through your Stremio account to your other devices.")
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }

                    row("PIN") {
                        SecureField(draft.hasPin ? "PIN set. Enter a new one to change it" : "4 digits, empty for none",
                                    text: $pinText)
                            .font(Theme.Typography.body)
                            .keyboardType(.numberPad)
                            .frame(width: 600)
                            .onChange(of: pinText) {
                                pinText = String(pinText.filter(\.isNumber).prefix(4))
                            }
                        if draft.hasPin {
                            Button("Remove PIN") { draft.pin = nil; pinText = "" }
                                .buttonStyle(ChipButtonStyle(selected: false))
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
                    .focusSection()
                }
                .padding(Theme.Space.screenEdge)
            }
            // Unfocusable while the gate is up, so the remote lands in the gate (same trick as
            // the picker; tvOS focus won't enter an overlay while anything beneath is focusable).
            .disabled(isLocked)

            if isLocked {
                PinGateOverlay(profile: original,
                               onUnlock: { unlocked = true },
                               onCancel: { dismiss() })
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
        if !pinText.isEmpty {
            draft.pin = UserProfile.pinHash(pinText, profileID: draft.id)
        }
        // empty field keeps the existing PIN; Remove PIN cleared it explicitly
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
        // Treat each row as a focus section so Down always drops to the next row, even when
        // the focused chip sits far to the right of the item below it. Without this, tvOS does
        // a strict geometric down-search and refuses to move unless you first level horizontally.
        .focusSection()
    }
}
