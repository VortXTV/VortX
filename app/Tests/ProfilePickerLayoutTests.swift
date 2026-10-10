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
                for count in 0...13 {
                    let rows = layout.rows(itemCount: count)
                    precondition(rows.flatMap { Array($0) } == Array(0..<count), "Every avatar occurs once")
                    precondition(rows.allSatisfy { !$0.isEmpty && $0.count <= layout.columns }, "No empty grid tracks")
                    if let row = rows.last {
                        let rowWidth = CGFloat(row.count) * layout.avatarSide + CGFloat(row.count - 1) * layout.spacing
                        precondition(rowWidth <= occupied, "Last populated row fits without phantom columns")
                    }
                }
            }
        }
        precondition(ProfilePickerLayout(width: 393, largeText: false).columns == 3)
        precondition(ProfilePickerLayout(width: 393, largeText: true).columns == 2)
        precondition(ProfilePickerLayout(width: 393, largeText: false, isPhone: true).isPhone,
                     "Phone picker retains its established placement policy")
        precondition(!ProfilePickerLayout(width: 834, largeText: false, isPhone: false).isPhone,
                     "iPad/TV/Mac picker selects the centered placement policy")
        let source = try String(contentsOfFile: "app/SourcesShared/ProfilesView.swift", encoding: .utf8)
        let picker = source.components(separatedBy: "/// Centered 4-digit gate")[0]
        precondition(picker.contains("LazyVGrid(columns:"))
        precondition(picker.contains("layout.rows(itemCount:"), "Large devices center actual populated avatar rows")
        precondition(picker.contains("pinIsForEditing = isEditing"))
        precondition(picker.contains("if profile.hasPin { pinTarget = profile }"))
        precondition(picker.contains(".disabled(pinTarget != nil || profileAction.isRunning)"))
        precondition(!picker.contains("nativeUnsupportedSettings"))
        precondition(!picker.contains("Reconnect the owner's Stremio account"))
        precondition(picker.contains("if !nativeSync.isSignedIn"))
        precondition(picker.contains("Button(\"Sign in\") { accountHelpNeeded = true }"))
        precondition(picker.contains(".disabled(!nativeSync.isSignedIn)"))
        precondition(picker.contains("isPhone: profilePickerIsPhone"))
        precondition(picker.contains("Spacer(minLength: max(40, geometry.size.height * 0.34)"))
        precondition(picker.contains(".padding(.bottom, layout.isPhone ? 32 : 0)"))
        precondition(picker.contains("alignment: layout.isPhone ? .bottom : .center"))
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
        precondition(artwork.contains("guard movie == nil, !Task.isCancelled else { return }"))
        precondition(artwork.contains("prewarmNext(after: index)"))
        precondition(artwork.contains("PosterImageLoader.cached(url, maxPixel: Self.artworkMaxPixel)"))
        precondition(artwork.contains("readyIDs.remove(candidate.id)"))
        precondition(artwork.components(separatedBy: "guard rotationToken == token, !Task.isCancelled else { return }").count - 1 >= 2,
                     "rotation rechecks generation after prewarm and each candidate load")
        print("PASS profile picker: phone/tablet/Mac/TV grid bounds, large text, PIN-preserving Edit, public-only artwork, no migration paragraphs")
    }
}
