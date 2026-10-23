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
        for width: CGFloat in [700, 960, 1024, 1200, 1280, 1440, 1920, 3840] {
            for largeText in [false, true] {
                let tv = ProfilePickerLayout(width: width, largeText: largeText, isTV: true)
                let occupied = tv.avatarSide * CGFloat(tv.columns)
                    + tv.spacing * CGFloat(tv.columns - 1) + tv.horizontalInset * 2 + 16
                precondition(occupied <= min(width, tv.contentMaxWidth) + 0.01, "TV avatars overflow at \(width)")
                precondition(tv.avatarSide >= 140, "TV avatars must remain readable at viewing distance")
                precondition(tv.nameTextSize == 28 && tv.headingTextSize == 50 && tv.movieTextSize == 34)
                precondition(!tv.isPhone, "TV composition remains centered")
                for count in 0...13 {
                    precondition(tv.rows(itemCount: count).flatMap { Array($0) } == Array(0..<count))
                }
            }
        }
        let tv = ProfilePickerLayout(width: 1920, largeText: false, isTV: true)
        precondition(tv.columns == 5 && tv.avatarSide == 216 && tv.contentMaxWidth == 1440)
        precondition(ProfilePickerLayout(width: 1920, largeText: true, isTV: true).columns == 4)
        let phone = ProfilePickerLayout(width: 393, largeText: false, isPhone: true)
        precondition(phone.nameTextSize == 18 && phone.headingTextSize == 25 && phone.contentMaxWidth == 1100,
                     "TV polish must not change the established phone metrics")
        let source = try String(contentsOfFile: "app/SourcesShared/ProfilesView.swift", encoding: .utf8)
        let picker = source.components(separatedBy: "/// Centered 4-digit gate")[0]
        precondition(picker.contains("LazyVGrid(columns:"))
        precondition(picker.contains("layout.rows(itemCount:"), "Large devices center actual populated avatar rows")
        precondition(picker.contains("pinIsForEditing = isEditing"))
        let pick = picker.components(separatedBy: "private func pick(_ profile: UserProfile)")[1]
            .components(separatedBy: "private func resumeDeferredSelection()")[0]
        let pin = pick.components(separatedBy: "if profile.hasPin {")[1]
            .components(separatedBy: "else if isEditing")[0]
        precondition(pin.contains("pinTarget = profile"))
        precondition(pin.contains("pinCredential = CredentialScopeRegistry.shared.capture()"),
                     "A PIN prompt retains the credential generation it was opened under")
        precondition(picker.contains(".disabled(pinTarget != nil || profileAction.isRunning)"))
        precondition(!picker.contains("nativeUnsupportedSettings"))
        precondition(!picker.contains("Reconnect the owner's Stremio account"))
        precondition(picker.contains("if !nativeSync.isSignedIn"))
        precondition(picker.contains("Button(\"Sign in\") { deferredSelection.cancel(); accountHelpNeeded = true }"))
        precondition(picker.contains(".disabled(!nativeSync.isSignedIn)"))
        precondition(picker.contains("isPhone: profilePickerIsPhone"))
        precondition(picker.contains("isTV: profilePickerIsTV"))
        precondition(picker.contains(".frame(maxWidth: layout.contentMaxWidth)"))
        precondition(picker.components(separatedBy: ".frame(width: side, alignment: .top)").count - 1 == 2,
                     "Actual tile labels keep populated rows centered without phantom expanding tracks")
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
        let loadArtwork = artwork.components(separatedBy: "func load() async {")[1]
            .components(separatedBy: "func startRotation(reduceMotion:")[0]
        precondition(loadArtwork.range(of: "if movie != nil { return }")!.lowerBound <
                     loadArtwork.range(of: "await catalogRequest.value")!.lowerBound,
                     "warm public artwork must not wait for a fresh catalog")
        let initialArtwork = artwork.components(separatedBy: "private func showInitialCandidate() async {")[1]
            .components(separatedBy: "private func prewarmNext(after")[0]
        precondition(initialArtwork.contains("for index in decoded + cold"),
                     "decoded public art must precede a shuffled network candidate")
        precondition(artwork.contains("candidates = Self.readPublicSeed()"))
        precondition(artwork.contains(".cachesDirectory, in: .userDomainMask"))
        precondition(artwork.contains("size <= publicSeedByteLimit"))
        precondition(artwork.contains("seed.movies.count <= candidateLimit"))
        precondition(artwork.contains("url.user == nil, url.password == nil"))
        precondition(artwork.contains("url.query == nil, url.fragment == nil"))
        precondition(artwork.contains("age >= -60, age <= publicSeedLifetime"))
        let publicMovie = picker.components(separatedBy: "private struct ProfilePickerMovie:")[1]
            .components(separatedBy: "private struct ProfilePickerBackdrop: View")[0]
        precondition(publicMovie.contains("var firstPaintArtworkURLs: [String]"))
        precondition(publicMovie.contains("ArtworkFallbackPolicy.candidates([poster, background])"),
                     "the first public image must not sit behind a slow large backdrop")
        let backdropSource = picker.components(separatedBy: "private struct ProfilePickerBackdrop: View")[1]
            .components(separatedBy: "private final class ProfilePickerArtwork")[0]
        precondition(backdropSource.contains("if let cached = synchronousCache"))
        precondition(backdropSource.contains("movie.firstPaintArtworkURLs"))
        precondition(artwork.contains("guard movie == nil, !Task.isCancelled else { return }"))
        precondition(artwork.contains("prewarmNext(after: index)"))
        precondition(artwork.contains("PosterImageLoader.cached(url, maxPixel: Self.artworkMaxPixel)"))
        precondition(artwork.contains("readyIDs.remove(candidate.id)"))
        precondition(artwork.contains("#if os(tvOS)\n        return CGFloat(HeroArtworkQualityPolicy.fullHDLongEdge)"),
                     "TV picker has a bounded full-HD decode, not the mobile cap")
        precondition(artwork.contains("return CGFloat(HeroArtworkQualityPolicy.mobileLongEdge)"))
        precondition(artwork.contains("rotationIntervalNanoseconds: UInt64 = 5_000_000_000"))
        let backdrop = picker.components(separatedBy: "private struct ProfilePickerBackdrop: View")[1]
            .components(separatedBy: "private final class ProfilePickerArtwork")[0]
        precondition(backdrop.contains(".transition(.opacity)"))
        precondition(backdrop.contains(".easeInOut(duration: 0.8)"))
        precondition(artwork.components(separatedBy: "guard rotationToken == token, !Task.isCancelled else { return }").count - 1 >= 2,
                     "rotation rechecks generation after prewarm and each candidate load")
        print("PASS profile picker: phone/tablet/Mac/TV grid bounds, large text, scope-bound PIN, PIN-preserving Edit, public-only artwork and transient preparation status")
    }
}
