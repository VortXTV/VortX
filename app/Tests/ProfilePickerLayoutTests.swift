import Foundation

@main
enum ProfilePickerLayoutTests {
    static func main() throws {
        for width: CGFloat in [280, 320, 375, 393, 430, 600, 768, 834, 1024, 1440, 1920] {
            for largeText in [false, true] {
                let layout = ProfilePickerLayout(width: width, largeText: largeText)
                let occupied = layout.avatarSide * CGFloat(layout.columns)
                    + layout.spacing * CGFloat(layout.columns - 1) + layout.horizontalInset * 2 + 16
                precondition(occupied <= min(width, 1100) + 0.01, "Avatar grid overflow at \(width)")
                precondition(layout.avatarSide >= 44, "Avatar hit area too small at \(width)")
            }
        }
        precondition(ProfilePickerLayout(width: 393, largeText: false).columns == 3)
        precondition(ProfilePickerLayout(width: 393, largeText: true).columns == 2)
        let source = try String(contentsOfFile: "app/SourcesShared/ProfilesView.swift", encoding: .utf8)
        let picker = source.components(separatedBy: "/// Centered 4-digit gate")[0]
        precondition(picker.contains("LazyVGrid(columns:"))
        precondition(picker.contains("pinIsForEditing = isEditing"))
        precondition(picker.contains("if profile.hasPin { pinTarget = profile }"))
        precondition(picker.contains(".disabled(pinTarget != nil || profileAction.isRunning)"))
        precondition(!picker.contains("nativeUnsupportedSettings"))
        precondition(!picker.contains("Reconnect the owner's Stremio account"))
        precondition(picker.contains("if !nativeSync.isSignedIn"))
        precondition(picker.contains("Button(\"Sign in\") { accountHelpNeeded = true }"))
        precondition(picker.contains(".disabled(!nativeSync.isSignedIn)"))
        let lockedEditor = source.components(separatedBy: "private var lockedPanel: some View")[1]
            .components(separatedBy: "private var canSave: Bool")[0]
        precondition(lockedEditor.contains("ViewThatFits(in: .horizontal)"))
        precondition(lockedEditor.contains(".accessibilityHidden(switchPinPrompt)"))
        precondition(lockedEditor.contains("admission: admission, finishPicker: false"))
        precondition(source.contains(".accessibilityHidden(isLocked)"))
        let artwork = picker.components(separatedBy: "private final class ProfilePickerArtwork")[1]
            .components(separatedBy: "private struct ProfileAvatarTile")[0]
        precondition(artwork.contains("AddonClient.cinemeta"))
        precondition(!artwork.contains("CoreBridge") && !artwork.contains("ProfileStore"))
        print("PASS profile picker: phone/tablet/Mac/TV grid bounds, large text, PIN-preserving Edit, public-only artwork, no migration paragraphs")
    }
}
