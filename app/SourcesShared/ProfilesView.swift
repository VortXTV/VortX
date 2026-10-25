import SwiftUI

#if os(iOS)
import UIKit
#endif

// MARK: - Cross-platform shims (file-local)
//
// ProfilesView now lives in SourcesShared, so it compiles into the iOS, macOS and tvOS targets.
// A few modifiers it uses are not available everywhere:
//   • `.focusSection()`:         tvOS / macOS 13+ / iOS 17+. The iOS target deploys to 16, so it
//                                 must be gated. On tvOS it shapes directional-focus traversal;
//                                 on iOS/macOS there is no remote focus engine, so it is a no-op.
//   • `.fullScreenCover(...)`:   iOS / tvOS only. macOS has no full-screen cover, so it falls back
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
    /// Actions capture the current admission when tapped. Picker artwork/layout has no
    /// engine-state dependency and must not subscribe to every engine publication.
    private let core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @ReducedMotion private var reduceMotion

    @State private var pinTarget: UserProfile?
    @State private var pinIsForEditing = false
    @State private var editorProfile: UserProfile?
    @State private var isEditing = false
    @State private var signInNeeded = false
    @State private var accountHelpNeeded = false
    @StateObject private var profileAction = ProfileMutationPresentation()
    @StateObject private var artwork = ProfilePickerArtwork.shared
    @ObservedObject private var nativeSync = VortXSyncManager.shared
    @State private var deferredSelection = NativeProfileActionPreparation.DeferredSelection<CredentialScopeRegistry.Capture>()
    @State private var pinCredential: CredentialScopeRegistry.Capture?
    @State private var signInCredential: CredentialScopeRegistry.Capture?
    @State private var signInProfileID: UUID?

    private var profilesArePreparing: Bool {
        nativeSync.nativeCheckpointStatus == "restoring" || nativeSync.accountRestoreState == .restoring
    }

    /// The device log spans every profile's activity. With a PIN-protected profile here, export waits until
    /// a profile is unlocked (Settings has it), unless profiles failed to load, the stuck case it exists for.
    private var exportAllowedBeforeProfile: Bool {
        if profileAction.errorMessage != nil { return true }
        if nativeSync.accountRestoreState == .failed { return true }
        return !store.profiles.contains { $0.pin != nil }
    }

    init(core: CoreBridge = .shared) { self.core = core }

    private var visibleProfileError: String? {
        if profilesArePreparing { return nil }
        return profileAction.errorMessage
    }

    private var profileActionStatus: String {
        if profilesArePreparing { return "Preparing your profiles—please wait…" }
        return "Opening profile…"
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let layout = ProfilePickerLayout(width: geometry.size.width,
                                                 largeText: dynamicTypeSize.isAccessibilitySize || theme.textScale > 1.20,
                                                 isPhone: profilePickerIsPhone,
                                                 isTV: profilePickerIsTV)
                ZStack {
                    backgroundArtwork
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 24) {
                            if layout.isPhone {
                                // Preserve the established phone composition. Only the larger picker
                                // surfaces move to true vertical centering below.
                                Spacer(minLength: max(40, geometry.size.height * 0.34))
                            }
                            if let movie = artwork.movie {
                                Text(movie.name)
                                    .modifier(ProfilePickerText(size: layout.movieTextSize, style: .title, design: .serif))
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(.bottom, 12)
                                    .accessibilityHidden(true)
                            }
                            Text(isEditing ? "Edit profiles" : "Who's watching?")
                                .modifier(ProfilePickerText(size: layout.headingTextSize, style: .title2, design: .rounded))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .accessibilityAddTraits(.isHeader)
                            if !nativeSync.isSignedIn {
                                Text("Sign in to your VortX account to load your profiles.")
                                    .font(.callout).foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                Button("Sign in") { deferredSelection.cancel(); accountHelpNeeded = true }
                                    .buttonStyle(.borderedProminent)
                                    .tint(theme.accent)
                            }
                            if profileAction.isRunning {
                                ProgressView(profileActionStatus).tint(Theme.Palette.accent).foregroundStyle(.white)
                            }
                            if !profileAction.isRunning, nativeSync.isSignedIn {
                                if profilesArePreparing {
                                    ProgressView("Preparing your profiles—please wait…").tint(Theme.Palette.accent).foregroundStyle(.white)
                                    Text(deferredSelection.profileID != nil
                                         ? "Your saved data is safe. Your selected profile will open when preparation finishes."
                                         : "Your saved data is safe. You can choose a profile while preparation finishes.")
                                        .font(.callout).foregroundStyle(.white)
                                        .multilineTextAlignment(.center)
                                } else if nativeSync.accountRestoreState == .failed, profileAction.errorMessage == nil {
                                    Text("Couldn't finish loading your profiles. Tap a profile to try again.")
                                        .font(.callout).foregroundStyle(.white)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            if let error = visibleProfileError {
                                Text(error).font(.callout).foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(12)
                                    .background(.red.opacity(0.22), in: RoundedRectangle(cornerRadius: 16))
                                    .accessibilityIdentifier("profile-picker-error")
                                Button("Account settings") { deferredSelection.cancel(); accountHelpNeeded = true }
                                    .buttonStyle(.bordered)
                                    .tint(.white)
                            }
                            profileGrid(layout: layout)
                                .disabled(!nativeSync.isSignedIn)
                        }
                        .padding(.horizontal, layout.horizontalInset)
                        .padding(.bottom, layout.isPhone ? 32 : 0)
                        .frame(maxWidth: layout.contentMaxWidth)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height,
                               alignment: layout.isPhone ? .bottom : .center)
                    }
                    .disabled(pinTarget != nil || profileAction.isRunning)
                    .accessibilityHidden(pinTarget != nil)
                    // Outside the disabled picker: a stuck profile/restore must not block its own log.
                    .safeAreaInset(edge: .bottom) {
                        if exportAllowedBeforeProfile {
                            DiagnosticLogExportButton()
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .disabled(pinTarget != nil)
                                .accessibilityHidden(pinTarget != nil)
                        }
                    }
                }
            }

            if let target = pinTarget {
                PinGateOverlay(profile: target,
                               onUnlock: {
                                   finishPIN(target)
                               },
                               onCancel: {
                                   pinTarget = nil; pinIsForEditing = false
                                   pinCredential = nil
                               })
            }
        }
        .profileCover(item: $editorProfile) { ProfileEditorView(original: $0) }
        .profileCover(isPresented: $signInNeeded) {
            #if os(tvOS)
            LoginView(account: account)
            #else
            iOSSignInView()
            #endif
        }
        .profileCover(isPresented: $accountHelpNeeded) {
            ProfileAccountRecoveryView().environmentObject(VortXSyncManager.shared)
        }
        .interactiveDismissDisabled(profileAction.isRunning)
        .task(id: artworkTaskKey) {
            guard artworkIsVisible else {
                artwork.stopRotation()
                return
            }
            await artwork.load()
            guard !Task.isCancelled else { return }
            artwork.startRotation(reduceMotion: reduceMotion)
        }
        .onDisappear {
            artwork.stopRotation()
            profileAction.cancel()
            deferredSelection.cancel()
            // A full-screen child can hide its presenter without removing its identity.
            if !signInNeeded { signInCredential = nil; signInProfileID = nil }
        }
        .onValueChange(of: nativeSync.accountRestoreState) { state in
            if state == .failed { deferredSelection.cancel() }
            if state == .ready, !profileAction.isRunning { profileAction.cancel() }
            resumeDeferredSelection()
        }
        .onValueChange(of: nativeSync.nativeCheckpointStatus) { _ in resumeDeferredSelection() }
        .onValueChange(of: profileAction.errorMessage) { _ in resumeDeferredSelection() }
        .onValueChange(of: signInNeeded) { presented in if !presented { finishPendingSignIn() } }
        .onValueChange(of: scenePhase) { phase in if phase == .active { resumeDeferredSelection() } }
        .onReceive(NotificationCenter.default.publisher(for: VortXSyncManager.credentialScopeDidChangeNote)) { _ in
            deferredSelection.cancel()
            pinTarget = nil; pinCredential = nil; pinIsForEditing = false
            signInCredential = nil; signInProfileID = nil
        }
    }

    private var artworkIsVisible: Bool {
        scenePhase == .active && pinTarget == nil && editorProfile == nil &&
        !signInNeeded && !accountHelpNeeded && !profileAction.isRunning
    }

    private var artworkTaskKey: String {
        "\(artworkIsVisible)-\(reduceMotion)"
    }

    private var profilePickerIsPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var profilePickerIsTV: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }

    private var backgroundArtwork: some View {
        ZStack {
            Color.black
            ProfilePickerBackdrop(movie: artwork.movie)
                .opacity(0.85)
            LinearGradient(stops: [.init(color: .black.opacity(0.12), location: 0),
                                   .init(color: .black.opacity(0.22), location: 0.3),
                                   .init(color: .black.opacity(0.85), location: 0.62),
                                   .init(color: .black, location: 0.84)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func profileGrid(layout: ProfilePickerLayout) -> some View {
        Group {
            if layout.isPhone {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: layout.spacing), count: layout.columns),
                          alignment: .center, spacing: 24) {
                    ForEach(0..<(store.profiles.count + 2), id: \.self) { index in
                        profileTile(at: index, side: layout.avatarSide, nameTextSize: layout.nameTextSize)
                    }
                }
            } else {
                VStack(spacing: 24) {
                    ForEach(layout.rows(itemCount: store.profiles.count + 2), id: \.lowerBound) { row in
                        HStack(alignment: .top, spacing: layout.spacing) {
                            ForEach(Array(row), id: \.self) { index in
                                profileTile(at: index, side: layout.avatarSide, nameTextSize: layout.nameTextSize)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .padding(8)
        .profileFocusSection()
    }

    @ViewBuilder private func profileTile(at index: Int, side: CGFloat, nameTextSize: CGFloat) -> some View {
        if index < store.profiles.count {
            let profile = store.profiles[index]
            ProfileAvatarTile(profile: profile, isCurrent: profile.id == store.activeID,
                              isEditing: isEditing, side: side, nameTextSize: nameTextSize) { pick(profile) }
        } else if index == store.profiles.count {
            ProfilePickerActionTile(title: "Add", symbol: "plus", side: side, nameTextSize: nameTextSize) {
                deferredSelection.cancel()
                editorProfile = UserProfile(name: "", avatar: "🎬", accentID: theme.accentID)
            }
        } else {
            ProfilePickerActionTile(title: isEditing ? "Done" : "Edit",
                                    symbol: isEditing ? "checkmark" : "pencil", side: side, nameTextSize: nameTextSize) {
                deferredSelection.cancel()
                isEditing.toggle()
            }
        }
    }

    private func pick(_ profile: UserProfile) {
        let capture = CredentialScopeRegistry.shared.capture()
        if !isEditing, profilesArePreparing || !core.hasCertifiedNativeSession(capture: capture, profileID: store.activeID) {
            profileAction.cancel()
            deferredSelection.request(profile.id, owner: capture, preparing: true,
                                      accountRestorePreparing: nativeSync.accountRestoreState == .restoring)
            if !profilesArePreparing {
                // Only preparation runs here. A failed selection/checkpoint write is never
                // enqueued for an automatic mutation retry.
                profileAction.start(operation: { await nativeSync.prepareNativeProfileSelection(credentialCapture: capture) },
                    failureMessage: { core.nativeProfileRecoveryMessage }, onSuccess: { resumeDeferredSelection() })
            }
            return
        }
        deferredSelection.cancel()
        // The editor already gates an inactive profile's switch. Do not ask for its PIN twice.
        if isEditing, profile.id != store.activeID { editorProfile = profile; return }
        pinIsForEditing = isEditing
        if profile.hasPin {
            pinCredential = CredentialScopeRegistry.shared.capture()
            pinTarget = profile
        }
        else if isEditing { editorProfile = profile }
        else { commit(profile) }
    }

    private func resumeDeferredSelection() {
        deferredSelection.observePreparation(profilesArePreparing,
                                             accountRestorePreparing: nativeSync.accountRestoreState == .restoring)
        // Observer delivery order is not an authority. A failed restore must cancel its
        // waiting intent even if a checkpoint, scene or error callback arrives first.
        if deferredSelection.waitedForAccountRestore, nativeSync.accountRestoreState == .failed {
            deferredSelection.cancel()
            return
        }
        guard scenePhase == .active, !profileAction.isRunning, !isEditing, pinTarget == nil,
              editorProfile == nil, !signInNeeded, !accountHelpNeeded else { return }
        let capture = CredentialScopeRegistry.shared.capture()
        guard let id = deferredSelection.take(owner: capture, preparing: profilesArePreparing,
            ready: core.hasCertifiedNativeSession(capture: capture, profileID: store.activeID),
            profileExists: { id in store.profiles.contains { $0.id == id } }),
              let profile = store.profiles.first(where: { $0.id == id }) else { return }
        // Resolve the freshly authenticated roster and its current PIN, not the cached tile.
        pick(profile)
    }

    private func finishPendingSignIn() {
        defer { signInCredential = nil; signInProfileID = nil }
        guard let capture = signInCredential, let profileID = signInProfileID,
              CredentialScopeRegistry.shared.isCurrent(capture), store.activeID == profileID,
              core.hasCertifiedNativeSession(capture: capture, profileID: profileID),
              core.nativeAccountMode(profileID: profileID) == "own",
              account.isSignedIn, account.signInError == nil else { return }
        store.pickedThisLaunch = true
    }

    private func finishPIN(_ target: UserProfile) {
        guard let capture = pinCredential, CredentialScopeRegistry.shared.isCurrent(capture),
              let current = store.profiles.first(where: { $0.id == target.id }) else {
            pinTarget = nil; pinCredential = nil; pinIsForEditing = false
            return
        }
        pinTarget = nil; pinCredential = nil
        guard !profilesArePreparing, core.hasCertifiedNativeSession(capture: capture, profileID: store.activeID) else {
            pick(current) // Re-prepare, then require a PIN against the newly loaded roster.
            return
        }
        guard current.pin == target.pin else { pick(current); return }
        if pinIsForEditing { editorProfile = current }
        else { commit(current) }
    }

    private func commit(_ profile: UserProfile) {
        pinTarget = nil
        let admission = core.captureNativeProfileActionAdmission()
        // Keep the parent picker alive until the selected profile is usable. In particular,
        // pending-own setup is a child presentation and must not lose its presenting view.
        profileAction.start(operation: { await store.selectNative(profile, admission: admission, finishPicker: false) },
                            failureMessage: { store.nativeProfileError ?? "Couldn't open this profile. Tap it to try again." },
                            onSuccess: {
                                guard CredentialScopeRegistry.shared.isCurrent(admission.credential),
                                      store.activeID == profile.id,
                                      core.hasCertifiedNativeSession(capture: admission.credential, profileID: profile.id) else { return }
                                deferredSelection.cancel()
                                account.reloadForActiveProfile()
                                if core.nativeAccountMode(profileID: profile.id) == "pending_own" {
                                    signInCredential = admission.credential; signInProfileID = profile.id
                                    signInNeeded = true
                                } else { store.pickedThisLaunch = true }
                            })
    }
}

/// A bounded public Cinemeta movie candidate. It deliberately carries no profile, account, history,
/// addon or playback state, so the pre-profile picker has no dependency on the profile being opened.
private struct ProfilePickerMovie: Identifiable, Hashable {
    let id: String
    let name: String
    let poster: String?
    let background: String?

    var artworkURLs: [String] {
        ArtworkFallbackPolicy.candidates([background, poster])
    }

    var firstPaintArtworkURLs: [String] {
        // Do not put a large backdrop's timeout ahead of the public poster's first paint.
        ArtworkFallbackPolicy.candidates([poster, background])
    }

    var cacheKey: String {
        "\(id)|\(background ?? "")|\(poster ?? "")"
    }
}

/// Keeps the previous decoded image until the next bounded candidate is warm in PosterImageLoader's cache.
/// The identity transition then cross-fades the two layers without a blank frame on a rotation tick.
private struct ProfilePickerBackdrop: View {
    let movie: ProfilePickerMovie?
    @ReducedMotion private var reduceMotion
    @State private var image: VXPosterImage?
    @State private var imageKey = ""

    private var synchronousCache: VXPosterImage? {
        guard let movie else { return nil }
        for raw in movie.artworkURLs {
            guard let url = URL(string: raw),
                  let cached = PosterImageLoader.cached(url, maxPixel: ProfilePickerArtwork.artworkMaxPixel) else {
                continue
            }
            return cached
        }
        return nil
    }

    var body: some View {
        Color.clear
            .overlay {
                ZStack {
                    if let image = image ?? synchronousCache {
                        imageView(image)
                            .id(imageKey)
                            .transition(.opacity)
                    } else {
                        Theme.Palette.surface1
                    }
                }
            }
            .clipped()
            .task(id: movie?.cacheKey) {
                guard let movie else { return }
                let loaded: VXPosterImage?
                if let cached = synchronousCache {
                    // Prefer a prewarmed landscape background, or an already-decoded poster,
                    // without awaiting an uncached URL earlier in the normal quality order.
                    loaded = cached
                } else {
                    loaded = await ArtworkFallbackPolicy.firstAvailable(movie.firstPaintArtworkURLs) {
                        await PosterImageLoader.load($0, maxPixel: ProfilePickerArtwork.artworkMaxPixel)
                    }
                }
                guard !Task.isCancelled, let loaded else { return }
                let key = movie.cacheKey
                if reduceMotion {
                    image = loaded
                    imageKey = key
                } else {
                    withAnimation(.easeInOut(duration: 0.8)) {
                        image = loaded
                        imageKey = key
                    }
                }
            }
    }

    @ViewBuilder
    private func imageView(_ image: VXPosterImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        #else
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        #endif
    }
}

/// Background art is public, not a peek into the previous profile's viewing history or add-ons.
/// One bounded public catalog request per app launch, independent of profile opening.
@MainActor
private final class ProfilePickerArtwork: ObservableObject {
    static let shared = ProfilePickerArtwork()

    private static let candidateLimit = 12
    private static let publicSeedByteLimit = 32_768
    private static let publicSeedLifetime: TimeInterval = 30 * 24 * 60 * 60

    // Cache only public Family-catalog metadata. This lives in purgeable Caches, not account
    // defaults/backups, and contains no owner/profile/history/add-on configuration or signed URL.
    private struct PublicSeed: Codable {
        let version: Int
        let savedAt: Date
        let movies: [PublicMovie]
    }

    private struct PublicMovie: Codable {
        let id: String
        let name: String
        let poster: String
    }

    private static var publicSeedURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("vortx-profile-picker-public-v1.json")
    }
    private static let rotationIntervalNanoseconds: UInt64 = 5_000_000_000
    // Keep the rotating picker bounded to full HD on TV, without a 4K prefetch queue.
    fileprivate static let artworkMaxPixel: CGFloat = {
        #if os(tvOS)
        return CGFloat(HeroArtworkQualityPolicy.fullHDLongEdge)
        #else
        return CGFloat(HeroArtworkQualityPolicy.mobileLongEdge)
        #endif
    }()

    @Published private(set) var movie: ProfilePickerMovie?
    private var candidates: [ProfilePickerMovie] = []
    private var catalogRequest: Task<[ProfilePickerMovie], Never>?
    private var didAttemptCatalog = false
    private var currentIndex = 0
    private var readyIDs = Set<String>()
    private var unavailableIDs = Set<String>()
    private var rotationTask: Task<Void, Never>?
    private var prewarmTask: Task<Bool, Never>?
    private var rotationToken = UUID()

    private init() {
        candidates = Self.readPublicSeed()
        // Publish public metadata synchronously. ProfilePickerBackdrop can begin its own existing
        // cache-first load immediately; it must not wait behind a fresh catalog request.
        if let index = candidates.firstIndex(where: { Self.hasDecodedArtwork($0) }) ?? candidates.indices.first {
            currentIndex = index
            movie = candidates[index]
        }
    }

    deinit {
        catalogRequest?.cancel()
        rotationTask?.cancel()
        prewarmTask?.cancel()
    }

    func load() async {
        if !didAttemptCatalog {
            didAttemptCatalog = true
            let preferredID = movie?.id
            catalogRequest = Task { await Self.fetchCandidates(preferredID: preferredID) }
        }
        // A warm singleton or disk-restored public seed is already usable. Refreshing public
        // metadata continues independently and must not postpone first paint or rotation.
        if movie != nil { return }
        guard let catalogRequest else { return }
        let fetched = await catalogRequest.value
        guard !Task.isCancelled else { return }
        if candidates.isEmpty {
            candidates = fetched
        }
        guard movie == nil, !Task.isCancelled else { return }
        await showInitialCandidate()
    }

    func startRotation(reduceMotion: Bool) {
        rotationTask?.cancel()
        rotationTask = nil
        rotationToken = UUID()
        guard !reduceMotion, candidates.count > 1, movie != nil else { return }

        let token = rotationToken
        rotationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: ProfilePickerArtwork.rotationIntervalNanoseconds)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, self.rotationToken == token else { return }
                await self.rotate(token: token)
            }
        }
    }

    func stopRotation() {
        rotationToken = UUID()
        rotationTask?.cancel()
        rotationTask = nil
        prewarmTask?.cancel()
        prewarmTask = nil
    }

    private func rotate(token: UUID) async {
        guard rotationToken == token, candidates.count > 1 else { return }
        if let prewarmTask {
            _ = await prewarmTask.value
            guard rotationToken == token, !Task.isCancelled else { return }
            self.prewarmTask = nil
        }
        // Walk the finite pool once. A failed candidate is negative-cached for this session, so a
        // rotation tick never retries the same unavailable URL or expands the request set.
        for offset in 1..<candidates.count {
            guard rotationToken == token, !Task.isCancelled else { return }
            let index = (currentIndex + offset) % candidates.count
            let loaded = await preload(candidates[index])
            guard rotationToken == token, !Task.isCancelled else { return }
            if loaded {
                currentIndex = index
                movie = candidates[index]
                prewarmNext(after: index)
                return
            }
        }
    }

    private func showInitialCandidate() async {
        guard !candidates.isEmpty, !Task.isCancelled else { return }
        let shuffled = candidates.indices.shuffled()
        let decoded = shuffled.filter { Self.hasDecodedArtwork(candidates[$0]) }
        let cold = shuffled.filter { !Self.hasDecodedArtwork(candidates[$0]) }
        for index in decoded + cold {
            if await preload(candidates[index], firstPaint: true) {
                guard !Task.isCancelled else { return }
                currentIndex = index
                movie = candidates[index]
                Self.writePublicSeed(candidates, preferredID: candidates[index].id)
                prewarmNext(after: index)
                return
            }
        }
    }

    private func prewarmNext(after index: Int) {
        prewarmTask?.cancel()
        guard candidates.count > 1 else {
            prewarmTask = nil
            return
        }
        let next = candidates[(index + 1) % candidates.count]
        prewarmTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.preload(next)
        }
    }

    private func preload(_ candidate: ProfilePickerMovie, firstPaint: Bool = false) async -> Bool {
        if readyIDs.contains(candidate.id) {
            let remainsDecoded = candidate.artworkURLs.contains { raw in
                guard let url = URL(string: raw) else { return false }
                return PosterImageLoader.cached(url, maxPixel: Self.artworkMaxPixel) != nil
            }
            if remainsDecoded { return true }
            // The bounded decoded LRU may evict an older rotation candidate. The ID is only a
            // hint; force the shared loader through its cache/URLCache path again before use.
            readyIDs.remove(candidate.id)
        }
        // The preferred initial candidate may already be decoded without a readyIDs hint.
        // Do not await a cold poster when its landscape background is already ready (or vice versa).
        if Self.hasDecodedArtwork(candidate) {
            readyIDs.insert(candidate.id)
            return true
        }
        if unavailableIDs.contains(candidate.id) { return false }
        let image = await ArtworkFallbackPolicy.firstAvailable(firstPaint ? candidate.firstPaintArtworkURLs : candidate.artworkURLs) {
            await PosterImageLoader.load($0, maxPixel: Self.artworkMaxPixel)
        }
        // Cancellation is not a real art failure; do not poison this candidate for the next visible
        // picker session if the current view disappeared while its request was in flight.
        guard !Task.isCancelled else { return false }
        guard image != nil else {
            unavailableIDs.insert(candidate.id)
            return false
        }
        readyIDs.insert(candidate.id)
        return true
    }

    private static func hasDecodedArtwork(_ candidate: ProfilePickerMovie) -> Bool {
        candidate.artworkURLs.contains { raw in
            guard let url = URL(string: raw) else { return false }
            return PosterImageLoader.cached(url, maxPixel: Self.artworkMaxPixel) != nil
        }
    }

    private static func publicMovieID(_ id: String) -> Bool {
        guard id.hasPrefix("tt") else { return false }
        let digits = id.dropFirst(2)
        return (5...12).contains(digits.count) && digits.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func publicPoster(_ raw: String?, id: String) -> String {
        if let raw, raw.utf8.count <= 2_048, let url = URLComponents(string: raw),
           url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
           url.query == nil, url.fragment == nil, url.port == nil || url.port == 443,
           ["images.metahub.space", "live.metahub.space", "image.tmdb.org"].contains(url.host?.lowercased() ?? "") {
            return raw
        }
        // Reconstruct from a validated public IMDb identifier rather than persisting unknown,
        // token-bearing or account-specific artwork endpoints received in catalog metadata.
        return "https://images.metahub.space/poster/medium/\(id)/img"
    }

    private static func readPublicSeed() -> [ProfilePickerMovie] {
        guard let url = publicSeedURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= publicSeedByteLimit,
              let data = try? Data(contentsOf: url), data.count <= publicSeedByteLimit,
              let seed = try? JSONDecoder().decode(PublicSeed.self, from: data), seed.version == 1,
              seed.movies.count <= candidateLimit else { return [] }
        let age = Date().timeIntervalSince(seed.savedAt)
        guard age >= -60, age <= publicSeedLifetime else { return [] }
        var seen = Set<String>()
        return seed.movies.compactMap { entry in
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard publicMovieID(entry.id), !name.isEmpty, name.utf8.count <= 800,
                  seen.insert(entry.id).inserted else { return nil }
            return ProfilePickerMovie(id: entry.id, name: name,
                                      poster: publicPoster(entry.poster, id: entry.id),
                                      background: "https://images.metahub.space/background/big/\(entry.id)/img")
        }
    }

    private static func writePublicSeed(_ candidates: [ProfilePickerMovie], preferredID: String?) {
        guard let url = publicSeedURL else { return }
        let ordered = candidates.filter { $0.id == preferredID } + candidates.filter { $0.id != preferredID }
        var seen = Set<String>()
        let movies = ordered.compactMap { candidate -> PublicMovie? in
            let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard publicMovieID(candidate.id), !name.isEmpty, name.utf8.count <= 800,
                  seen.insert(candidate.id).inserted else { return nil }
            return PublicMovie(id: candidate.id, name: name, poster: publicPoster(candidate.poster, id: candidate.id))
        }
        let seed = PublicSeed(version: 1, savedAt: Date(), movies: Array(movies.prefix(candidateLimit)))
        guard !seed.movies.isEmpty, let data = try? JSONEncoder().encode(seed),
              data.count <= publicSeedByteLimit else { return }
        // Cache failure is cosmetic only; never reset account data or block the picker.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func fetchCandidates(preferredID: String?) async -> [ProfilePickerMovie] {
        let client = AddonClient()
        guard let titles = try? await client.catalog(base: AddonClient.cinemeta,
                                                     type: "movie", id: "top", genre: "Family") else {
            return []
        }

        var seen = Set<String>()
        let eligible = titles.filter { title in
            guard title.type.lowercased() == "movie",
                  title.id.hasPrefix("tt"),
                  !title.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let poster = title.poster,
                  let url = URL(string: poster),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                return false
            }
            return seen.insert(title.id).inserted
        }
        let preferred = eligible.filter { $0.id == preferredID }
        let others = eligible.filter { $0.id != preferredID }.shuffled()
        let bounded = Array((preferred + others).prefix(candidateLimit))
        guard !bounded.isEmpty else { return [] }

        let movies = bounded.map { title in
            let metahub = "https://images.metahub.space/background/big/\(title.id)/img"
            return ProfilePickerMovie(id: title.id,
                                      name: title.name,
                                      poster: title.poster,
                                      background: metahub)
        }
        // Refresh for the next launch even when load() returned immediately for a warm seed.
        // A previously visible seed is retained only if it is still in this public Family catalog.
        guard !Task.isCancelled else { return [] }
        writePublicSeed(movies, preferredID: preferredID)
        return movies
    }
}

private struct ProfileAvatarTile: View {
    let profile: UserProfile
    let isCurrent: Bool
    let isEditing: Bool
    let side: CGFloat
    let nameTextSize: CGFloat
    let action: () -> Void

    private var accent: Color {
        ThemeManager.accents.first { $0.id == profile.accentID }?.base ?? Theme.Palette.accent
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ProfileAvatarFace(profile: profile, isCurrent: isCurrent, isEditing: isEditing, side: side, accent: accent)
                Text(profile.name).modifier(ProfilePickerText(size: nameTextSize, style: .headline))
                    .multilineTextAlignment(.center).lineLimit(2)
            }
            .foregroundStyle(.white)
            .frame(width: side, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(ProfilePickerButtonStyle(outline: false))
        .accessibilityLabel(isEditing ? "Edit \(profile.name)" : profile.name)
        .accessibilityValue(profile.hasPin ? "PIN required" : (isCurrent ? "Current profile" : ""))
        .accessibilityIdentifier("profile-tile-\(profile.id.uuidString)")
    }
}

/// This reader is inside the Button label, where the remote's focus environment is available.
private struct ProfileAvatarFace: View {
    let profile: UserProfile
    let isCurrent: Bool
    let isEditing: Bool
    let side: CGFloat
    let accent: Color
    @Environment(\.isFocused) private var focused
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: side * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [accent, accent.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(profile.avatar).font(.system(size: side * 0.53))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if profile.hasPin || isEditing || isCurrent {
                Image(systemName: isEditing ? "pencil" : (profile.hasPin ? "lock.fill" : "checkmark"))
                    .font(.system(size: side * 0.16, weight: .bold))
                    .padding(7).background(.black.opacity(0.7), in: Circle()).padding(6)
            }
        }
        .frame(width: side, height: side)
        .overlay(RoundedRectangle(cornerRadius: side * 0.23, style: .continuous)
            .strokeBorder(.white.opacity(focused ? 1 : 0.15), lineWidth: focused ? 4 : 1))
    }
}

private struct ProfilePickerText: ViewModifier {
    @EnvironmentObject private var theme: ThemeManager
    @ScaledMetric private var size: CGFloat
    let design: Font.Design
    init(size: CGFloat, style: Font.TextStyle, design: Font.Design = .rounded) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.design = design
    }
    func body(content: Content) -> some View {
        content.font(.system(size: size * theme.textScale, weight: .semibold, design: design))
    }
}

private struct ProfilePickerActionTile: View {
    let title: String
    let symbol: String
    let side: CGFloat
    let nameTextSize: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: side * 0.40, weight: .light))
                    .frame(width: side, height: side)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: side * 0.23, style: .continuous))
                Text(title).modifier(ProfilePickerText(size: nameTextSize, style: .headline))
            }
            .foregroundStyle(.white)
            .frame(width: side, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(ProfilePickerButtonStyle())
        .accessibilityLabel(title == "Add" ? "Add profile" : title)
    }
}

private struct ProfilePickerButtonStyle: ButtonStyle {
    var outline = true
    func makeBody(configuration: Configuration) -> some View {
        ProfilePickerButtonContent(configuration: configuration, outline: outline)
    }
}

private struct ProfilePickerButtonContent: View {
    let configuration: ButtonStyleConfiguration
    let outline: Bool
    @Environment(\.isFocused) private var focused
    @ReducedMotion private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : (focused && !reduceMotion ? 1.04 : 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: focused)
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(focused && outline ? 0.8 : 0), lineWidth: 2))
    }
}

/// A full-screen account form needs its own way back to the picker, including before sign-in.
private struct ProfileAccountRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("VortX account").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered)
            }
            .padding()
            SyncSettingsView(onSignedIn: { dismiss() })
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
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
    @AccessibilityFocusState private var pinAccessibilityFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: Theme.Space.lg) {
                        Text("Enter PIN for \(profile.name)")
                            .font(Theme.Typography.sectionTitle)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        SecureField("PIN", text: $input)
                            .font(Theme.Typography.body)
                            .numberPadKeyboard()
                            .frame(maxWidth: 360)
                            .accessibilityLabel("Enter your four-digit PIN")
                            .accessibilityFocused($pinAccessibilityFocused)
                            .onValueChange(of: input) { _ in
                                input = String(input.filter(\.isNumber).prefix(4))
                                wrong = false
                            }
                        if wrong {
                            Text("Wrong PIN").font(Theme.Typography.label).foregroundStyle(Theme.Palette.danger)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Theme.Space.md) { pinActions }
                            VStack(spacing: Theme.Space.md) { pinActions }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 560)
                    .vortxGlassPanel(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear { pinAccessibilityFocused = true }
    }

    @ViewBuilder private var pinActions: some View {
        Button("Unlock") {
            if profile.pinMatches(input) { onUnlock() } else { wrong = true }
        }
        .buttonStyle(PrimaryActionStyle())
        .disabled(input.count != 4)
        Button("Cancel", action: onCancel)
            .buttonStyle(ChipButtonStyle(selected: false))
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
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @ObservedObject private var nativeSync = VortXSyncManager.shared

    @State private var draft: UserProfile
    @State private var pinText: String
    @State private var customAvatar = ""
    @State private var confirmDelete = false
    @State private var switchPinPrompt = false   // PIN gate when switching INTO a locked profile
    @State private var accountHelpNeeded = false
    @State private var signInNeeded = false      // an own-account profile with no stored token
    @StateObject private var profileAction = ProfileMutationPresentation()

    private var isNew: Bool { !store.profiles.contains { $0.id == original.id } }

    private var usesWideEditorLayout: Bool {
        #if os(tvOS)
        return true
        #elseif os(macOS)
        return true
        #else
        return horizontalSizeClass == .regular
        #endif
    }

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
                LazyVStack(alignment: .leading, spacing: usesWideEditorLayout ? Theme.Space.xl : Theme.Space.md) {
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
                            .onValueChange(of: customAvatar) { _ in
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
                        Text("Your main profile. Other profiles keep their own watch history.")
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
                            if !isNew && draft.usesOwnAccount == original.usesOwnAccount {
                                let pending = core.nativeAccountMode(profileID: draft.id) == "pending_own"
                                if nativeSync.nativeOwnAccountOverlayPending.contains(draft.id) {
                                    Text(nativeSync.nativeOwnAccountOverlayUnattributed.contains(draft.id)
                                         ? "These older updates have no verified account link and remain pending. Connecting another account will not import them. Current library and history remain available."
                                         : "Older updates for this profile are still pending verification. Reconnect the original account; current library and history have not been replaced.")
                                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                                }
                                if pending || nativeSync.nativeOwnAccountResyncUnavailable.contains(draft.id)
                                    || (store.activeID == draft.id && !account.isSignedIn) {
                                    Text(pending ? "Connect an account to start this independent profile."
                                         : "Saved library and history are available. Reconnect to refresh from the external account.")
                                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                                }
                                Button(pending ? "Connect account" : "Connect or change account") {
                                    let admission = core.captureNativeProfileActionAdmission()
                                    profileAction.start(operation: {
                                        if store.activeID == draft.id, core.nativePlaybackTargetIsCurrent(admission.target) { return true }
                                        return await store.selectNative(original, admission: admission)
                                    }, failureMessage: { store.nativeProfileError ?? "Profile could not be opened." }, onSuccess: {
                                        account.reloadForActiveProfile(); signInNeeded = true
                                    })
                                }.buttonStyle(ChipButtonStyle(selected: false))
                            } else {
                                Text("Save this account choice, then open the profile to connect. Existing account libraries remain separate.")
                                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                            }
                        } else {
                            Text("Uses the same add-ons, but keeps its own watch history.")
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
                            .onValueChange(of: pinText) { _ in
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
                        Button(profileAction.isRunning ? "Saving…" : "Save") { save() }
                            .buttonStyle(PrimaryActionStyle())
                            .disabled(!canSave)
                        Button("Cancel") { dismiss() }
                            .buttonStyle(ChipButtonStyle(selected: false))
                        if canDeleteProfile {
                            Button("Delete Profile", role: .destructive) { confirmDelete = true }
                                .buttonStyle(ChipButtonStyle(selected: false))
                        }
                    }
                    .padding(.top, Theme.Space.md)
                    .profileFocusSection()
                    if let error = profileAction.errorMessage {
                        Text(error).font(Theme.Typography.label).foregroundStyle(.red)
                        Button("Try again") {
                            core.refreshNativeProfileEditBinding(draft.id)
                            save()
                        }.buttonStyle(ChipButtonStyle(selected: false))
                        Button("Account settings") { accountHelpNeeded = true }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }
                .frame(maxWidth: usesWideEditorLayout ? 900 : .infinity, alignment: .leading)
                .padding(usesWideEditorLayout ? Theme.Space.screenInset : Theme.Space.sm)
            }
            // Unfocusable while the lock is up, so the remote lands in the lock panel (tvOS focus
            // won't enter an overlay while anything beneath stays focusable).
            .disabled(isLocked || profileAction.isRunning)
            .accessibilityHidden(isLocked)

            if isLocked { lockedPanel }
        }
        .confirmationDialog("Delete \(original.name)? Its settings and sign-in are removed.",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let admission = core.captureNativeProfileActionAdmission()
                profileAction.start(operation: { await store.removeNative(original, admission: admission) },
                                    failureMessage: { store.nativeProfileError ?? "Profile could not be removed. Please retry." },
                                    onSuccess: { dismiss() })
            }
        }
        .profileCover(isPresented: $accountHelpNeeded) {
            ProfileAccountRecoveryView().environmentObject(VortXSyncManager.shared)
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
        .interactiveDismissDisabled(profileAction.isRunning)
        .onDisappear { profileAction.cancel() }
    }

    /// The store is the authorization source, not the editable draft or the caller's original copy. Hide the
    /// destructive control for both owner identities and when the target has already disappeared.
    private var canDeleteProfile: Bool {
        guard !isNew, store.profiles.count > 1,
              let target = store.profiles.first(where: { $0.id == original.id }) else { return false }
        return !target.isOwner && target.id != UserProfile.ownerID
    }

    /// Shown instead of the form for a non-active profile: editing is only allowed from within that
    /// profile. The door to editing stays closed (no PIN bypass), but the user can SWITCH to it here.
    private var lockedPanel: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: Theme.Space.lg) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 48)).foregroundStyle(Theme.Palette.accent)
                        Text("Switch to \(original.name) to edit this profile.")
                            .font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
                            .multilineTextAlignment(.center)
                        if profileAction.isRunning { ProgressView("Opening profile…") }
                        if let error = profileAction.errorMessage {
                            Text(error).font(Theme.Typography.label).foregroundStyle(.red)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Theme.Space.md) { lockedActions }
                            VStack(spacing: Theme.Space.md) { lockedActions }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 560)
                    .vortxGlassPanel(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                }
            }
            // Unfocusable while the PIN gate is up, so the remote lands in the gate (tvOS).
            .disabled(switchPinPrompt || profileAction.isRunning)
            .accessibilityHidden(switchPinPrompt)

            if switchPinPrompt {
                PinGateOverlay(profile: original,
                               onUnlock: { switchPinPrompt = false; commitSwitch() },
                               onCancel: { switchPinPrompt = false })
            }
        }
    }

    @ViewBuilder private var lockedActions: some View {
        Button("Switch profile") {
            if original.hasPin { switchPinPrompt = true } else { commitSwitch() }
        }
        .buttonStyle(PrimaryActionStyle())
        Button("Cancel") { dismiss() }.buttonStyle(ChipButtonStyle(selected: false))
    }

    /// Switch the active profile to this (locked) one, mirroring ProfilePickerView.commit: select it,
    /// then reload the account/engine and unlock its editor. A PIN-protected profile prompts
    /// for its PIN first (switchPinPrompt). On .needsSignIn the editor presents sign-in (Option B)
    /// instead of dismissing into a signed-out profile.
    private func commitSwitch() {
        let admission = core.captureNativeProfileActionAdmission()
        profileAction.start(operation: { await store.selectNative(original, admission: admission, finishPicker: false) },
                            failureMessage: { store.nativeProfileError ?? "Profile could not be opened. Please retry." },
                            onSuccess: {
                                account.reloadForActiveProfile()
                                if core.nativeAccountMode(profileID: original.id) == "pending_own" { signInNeeded = true }
                            })
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
        let admission = core.captureNativeProfileActionAdmission()
        let profile = draft, creating = isNew, preferenceBaseline = original
        profileAction.start(operation: { await store.saveNative(profile, creating: creating, admission: admission, preferenceBaseline: preferenceBaseline) },
                            failureMessage: { store.nativeProfileError ?? "Profile could not be saved. Please retry." },
                            onSuccess: { dismiss() })
    }

    @ViewBuilder private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        let rowBody = VStack(alignment: .leading, spacing: Theme.Space.sm) {
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
        if usesWideEditorLayout {
            rowBody
                .padding(Theme.Space.md)
                .vortxCinemaCard()
                .profileFocusSection()
        } else {
            rowBody
                .padding(.vertical, Theme.Space.xs)
                .profileFocusSection()
        }
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
                        // Selection is carried by the direct circle stroke; the touch/Mac picker should
                        // not add a second rectangular focus platter around the color control.
                        .buttonStyle(.plain)
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
