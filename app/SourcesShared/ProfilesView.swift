import SwiftUI

// MARK: - Cross-platform shims (file-local)
//
// ProfilesView now lives in SourcesShared, so it compiles into the iOS, macOS and tvOS targets.
// A few modifiers it uses are not available everywhere:
//   • `.focusSection()`        — tvOS / macOS 13+ / iOS 17+. The iOS target deploys to 16, so it
//                                 must be gated. On tvOS it shapes directional-focus traversal;
//                                 on iOS/macOS there is no remote focus engine, so it is a no-op.
//   • `.fullScreenCover(...)`  — iOS / tvOS only. macOS has no full-screen cover, so it falls back
//                                 to a sheet there.
// These helpers keep the tvOS behaviour byte-for-byte identical while letting the file build on
// iOS and macOS. `PlatformModifiers.swift` has equivalents but lives in SourcesiOS (not compiled
// into tvOS), so ProfilesView carries its own file-local copies.
private extension View {
    @ViewBuilder func profileFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }

    @ViewBuilder func profileCover<Item: Identifiable, C: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> C) -> some View {
        #if os(macOS)
        self.sheet(item: item, content: content)
        #else
        self.fullScreenCover(item: item, content: content)
        #endif
    }

    @ViewBuilder func profileCover<C: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        #if os(macOS)
        self.sheet(isPresented: isPresented, content: content)
        #else
        self.fullScreenCover(isPresented: isPresented, content: content)
        #endif
    }

    /// `.keyboardType(_:)` is UIKit-backed (iOS / tvOS only); macOS has no software keyboard, so
    /// this is a no-op there. Used for the 4-digit PIN fields.
    @ViewBuilder func numberPadKeyboard() -> some View {
        #if os(macOS)
        self
        #else
        self.keyboardType(.numberPad)
        #endif
    }
}

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
    #if !os(tvOS)
    /// Measured width of the picker's horizontal scroll viewport (iOS + macOS), used to pin the card row's
    /// minWidth so a short row centers instead of sitting hard-left (see the picker body below).
    @State private var pickerRowWidth: CGFloat = 0
    #endif

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            VStack(spacing: Theme.Space.xxl) {
                Text("Who's watching?")
                    .font(Theme.Typography.hero)
                    .foregroundStyle(Theme.Palette.textPrimary)
                // Touch: scroll horizontally so 3+ cards (230pt each) don't overflow + clip both edges
                // on a phone (systemic fix S1b). tvOS keeps the centered HStack for remote focus nav.
                // macOS: the picker presents as a `.sheet`, which sizes to content; a horizontal ScrollView
                // has no intrinsic width, so the sheet collapsed to ~one card and clipped the second avatar
                // at the right edge (the Mac "Who's watching? cuts off the second avatar" report). The
                // explicit `.frame` below gives the sheet a real width so a few cards fit, and this same
                // horizontal ScrollView still scrolls when N avatars exceed it.
                #if os(tvOS)
                profileCards
                #elseif os(macOS)
                // Center the row when it is narrower than the viewport so a couple of avatars sit balanced
                // rather than pinned hard-left with trailing dead space. A flexible `maxWidth: .infinity`
                // frame is a NO-OP along a horizontal ScrollView's unbounded scroll axis (it collapses to the
                // row's ideal width), so real centering needs the actual viewport width: measure it via a
                // background GeometryReader and pin the row's minWidth to it. When the avatars exceed that
                // width the row's intrinsic width wins and it scrolls, as before.
                ScrollView(.horizontal, showsIndicators: false) {
                    profileCards
                        .frame(minWidth: pickerRowWidth, alignment: .center)
                }
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { pickerRowWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { newWidth in pickerRowWidth = newWidth }
                })
                #else
                // iOS: the horizontal scroll is the systemic S1b fix so 3+ cards do not clip both phone
                // edges. S12: use the SAME measured-minWidth centering as macOS so a short row (1-2 profiles)
                // sits balanced instead of hard-left with trailing dead space; it still scrolls identically
                // once the cards exceed the measured viewport width (the intrinsic row width then wins).
                ScrollView(.horizontal, showsIndicators: false) {
                    profileCards
                        .frame(minWidth: pickerRowWidth, alignment: .center)
                }
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { pickerRowWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { newWidth in pickerRowWidth = newWidth }
                })
                #endif
            }
            .padding(Theme.Space.screenInset)
            // macOS sheet sizing: without a concrete width the sheet adopts the horizontal ScrollView's
            // tiny ideal width and clipped the avatars. Open wide enough for ~3 cards (230pt each + xl gaps),
            // capped so a big display never blows the sheet up; the ScrollView carries any overflow.
            // idealWidth stays UNDER the app's 900pt minimum window width (StremioXiOSApp.swift:176) because
            // AppKit does not clamp a sheet to its parent window: a 940pt ideal overhung both edges of a
            // minimum-width window. 860 still fits 3 cards (690pt) plus gaps and insets.
            #if os(macOS)
            .frame(minWidth: 760, idealWidth: 860, maxWidth: 1100, minHeight: 520, idealHeight: 600)
            #endif
            // Unfocusable while the PIN gate is up, so focus must move into the gate (on a real
            // remote, focus will not enter an overlay while anything beneath stays focusable).
            .disabled(pinTarget != nil)

            if let target = pinTarget {
                PinGateOverlay(profile: target,
                               onUnlock: { commit(target) },
                               onCancel: { pinTarget = nil })
            }
        }
        .profileCover(item: $editorProfile) { profile in
            ProfileEditorView(original: profile)
        }
        .profileCover(isPresented: $signInNeeded) {
            // LoginView is the tvOS sign-in panel (SourcesTV); the touch UI ships iOSSignInView.
            #if os(tvOS)
            LoginView(account: account)
            #else
            iOSSignInView()
            #endif
        }
    }

    private var profileCards: some View {
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
                    .numberPadKeyboard()
                    .frame(maxWidth: 360)
                    .onChange(of: input) { _ in
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
    @EnvironmentObject private var account: StremioAccount   // for the locked-panel "Switch profile" reload
    @EnvironmentObject private var core: CoreBridge          // (mirrors ProfilePickerView's switch path)
    @Environment(\.dismiss) private var dismiss

    @State private var draft: UserProfile
    @State private var pinText: String
    @State private var customAvatar = ""
    @State private var confirmDelete = false
    @State private var switchPinPrompt = false   // PIN gate when switching INTO a locked profile
    @State private var signInNeeded = false      // an own-account profile with no stored token

    private var isNew: Bool { !store.profiles.contains { $0.id == original.id } }

    /// The guardrail: a profile can ONLY be edited while it is the one in use. You cannot change
    /// another profile from yours, with or without a PIN (the PIN bypass was the hole in the
    /// 0.2.46 version). To edit profile B, switch to B first. New-profile creation is exempt.
    private var isLocked: Bool {
        !isNew && original.id != store.activeID
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
                // LazyVStack, not VStack: a plain VStack inside a vertical ScrollView sizes to its
                // widest child, so the fixed-width fields + chip rows below pushed the whole editor
                // wider than the phone and it clipped on BOTH edges ("ile", "ED Black"). LazyVStack is
                // greedy on width and pins the column to the viewport. (Systemic fix S1.)
                LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                    Text(isNew ? "New Profile" : "Edit \(original.name)")
                        .font(Theme.Typography.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)

                    row("Name") {
                        TextField("Name", text: $draft.name)
                            .font(Theme.Typography.body)
                            .frame(maxWidth: 600)
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
                            .frame(maxWidth: 600)
                            .onChange(of: customAvatar) { _ in
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
                    .profileFocusSection()

                    // ThemeAccentPicker / ThemeBackgroundPicker live in SourcesTV/SettingsView.swift
                    // (not compiled into iOS/macOS). On tvOS use them verbatim; on iOS/macOS use the
                    // file-local equivalents below, built from the same shared ChipButtonStyle.
                    #if os(tvOS)
                    ThemeAccentPicker(selection: $draft.accentID).profileFocusSection()
                    ThemeBackgroundPicker(oled: $draft.oled).profileFocusSection()
                    #else
                    ProfileAccentPicker(selection: $draft.accentID).profileFocusSection()
                    ProfileBackgroundPicker(oled: $draft.oled).profileFocusSection()
                    #endif

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
                            .numberPadKeyboard()
                            .frame(maxWidth: 600)
                            .onChange(of: pinText) { _ in
                                pinText = String(pinText.filter(\.isNumber).prefix(4))
                            }
                        if draft.hasPin {
                            Button("Remove PIN") { draft.pin = nil; pinText = "" }
                                .buttonStyle(ChipButtonStyle(selected: false))
                        }
                    }

                    if !draft.isOwner {
                        row("Kids") {
                            Button("Off") { draft.isKids = false }
                                .buttonStyle(ChipButtonStyle(selected: !draft.isKids))
                            Button("Kids profile") { draft.isKids = true }
                                .buttonStyle(ChipButtonStyle(selected: draft.isKids))
                        }
                        if draft.isKids {
                            Text("Hides adult and CAM/fake sources from this profile. For a full lock, set a PIN on your own profile so it can't be opened from here, and hide adult add-ons under Add-ons.")
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Palette.textTertiary)
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
                    .profileFocusSection()
                }
                .padding(Theme.Space.screenInset)
            }
            // Unfocusable while the lock is up, so the remote lands in the lock panel (tvOS focus
            // won't enter an overlay while anything beneath stays focusable).
            .disabled(isLocked)

            if isLocked { lockedPanel }
        }
        .confirmationDialog("Delete \(original.name)? Its settings and sign-in are removed.",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.remove(original)
                dismiss()
            }
        }
        .profileCover(isPresented: $signInNeeded) {
            // An own-account profile with no stored token: sign in here rather than dismissing into a
            // signed-out profile. LoginView is the tvOS panel; the touch UI ships iOSSignInView.
            #if os(tvOS)
            LoginView(account: account)
            #else
            iOSSignInView()
            #endif
        }
    }

    /// Shown instead of the form for a non-active profile: editing is only allowed from within that
    /// profile. The door to editing stays closed (no PIN bypass), but the user can SWITCH to it here.
    private var lockedPanel: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48)).foregroundStyle(Theme.Palette.accent)
                Text("\(original.name) can only be edited from that profile")
                    .font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Switch to \(original.name) to use it and edit its settings.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 640)
                HStack(spacing: Theme.Space.md) {
                    Button("Switch to \(original.name)") {
                        if original.hasPin { switchPinPrompt = true } else { commitSwitch() }
                    }
                    .buttonStyle(PrimaryActionStyle())
                    Button("Cancel") { dismiss() }
                        .buttonStyle(ChipButtonStyle(selected: false))
                }
            }
            .padding(Theme.Space.xxl)
            .background(Theme.Palette.surface1,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            // Unfocusable while the PIN gate is up, so the remote lands in the gate (tvOS).
            .disabled(switchPinPrompt)

            if switchPinPrompt {
                PinGateOverlay(profile: original,
                               onUnlock: { switchPinPrompt = false; commitSwitch() },
                               onCancel: { switchPinPrompt = false })
            }
        }
    }

    /// Switch the active profile to this (locked) one, mirroring ProfilePickerView.commit: select it,
    /// then reload the account/engine for the new profile, and dismiss. A PIN-protected profile prompts
    /// for its PIN first (switchPinPrompt). On .needsSignIn the editor presents sign-in (Option B)
    /// instead of dismissing into a signed-out profile.
    private func commitSwitch() {
        switch store.select(original) {
        case .sameAccount:
            dismiss()
        case .switchAccount(let token):
            account.reloadForActiveProfile()
            core.switchAccount(token: token)
            dismiss()
        case .needsSignIn:
            account.reloadForActiveProfile()
            signInNeeded = true
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
        .profileFocusSection()
    }
}

#if !os(tvOS)
// MARK: - Touch / Mac accent + background pickers
//
// The tvOS picker types (ThemeAccentPicker / ThemeBackgroundPicker) live in SourcesTV and are not
// compiled into the iOS / macOS targets. These file-local equivalents mirror their behaviour for
// the profile editor on touch and Mac, built from the same shared ChipButtonStyle / CardFocusStyle.
private struct ProfileAccentPicker: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Accent").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.md) {
                    ForEach(ThemeManager.accents) { opt in
                        Button { selection = opt.id } label: {
                            Circle()
                                .fill(opt.base)
                                .frame(width: 44, height: 44)
                                .overlay(Circle().strokeBorder(
                                    selection == opt.id ? Theme.Palette.textPrimary : .clear,
                                    lineWidth: 3))
                        }
                        .buttonStyle(CardFocusStyle())
                    }
                }
                .padding(.horizontal, Theme.Space.sm)
                .padding(.vertical, Theme.Space.sm)
            }
        }
    }
}

private struct ProfileBackgroundPicker: View {
    @Binding var oled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Background").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            HStack(spacing: Theme.Space.sm) {
                Button("Warm") { oled = false }
                    .buttonStyle(ChipButtonStyle(selected: !oled))
                Button("OLED Black") { oled = true }
                    .buttonStyle(ChipButtonStyle(selected: oled))
            }
        }
    }
}
#endif
