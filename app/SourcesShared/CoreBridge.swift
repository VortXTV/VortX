import Foundation
import StremioXCore

/// Bridges the native Rust **stremio-core** engine (StremioXCore.xcframework) to Swift.
///
/// The engine owns catalogs, library, Continue-Watching, meta and streams, the same way the official
/// app does. We dispatch JSON actions into it, read JSON state out, and it calls us back (on a Rust
/// worker thread) whenever model fields change, so the UI can re-pull exactly what changed.
final class CoreBridge: ObservableObject {
    static let shared = CoreBridge()

    /// Bumped on every `RuntimeEvent::NewState`; SwiftUI observes this to refresh. `changedFields`
    /// holds the field names that changed since the last bump (e.g. ["board", "ctx"]).
    @Published private(set) var revision = 0
    private(set) var changedFields: Set<String> = []

    /// Decoded screen state, refreshed on the main queue as the engine emits field changes.
    @Published private(set) var continueWatching: [CoreCWItem] = []
    @Published private(set) var boardRows: [CoreBoardRow] = []
    @Published private(set) var metaDetails: CoreMetaDetails?
    /// Request-owned terminal refresh receipt. Unlike a global meta event count, this can only be populated
    /// by the exact two-phase Apple CW refresh that invalidated the resident meta and then settled its own
    /// Load generation. This is a request-completion receipt, not a full-series completeness proof.
    /// Main-queue writes only.
    private(set) var appleCWMetaRefreshReceipt: AppleCWMetaRefreshReceipt?
    /// The exact settled payload paired with `appleCWMetaRefreshReceipt`. Players consume this snapshot,
    /// not a later global `metaDetails` re-emit that might belong to another source/progress event.
    private(set) var appleCWMetaRefreshDetails: CoreMetaDetails?
    /// Monotonic epoch of the READY-STREAM SET for the loaded meta. Bumps ONLY when the coalesced
    /// `meta_details` republish actually changed the loaded meta id or the per-group ready-stream
    /// signature (or on an explicit load/unload that cleared it), never on a library/progress-only
    /// republish and never on the raw `revision` storm. `SourceListModel` keys its O(1) rebuild
    /// signature on this instead of hashing every stream, so a source-search burst costs the source
    /// list nothing until streams really changed. Main-queue writes only.
    @Published private(set) var streamsEpoch = 0
    @Published private(set) var discover: CoreDiscover?
    @Published private(set) var library: CoreLibrary?
    @Published private(set) var searchResults: [CoreMeta] = []
    @Published private(set) var searchIsLoading = false
    @Published private(set) var searchSuggestions: [CoreSearchSuggestion] = []
    @Published private(set) var addons: [CoreDescriptor] = []

    /// Raw addon descriptors keyed by transportUrl, kept so we can round-trip a full Descriptor back
    /// to the engine for UninstallAddon (which takes the whole descriptor, not just a URL).
    private var rawAddonsByUrl: [String: [String: Any]] = [:]

    /// Short-lived cache of a manifest preview so QR preview -> confirmed install uses the same guarded
    /// response instead of fetching a mutable/remote URL twice. The cache is consume-once and bounded.
    private var manifestPreviewCache: [String: (manifest: [String: Any], canonicalURL: String, fetchedAt: Date)] = [:]
    private static let manifestCacheTTL: TimeInterval = 60
    private static let manifestCacheCap = 64
    private var started = false
    /// Coalesces the Home-board rebuild. The engine emits a BURST of `board` events during launch and while a
    /// catalog page lands (one per catalog settling), and each event used to trigger a full `buildBoardRows()`
    /// JSON decode + a `boardRows` republish + a hero reseed, which was a real main-thread stall on open. This
    /// timer collapses a burst into a single trailing rebuild ~80 ms after the last event, so the board still
    /// updates but only once per burst. Touched only on the main actor.
    private var boardRebuildWork: DispatchWorkItem?
    private static let boardRebuildDebounce: TimeInterval = 0.08
    /// Raw catalog count from the engine board. Hidden, disabled, empty, and failed rows are filtered
    /// out of `boardRows`, so their visible count cannot decide whether vertical pagination is finished.
    private var boardCatalogTotal = 0
    /// Coalesces the `meta_details` re-decode+publish. Source search for a high-source title emits a BURST
    /// of `meta_details` events as stream batches land (GoT: ~11 re-emits of the same 1757-row payload as it
    /// grows), and each used to run a full off-main decode + a main-thread republish, invalidating every
    /// view subscribed to CoreBridge (including the presented player). This timer collapses a burst into one
    /// trailing decode ~90 ms after the last emit, and the decode then DIFFS against the stored value so an
    /// identical re-emit republishes nothing. An episode switch still lands within one debounce window (well
    /// inside the in-player 20s / 250ms poll), so next-episode / binge is unaffected. Touched only on main.
    private var metaDetailsWork: DispatchWorkItem?
    private static let metaDetailsDebounce: TimeInterval = 0.09
    private struct AppleCWMetaRefreshRequest {
        enum Phase {
            case awaitingInvalidation
            case awaitingLoadSettlement
        }

        let generation: Int
        let type: String
        let libraryID: String
        let streamType: String?
        let streamID: String
        var phase: Phase
    }
    private var appleCWMetaRefreshGeneration = 0
    private var appleCWMetaRefreshRequest: AppleCWMetaRefreshRequest?
    /// `rebuildContinueWatching` decodes on whichever engine worker delivered the event, then publishes on main.
    /// Fence those asynchronous publications so a slower, older snapshot cannot overwrite a newer rebuild.
    private let continueWatchingRebuildLock = NSLock()
    private var continueWatchingRebuildGeneration = 0

    /// Re-find sources ("Re-find sources" control). A plain re-Load of the same meta is an engine
    /// eq_update no-op with ZERO add-on HTTP, so the only way to make expired sources get replaced is
    /// Unload -> (await the nil meta_details receipt) -> Load. This is the MINIMAL twin of the Apple CW
    /// authoritative refresh: it carries NO completion receipt and NO Continue-Watching bookkeeping, and
    /// its `streamID` is OPTIONAL so a MOVIE (no episode stream path) re-finds too. One-shot: once the
    /// nil receipt re-dispatches the exact Load, the request clears and the ordinary republish takes over.
    private struct RefindRequest {
        let generation: Int
        let type: String
        let id: String
        let streamType: String?
        let streamID: String?
        var awaitingInvalidation: Bool
    }
    private var refindGeneration = 0
    private var refindRequest: RefindRequest?
    /// True while we're seeding the engine from the old app's authKey and waiting for the user fetch.
    private var awaitingAuthMigration = false
    /// Set while a profile account switch is in flight: the uid we're leaving (nil = was signed out).
    private var switchInFlight = false
    private var switchFromUID: String?

    // MARK: Player-active gating (playback lag fix)
    //
    // A high-source title (e.g. GoT S2E1: 1757 streams across 17 groups) makes source search re-emit
    // `meta_details` a dozen-plus times as batches land, and a single ~20s progress save re-emits both
    // `library` and `meta_details`. The library branch decoded the whole 1757-stream payload on the
    // worker thread only to update the In-Library button. During playback the detail page is covered
    // (Mac leaves it mounted at opacity 0), so that decode is pure waste and starved the main thread,
    // which is what stalled the mpv Metal surface. `playerActive` (a depth counter so a trailer-over-
    // detail then a real player, or a teardown straddle, can't clear it early) lets the library branch
    // skip that In-Library re-decode while a player is up. It does NOT gate the primary meta_details
    // republish: in-player episode switching / binge auto-advance load a NEW meta and poll
    // streamGroups(forStreamId:), which reads the stored metaDetails, so that republish must keep
    // landing. Toggled from PlayerScreen (iOS/Mac) and TVPlayerView (tvOS) on appear/disappear.
    @Published private(set) var playerActive = false
    private var playerActiveDepth = 0

    /// Increment/decrement the player-active depth on the MAIN actor and publish `playerActive`.
    /// Balanced calls from each player host's onAppear (+1) and onDisappear (-1); the depth counter
    /// keeps it true across a nested trailer→player mount and a teardown straddle.
    func setPlayerActive(_ on: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.playerActiveDepth = max(0, self.playerActiveDepth + (on ? 1 : -1))
            let active = self.playerActiveDepth > 0
            if self.playerActive != active { self.playerActive = active }
        }
    }

    /// The Keychain slot holding the ACTIVE profile's session key (shared profiles use the primary
    /// slot, own-account profiles their own). Resolved per read so a profile switch re-points it.
    private var activeTokenAccount: String { ProfileStore.shared.activeKeychainAccount }

    /// Wave 4: this device has imported its Stremio-owned library into the VortX account AND is not opted into
    /// two-way Stremio sync, so the engine must run purely LOCAL: never seed / re-auth the Stremio token, never
    /// pull from api.strem.io. BOTH bootstrapAuth and scheduleSessionRepair gate on this so neither re-establishes
    /// a Stremio session behind the migration (the logout / re-login ping-pong that would defeat the import).
    /// Computed from the Keychain token + the per-account import flag + the opt-in. After the post-import Logout
    /// the (now server-dead) token is cleared, so there is no token and this reads false: the device is then
    /// simply signed out of Stremio and takes the signed-out recovery path.
    private var importedAwayFromStremio: Bool {
        guard let token = Keychain.string(activeTokenAccount), !token.isEmpty else { return false }
        return ProfileSync.libraryImportedFromStremio(authKey: token) && !ProfileSync.alsoSyncToStremio
    }

    private init() {}

    /// Hydrate the engine from persisted storage and start the event loop. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        let storageDir = Self.makeDir(at: Self.storageDirURL)
        let cacheDir = Self.makeDir(.cachesDirectory, "stremio-core-http")
        // The pointer is passed through but never dereferenced on the way back: the C callback
        // resolves `CoreBridge.shared` directly. An unretained pointer round-tripped through a
        // Rust worker thread would dangle if this object were ever deallocated.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let ok = storageDir.withCString { storage in
            cacheDir.withCString { cache in
                stremiox_core_init(storage, cache, ctx, coreEventCallback)
            }
        }
        if !ok { NSLog("[CoreBridge] stremiox_core_init failed"); return }
        // Bring up RemoteConfig once, on the single shared launch path every Apple target runs (VortXTV,
        // VortXTVLite, VortXiOSNative, VortXMac, VortX). Synchronously loads last-good cached JSON into the
        // lock-free snapshot (else all-baked, behaviorally identical to shipping), then kicks a background
        // refresh. Fail-soft: any error keeps baked defaults, so this never blocks or bricks launch.
        Task { await RemoteConfig.shared.bootstrap() }
        bootstrapAuth()
        seedInitialState()
        scheduleSessionRepair()   // runs on EVERY launch path: covers the force-close add-on-loss desync
    }

    /// Pull state the engine populated at construction (e.g. `continue_watching_preview` from the
    /// hydrated library), it emits no `NewState`, so capture it once after init; events keep it fresh.
    private func seedInitialState() {
        let rows = buildBoardRows()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !rows.isEmpty { self.boardRows = rows }
        }
        // Seed Continue Watching through the SAME union path events use, so a cold / migrated device that
        // re-added its owner library at time 0 still paints the rail from OwnerResumeStore instead of blank
        // (#149), rather than only reflecting the engine's own (empty) continue_watching_preview here.
        rebuildContinueWatching()
        refreshAddons()
    }

    /// Refresh the installed-addons list (and the raw descriptors for uninstall) from ctx.profile.
    ///
    /// TOMBSTONE ENFORCEMENT (the load-bearing removal-sticks guard): `refreshAddons` is the SINGLE
    /// point where the engine's ctx add-on set is published, and it fires on EVERY ctx change, including
    /// after the live Stremio import path (`PullAddonsFromAPI` / `switchAccount` / `refreshFromAPI`),
    /// which re-installs the whole Stremio add-on collection into the engine ctx, a tombstoned add-on
    /// among them. The `syncDown` tombstone loop only runs on a strictly-newer account `.doc` pull, so a
    /// Stremio import re-adds a dashboard-deleted add-on into the LIVE engine with no sync-doc pull to
    /// catch it (the "keeps showing installed / reappeared in Stremio" bug). We close that here: any ctx
    /// add-on that is in the durable removal set (`AddonTombstones`, which already folded in the web
    /// dashboard's `doc.webAddonRemovals` + `doc.vortx.deletedAddons` on syncDown) and is NOT
    /// official/protected is uninstalled from the engine and dropped from the published set, so a
    /// dashboard deletion is honored the instant the engine re-surfaces it, on every ctx path, not only
    /// on sync-down. A genuine fresh RE-install later still works: `installAddon` (the single hardened
    /// installer every UI routes through) calls `AddonTombstones.forget` BEFORE dispatching InstallAddon
    /// (#205), so the URL has already left the set when this function sees the new ctx and the add-on is
    /// NOT suppressed here. The same holds for an explicit Stremio reconnect (`signedInWithLegacyAuthKey`
    /// clears the removal set before the account import).
    private func refreshAddons() {
        let typed = decode(CoreCtx.self, field: "ctx")?.profile.addons ?? []
        // A synced order can arrive before OR after the final add-on hydrate. Keep the full-range intent
        // alive across both sequences: if an explicit order already exists when ctx grows, widen only when
        // the new raw manifest count exceeds the range already requested. This is a LoadRange, not a full
        // board Load; stremio-core has already replanned the board on ProfileChanged.
        if !CatalogPrefsStore.order().isEmpty {
            let installedCatalogTotal = typed.reduce(0) { $0 + $1.manifest.catalogs.count }
            DispatchQueue.main.async { [weak self] in
                self?.ensureCatalogOrderRangeLoaded(installedCatalogTotal: installedCatalogTotal)
            }
        }
        var raw: [String: [String: Any]] = [:]
        if let data = stateData("ctx"),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = object["profile"] as? [String: Any],
           let addons = profile["addons"] as? [[String: Any]] {
            for addon in addons { if let url = addon["transportUrl"] as? String { raw[url] = addon } }
        }
        // Enforce durable removal tombstones at the publish point. PROTECTED stubs (Cinemeta, Local Files)
        // are NEVER tombstoned (a logout resets the engine to exactly those, and the UI has no Remove for
        // them), so this can only ever remove an add-on the user explicitly deleted: a user-installed
        // add-on OR a REMOVABLE official one (YouTube, WatchHub, Public Domain, OpenSubtitles are
        // official=true, protected=false and the engine re-seeds them on every reset, #137).
        let removed = AddonTombstones.all()
        if !removed.isEmpty {
            func isTombstoned(_ descriptor: CoreDescriptor) -> Bool {
                removed.contains(AddonTombstones.normalize(descriptor.transportUrl))
                    && !descriptor.isProtected
            }
            let toUninstall = typed.filter(isTombstoned).compactMap { raw[$0.transportUrl] }
            let survivingTyped = typed.filter { !isTombstoned($0) }
            for descriptor in typed where isTombstoned(descriptor) {
                raw.removeValue(forKey: descriptor.transportUrl)
            }
            let publishedRaw = raw
            // Uninstall the tombstoned add-ons from the engine off this event-processing thread (mirrors
            // the syncDown apply loop's @MainActor hop), so we never re-enter the engine synchronously
            // while it is emitting the ctx event we are handling. tombstone:false via a direct dispatch
            // because the URL is already in the set; re-recording would be a redundant no-op.
            //
            // Push-to-Stremio gate (owner-locked default OFF = one-way / pull-only): when a live Stremio
            // session exists, stremio-core PERSISTS an engine UninstallAddon upstream via api.strem.io
            // addonCollectionSet, so this loop is the periodic path that would delete a tombstoned add-on
            // from the user's REAL Stremio account on every ctx cycle (launch / PullAddonsFromAPI). Only
            // reconcile the engine collection when push is ON, OR when signed out of Stremio (a local-only
            // engine edit that cannot reach the account). When push is OFF + a session is live we STILL
            // drop the tombstoned add-on from the published set below (survivingTyped / publishedRaw), so
            // the user never sees it, but we leave the engine collection (and the Stremio account) intact.
            let pushDeletionsToStremio = (MirrorSettings.mirrorAddons && isLoggedIn()) || !isLoggedIn()
            if !toUninstall.isEmpty, pushDeletionsToStremio {
                Task { @MainActor [weak self] in
                    for rawDescriptor in toUninstall {
                        self?.dispatchCtx(["action": "UninstallAddon", "args": rawDescriptor])
                    }
                }
            }
            // Publish the tmdb:-meta gate from the FINAL surviving set (thread-safe UserDefaults write, no
            // self needed) so the off-main catalog resolvers gate the tmdb: fallback on real installed state.
            AddonMetaGate.publish(survivingTyped.contains { $0.providesTMDBMeta })
            DispatchQueue.main.async { [weak self] in
                self?.addons = survivingTyped
                self?.rawAddonsByUrl = publishedRaw
            }
            return
        }
        AddonMetaGate.publish(typed.contains { $0.providesTMDBMeta })
        DispatchQueue.main.async { [weak self] in
            self?.addons = typed
            self?.rawAddonsByUrl = raw
        }
    }

    /// Remove an installed addon. UninstallAddon takes a full Descriptor, so we send back the raw one
    /// the engine gave us (matched by transportUrl).
    ///
    /// `tombstone` (default true) records a DURABLE cross-device removal in `AddonTombstones` so the
    /// removal SYNCS: `vortxSummary` pushes the set into `doc.vortx.deletedAddons` and subtracts it from
    /// the `doc.vortx.addons` UNION, and `syncDown` re-applies it on peers (mirrors `deletedProfiles`).
    /// PROTECTED stubs (Cinemeta, Local Files) are NEVER tombstoned (a logout resets the engine to exactly
    /// those, so a tombstone there would wrongly suppress an essential default forever; the UI also offers
    /// no Remove for them). A REMOVABLE official add-on (YouTube, WatchHub, Public Domain, OpenSubtitles:
    /// official=true, protected=false) IS tombstoned, because the engine re-seeds OFFICIAL_ADDONS on every
    /// reset and would otherwise resurrect a user's deletion on the next launch (#137); a genuine re-add
    /// through the store clears it via `AddonTombstones.forget`. The Change-URL replace path passes
    /// `tombstone: false`: swapping a manifest URL removes the OLD url but is not a real removal, so the
    /// URL must stay re-addable on every device.
    func uninstallAddon(_ descriptor: CoreDescriptor, tombstone: Bool = true) {
        // Record the durable removal FIRST, before touching rawAddonsByUrl. A synced add-on can be visible
        // in the published `addons` list yet be MISSING from `rawAddonsByUrl` (its raw engine descriptor
        // never landed, e.g. a roster the sync layer added without an engine InstallAddon). The old
        // `guard let raw ... else { return }` made Remove a SILENT NO-OP in that case, which is exactly the
        // owner-reported "pressing delete doesn't delete." Tombstoning + refreshAddons still suppresses it.
        if tombstone, !descriptor.isProtected {
            AddonTombstones.tombstone(descriptor.transportUrl)
            // Propagate the removal to your other devices PROMPTLY. The tombstone write arms the
            // UserDefaults-didChange auto-sync, but that push is DEBOUNCED and reschedules on every write,
            // so a steady trickle of unrelated UserDefaults writes (health probes, poster caches) can starve
            // it and delay the delete from syncing for minutes (owner-reported: pressed "Sync now" on the
            // phone, it did not delete; ~5 minutes later it did). Kick an immediate, non-debounced push so
            // the tombstone lands in doc.vortx.deletedAddons right away and peers pick it up on their next pull.
            let removedUrl = descriptor.transportUrl
            Task {
                let ok = await VortXSyncManager.shared.pushThisDevice()
                NSLog("[addon] removal of %@ pushed to sync immediately (ok=%@)", removedUrl, ok ? "yes" : "no")
            }
        }
        let raw = rawAddonsByUrl[descriptor.transportUrl]
        // Push-to-Stremio gate (owner-locked default OFF = one-way / pull-only). When a live Stremio
        // session exists, stremio-core's ctx reducer PERSISTS an UninstallAddon by calling api.strem.io
        // addonCollectionSet, i.e. the deletion would propagate to the user's REAL Stremio account. That
        // is the destructive two-way delete users reported. So only dispatch the engine uninstall when
        // the "Mirror add-ons from Stremio" two-way toggle is ON, OR when there is no live Stremio session
        // (deleting from a signed-out engine is local-only and safe). When push is OFF and a session is
        // live, we keep the tombstone (the VortX-view removal) and rely on refreshAddons to suppress the
        // add-on from the published set every ctx cycle, never touching the user's Stremio account.
        // The Change-URL replace path (tombstone:false) always dispatches: swapping a manifest URL is a
        // local edit, not a real removal, and must not be blocked.
        let pushDeletionToStremio = (MirrorSettings.mirrorAddons && isLoggedIn()) || !isLoggedIn()
        if let raw, !tombstone || pushDeletionToStremio {
            dispatchCtx(["action": "UninstallAddon", "args": raw])
        } else {
            // Tombstone-only path (push OFF + live Stremio session, OR no raw descriptor to dispatch): we did
            // NOT dispatch an engine uninstall, so no ctx event will fire and refreshAddons will not re-run
            // on its own. Apply the same tombstone suppression to the CURRENTLY published set now so the
            // add-on disappears from the VortX view immediately, while the engine (and the user's Stremio
            // account) keep it. On the next real ctx event refreshAddons re-derives from the tombstone set
            // identically, so this is a pure local echo, not a divergent source of truth.
            refreshAddons()
            // Also rebuild the board now: no engine event fires on this path, and buildBoardRows filters
            // the removed add-on's rows via the tombstone set (#121), so the rebuild drops its Home rows
            // (and the catalog manager entries, which read `allCatalogs`) immediately.
            rebuildBoardRows()
        }
    }

    /// Normalize a pasted add-on URL using the shared query/fragment-safe canonical identity rule.
    func normalizedAddonURL(_ urlString: String) -> String? {
        canonicalAddonIdentity(urlString)
    }

    /// Legacy facade: nil means the engine has confirmed the add-on, while the typed path below carries
    /// already-installed/retryability information for QR acknowledgements.
    @MainActor
    func installAddon(urlString: String, replacingExisting: Bool = false) async -> String? {
        switch await installAddonConfirmed(urlString: urlString, replacingExisting: replacingExisting) {
        case .installed, .alreadyInstalled:
            return nil
        case .failed(_, let message):
            return message
        }
    }

    /// Single hardened installer used by QR. It does not report success at dispatch time: the engine roster
    /// must contain the expected descriptor first. A timeout is retryable and leaves the previous replacement
    /// intact when the new manifest never confirms.
    @MainActor
    func installAddonConfirmed(urlString: String, replacingExisting: Bool = false) async -> AddonInstallOutcome {
        // A /configure PAGE is not an installable manifest (it mints a per-user manifest only after sign-in +
        // debrid key). Normalizing it to /configure/manifest.json fetches a valid-shaped but DEAD default from
        // the add-on SDK router, so the install would "succeed" yet return no sources. Refuse it here at the
        // install boundary with configuration guidance; canonicalAddonIdentity is left unchanged (QR dedupe
        // shares it), this is an install-time gate only.
        if isAddonConfigurationPageURL(urlString) {
            return .failed(retryable: false, message: Self.addonNeedsConfigurationMessage)
        }
        guard let normalized = normalizedAddonURL(urlString), let url = URL(string: normalized) else {
            return .failed(retryable: false, message: "Enter a valid add-on URL (https://…/manifest.json).")
        }
        if addons.contains(where: { $0.transportUrl == normalized }), !replacingExisting {
            return .alreadyInstalled
        }

        let manifest: [String: Any]
        let identity: String
        if let cached = takeCachedManifest(normalized) {
            manifest = cached.manifest
            identity = cached.canonicalURL
        } else {
            switch await AddonURLGuard.fetch(url) {
            case .failure(let rejection):
                return .failed(retryable: Self.isRetryable(rejection), message: rejection.message)
            case .success(let (data, finalURL)):
                // Secondary net: a manifest URL that 3xx-redirects to a /configure page, or returns an HTML
                // page instead of a JSON manifest, is the same dead-instance trap. Guide the user to configure
                // rather than installing a dead copy (or falling through to a generic parse error).
                if isAddonConfigurationPageURL(finalURL.absoluteString) || Self.looksLikeHTMLBody(data) {
                    return .failed(retryable: false, message: Self.addonNeedsConfigurationMessage)
                }
                guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      Self.hasNonEmptyIdentity(parsed) else {
                    return .failed(retryable: false, message: "That URL did not return a valid add-on manifest.")
                }
                manifest = parsed
                identity = normalizedAddonURL(finalURL.absoluteString) ?? normalized
            }
        }
        guard let identityURL = URL(string: identity) else {
            return .failed(retryable: false, message: "That URL did not return a valid add-on manifest.")
        }

        // A redirect can land on an already-installed identity different from the submitted URL.
        let replacing = addons.contains(where: { $0.transportUrl == identity })
        if replacing, !replacingExisting { return .alreadyInstalled }
        let previousManifest: [String: Any]? = replacing
            ? (rawAddonsByUrl[identity]?["manifest"] as? [String: Any]) : nil
        if replacing, let existing = rawAddonsByUrl[identity] {
            dispatchCtx(["action": "UninstallAddon", "args": existing])
        }

        // The descriptor is installed under the guarded final identity, never the unvalidated redirect source.
        let descriptor: [String: Any] = [
            "transportUrl": identityURL.absoluteString,
            "manifest": manifest,
            "flags": ["official": false, "protected": false],
        ]
        // Clear any prior removal tombstone BEFORE dispatching the install (#205): refreshAddons fires on
        // the ctx change InstallAddon produces, and it uninstalls any non-protected ctx add-on that is
        // still in the durable removal set. Forgetting only AFTER confirmation (the old order) meant the
        // freshly installed add-on was suppressed and uninstalled in that same ctx cycle, confirmation
        // could never succeed, the tombstone was never cleared, and every retry of a previously removed
        // URL failed with "Install did not confirm". An explicit user install is intent to have the
        // add-on, the same authority the Library add path uses to supersede LibraryTombstones. If the
        // install itself fails, the user can remove the add-on again, which re-tombstones it.
        AddonTombstones.forget(identityURL.absoluteString)
        dispatchCtx(["action": "InstallAddon", "args": descriptor])

        guard await awaitAddonInstalled(identity, replacingManifest: previousManifest, expectedManifest: manifest) else {
            return .failed(retryable: true, message: "Install did not confirm. Check your connection and try again.")
        }
        return .installed
    }

    struct AddonManifestPreview: Equatable {
        let normalizedURL: String
        let name: String
        let alreadyInstalled: Bool
    }

    /// Typed preview used by the durable QR reducer. It caches a guarded, final-redirect identity for the
    /// following install, while the legacy optional facade below preserves existing callers' behavior.
    @MainActor
    func previewAddonManifestResult(urlString: String) async -> AddonPreviewOutcome {
        // Same install-boundary configuration-page guard as installAddonConfirmed, so a /configure link relayed
        // through QR previews as needs-configuration instead of resolving a dead default manifest.
        if isAddonConfigurationPageURL(urlString) {
            return .rejected(retryable: false, message: Self.addonNeedsConfigurationMessage)
        }
        guard let normalized = normalizedAddonURL(urlString), let url = URL(string: normalized) else {
            return .rejected(retryable: false, message: "Enter a valid add-on URL (https://…/manifest.json).")
        }
        switch await AddonURLGuard.fetch(url) {
        case .failure(let rejection):
            return .rejected(retryable: Self.isRetryable(rejection), message: rejection.message)
        case .success(let (data, finalURL)):
            if isAddonConfigurationPageURL(finalURL.absoluteString) || Self.looksLikeHTMLBody(data) {
                return .rejected(retryable: false, message: Self.addonNeedsConfigurationMessage)
            }
            guard let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let name = manifest["name"] as? String, !name.isEmpty,
                  Self.hasNonEmptyIdentity(manifest) else {
                return .rejected(retryable: false, message: "That URL did not return a valid add-on manifest.")
            }
            let identity = normalizedAddonURL(finalURL.absoluteString) ?? normalized
            storeCachedManifest(normalized, manifest: manifest, canonicalURL: identity)
            let alreadyInstalled = addons.contains { $0.transportUrl == normalized || $0.transportUrl == identity }
            return alreadyInstalled ? .alreadyInstalled(name: name) : .ready(name: name)
        }
    }

    /// Existing optional preview facade; QR uses `previewAddonManifestResult` to preserve retryability.
    @MainActor
    func previewAddonManifest(urlString: String) async -> AddonManifestPreview? {
        switch await previewAddonManifestResult(urlString: urlString) {
        case let .ready(name):
            guard let normalized = normalizedAddonURL(urlString) else { return nil }
            return AddonManifestPreview(normalizedURL: normalized, name: name, alreadyInstalled: false)
        case let .alreadyInstalled(name):
            guard let normalized = normalizedAddonURL(urlString) else { return nil }
            return AddonManifestPreview(normalizedURL: normalized, name: name, alreadyInstalled: true)
        case .rejected:
            return nil
        }
    }

    private static func hasNonEmptyIdentity(_ manifest: [String: Any]) -> Bool {
        guard let id = manifest["id"] as? String, !id.isEmpty,
              let name = manifest["name"] as? String, !name.isEmpty else { return false }
        return true
    }

    /// Shown when a pasted link is a configuration page rather than an installable manifest. The user must
    /// finish setup on the add-on's own page and paste the personalized manifest link it then mints.
    static let addonNeedsConfigurationMessage = String(localized: "This add-on needs to be set up first. Open its configuration page in a browser, sign in and enter your debrid key, then copy the personalized add-on link it gives you (it ends in /manifest.json, not /configure) and paste that here.")

    /// True when a fetched body is an HTML document rather than a JSON manifest. A `/configure` page commonly
    /// serves HTML; a manifest URL that returns HTML is a landing/config page, not an add-on, so we treat it as
    /// needs-configuration instead of a generic parse failure. Checks only the leading non-whitespace bytes, so
    /// it is cheap and never misreads a real JSON manifest (which starts with `{`).
    private static func looksLikeHTMLBody(_ data: Data) -> Bool {
        let prefix = data.prefix(512)
        guard !prefix.isEmpty else { return false }
        var scalars = String(decoding: prefix, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if scalars.hasPrefix("\u{FEFF}") { scalars.removeFirst() }   // strip a leading BOM
        return scalars.hasPrefix("<!doctype html") || scalars.hasPrefix("<html")
    }

    @MainActor
    private func awaitAddonInstalled(_ identity: String,
                                     replacingManifest: [String: Any]?,
                                     expectedManifest: [String: Any]?,
                                     timeout: TimeInterval = 6) async -> Bool {
        if confirmedInstalled(identity, replacingManifest: replacingManifest, expectedManifest: expectedManifest) {
            return true
        }
        let stepNanos: UInt64 = 100_000_000
        let deadlineNanos = UInt64(timeout * 1_000_000_000)
        var elapsed: UInt64 = 0
        while elapsed < deadlineNanos, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: stepNanos)
            if confirmedInstalled(identity, replacingManifest: replacingManifest, expectedManifest: expectedManifest) {
                return true
            }
            elapsed += stepNanos
        }
        return confirmedInstalled(identity, replacingManifest: replacingManifest, expectedManifest: expectedManifest)
    }

    @MainActor
    private func confirmedInstalled(_ identity: String,
                                    replacingManifest: [String: Any]?,
                                    expectedManifest: [String: Any]?) -> Bool {
        guard addons.contains(where: { $0.transportUrl == identity }) else { return false }
        guard replacingManifest != nil, let expectedManifest else { return true }
        guard let published = rawAddonsByUrl[identity]?["manifest"] as? [String: Any] else { return false }
        return NSDictionary(dictionary: published).isEqual(to: expectedManifest)
    }

    private static func isRetryable(_ rejection: AddonURLGuard.Rejection) -> Bool {
        switch rejection {
        case .unresolvable: return true
        case .invalidScheme, .privateAddress, .tooManyRedirects: return false
        }
    }

    @MainActor
    private func takeCachedManifest(_ normalizedURL: String) -> (manifest: [String: Any], canonicalURL: String)? {
        guard let cached = manifestPreviewCache.removeValue(forKey: normalizedURL) else { return nil }
        guard Date().timeIntervalSince(cached.fetchedAt) < Self.manifestCacheTTL else { return nil }
        return (cached.manifest, cached.canonicalURL)
    }

    @MainActor
    private func storeCachedManifest(_ normalizedURL: String, manifest: [String: Any], canonicalURL: String) {
        let now = Date()
        manifestPreviewCache = manifestPreviewCache.filter {
            now.timeIntervalSince($0.value.fetchedAt) < Self.manifestCacheTTL
        }
        if manifestPreviewCache.count >= Self.manifestCacheCap,
           let oldest = manifestPreviewCache.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            manifestPreviewCache.removeValue(forKey: oldest)
        }
        manifestPreviewCache[normalizedURL] = (manifest, canonicalURL, now)
    }

    /// True when the engine has NO stream-capable add-on installed (every title would report "no
    /// sources"). The account-owns-everything hydration targets exactly this condition. Extracted from
    /// `scheduleSessionRepair`'s inline test so launch / scenePhase / sync can share it.
    var hasNoStreamAddon: Bool { !addons.contains { $0.providesStreams } }

    /// True when the engine has no USER-INSTALLED stream add-on (only the official stubs, or none). This
    /// is the REAL "we lost the user's sources" signal: a Stremio logout / token-expiry reinstalls the
    /// OFFICIAL stream stubs (local / WatchHub / Public Domain), so `hasNoStreamAddon` is structurally
    /// FALSE after a logout even though every real title reports "no sources". The account-owns-everything
    /// restore triggers off THIS so a logout re-applies the user's owned add-ons instead of staying wiped.
    var hasNoUserStreamAddon: Bool {
        !addons.contains { $0.providesStreams && !($0.isOfficial || $0.isProtected) }
    }

    /// Await the engine's Stremio add-on pull settling before a caller snapshots the owned set. On sign-in
    /// the engine fires PullAddonsFromAPI asynchronously; snapshotting after a FIXED delay can capture the
    /// set MID-PULL (a slow / down add-on host lands late), which is the partial-import users reported. This
    /// polls until the engine holds at least one USER stream add-on (hasNoUserStreamAddon == false) or a
    /// bounded timeout elapses, so the snapshot only runs once the pull looks complete. The timeout is a
    /// safety net, not a happy path: snapshotOwnedFromEngine is itself never-zero guarded, so a genuinely
    /// empty account after timeout is a no-op rather than a partial write.
    @MainActor
    func awaitAddonsHydrated(timeout: TimeInterval = 12) async {
        let deadlineNanos = UInt64(timeout * 1_000_000_000)
        let stepNanos: UInt64 = 250_000_000   // 0.25s poll cadence
        var elapsed: UInt64 = 0
        while hasNoUserStreamAddon, elapsed < deadlineNanos {
            try? await Task.sleep(nanoseconds: stepNanos)
            elapsed += stepNanos
        }
    }

    /// The raw installed add-on descriptors the engine currently holds (the exact `{transportUrl,
    /// manifest, flags}` objects kept for round-tripping), so the sync layer can snapshot the full
    /// descriptor set into the VortX account doc for network-free re-hydration. Account/engine add-on
    /// set only; never a per-profile overlay.
    func rawAddonDescriptors() -> [[String: Any]] {
        Array(rawAddonsByUrl.values)
    }

    /// Same descriptors as `rawAddonDescriptors`, but in the engine's TRUE install order (the typed `addons`
    /// Vec order) instead of the nondeterministic dictionary order, so the sync layer can persist + round-trip
    /// the user's add-on PRIORITY: a reorder on one device reaches the others via doc.vortx.addons.
    func rawAddonDescriptorsOrdered() -> [[String: Any]] {
        addons.compactMap { rawAddonsByUrl[$0.transportUrl] }
    }

    /// Install the VortX account's owned add-ons back INTO the engine, but ONLY descriptors the engine
    /// lacks (idempotent). This is the load-bearing "account owns everything" capability: it lets a
    /// logged-out / degraded Stremio session show the account's add-ons + sources instead of zero.
    ///
    /// Uses the EXACT `InstallAddon` descriptor shape `installAddon` sends (`{transportUrl, manifest,
    /// flags}`, camelCase), the engine mutates `ctx.profile.addons` LOCALLY with no api.strem.io call.
    /// A lowercase-key mismatch silently no-ops in the engine, so `VortXOwnedAddon.installDescriptor`
    /// keeps the keys aligned with `installAddon`. Targets the account/engine add-on set ONLY; it never
    /// touches a per-profile overlay and never `disabledAddons` (which stays a render-layer filter).
    func hydrateAddonsFromAccount(_ owned: [VortXOwnedAddon]) {
        guard !owned.isEmpty else { return }
        let installed = Set(addons.map(\.transportUrl)) .union(rawAddonsByUrl.keys)
        var installedCount = 0
        for addon in owned where !installed.contains(addon.transportUrl) {
            dispatchCtx(["action": "InstallAddon", "args": addon.installDescriptor])
            installedCount += 1
        }
        if installedCount > 0 {
            NSLog("%@", "[CoreBridge] hydrated \(installedCount) account-owned add-on(s) into the engine (no Stremio session needed)")
        }
    }

    /// stremio-core's storage schema version, a smoke check that the FFI is wired end-to-end.
    var schemaVersion: UInt32 { stremiox_core_schema_version() }

    // MARK: Auth bootstrap / migration

    /// Get the engine into a logged-in state with library + addons populated.
    ///  - Engine already has a session (hydrated from its own storage on a later launch) → refresh.
    ///  - Else migrate the legacy authKey: fetch the real User (PullUserFromAPI builds profile.auth),
    ///    then, once the `ctx` event confirms we're logged in, pull addons + sync the library.
    private func bootstrapAuth() {
        // Wave 4 (VortX owns the library + Continue Watching): once THIS Stremio account's library has been
        // imported into the VortX account doc, the engine runs on its purely-LOCAL library bucket (already
        // mirrored to doc.vortx.library + re-hydrated on cold devices), and the engine's Stremio session is
        // unloaded (see the importedAway branch below) so stremio-core stops auto-syncing to api.strem.io.
        // `importedAway` = migrated AND not opted into two-way sync.
        let stremioToken = Keychain.string(activeTokenAccount)
        let hasStremioToken = (stremioToken?.isEmpty == false)
        let importedAway = importedAwayFromStremio

        if isLoggedIn() {
            if importedAway {
                // Wave 4 (Finding 2): this account is migrated to VortX and NOT opted into two-way sync, yet the
                // engine still holds a live Stremio session from its own persisted storage. stremio-core
                // auto-persists library / progress mutations to api.strem.io whenever a session is loaded (the
                // same upstream-persist behavior the add-on delete paths guard against), so leaving it logged in
                // keeps writing to Stremio behind our back and the device is not actually independent. Unload the
                // engine session ONCE. Logout KILLS the Stremio session SERVER-SIDE (so the token is now dead)
                // and resets the engine to its empty default profile, so: gate it on the account doc being
                // reachable THIS launch; then clear the now-dead Keychain token (Fix A: reconnecting Stremio
                // later is a FRESH sign-in, never a reuse of this dead token); then DETERMINISTICALLY recover the
                // owner library at launch (Fix C: wait for the engine to process the Logout, load the empty
                // library, then hydrate owned add-ons + recover from doc.vortx) instead of waiting for the 14s
                // session repair. Next launch has no token, so isLoggedIn() is false and this runs at most once;
                // on an unreachable launch we keep the session and retry next launch (never an empty UI).
                Task { @MainActor in
                    if await VortXSyncManager.shared.accountDocReachable() {
                        NSLog("[CoreBridge] imported to VortX + opt-out: unloading the engine's Stremio session")
                        self.logOut()   // Ctx Logout: kills the Stremio session server-side + resets the engine
                        // The Logout invalidated the Stremio token server-side, so the retained Keychain token is
                        // dead. Clear it: it is useless, and keeping it would keep scheduleSessionRepair trying to
                        // re-auth a dead session. "Connect Stremio" / alsoSyncToStremio is a fresh sign-in.
                        Keychain.set(nil, for: self.activeTokenAccount)
                        // Deterministic post-logout recovery: wait for the engine to actually process the Logout
                        // (isLoggedIn flips false and the library resets), then load that empty library and recover
                        // the owner library from doc.vortx at launch, not after the 14s repair.
                        for _ in 0 ..< 30 where self.isLoggedIn() { try? await Task.sleep(nanoseconds: 100_000_000) }
                        await self.loadLibraryAndAwait()
                        await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()
                    } else {
                        NSLog("[CoreBridge] deferring engine Stremio-session unload: VortX doc unreachable this launch")
                    }
                    self.loadBoard()
                }
                loadBoard()
                return
            }
            // Not migrated yet (or opted into two-way sync): pull/sync from Stremio as before.
            refreshFromAPI()
            // VortX-first (account-owns-everything): hydrate the VortX account's owned add-ons into the engine
            // on EVERY launch, not only when degraded, so doc.vortx.addons is the source of truth and a still-
            // valid Stremio session reconciles ON TOP of it rather than the engine's Stremio-sourced storage
            // being the sole source. Idempotent + never-zero guarded inside the sync manager (installs only the
            // missing owned add-ons), so a healthy engine is a no-op and a failed/empty account pull does nothing.
            // Then run the one-time library import so the token-load can stop on the next launch (data-safe:
            // capture-then-record, never destroys; a no-op once the per-account flag is set).
            Task { @MainActor in
                await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()
                if hasStremioToken, let stremioToken {
                    await VortXSyncManager.shared.importOwnerLibraryFromStremioOnce(stremioToken: stremioToken)
                }
                self.loadBoard()
            }
            loadBoard() // refresh the board now too; addons were already hydrated from the engine's own storage
            return       // scheduleSessionRepair() is now called once from start() for ALL paths
        }
        guard hasStremioToken, let stremioToken, !importedAway else {
            // Either genuinely signed out (no token), OR post-import + opt-out: do NOT seed the engine with the
            // Stremio token. Account-owns-everything: hydrate the VortX account's owned add-ons + recover the
            // owner library BEFORE loading the board, so the device shows the account's add-ons + sources +
            // library instead of only Cinemeta. Idempotent + never-zero guarded inside the sync manager (a
            // failed/empty account pull does nothing). loadBoard runs once hydration kicks the ctx event, and
            // again here so a no-account-doc device still gets the default browsable Home.
            NSLog("[CoreBridge] engine stays signed out of Stremio (%@)",
                  hasStremioToken ? "library imported to VortX; token retained but not loaded" : "no token in Keychain")
            Task { @MainActor in
                await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()
                self.loadBoard()
            }
            // Still surface the default addons' catalogs (Cinemeta et al. ship in the engine's default
            // profile) so a signed-out Home is a real, browsable landing screen (backdrop hero + rails),
            // not an empty "please sign in" page. Discover already loads signed-out; Home should too.
            loadBoard()
            return
        }
        // Not yet imported (or opted into two-way sync): seed the engine from the Stremio token as before. The
        // ctx event completes the pull; the one-time import then runs on a subsequent launch's isLoggedIn() path.
        awaitingAuthMigration = true
        NSLog("[CoreBridge] seeding engine from legacy authKey…")
        dispatchCtx(["action": "PullUserFromAPI", "args": ["token": stremioToken]])
    }

    /// Self-heal a stale or INCOMPLETE engine session. Two failure modes seen in the wild, both of
    /// which leave the UI "signed in" (the Keychain token persists immediately) while the engine's own
    /// state is wrong:
    ///  - a session the API no longer honors (an old account-slot bug) → library + Continue Watching
    ///    sit empty forever; and
    ///  - a force-close that lost the just-pulled add-ons before the engine's async storage write
    ///    flushed (the engine persists fire-and-forget) → the engine comes back with NO stream-capable
    ///    add-on, so every title reports "no sources" until a manual logout/login. This is the
    ///    user-reported "force close → lost all my addons but still shows logged in" bug.
    /// If, a while after launch, the stored token says we're signed in but the engine has no account
    /// data OR no stream add-on, re-establish the session from the token; the engine then pulls
    /// add-ons + the full library fresh. Runs once per launch and never fights an in-flight auth/switch.
    private func scheduleSessionRepair() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in
            guard let self, !self.switchInFlight, !self.awaitingAuthMigration else { return }
            let cwItems = self.decode(CoreCWPreview.self, field: "continue_watching_preview")?.items ?? []
            let noAccountData = self.continueWatching.isEmpty && cwItems.isEmpty && (self.library?.catalog.isEmpty ?? true)
            let noStreamAddon = self.hasNoUserStreamAddon   // user-installed stream add-ons gone (logout-proof)
            guard noAccountData || noStreamAddon else { return }
            let key = Keychain.string(self.activeTokenAccount)
            let hasStremioToken = (key?.isEmpty == false)
            // Account-owns-everything: hydrate the VortX account's owned add-ons + recover the owner
            // library FIRST, regardless of whether a Stremio token exists. Idempotent + never-zero
            // guarded inside the sync manager (a failed/empty account pull does nothing), so it can
            // never make things worse. This is what fixes "post-update: 0 sources / 0 add-ons" on a
            // genuinely-logged-out or degraded device.
            Task { @MainActor in
                await VortXSyncManager.shared.hydrateEngineFromOwnedAddons()
                // Re-establish a live Stremio session to reconcile on top of the hydrated floor ONLY when a
                // usable token exists AND this device is NOT migrated-and-opted-out. Wave 4 (Finding 2): an
                // importedAway device must NEVER re-auth Stremio here, or it would defeat the import with a
                // logout / re-login ping-pong (and, since the post-import token is server-dead, thrash the UI).
                // In that case (or when genuinely logged out), the VortX doc hydration above is the whole recovery.
                // Never call switchAccount with an empty token.
                if hasStremioToken, let key, !self.importedAwayFromStremio {
                    NSLog("%@", "[CoreBridge] degraded session (\(noStreamAddon ? "no stream add-on" : "no account data")) with a stored token; hydrated account add-ons, now re-authenticating to reconcile from Stremio")
                    self.switchAccount(token: key)
                } else {
                    NSLog("[CoreBridge] degraded session with no Stremio token; recovered from the VortX account doc")
                    self.loadBoard()
                }
            }
        }
    }

    /// Refresh installed addons + library from api.strem.io (needs an authenticated session).
    private func refreshFromAPI() {
        dispatchCtx(["action": "PullAddonsFromAPI"])
        dispatchCtx(["action": "SyncLibraryWithAPI"])
    }

    /// Reconcile the engine's library copy with api.strem.io NOW. The tvOS player writes watch progress
    /// directly to the account API (StremioAccount.saveProgress), which the engine cannot see until its
    /// next library sync, and nothing scheduled one after playback, so the Home dashboard's Continue
    /// Watching card kept the pre-playback timestamp (and fed a stale resume) until a detail-page load
    /// happened to trigger a sync (the "have to long-press → Details to refresh the timestamp" report).
    /// Called by the player's exit path AFTER its final save has landed on the API, so the pull can
    /// never race the write it exists to fetch. The sync re-emits `continue_watching_preview`, which
    /// republishes the rail. No-op for overlay profiles (their history never touches the engine).
    func syncLibraryNow() {
        guard ProfileStore.shared.activeUsesEngineHistory else { return }
        // Signed-out (and anonymous) engines have no authenticated session for SyncLibraryWithAPI to
        // pull from, so the dispatch was dead weight on every player exit. Skip it.
        guard isLoggedIn() else { return }
        dispatchCtx(["action": "SyncLibraryWithAPI"])
    }

    /// Seed the engine right after a fresh sign-in (LoginView wrote the authKey to the active
    /// profile's slot). When the engine still holds ANOTHER profile's session, this routes through
    /// the switch path instead, because bootstrapAuth would see "logged in" and keep the old session.
    func signedInWithLegacyAuthKey() {
        // Explicit Stremio reconnect = explicit import intent (#205): the user is deliberately pulling
        // this account's add-ons back in, so prior local removal tombstones must not suppress them
        // (refreshAddons uninstalls any non-protected ctx add-on still in the removal set, so the
        // import would report "0 add-ons" forever for any add-on the user once deleted here).
        // Background pulls (launch recovery, periodic refresh) never route through this function, so
        // ordinary removal-sticks behavior is unchanged everywhere else.
        for removedURL in AddonTombstones.all() {
            AddonTombstones.forget(removedURL)
        }
        if isLoggedIn(), let key = Keychain.string(activeTokenAccount), !key.isEmpty {
            switchAccount(token: key)
        } else {
            bootstrapAuth()
        }
    }

    /// Switch the engine to a different Stremio session WITHOUT logging the current one out.
    /// (Engine Logout destroys its session server-side, which would permanently invalidate the
    /// profile we're leaving.) LoginWithToken installs the new session in place and the engine then
    /// pulls that account's addons + library itself; completion is detected in handleEvent when the
    /// ctx uid changes.
    func switchAccount(token: String) {
        switchInFlight = true
        switchFromUID = currentUID()
        clearUserState()
        NSLog("[CoreBridge] switching engine session (profile change)…")
        dispatchCtx(["action": "Authenticate", "args": ["type": "LoginWithToken", "token": token]])
        // A re-auth into the SAME account never changes the uid, so the uid-watch in handleEvent
        // cannot see it complete and the cleared UI would stay empty. Refresh unconditionally once
        // the round trip has had time to land; harmless when the uid-watch already did it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.switchInFlight else { return }
            self.switchInFlight = false
            self.switchFromUID = nil
            NSLog("[CoreBridge] account switch backstop → reloading")
            self.refreshFromAPI()
            self.seedInitialState()
            self.loadBoard()
        }
    }

    /// Log out of the engine (clears the persisted profile + library, and kills the session
    /// server-side) and the published UI state. For explicit sign-out, never for profile switching.
    func logOut() {
        dispatchCtx(["action": "Logout"])
        clearUserState()
    }

    /// Clear the published per-account UI state (rails, library, details).
    private func clearUserState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.continueWatching = []
            self.boardRows = []
            self.discover = nil
            // Drop the no-op-suppression fingerprint alongside the state it guards: a fresh discover load
            // after this clear must never be suppressed by a stale fingerprint from the previous account.
            self.discoverPublishedFingerprint = nil
            self.library = nil
            self.metaDetails = nil
        }
    }

    /// Load the Home board: every catalog of every installed addon, then fetch the first `rows`.
    /// (Targets the `board` field specifically, `search` is also a CatalogsWithExtra.)
    func loadBoard(rows: Int = 30) {
        let installedCatalogTotal = installedCatalogs(
            includeTombstoned: true,
            includeDisabled: true
        ).count
        let requestedRows = CatalogPrefsStore.order().isEmpty
            ? rows
            : HomeCatalogLoadPolicy.fullLoadDepth(
                current: rows,
                engineCatalogTotal: boardCatalogTotal,
                installedCatalogTotal: installedCatalogTotal
            )
        boardRowsLoaded = requestedRows
        boardPageInFlight = false
        boardRowPageInFlight = [:]   // catalogs reload from page 1, so engine indices reset (#95)
        boardRowExhausted = []
        dispatch(action: ["action": "Load",
                          "args": ["model": "CatalogsWithExtra",
                                   "args": ["type": NSNull(), "extra": []]]],
                 field: "board")
        dispatch(action: ["action": "CatalogsWithExtra",
                          "args": ["action": "LoadRange", "args": ["start": 0, "end": requestedRows]]],
                 field: "board")
    }

    /// How wide a board window (catalog-row count) has been requested so far; grows as the user scrolls
    /// the Home page to the bottom. The board paginates by ROWS (whole catalogs / rails), not by items.
    private var boardRowsLoaded = 30
    /// Set while a wider board load is dispatched, cleared when `board` re-emits, so a burst of last-row
    /// onAppear events can't fire duplicate loads (mirrors `discoverPageInFlight`).
    private var boardPageInFlight = false

    /// Per-row ITEM pagination for the Home board (#95: a Home catalog row was capped at its first page,
    /// e.g. MyTraktSync stuck at ~20 while it scrolls forever on official Stremio). The board only ever
    /// range-loaded whole ROWS; the engine's `CatalogsWithExtra.LoadNextPage(index)` appends the next page
    /// to ONE catalog, which we drive per row on horizontal scroll. Keyed by the engine catalog index
    /// (stable across LoadNextPage + board widening; carried on `CoreBoardRow.engineIndex`). Both maps are
    /// touched only on the main queue (mirrors `boardPageInFlight`).
    private var boardRowPageInFlight: [Int: Int] = [:]   // engineIndex -> item count when the load was dispatched
    private var boardRowExhausted: Set<Int> = []          // engine indices whose last settled load added nothing

    /// True while the requested range has not covered the engine's raw catalog count. The visible
    /// `boardRows` count is intentionally irrelevant: hidden, disabled, empty, and failed rows are
    /// filtered out but still occupy engine board indices.
    var boardHasNextPage: Bool {
        HomeCatalogLoadPolicy.hasNextPage(
            loaded: boardRowsLoaded,
            engineCatalogTotal: boardCatalogTotal
        )
    }

    /// Load the next page of Home catalogs (the vertical infinite scroll). Re-dispatches a wider LoadRange
    /// so more catalog rows hydrate; no-op at the end or while a page is already in flight. Without this
    /// Home was permanently capped at its first 30 catalogs.
    func loadBoardNextPage(step: Int = 30) {
        guard boardHasNextPage, !boardPageInFlight else { return }
        boardPageInFlight = true
        boardRowsLoaded += step
        dispatch(action: ["action": "CatalogsWithExtra",
                          "args": ["action": "LoadRange", "args": ["start": 0, "end": boardRowsLoaded]]],
                 field: "board")
    }

    /// Load the next page of ITEMS for one Home catalog row (#95, the horizontal infinite scroll). The
    /// engine appends to `board.catalogs[engineIndex]` and re-emits `board`, so the row grows in place.
    /// No-op while a page is already in flight for this row, or once the row is exhausted (a settled load
    /// added no new items). Call from the row's last-card `onAppear`. Main-queue only (mirrors the others).
    func loadBoardRowNextPage(engineIndex: Int) {
        guard !boardRowExhausted.contains(engineIndex), boardRowPageInFlight[engineIndex] == nil else { return }
        guard let board = decode(CoreBoardState.self, field: "board"), engineIndex < board.catalogs.count else { return }
        let count = board.catalogs[engineIndex].compactMap { $0.content?.ready }.flatMap { $0 }.count
        guard count > 0 else { return }   // the row has not hydrated yet; nothing to page from
        boardRowPageInFlight[engineIndex] = count
        dispatch(action: ["action": "CatalogsWithExtra",
                          "args": ["action": "LoadNextPage", "args": engineIndex]],
                 field: "board")
    }

    /// Reconcile in-flight per-row pagination after a `board` emit (#95). A SETTLED load (the catalog no
    /// longer loading) that GREW the row clears the in-flight gate so the next page can load; a settled
    /// load that added nothing marks the row exhausted so it stops (a finite catalog never loops on no-op
    /// loads, mirroring `discoverExhausted`). Main-queue only; takes the board decoded off-main by the caller.
    private func reconcileBoardRowPagination(_ board: CoreBoardState?) {
        guard !boardRowPageInFlight.isEmpty, let board else { return }
        for (index, dispatchedCount) in boardRowPageInFlight {
            guard index < board.catalogs.count else { boardRowPageInFlight[index] = nil; continue }
            let pages = board.catalogs[index]
            if pages.contains(where: { $0.content?.isLoading == true }) { continue }   // still settling; wait
            let count = pages.compactMap { $0.content?.ready }.flatMap { $0 }.count
            boardRowPageInFlight[index] = nil
            if count <= dispatchedCount { boardRowExhausted.insert(index) }
        }
    }

    /// Apply a catalog presentation-order change to Home. The stored order only sorts populated rows after
    /// the engine board is decoded; it does not change engine indices. A catalog moved to the top can still
    /// sit at raw index 121, so hydrate the full raw range before rebuilding the visible order. This covers
    /// local moves/grouping and a synced or backup-restored order through `CatalogPreferences`.
    func catalogOrderDidChange() {
        guard !CatalogPrefsStore.order().isEmpty else {
            rebuildBoardRows()
            return
        }
        let installedCatalogTotal = installedCatalogs(
            includeTombstoned: true,
            includeDisabled: true
        ).count
        ensureCatalogOrderRangeLoaded(installedCatalogTotal: installedCatalogTotal)
        rebuildBoardRows()
    }

    /// Widen, but never restart, the board model. Kept separate so a late ctx hydrate can finish an order
    /// restoration that ran against an interim add-on roster.
    private func ensureCatalogOrderRangeLoaded(installedCatalogTotal: Int) {
        let needed = HomeCatalogLoadPolicy.fullLoadDepth(
            current: boardRowsLoaded,
            engineCatalogTotal: boardCatalogTotal,
            installedCatalogTotal: installedCatalogTotal
        )
        if needed > boardRowsLoaded {
            boardRowsLoaded = needed
            boardPageInFlight = true
            dispatch(action: ["action": "CatalogsWithExtra",
                              "args": ["action": "LoadRange", "args": ["start": 0, "end": needed]]],
                     field: "board")
        }
    }

    /// Ensure the Live tab can see EVERY installed add-on's live catalogs. The Live surface filters the
    /// Home board (`liveBoardRows`), but the board only range-loads its first window of rows and widens
    /// only as Home is scrolled. Add-ons order their tv / channel / live catalogs AFTER their movie and
    /// series catalogs, so a live catalog (e.g. MediaFusion's "Live TV") routinely falls outside the
    /// default 30-row window: the catalog never has its content range-loaded, `buildBoardRows` drops it
    /// (the `items.isEmpty` guard), and the Live tab reads "No Live TV add-ons installed" even though the
    /// add-on is installed and online. Widen the board to cover every catalog the installed add-ons
    /// provide so those rows hydrate wherever they sit. Idempotent: a no-op once the window covers them.
    /// (Engine-lane follow-up: a dedicated typed live-catalog load would avoid hydrating the whole Home
    /// board here, see [[vortx-engine-needs]] #7 IPTV + the source-registry.)
    func ensureLiveCatalogsLoaded() {
        // RAW count (tombstoned AND per-profile disabled add-ons included): both kinds of catalog
        // still occupy engine board indices, so the widen bound must cover them or trailing live
        // catalogs that sit behind them would never range-load. Rendering is unaffected: the
        // disabled / tombstone filters still apply where rows are built and listed.
        let needed = installedCatalogs(includeTombstoned: true, includeDisabled: true).count
        if boardRows.isEmpty {
            loadBoard(rows: max(needed, 30))
            return
        }
        guard needed > boardRowsLoaded else { return }   // already wide enough
        boardRowsLoaded = needed
        dispatch(action: ["action": "CatalogsWithExtra",
                          "args": ["action": "LoadRange", "args": ["start": 0, "end": needed]]],
                 field: "board")
    }

    // MARK: Discover / Library

    /// Load Discover's default catalog (the engine picks the first selectable type).
    func loadDiscover() {
        resetDiscoverPagination()
        dispatch(action: ["action": "Load", "args": ["model": "CatalogWithFilters", "args": NSNull()]],
                 field: "discover")
    }

    /// Switch Discover's type / catalog / genre, pass the chip's own `request` back verbatim.
    func selectDiscover(_ request: CoreRequest) {
        guard let requestDict = Self.encodeToDict(request) else { return }
        resetDiscoverPagination()
        dispatch(action: ["action": "Load", "args": ["model": "CatalogWithFilters", "args": ["request": requestDict]]],
                 field: "discover")
    }

    /// True when the current Discover catalog has another page to load. `selectable.nextPage` is the
    /// authoritative cursor, but the engine only sets it when the add-on declares the `skip` extra. Many
    /// add-ons (e.g. AIO Metadata, KhmerAve) omit `skip`, so the cursor is always nil even though
    /// `LoadNextPage` pages them fine and the official app paginates them too. For those catalogs we fall
    /// back to a count-driven gate that keeps paging until a fully-settled load returns no new items
    /// (`discoverExhausted`).
    ///
    /// #95: a catalog can ADVERTISE `skip` (so a cursor appears) yet have its cursor go nil mid-catalog
    /// while more items still exist (MyTraktSync stops at ~15-20 this way). The old gate latched
    /// `discoverEverHadCursor` the first time any cursor appeared and then returned `false` forever once the
    /// cursor went nil, permanently disabling the count-driven fallback and stranding the catalog at one
    /// page. So we no longer hard-stop on the latch alone: when there is no cursor we defer to the same
    /// count-driven gate the cursorless catalogs use, which keeps paging only until a settled `LoadNextPage`
    /// returns no new items (`discoverExhausted`). A genuinely finished cursored catalog therefore makes at
    /// most ONE extra no-op `LoadNextPage` (the engine ignores it when there is truly no next page) and then
    /// `discoverExhausted` stops it -- additive, and it does not loop. A healthy catalog that still has its
    /// cursor returns early on the first line and is unaffected.
    var discoverHasNextPage: Bool {
        if discover?.selectable.nextPage != nil { return true }
        return !discoverExhausted && (discover?.items.count ?? 0) > 0   // count-driven fallback (#95)
    }
    /// Set while a next-page load is dispatched, cleared when the load SETTLES (not on the interim
    /// "Loading" emit), so a burst of last-item onAppear events from the grid can't fire duplicate loads.
    private var discoverPageInFlight = false
    /// Latched true when a next-page load settles without growing the list (no more pages), so a finite
    /// catalog never loops on no-op loads. Reset on every catalog change. #95: this is now the SOLE stop for
    /// a cursor that went nil (cursorless from the start, or a cursored catalog whose cursor dropped
    /// mid-catalog), so it must stay accurate for both.
    private var discoverExhausted = false
    /// Item count captured when a next-page load is dispatched, to detect whether the settled load grew the
    /// list (more pages) or not (end of a cursorless catalog).
    private var discoverCountAtLoad = 0
    /// Fingerprint of the last `discover` payload actually published to `self.discover`. The engine
    /// re-announces `discover` as changed on every LibraryChanged FOR FREE (`catalog_with_filters.rs`
    /// returns `Effects::none()` for `LibraryChanged`, so `has_changed` is set with nothing actually
    /// different), so the discover branch fires on every ~20-90s library tick. Comparing this fingerprint
    /// against the RAW field bytes before decoding lets that branch skip the large-payload JSONDecoder
    /// pass and the main-queue republish whenever the bytes are byte-identical to the last publish. It is
    /// a change-detection fingerprint, NOT a parallel copy of engine-owned state: it covers every byte, so
    /// any real change to `selected` or any catalog item always differs and always republishes. Reset to
    /// nil wherever `self.discover` is cleared so a fresh load after a clear is never suppressed. Touched
    /// on the engine worker thread inside `handleEvent`; the lone cross-thread reset in `clearUserState`
    /// is a benign nil-write (worst case one redundant republish, never a dropped change), matching the
    /// file's existing tolerance for cross-thread reads of these optimization flags (see `playerActive`).
    private var discoverPublishedFingerprint: Int?

    /// Load the next page of the current Discover catalog (infinite scroll). The engine appends the
    /// page to `discover.catalog` and clears `next_page` at the end. No-op at the end or while a page
    /// is already in flight. Previously missing entirely, the catalog stopped at its first page, which
    /// add-on authors saw as "next page / next catalog not loading."
    func loadDiscoverNextPage() {
        guard discoverHasNextPage, !discoverPageInFlight else { return }
        discoverPageInFlight = true
        discoverCountAtLoad = discover?.items.count ?? 0
        dispatch(action: ["action": "CatalogWithFilters", "args": ["action": "LoadNextPage"]], field: "discover")
    }

    /// Reset the cursorless-pagination tracking on every catalog change (new type / catalog / genre), so
    /// the next catalog starts fresh and the previous one's exhausted/cursor state never leaks across.
    private func resetDiscoverPagination() {
        discoverPageInFlight = false
        discoverExhausted = false
        discoverCountAtLoad = 0
    }

    /// Load the Library (all types, most-recent first). Auto-refreshes on library changes.
    func loadLibrary() {
        dispatch(action: ["action": "Load",
                          "args": ["model": "LibraryWithFilters",
                                   "args": ["request": ["type": NSNull(), "sort": "lastwatched", "page": 1]]]],
                 field: "library")
    }

    /// Dispatch `loadLibrary()` and AWAIT the engine populating its `library` field (LibraryWithFilters), so a
    /// caller (the Wave 4 one-time Stremio import) can snapshot the FULL owner library rather than racing the
    /// load. Bounded poll; returns as soon as `library` is non-nil or the timeout elapses. Idempotent: if the
    /// library is already loaded this returns immediately without re-dispatching.
    @MainActor
    func loadLibraryAndAwait(timeout: TimeInterval = 6) async {
        if library == nil { loadLibrary() }
        let deadlineNanos = UInt64(timeout * 1_000_000_000)
        let stepNanos: UInt64 = 200_000_000   // 0.2s poll cadence
        var elapsed: UInt64 = 0
        while library == nil, elapsed < deadlineNanos {
            try? await Task.sleep(nanoseconds: stepNanos)
            elapsed += stepNanos
        }
    }

    /// Switch the Library's type / sort, pass the chip's own `request` back verbatim.
    func selectLibrary(_ request: CoreLibraryRequest) {
        guard let requestDict = Self.encodeToDict(request) else { return }
        dispatch(action: ["action": "Load", "args": ["model": "LibraryWithFilters", "args": ["request": requestDict]]],
                 field: "library")
    }

    /// The last catalog index this app asks the engine to actually fetch for a search, and the app's own
    /// record of it. The engine's `Load` PLANS one catalog per searchable add-on catalog with no upper
    /// bound, then `LoadRange` decides which of those get requested: `catalogs_update` fetches exactly the
    /// indices where `range.start <= index && index <= range.end` (INCLUSIVE at both ends, so `0...30` is
    /// 31 catalogs) and leaves every later index parked at a nil content, permanently. Nothing ever
    /// revisits them: a later re-plan (ProfileChanged) only reuses a catalog whose page already has a
    /// content, so a nil-content one is simply re-created nil.
    ///
    /// The cap is deliberate. Every requested catalog is one live add-on HTTP request per keystroke-settled
    /// query, so searching a large profile unbounded would fan out to dozens of add-ons at once; widening
    /// it is a product/cost decision, filed separately, NOT something to change while fixing a spinner.
    /// What must hold here is only that the app tells the truth about it: a catalog past this end will
    /// never be fetched, so it is settled-and-skipped, not in flight. Both the dispatch below and the
    /// loading derivation in the `search` field handler read this one constant, so they cannot drift.
    private static let searchLoadRangeEnd = 30

    /// The app's own record of whether a search is currently LOADED in the engine: set when `search`
    /// dispatches its `Load`, cleared when the clear path `Unload`s it. This is the app knowing what it
    /// itself dispatched (a `Load` it has not yet `Unload`ed), NOT a mirror of engine state, so re-issuing
    /// the query off it stays app-initiated and inside the CoreBridge invariant. Read on the engine worker
    /// thread in the `ctx` branch to decide whether a profile/addon change must re-fetch the re-planned
    /// search catalogs; a `Bool` is word-atomic on 64-bit, so the cross-thread read is benign (a stale
    /// read at worst skips one re-dispatch that the next ctx change catches, or fires one harmless no-op
    /// `LoadRange`), matching the file's `playerActive` convention.
    private var searchLoaded = false

    /// Fetch the planned search catalogs the app actually wants: indices `0...searchLoadRangeEnd`,
    /// inclusive engine-side. Shared by the initial `search()` and the mid-search re-dispatch in the `ctx`
    /// branch so the two can never drift on the range. `catalogs_update` reuses any catalog that already
    /// has content untouched and only issues a fetch for the in-range indices still parked at a nil
    /// content, so a re-dispatch is idempotent: it fills the re-seeded holes without re-loading settled
    /// results.
    private func loadSearchRange() {
        dispatch(action: ["action": "CatalogsWithExtra",
                          "args": ["action": "LoadRange",
                                   "args": ["start": 0, "end": Self.searchLoadRangeEnd]]],
                 field: "search")
    }

    /// Search across the installed addons (engine `search` field = CatalogsWithExtra with a search
    /// extra). Results land in `searchResults`, flattened and de-duplicated into one grid.
    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        setSearchLoading(trimmed.count >= 2)
        guard trimmed.count >= 2 else {
            searchLoaded = false
            // Tell the ENGINE the search is over, not just the UI. Clearing `searchResults` alone left the
            // engine's CatalogsWithExtra holding the last query's full result set for the life of the
            // process, and because it re-announces `search` as changed on every LibraryChanged, that dead
            // result set was re-serialized and re-published on the next library tick: the results the user
            // just cleared reappeared in the grid, in the suggestion titles, and in the genre stats. Unload
            // drops both the selection and the pages engine-side, so the re-announce carries nothing.
            // Mirrors `unloadMeta` / `unloadEnginePlayer`; the `field` scopes it to this model alone.
            dispatch(action: ["action": "Unload"], field: "search")
            DispatchQueue.main.async { [weak self] in self?.searchResults = [] }
            return
        }
        searchLoaded = true
        dispatch(action: ["action": "Load",
                          "args": ["model": "CatalogsWithExtra",
                                   "args": ["type": NSNull(), "extra": [["search", trimmed]]]]],
                 field: "search")
        loadSearchRange()
    }

    private func setSearchLoading(_ loading: Bool) {
        if Thread.isMainThread {
            searchIsLoading = loading
        } else {
            DispatchQueue.main.async { [weak self] in self?.searchIsLoading = loading }
        }
    }

    /// Load Cinemeta's local-search index and ask it for autocomplete suggestions as the user types.
    func loadSearchSuggestions() {
        dispatch(action: ["action": "Load", "args": ["model": "LocalSearch"]], field: "local_search")
    }

    func suggestSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { [weak self] in self?.searchSuggestions = [] }
        guard trimmed.count >= 2 else { return }
        dispatch(action: ["action": "Search",
                          "args": ["searchQuery": trimmed, "maxResults": 10]],
                 field: "local_search")
    }

    private static func encodeToDict<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict
    }

    // MARK: Meta details

    private func metaLoadAction(type: String, id: String,
                                streamType: String?, streamId: String?) -> [String: Any] {
        var args: [String: Any] = [
            "metaPath": ["resource": "meta", "type": type, "id": id, "extra": []],
            "guessStream": true,
        ]
        if let streamType, let streamId {
            args["streamPath"] = [
                "resource": "stream", "type": streamType, "id": streamId, "extra": []
            ]
        } else {
            args["streamPath"] = NSNull()
        }
        return ["action": "Load", "args": ["model": "MetaDetails", "args": args]]
    }

    /// Begin the Apple terminal-finality refresh with an explicit invalidation phase. A resident same-ID
    /// payload is cleared and unloaded first; only a later non-ready invalidation receipt is permitted to
    /// issue this request's exact Load. The returned generation is the only generation whose later terminal
    /// receipt can certify completion for this exact stream request; full-series/finality authority remains
    /// a separate policy decision.
    func beginAppleCWAuthoritativeMetaRefresh(type: String, id: String,
                                               streamType: String?, streamId: String) -> Int {
        appleCWMetaRefreshGeneration &+= 1
        let generation = appleCWMetaRefreshGeneration
        appleCWMetaRefreshRequest = AppleCWMetaRefreshRequest(
            generation: generation,
            type: type,
            libraryID: id,
            streamType: streamType,
            streamID: streamId,
            phase: .awaitingInvalidation
        )
        appleCWMetaRefreshReceipt = nil
        appleCWMetaRefreshDetails = nil
        metaDetailsWork?.cancel()
        metaDetailsWork = nil
        let hadDetails = metaDetails != nil
        metaDetails = nil
        if hadDetails { streamsEpoch &+= 1 }
        dispatch(action: ["action": "Unload"], field: "meta_details")
        return generation
    }

    /// Re-find sources: force a FRESH add-on re-query for this exact title/episode so expired sources are
    /// replaced. Modeled on `beginAppleCWAuthoritativeMetaRefresh` but with an OPTIONAL `streamId` (so
    /// MOVIES re-find, not just episodes) and WITHOUT the Continue-Watching receipt bookkeeping. A plain
    /// re-Load of the same meta is an engine eq_update no-op (zero add-on HTTP), so this clears + Unloads
    /// the resident meta first and only re-dispatches the exact Load on the Unload's nil meta_details
    /// receipt (see the `refindRequest` arm in `scheduleMetaDetailsRepublish`). The source list empties and
    /// repaints to its loading state, then refills as the fresh sources land. Main-actor only (called from
    /// SwiftUI actions), mirroring `beginAppleCWAuthoritativeMetaRefresh`'s synchronous mutation style.
    func refindSources(type: String, id: String, streamType: String? = nil, streamId: String? = nil) {
        refindGeneration &+= 1
        refindRequest = RefindRequest(
            generation: refindGeneration,
            type: type,
            id: id,
            streamType: streamType,
            streamID: streamId,
            awaitingInvalidation: true
        )
        metaDetailsWork?.cancel()
        metaDetailsWork = nil
        let hadDetails = metaDetails != nil
        metaDetails = nil
        // Clearing the resident streams IS a ready-stream-set change: bump the source-list epoch so the
        // model empties, then repaints as the re-queried title lands.
        if hadDetails { streamsEpoch &+= 1 }
        dispatch(action: ["action": "Unload"], field: "meta_details")
    }

    /// Cancel a pending Apple terminal refresh when ordinary navigation or player teardown takes ownership
    /// of the shared meta slot. A stale polling Task may return harmlessly, but its bridge request must also
    /// be unable to dispatch a late Load into the newer target.
    func cancelAppleCWMetaRefresh() {
        guard let generation = appleCWMetaRefreshRequest?.generation else {
            appleCWMetaRefreshReceipt = nil
            appleCWMetaRefreshDetails = nil
            return
        }
        _ = cancelAppleCWMetaRefresh(generation: generation)
    }

    /// Cancel only the request owned by one player generation. A view replacement can call this after its
    /// successor has already started a same-title refresh, so a mismatched generation must be a no-op and
    /// must not cancel the replacement's pending coalesced republish or exact Load.
    @discardableResult
    func cancelAppleCWMetaRefresh(generation: Int) -> Bool {
        guard AppleCWMetaRefreshGenerationFence.owns(
            capturedGeneration: generation,
            activeGeneration: appleCWMetaRefreshRequest?.generation
        ) else { return false }
        metaDetailsWork?.cancel()
        metaDetailsWork = nil
        appleCWMetaRefreshRequest = nil
        appleCWMetaRefreshReceipt = nil
        appleCWMetaRefreshDetails = nil
        return true
    }

    /// Scoped observations for detail recovery. Keeping these behind the bridge preserves the detail
    /// screens' one-read identity contract while still fencing terminal and canonical-ready state to
    /// the engine selection that owns it.
    func detailMetaResolution(for requestedID: String) -> DetailMetaRecoveryPolicy.Resolution? {
        metaDetails?.metaResolution(for: requestedID)
    }

    func canonicalReadyMetaTarget(for requestedID: String) -> (id: String, type: String)? {
        guard let details = metaDetails,
              details.selectedMetaID == requestedID,
              let readyMeta = details.meta,
              case .imdb(let imdb) = DetailMetaRecoveryPolicy.catalogIDShape(readyMeta.id) else {
            return nil
        }
        return (imdb, readyMeta.type)
    }

    /// Load a title's meta + streams. For a series episode, pass the episode's video id as the stream
    /// path so the engine fetches that episode's streams.
    func loadMeta(type: String, id: String, streamType: String? = nil, streamId: String? = nil) {
        cancelAppleCWMetaRefresh()
        // A navigation/load takes ownership of the meta slot: drop any pending re-find so its Unload's nil
        // receipt cannot re-dispatch a stale Load into this new target.
        refindRequest = nil
        dispatch(action: metaLoadAction(type: type, id: id, streamType: streamType, streamId: streamId),
                 field: "meta_details")
        // If the engine already had this exact meta loaded, ActionLoad is a no-op (eq_update) and no
        // meta_details NewState fires, so the page would stick on the spinner. Read the current state:
        // keep it when the requested meta is already ready, otherwise clear to the spinner until it loads.
        let current = decode(CoreMetaDetails.self, field: "meta_details")
        let alreadyLoaded = current?.meta?.id == id
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let hadDetails = self.metaDetails != nil
            self.metaDetails = alreadyLoaded ? current : nil
            // A fresh load clears the resident streams: that IS a ready-stream-set change, so the
            // source-list epoch must bump (the model empties, then repaints as the new title lands).
            if !alreadyLoaded, hadDetails { self.streamsEpoch &+= 1 }
        }
    }

    func unloadMeta() {
        cancelAppleCWMetaRefresh()
        refindRequest = nil
        dispatch(action: ["action": "Unload"], field: "meta_details")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.metaDetails != nil { self.streamsEpoch &+= 1 }
            self.metaDetails = nil
        }
    }

    /// Loaded streams grouped by their source addon (for the per-addon filter + source labels).
    ///
    /// TOMBSTONE SUBTRACTION (the streams half of the remove-add-on fix): `refreshAddons` enforces the
    /// durable removal set on the add-on LIST surface, but the streams a deleted add-on had already
    /// loaded into `meta_details` kept SERVING SOURCES here until the next stream load. Subtract any
    /// group whose transport base is tombstoned, mirroring the refreshAddons filter, so a deleted
    /// add-on's sources disappear from every open source list too.
    @MainActor
    func streamGroups() -> [CoreStreamSourceGroup] {
        guard let details = metaDetails else { return [] }
        return assembleStreamGroups(details, streamId: nil)
    }

    /// Shared assembly for both `streamGroups` overloads: walk the meta-embedded stream groups
    /// (`metaStreams`) FIRST, then the stream-resource responses, mirroring the engine's own
    /// `[meta_streams, streams]` concat. This is the #122 fix: add-ons that serve plain HTTP / HLS links
    /// usually embed them in the meta's videos instead of implementing a `stream` resource; the engine
    /// surfaces those under `metaStreams`, which this layer previously never read, so every such add-on
    /// showed zero sources. The disabled-add-on and tombstone guards apply identically to both surfaces.
    /// An add-on that answers via BOTH surfaces merges into ONE group (two same-id groups would collide in
    /// the list's ForEach identity), dropping only EXACT repeats (full Equatable match).
    @MainActor
    private func assembleStreamGroups(_ details: CoreMetaDetails, streamId: String?) -> [CoreStreamSourceGroup] {
        let names = addonNamesByBase()
        let disabledAddons = ProfileStore.activeDisabledAddons()   // per-profile add-on set, hoisted once
        let removed = AddonTombstones.all()                        // durable removal set, hoisted once
        var groups: [CoreStreamSourceGroup] = []
        var indexByBase: [String: Int] = [:]
        for group in details.allStreamGroups {
            if let streamId, group.request.path.id != streamId { continue }
            guard !disabledAddons.contains(group.request.base) else { continue }
            guard removed.isEmpty || !isTombstonedAddonBase(group.request.base, removed: removed) else { continue }
            guard let streams = group.content?.ready, !streams.isEmpty else { continue }
            if let i = indexByBase[group.request.base] {
                // Dedupe by FULL Equatable containment, not CoreStream.id: the id fingerprint excludes
                // behaviorHints and fileIdx, so keying on it could conflate two genuinely different
                // streams (a shared infoHash split into episodes only by fileIdx, or one URL carried on
                // both surfaces with different proxy headers) and silently drop one. Containment is
                // O(n^2) over the merged group, which is fine here: it runs only on a same-base
                // collision (rare), and a single add-on's group is tens of streams.
                var merged = groups[i].streams
                for stream in streams where !merged.contains(stream) {
                    merged.append(stream)
                }
                groups[i] = CoreStreamSourceGroup(id: groups[i].id, addon: groups[i].addon, streams: merged)
            } else {
                indexByBase[group.request.base] = groups.count
                groups.append(CoreStreamSourceGroup(id: group.request.base,
                                                    addon: names[group.request.base] ?? "Add-on",
                                                    streams: streams))
            }
        }
        return groups
    }

    /// True when a stream group's source add-on (keyed by its transport base URL, which is the
    /// descriptor's transportUrl) is in the durable removal tombstone set. Mirrors the refreshAddons
    /// enforcement (CoreBridge.refreshAddons): PROTECTED add-ons (Cinemeta, Local Files) are never
    /// subtracted, so a malformed web-authored removal of an essential default can hide nothing. A
    /// removable official add-on (YouTube, WatchHub, …) the user deleted IS subtracted, matching the list
    /// and board surfaces (#137).
    @MainActor
    private func isTombstonedAddonBase(_ base: String, removed: Set<String>) -> Bool {
        let key = AddonTombstones.normalize(base)
        guard removed.contains(key) else { return false }
        if let descriptor = addons.first(where: { AddonTombstones.normalize($0.transportUrl) == key }),
           descriptor.isProtected {
            return false
        }
        return true
    }

    /// Stream-addon load progress: `total` = add-ons queried for this title's streams, `loaded` = those
    /// that have finished (returned streams or errored). The engine creates one loadable per stream
    /// add-on up front (all `.loading`), so `total` is stable and the UI can show "Loaded X/Y add-ons"
    /// to tell users whether to keep waiting or whether loading has stalled.
    func streamLoadProgress() -> (loaded: Int, total: Int) {
        guard let details = metaDetails else { return (0, 0) }
        // Count the meta-embedded groups too (they land Ready the moment the meta resolves), so a title
        // whose ONLY sources are embedded HTTP/HLS streams settles at loaded == total instead of hanging
        // the UI on the `total == 0` "still loading" state forever.
        let all = details.allStreamGroups
        var loaded = 0
        for group in all {
            switch group.content {
            case .some(.ready), .some(.err): loaded += 1
            default: break   // .loading or nil → not done yet
            }
        }
        return (loaded, all.count)
    }

    /// Ready stream groups for a specific stream/episode id, matched on the stream request's own
    /// path id. An in-player episode switch uses this so it never grabs the previous episode's
    /// streams that are still loaded in `metaDetails` during the brief window before the new ones
    /// arrive, and so it can RANK across every add-on instead of taking whoever answered first.
    @MainActor
    func streamGroups(forStreamId streamId: String) -> [CoreStreamSourceGroup] {
        guard let details = metaDetails else { return [] }
        return assembleStreamGroups(details, streamId: streamId)
    }

    /// Stream-addon load progress for one stream/episode id (see `streamLoadProgress`).
    func streamLoadProgress(forStreamId streamId: String) -> (loaded: Int, total: Int) {
        guard let details = metaDetails else { return (0, 0) }
        var loaded = 0, total = 0
        for group in details.allStreamGroups where group.request.path.id == streamId {
            total += 1
            switch group.content {
            case .some(.ready), .some(.err): loaded += 1
            default: break
            }
        }
        return (loaded, total)
    }

    /// Registration-aware raw contributor state for SourceListModel's complete-set receipt. `total == 0`
    /// alone is ambiguous: it is both the brief pre-registration window and the legitimate shape of an
    /// auxiliary-only install. Once the current meta selection is resident, an installed profile with no
    /// stream resource is known inactive; otherwise zero remains pending until registration or the deadline.
    @MainActor
    func streamContributorSettlement(metaId: String, streamId: String?) -> SourceContributorSettlement {
        let progress = streamId.map { streamLoadProgress(forStreamId: $0) } ?? streamLoadProgress()
        if progress.total > 0 {
            return progress.loaded >= progress.total ? .terminal : .pending
        }
        guard let details = metaDetails,
              details.selectedMetaID == metaId || details.meta?.id == metaId else { return .pending }
        return addons.contains(where: \.providesStreams) ? .pending : .inactive
    }

    /// Per-add-on stream-resolution state for the loaded title, read from the RAW engine JSON so it
    /// can expose what `streamGroups()` (ready-only) silently drops: an add-on whose stream request
    /// ERRORED (a fetch failure, timeout, TLS/ATS block, or bad response) otherwise looks identical
    /// to one that simply returned an empty list, so a "no sources" page can never say WHY. This is
    /// the difference that explains "tvOS Lite finds links but iOS doesn't": if iOS gets `Err(Fetch …)`
    /// where Lite gets `Ready`, the network/transport is the culprit, not the add-on set. `EmptyContent`
    /// is reported as a non-error empty (the add-on genuinely had nothing for this title).
    struct StreamAddonState: Identifiable, Equatable {
        let base: String
        let name: String
        let ready: Int          // streams returned
        let loading: Bool       // still in flight
        let error: String?      // non-nil → the add-on's stream request FAILED (not just empty)
        var id: String { base }
    }

    /// Memo for `streamAddonStates`, keyed per stream id on `streamsEpoch`: every fact it surfaces
    /// (per-group ready count, loading flag, error transition) changes exactly when the ready-stream
    /// signature changes, which is when `streamsEpoch` bumps. Without this, the three iOS source-list
    /// call sites pulled the FULL raw meta_details JSON across the FFI and re-parsed it with
    /// JSONSerialization on EVERY SwiftUI body eval (6-7x/sec during source search on a 1200+ stream
    /// title), a main-thread saturator of its own alongside the old per-eval assembly.
    private var addonStatesCache: [String: (epoch: Int, value: [StreamAddonState])] = [:]

    @MainActor
    func streamAddonStates(forStreamId streamId: String? = nil) -> [StreamAddonState] {
        let cacheKey = streamId ?? ""
        if let hit = addonStatesCache[cacheKey], hit.epoch == streamsEpoch { return hit.value }
        var out: [StreamAddonState] = []
        if let data = stateData("meta_details"),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let streams = object["streams"] as? [[String: Any]] {
            let names = addonNamesByBase()
            for group in streams {
                let request = group["request"] as? [String: Any]
                if let streamId,
                   let path = request?["path"] as? [String: Any],
                   path["id"] as? String != streamId { continue }
                let base = request?["base"] as? String ?? ""
                let name = names[base] ?? "Add-on"
                let content = group["content"] as? [String: Any]
                switch content?["type"] as? String {
                case "Ready":
                    let n = (content?["content"] as? [[String: Any]])?.count ?? 0
                    out.append(.init(base: base, name: name, ready: n, loading: false, error: nil))
                case "Err":
                    let msg = Self.describeResourceError(content?["content"])
                    out.append(.init(base: base, name: name, ready: 0, loading: false, error: msg))
                default:
                    out.append(.init(base: base, name: name, ready: 0, loading: true, error: nil))
                }
            }
        }
        // Bounded: a long episode-hopping session accumulates one slot per episode id; reset on overflow
        // (worst case one extra parse). Failures cache too, so a broken payload cannot re-parse per eval.
        if addonStatesCache.count > 8 { addonStatesCache.removeAll(keepingCapacity: true) }
        addonStatesCache[cacheKey] = (streamsEpoch, out)
        return out
    }

    /// Flatten stremio-core's `ResourceError` / `EnvError` JSON into a short human string. Returns nil
    /// for `EmptyContent` (the add-on returned an empty list, not an error). Tagged-enum shapes:
    /// `{"type":"Fetch","content":"…"}`, `{"type":"Env","content":{"type":"Fetch","content":"…"}}`, or a bare string.
    private static func describeResourceError(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        guard let d = content as? [String: Any] else { return "error" }
        let type = d["type"] as? String
        if type == "EmptyContent" { return nil }   // not an error: the add-on simply had nothing
        if let innerStr = d["content"] as? String { return [type, innerStr].compactMap { $0 }.joined(separator: ": ") }
        if let innerDict = d["content"] as? [String: Any] {
            let parts = [type, innerDict["type"] as? String, innerDict["content"] as? String]
            return parts.compactMap { $0 }.joined(separator: ": ")
        }
        return type ?? "error"
    }

    /// Cache of the addon transportUrl -> name map. Decoding the whole `ctx` JSON to build
    /// it ran on EVERY streamGroups() call, which the DetailView and player source panel hit
    /// per render. Built once, reused, and invalidated on the main actor whenever `ctx`
    /// changes (handleEvent). Main-actor only: addonNamesByBase is called from view code.
    private var addonNamesCache: [String: String]?
    @MainActor
    private func addonNamesByBase() -> [String: String] {
        if let cached = addonNamesCache { return cached }
        guard let ctx = decode(CoreCtx.self, field: "ctx") else { return [:] }
        var map: [String: String] = [:]
        for addon in ctx.profile.addons { map[addon.transportUrl] = addon.manifest.name }
        addonNamesCache = map   // only cache a real result; an empty decode retries next call
        return map
    }

    // MARK: Mark watched / unwatched (updates the library + syncs; markers refresh live)

    /// Mark the whole title (all episodes of a series, or a movie) watched/unwatched.
    func markWatched(_ isWatched: Bool) {
        // Snapshot one resident detail identity before constructing actions. A stale menu closure may
        // outlive a detail replacement; never let it dispatch through whichever meta_details happens
        // to be resident now.
        guard let residentMeta = metaDetails?.meta else { return }
        switch LibraryWatchedMutationPolicy.route(usesEngineHistory: ProfileStore.shared.activeUsesEngineHistory) {
        case .profileOverlay:
            // Keep this local to the active overlay. Missing detail context must remain a no-op,
            // never a fallthrough write into the account library.
            let ids = (residentMeta.videos ?? []).map(\.id)
            ProfileStore.shared.setWatched(isWatched, metaId: residentMeta.id,
                                           videoIds: ids.isEmpty ? [residentMeta.id] : ids,
                                           name: residentMeta.name, type: residentMeta.type, poster: residentMeta.poster)
            return
        case .engineAccount:
            break
        }
        // `MarkAsWatched` changes only the library item's aggregate watched state. Episode ticks
        // come from the separate per-video watched bitfield, so BOTH directions must visit every
        // known video. The old true branch sent only the aggregate action, making a whole-series
        // mark look like a silent no-op on the detail page.
        let videos = (residentMeta.videos ?? []).map {
            LibraryWatchedMutationPolicy.Video(id: $0.id, season: $0.season, episode: $0.episode)
        }
        for action in LibraryWatchedMutationPolicy.wholeTitleActions(videos: videos, isWatched: isWatched) {
            switch action {
            case .video(let video, let watched):
                var payload: [String: Any] = ["id": video.id]
                if let season = video.season { payload["season"] = season }
                if let episode = video.episode { payload["episode"] = episode }
                dispatchMetaDetails(["action": "MarkVideoAsWatched", "args": [payload, watched]])
            case .title(let watched):
                dispatchMetaDetails(["action": "MarkAsWatched", "args": watched])
            }
        }
    }

    /// Mark every episode of a season watched/unwatched.
    func markSeasonWatched(_ season: Int, _ isWatched: Bool) {
        guard let residentMeta = metaDetails?.meta,
              residentMeta.videos?.contains(where: { $0.season == season }) == true else { return }
        if overlayMarkWatched(isWatched, videoIds: { meta in
            (meta.videos ?? []).filter { $0.season == season }.map(\.id)
        }) { return }
        dispatchMetaDetails(["action": "MarkSeasonAsWatched", "args": [season, isWatched]])
    }

    /// Mark a single episode watched/unwatched. The engine's `Video` only needs `id`.
    func markVideoWatched(_ video: CoreVideo, _ isWatched: Bool) {
        guard let residentMeta = metaDetails?.meta,
              residentMeta.videos?.contains(where: { $0.id == video.id }) == true else { return }
        if overlayMarkWatched(isWatched, videoIds: { _ in [video.id] }) { return }
        var payload: [String: Any] = ["id": video.id]
        if let season = video.season { payload["season"] = season }
        if let episode = video.episode { payload["episode"] = episode }
        dispatchMetaDetails(["action": "MarkVideoAsWatched", "args": [payload, isWatched]])
    }

    /// Route a detail-page watched toggle into the overlay when the active profile keeps
    /// its own history, so a non-owner profile can never touch the account's library.
    /// Returns false for engine profiles, which then dispatch as before.
    private func overlayMarkWatched(_ isWatched: Bool, videoIds: (CoreMetaItem) -> [String]) -> Bool {
        guard !ProfileStore.shared.activeUsesEngineHistory else { return false }
        guard let meta = metaDetails?.meta else { return true }   // no detail context: drop, never mutate the account
        let ids = videoIds(meta)
        ProfileStore.shared.setWatched(isWatched, metaId: meta.id,
                                       videoIds: ids.isEmpty ? [meta.id] : ids,
                                       name: meta.name, type: meta.type, poster: meta.poster)
        return true
    }

    /// Display info for an overlay watch entry when a toggle arrives by bare id (the
    /// Library tab and poster menus). Resolved from whatever state already holds the
    /// title; nil means nothing knows it and the toggle is dropped rather than creating
    /// a nameless Continue Watching card.
    private func overlayDisplayInfo(forId id: String) -> (name: String, type: String, poster: String?)? {
        if let meta = metaDetails?.meta, meta.id == id { return (meta.name, meta.type, meta.poster) }
        if let item = continueWatching.first(where: { $0.id == id }) { return (item.name, item.type, item.poster) }
        if let item = library?.catalog.first(where: { $0.id == id }) { return (item.name, item.type, item.poster) }
        // Fall back to the raw catalog preview (board/discover/search), so an overlay profile can
        // mark-watched a title straight from a discover row that isn't in any loaded detail/CW/library
        // state. Without this the toggle was a silent no-op there.
        if let raw = rawMetaPreview(forId: id),
           let name = raw["name"] as? String, let type = raw["type"] as? String {
            return (name, type, raw["poster"] as? String)
        }
        return nil
    }

    /// Id-only watched toggle into the overlay. Without an episode list the id itself is
    /// the marker (exactly how movies are tracked); unwatch clears everything recorded.
    private func overlaySetWatchedById(_ id: String, _ isWatched: Bool) {
        if isWatched {
            guard let info = overlayDisplayInfo(forId: id) else { return }
            ProfileStore.shared.setWatched(true, metaId: id, videoIds: [id],
                                           name: info.name, type: info.type, poster: info.poster)
        } else {
            let recorded = Array(ProfileStore.shared.watchedVideoIds(forMeta: id))
            guard !recorded.isEmpty else { return }
            ProfileStore.shared.setWatched(false, metaId: id, videoIds: recorded,
                                           name: "", type: "", poster: nil)
        }
    }

    /// Called by the player when a title is effectively watched (~end of playback) so the marker
    /// flips live instead of waiting for a library sync. Relies on meta_details being loaded (it is,
    /// since playback is launched from the detail screen).
    func markPlaybackWatched(_ meta: PlaybackMeta, target: PlaybackMutationTarget? = nil,
                             allowEngineWrite: Bool = true) {
        let target = target ?? PlaybackMutationTarget.capture(core: self)
        guard target.stillOwnsCurrentContext(core: self) else {
            NSLog("[playback] dropped watched callback after profile/account ownership changed")
            return
        }
        // External sync (Trakt/SIMKL): the definitive watch signal fans out from this shared chokepoint
        // (the 90% marker, the EOF path, and manual in-player marks all route here). Additive + fail-soft +
        // gated + once-latched inside the coordinator (owner profile only; a no-op with empty creds). It
        // never touches an engine libraryItem field, honoring the poison invariant.
        // Scrobbling is account-owned. An inactive overlay callback may still update that overlay's
        // private cache below, but it must never fan out through a newly active owner account.
        if target.overlayProfileID == nil { ScrobbleCoordinator.shared.watched(meta) }
        if let profileID = target.overlayProfileID {
            ProfileStore.shared.markWatched(meta: meta, profileID: profileID)
            return
        }
        // Scrobble and overlay-profile state above are keyed by the explicit PlaybackMeta and remain safe even
        // when an episodic engine re-point failed. Only the owner-engine dispatch depends on confirmed Player
        // attribution; callers close this leg rather than suppressing the correct external watched signal.
        guard allowEngineWrite else { return }
        if meta.usesSeriesLifecycle {
            guard metaDetails?.meta?.id == meta.libraryId else {
                NSLog("[playback] dropped stale series watched callback id=%@", meta.libraryId)
                return
            }
            var payload: [String: Any] = ["id": meta.videoId]
            if let season = meta.season { payload["season"] = season }
            if let episode = meta.episode { payload["episode"] = episode }
            dispatchMetaDetails(["action": "MarkVideoAsWatched", "args": [payload, true]])
        } else {
            dispatchMetaDetails(["action": "MarkAsWatched", "args": true])
            // Belt-and-suspenders: MarkAsWatched routes through the meta_details model, which is a silent
            // no-op if meta_details isn't currently loaded for this movie (CW direct-resume from Home, or
            // after the user navigated away mid-playback). Also mark the library item directly via Ctx (by
            // id, no meta_details dependency) so a finished movie reliably leaves Continue Watching.
            dispatchCtx(["action": "LibraryItemMarkAsWatched", "args": ["id": meta.libraryId, "is_watched": true]])
        }
    }

    /// Resume position (seconds) from the engine's library item for `meta`, or nil if the engine has
    /// no entry. For a series, the saved offset only counts when the saved video matches the episode
    /// being opened; a mismatch answers 0. (timeOffset is stored in ms.)
    ///
    /// CONTRACT (the account-fallback fix): the engine's answer is trusted only when it is a REAL
    /// position greater than 5 seconds. Anything else (nil: no entry; 0 or near-0: "start fresh",
    /// including the series video_id-mismatch branch) sends the caller to the account fallback
    /// instead. The engine's library copy can lag the account: it hears TimeChanged on a throttle and
    /// a watched/unwatched toggle can leave its video_id stale, while this device's exit save already
    /// put the fresh position on the account, so a bare 0 here is not proof the viewer starts over.
    /// The fallback is episode-safe by construction: account.resumeOffset does its own video_id match
    /// and returns 0 for a different episode, so the wrong-episode resume that the old "trust the
    /// engine's 0" rule guarded against cannot come back through it.
    ///
    /// PLANNED ARBITER: a later change makes engineResumeSeconds the single decision point, returning
    /// nil to mean "consult the account fallback" and 0 to mean "genuinely start fresh". Once that
    /// lands, the caller reverts to trusting any non-nil answer.
    func engineResumeSeconds(for meta: PlaybackMeta) -> Double? {
        // Overlay (non-owner) profile: the engine library item belongs to the owner account, so its saved
        // resume position is not this profile's. Decline here so the caller falls back to account.resumeOffset,
        // which reads the active overlay profile's own history. Mirrors the activeUsesEngineHistory guard used
        // throughout this file (markPlaybackWatched, removeFromLibrary, setLibraryItemWatched, finishedWatching).
        guard ProfileStore.shared.activeUsesEngineHistory else { return nil }
        guard let item = metaDetails?.libraryItem else { return vortxOwnedResumeSeconds(for: meta) }
        if EpisodePlaybackIdentity.savedResumeTargetsDifferentEpisode(
            usesSeriesLifecycle: meta.usesSeriesLifecycle,
            savedVideoID: item.state.videoId,
            requestedVideoID: meta.videoId
        ) {
            return vortxOwnedResumeSeconds(for: meta) ?? 0
        }
        let engine = max(0, item.state.timeOffset / 1000.0)
        if engine > 0 { return flooredResumeSeconds(engine: engine, for: meta) }   // freshest local play wins
        // engine reports 0: only fall back to the VortX cache for the BARE re-add signature (timeOffset == 0 AND
        // duration == 0, a recovered item the engine could not be given an offset). A genuine finished / rewound
        // 0 keeps duration > 0 and is REAL, so trust it and never offer a stale resume for a just-finished title.
        if item.state.duration == 0 { return vortxOwnedResumeSeconds(for: meta) ?? 0 }
        return 0
    }

    /// Resume position (seconds) for `meta` read from the engine's LOCAL library bucket BY ID: the currently
    /// loaded meta_details item (matched on id), else the Continue-Watching preview, else the loaded library
    /// catalog. Unlike `engineResumeSeconds` (which reads whatever meta_details currently holds, trusting the
    /// caller to have loaded the right title), this matches on `meta.libraryId`, so it stays correct even when a
    /// DIFFERENT title is loaded, the Continue-Watching direct-resume race where meta_details has not landed yet
    /// and the caller fell through from `engineResumeSeconds`. This is the VortX-owned resume source: the local
    /// bucket is mirrored to doc.vortx.library and re-hydrated on cold devices, so it needs no Stremio session.
    /// Returns nil only when the engine has no entry for this title at all (the caller then decides 0 vs the
    /// opt-in Stremio read). A series entry whose saved episode differs returns 0 (start this episode fresh),
    /// mirroring `engineResumeSeconds`.
    @MainActor
    func engineResumeSecondsByLibraryId(for meta: PlaybackMeta) -> Double? {
        guard ProfileStore.shared.activeUsesEngineHistory else { return nil }   // overlay: not this profile's item
        // The engine's own library item for this id: the loaded meta, else the published CW, else the RAW preview
        // (which still includes finished movies / mid-series roll-forwards the published CW prunes), else the
        // loaded library catalog.
        var matched: CoreCWItem?
        if let loaded = metaDetails?.libraryItem, loaded.id == meta.libraryId { matched = loaded }
        else if let cw = continueWatching.first(where: { $0.id == meta.libraryId }) { matched = cw }
        else if let preview = decode(CoreCWPreview.self, field: "continue_watching_preview")?
            .items.first(where: { $0.id == meta.libraryId }) { matched = preview }
        else if let lib = library?.catalog.first(where: { $0.id == meta.libraryId }) { matched = lib }
        guard let item = matched else { return vortxOwnedResumeSeconds(for: meta) }   // engine has no entry: cache
        if EpisodePlaybackIdentity.savedResumeTargetsDifferentEpisode(
            usesSeriesLifecycle: meta.usesSeriesLifecycle,
            savedVideoID: item.state.videoId,
            requestedVideoID: meta.videoId
        ) {
            return vortxOwnedResumeSeconds(for: meta) ?? 0
        }
        let engine = max(0, item.state.timeOffset / 1000.0)
        if engine > 0 { return flooredResumeSeconds(engine: engine, for: meta) }   // freshest local play wins
        // Engine reports 0: only fall back to the VortX cache for the BARE re-add signature (timeOffset == 0 AND
        // duration == 0). A genuine finished / rewound 0 keeps duration > 0 and is REAL, so trust it.
        if item.state.duration == 0 { return vortxOwnedResumeSeconds(for: meta) ?? 0 }
        return 0
    }

    /// The VortX-owned resume offset (seconds) for `meta.libraryId` held in the local owner-resume cache
    /// (`OwnerResumeStore`, populated from `doc.vortx.library` on cold recovery). Consulted ONLY when the
    /// engine's own library bucket has no positive offset for the title: a cold / reinstalled / post-import
    /// device re-adds owner titles at time 0 because stremio-core exposes no action to inject a saved offset,
    /// so this cache is what restores cross-device resume. Series: only when the cached episode matches. Returns
    /// nil (not 0) when there is no positive cached offset, so a genuine "start from 0" is never overridden.
    private func vortxOwnedResumeSeconds(for meta: PlaybackMeta) -> Double? {
        guard ProfileStore.shared.activeUsesEngineHistory else { return nil }
        guard let entry = OwnerResumeStore.entry(forId: meta.libraryId), entry.t > 0 else { return nil }
        if EpisodePlaybackIdentity.savedResumeTargetsDifferentEpisode(
            usesSeriesLifecycle: meta.usesSeriesLifecycle,
            savedVideoID: entry.v,
            requestedVideoID: meta.videoId
        ) { return nil }
        return entry.t
    }

    /// Apply the Continue Watching FLOOR to a POSITIVE engine-held resume position.
    ///
    /// With a live Stremio session and "Mirror Continue Watching from Stremio" OFF, the engine's offset may have
    /// been authored by an official Stremio client, so a copy that sits BEHIND VortX's own saved position must
    /// not drag the resume point backwards. Returns the engine value untouched in every other case: mirror ON,
    /// no live Stremio session (the default and every VortX-only device), a locally-finished title, an overlay
    /// profile, or no cached VortX position that is actually ahead. `vortxOwnedResumeSeconds` does the owner
    /// gate and the episode-identity match, so a series never resumes another episode's position through here.
    private func flooredResumeSeconds(engine: Double, for meta: PlaybackMeta) -> Double {
        guard !MirrorSettings.stremioMayReplaceContinueWatching(stremioSessionLive: isLoggedIn()),
              !LocalRewindLog.contains(meta.libraryId),
              let owned = vortxOwnedResumeSeconds(for: meta), owned > engine else { return engine }
        return owned
    }

    // MARK: Library / Continue Watching mutations (Ctx actions; CW + library refresh live via events)

    /// Remove a title from the library entirely (the engine sets `removed = true`). Used by both the
    /// Continue Watching "dismiss" (Stremio auto-adds to the library on play, so dismissing is a library
    /// removal, matching the reference apps) and the Library tab's "Remove from Library". The engine
    /// re-emits `continue_watching_preview` + `library`, so both rails update on their own.
    func removeFromLibrary(id: String) {
        guard ProfileStore.shared.activeUsesEngineHistory else {
            // Overlay profile: dismissing CW must touch only the profile's private history,
            // never the owner account's library. That path is already tombstone-safe via ProfileStore,
            // so it must NOT enter the account-scoped LibraryTombstones set.
            ProfileStore.shared.removeWatchEntry(metaId: id)
            return
        }
        // Record the durable cross-device removal BEFORE the dispatch, the library analogue of
        // uninstallAddon's AddonTombstones.tombstone: vortxSummary pushes the set into
        // doc.vortx.deletedLibrary and SUBTRACTS it from the doc.vortx.library UNION, and syncDown re-folds
        // it on peers, so a title removed here can never be resurrected by a peer's union hydrate or the
        // cold-device library recovery (the Continue-Watching resurrection fix).
        LibraryTombstones.tombstone(id)
        dispatchCtx(["action": "RemoveFromLibrary", "args": id])
        // Propagate the removal to your other devices PROMPTLY. A bare background push can be lost if a
        // sideload UPDATE kills the process before the unextended background Task's 2-round-trip push
        // completes (the exact race that resurrected removed titles). Kick an immediate, non-debounced push
        // so the tombstone lands in doc.vortx.deletedLibrary right away, mirroring uninstallAddon.
        Task {
            let ok = await VortXSyncManager.shared.pushThisDevice()
            NSLog("[library] removal of %@ pushed to sync immediately (ok=%@)", id, ok ? "yes" : "no")
        }
    }

    /// Clear the WHOLE Continue Watching rail durably (Settings > Advanced). Per title this is exactly the
    /// long-press "Remove from Continue Watching" path, so it inherits its cross-device durability: the
    /// OWNER branch tombstones every id (LibraryTombstones) BEFORE the engine dispatch so vortxSummary
    /// subtracts them from the doc.vortx.library union and peers fold the removals, and an overlay profile
    /// touches only its private history via ProfileStore. One immediate push at the end for the whole batch
    /// (not one per title, unlike the single-item path) so the tombstones land promptly without N round
    /// trips. Never "just delete locally": a bare local clear would be resurrected by the next union pull.
    func clearContinueWatching() {
        guard ProfileStore.shared.activeUsesEngineHistory else {
            // Overlay profile: CW renders from the profile's private overlay; clear those entries only.
            for item in ProfileStore.shared.cwItems {
                ProfileStore.shared.removeWatchEntry(metaId: item.id)
            }
            return
        }
        let ids = continueWatching.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids {
            LibraryTombstones.tombstone(id)
            dispatchCtx(["action": "RemoveFromLibrary", "args": id])
        }
        // The engine re-emits continue_watching_preview + library, so the rail empties on its own.
        Task {
            let ok = await VortXSyncManager.shared.pushThisDevice()
            NSLog("[library] cleared Continue Watching (%d titles), pushed to sync (ok=%@)", ids.count, ok ? "yes" : "no")
        }
    }

    /// Mark a library item watched / unwatched by id. `LibraryItemMarkAsWatched` acts on the existing
    /// library entry (no `MetaItemPreview` needed), so it fits the Library tab, where items are library
    /// entries rather than full catalog previews. A no-op if the id isn't in the library.
    func setLibraryItemWatched(id: String, _ isWatched: Bool) {
        guard ProfileStore.shared.activeUsesEngineHistory else {
            overlaySetWatchedById(id, isWatched)   // overlay profile: private history only
            return
        }
        dispatchCtx(["action": "LibraryItemMarkAsWatched", "args": ["id": id, "is_watched": isWatched]])
    }

    /// Drop finished titles from the Continue Watching list the engine hands us, BEFORE we publish it.
    ///
    /// The engine's `is_in_continue_watching()` is purely `time_offset > 0` with no completion check, so a
    /// title watched to the end, marked watched, or finished on another device and synced down keeps a
    /// non-zero offset and sits in the rail forever. `finishedWatching` (the runtime rewind) only fires from
    /// a local play-to-EOF, so it never catches the marked-watched or watched-elsewhere cases. Filtering
    /// here at the data layer is the single movie backstop that covers all of them for every surface (tvOS Home
    /// and iOS/Mac both render `continueWatching` directly). Series membership is owned by the engine/account
    /// or active overlay profile, so app-side progress never removes a series entry.
    static func pruneFinished(_ items: [CoreCWItem]) -> [CoreCWItem] {
        items.filter {
            EpisodePlaybackIdentity.usesSeriesLifecycle(type: $0.type) || !$0.isFinished
        }
    }

    /// Recompute + publish the owner Continue Watching rail as the engine's own `continue_watching_preview`
    /// UNIONED with owner-library titles the engine currently holds at time 0 whose saved resume offset is
    /// cached in `OwnerResumeStore`.
    ///
    /// A device migrated off Stremio (the default) or cold-installed against a VortX account re-adds its owner
    /// library through `AddToLibrary` at time 0 (stremio-core exposes no action to inject a saved offset), so
    /// the engine's `continue_watching_preview` (membership is purely `time_offset > 0`) comes back EMPTY and
    /// the Home rail hides (#149) even though every resume position is already synced into `OwnerResumeStore`.
    /// Those offsets were previously consulted ONLY at play time (`vortxOwnedResumeSeconds`), never surfaced
    /// into the rail. This paints them from the LOCAL cache immediately, before any per-title Cinemeta re-add
    /// or network round trip settles, which also fixes the #147 "CW slower / flashes then disappears" report.
    ///
    /// Owner-profile only: an overlay profile rides `profiles.cwItems` and ignores this published value, so for
    /// a non-owner profile this stays EXACTLY `pruneFinished(engine preview)` (unchanged behaviour). Decodes off
    /// the caller's thread (the Rust worker thread on the event path) to keep the JSON parse off main, then
    /// synthesizes + publishes on main.
    func rebuildContinueWatching() {
        continueWatchingRebuildLock.lock()
        continueWatchingRebuildGeneration &+= 1
        let generation = continueWatchingRebuildGeneration
        continueWatchingRebuildLock.unlock()
        // "Mirror Continue Watching from Stremio": with a live Stremio session and the toggle OFF, a
        // Stremio-sourced position must not drag the RAIL backwards either, not just the account doc. Resolved
        // here off-main (a UserDefaults read plus the ctx auth probe, both thread-safe) and applied BEFORE
        // `pruneFinished`, because a title Stremio reports as finished would otherwise be pruned away before
        // the floor could restore VortX's own in-progress position.
        let mayReplaceCW = MirrorSettings.stremioMayReplaceContinueWatching(stremioSessionLive: isLoggedIn())
        let preview = decode(CoreCWPreview.self, field: "continue_watching_preview")?.items ?? []
        let library = decode(CoreLibrary.self, field: "library")?.catalog ?? []
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.continueWatchingRebuildLock.lock()
            let isLatest = generation == self.continueWatchingRebuildGeneration
            self.continueWatchingRebuildLock.unlock()
            guard isLatest else { return }
            // Owner profile only: the floor and the union are both owner-library concepts, and an overlay
            // profile rides `profiles.cwItems` and ignores this published value entirely.
            let ownerProfile = ProfileStore.shared.activeUsesEngineHistory
            let engine = Self.pruneFinished(ownerProfile
                ? Self.applyOwnedContinueWatchingFloor(preview, mayReplace: mayReplaceCW)
                : preview)
            let items = ownerProfile
                ? Self.unionOwnerContinueWatching(engine: engine, library: library)
                : engine
            VXProbe.log("engine", "continueWatching rebuilt n=\(items.count) (engine=\(engine.count))")
            self.continueWatching = items
        }
    }

    /// FLOOR each engine Continue Watching item against the VortX-owned position cached in `OwnerResumeStore`.
    ///
    /// A pass-through when `mayReplace` (mirror ON, or no live Stremio session), which is the default path for
    /// every VortX-only / imported-away device, so this changes nothing for them. Owner-profile only; the caller
    /// gates. The decision itself is pure and lives in `MirrorSettings.resolveContinueWatching`.
    static func applyOwnedContinueWatchingFloor(_ items: [CoreCWItem], mayReplace: Bool) -> [CoreCWItem] {
        guard !mayReplace else { return items }
        return items.map { item in
            let owned = OwnerResumeStore.entry(forId: item.id)
            let enginePosition = MirrorSettings.CWPosition(t: item.state.timeOffset / 1000,
                                                          d: item.state.duration / 1000,
                                                          v: item.state.videoId)
            let resolved = MirrorSettings.resolveContinueWatching(
                engine: enginePosition,
                owned: owned.map { MirrorSettings.CWPosition(t: $0.t, d: $0.d, v: $0.v) },
                mayReplace: false,
                locallyRewound: LocalRewindLog.contains(item.id))
            // Unchanged position: hand back the ORIGINAL item so the engine's watched bookkeeping
            // (flaggedWatched / timesWatched, which `pruneFinished` reads) is preserved untouched. Compared
            // against the NORMALIZED engine position, not the raw fields: `CWPosition` folds an empty video id
            // to nil, so comparing raw would read "changed" for every item the engine spells with `""` and
            // would silently strip the watched counters off titles the floor never touched.
            guard resolved != enginePosition else { return item }
            // Floored: the VortX position won, so the title is in progress by VortX's own truth and must not
            // carry the engine's Stremio-sourced watched flags into `pruneFinished`.
            let state = CoreLibState(timeOffset: resolved.t * 1000, duration: resolved.d * 1000, videoId: resolved.v)
            return CoreCWItem(id: item.id, type: item.type, name: item.name, poster: item.poster, state: state,
                              removed: item.removed, temp: item.temp)
        }
    }

    /// Merge the engine's live-offset preview with SYNTHESIZED entries for owner-library titles the engine
    /// holds at time 0 whose saved offset is cached in `OwnerResumeStore`. Engine items come FIRST (they are
    /// authoritative and already recency-sorted) and win any id present in both, so a title is never
    /// double-counted (the engine's live position also wins the resume read, `vortxOwnedResumeSeconds`).
    /// Synthesized items follow in library order (the library's default `lastwatched` sort, so still
    /// recency-leaning) and are pruned of finished titles. Pure + owner-only; the caller gates on
    /// `activeUsesEngineHistory`.
    static func unionOwnerContinueWatching(engine: [CoreCWItem], library: [CoreCWItem]) -> [CoreCWItem] {
        var synthesized: [CoreCWItem] = []
        for item in library {
            // Real saved titles only: skip removed / temp markers, and skip anything the engine already
            // surfaces with a live offset. Deduplication happens below so aliases as well as exact ids collapse.
            guard !(item.removed ?? false), !(item.temp ?? false) else { continue }
            // Only titles with a positive CACHED offset are resumable; a finished/rewound title caches t == 0
            // (a finish that propagated) and is correctly excluded, so it never resurrects here.
            guard let entry = OwnerResumeStore.entry(forId: item.id), entry.t > 0 else { continue }
            // Overlay the cached offset (seconds -> ms) onto the library item's own display fields. Watched
            // counts are left at 0 (as the overlay-profile builder does): the title HAS a resume position, so
            // it should show unless its own progress is at/past the 0.9 finished ceiling, which pruneFinished
            // below still enforces. The resume video id falls back to the library item's when the cache has
            // none (a movie).
            let overlaid = CoreLibState(timeOffset: entry.t * 1000, duration: entry.d * 1000,
                                        videoId: entry.v ?? item.state.videoId)
            synthesized.append(CoreCWItem(id: item.id, type: item.type, name: item.name,
                                          poster: item.poster, state: overlaid))
        }
        // Engine order is already newest-first and remains authoritative when its clock is not exposed. The
        // played video id supplies the cross-provider alias bridge (for example tmdb display id plus tt…:S:E),
        // so poster rotations never split a title and unrelated same-name titles never meet.
        return ContinueWatchingDedupe.fold(engine + pruneFinished(synthesized)) {
            .init(
                id: $0.id,
                type: $0.type,
                aliases: [$0.state.videoId].compactMap { $0 },
                hasValidProgress: $0.state.timeOffset.isFinite && $0.state.timeOffset > 0
                    && $0.state.duration.isFinite && $0.state.duration > 0,
                removed: $0.removed ?? false
            )
        }
    }

    /// Drop a finished movie, or honor an explicit owner/profile finish action, by rewinding its saved
    /// position to zero. Apple terminal series paths do not call this from inferred metadata because
    /// `CoreMetaDetails` has no completeness marker; engine/account state owns genuine final-series removal.
    /// `is_in_continue_watching()` is just `time_offset > 0`, so a movie at its end position would otherwise
    /// linger forever. Rewind keeps the library entry and its new-episode notifications, unlike full removal.
    func finishedWatching(libraryId: String, target: PlaybackMutationTarget? = nil) {
        let target = target ?? PlaybackMutationTarget.capture(core: self)
        guard target.stillOwnsCurrentContext(core: self) else {
            NSLog("[playback] dropped finish callback after profile/account ownership changed")
            return
        }
        if let profileID = target.overlayProfileID {
            ProfileStore.shared.finishedWatching(metaId: libraryId, profileID: profileID)
            return
        }
        // Stamp the LOCAL rewind before the dispatch. This is the app's single `RewindLibraryItem` site, and a
        // finish is indistinguishable by value from a Stremio rollback (t drops to 0), so the Continue Watching
        // FLOOR would otherwise refuse this device's own finish and pin the title in the rail whenever a Stremio
        // session is live and "Mirror Continue Watching from Stremio" is OFF. `vortxSummary` clears the stamp as
        // soon as the account doc carries the zero, which the immediate push below normally makes the next round.
        LocalRewindLog.stamp(libraryId)
        dispatchCtx(["action": "RewindLibraryItem", "args": libraryId])
        // A rewind is NOT a removal (the library entry stays), so no tombstone applies; but its pushed
        // t/d=0 must survive an imminent sideload-update process kill, or the title comes back with stale
        // pre-finish progress. Kick an immediate best-effort push so the rewound position lands in the
        // account doc right away instead of only on the next unextended background sync.
        Task { _ = await VortXSyncManager.shared.pushThisDevice() }
    }

    /// Whether the open detail page's title is saved to the library proper (present,
    /// not removed, not a temporary watched-marker entry). Drives the Library button.
    var detailInLibrary: Bool {
        // Overlay (non-owner) profile: the engine's libraryItem belongs to the account, so the
        // chip must reflect the profile's own overlay, kept symmetric with the guarded add/remove.
        if !ProfileStore.shared.activeUsesEngineHistory {
            guard let id = metaDetails?.meta?.id else { return false }
            return ProfileStore.shared.watch[id] != nil
        }
        guard let item = metaDetails?.libraryItem else { return false }
        return item.removed != true && item.temp != true
    }

    /// Add the OPEN detail page's title to the library. Catalog adds round-trip a
    /// `MetaItemPreview` found in a catalog, but a detail page reached from the
    /// Library tab or Continue Watching is in no catalog, so this hands the engine
    /// its own full meta JSON instead (a superset of the preview it expects).
    func addDetailToLibrary() {
        // External sync (Trakt/SIMKL): mirror a detail-page library ADD to each connected provider's
        // watchlist. Whole-title intent (movie or show). Additive + fail-soft + gated inside the coordinator
        // (owner profile only, watchlist toggle on); a no-op with empty creds. Built from the open detail
        // meta, so this covers both iOS and tvOS (both route their add button here).
        if let meta = metaDetails?.meta {
            ScrobbleCoordinator.shared.addedToLibrary(
                PlaybackMeta(libraryId: meta.id, videoId: meta.id, type: meta.type,
                             name: meta.name, poster: meta.poster, season: nil, episode: nil))
        }
        switch LibraryWatchedMutationPolicy.route(usesEngineHistory: ProfileStore.shared.activeUsesEngineHistory) {
        case .profileOverlay:
            // Overlay profile: save to the profile's private overlay, never the account library.
            if let meta = metaDetails?.meta {
                ProfileStore.shared.addLibraryEntry(metaId: meta.id, name: meta.name,
                                                    type: meta.type, poster: meta.poster)
            }
            return
        case .engineAccount:
            break
        }
        guard let meta = detailMetaPreview() else {
            NSLog("[CoreBridge] AddToLibrary found no usable detail meta")
            return
        }
        // An explicit add supersedes any prior removal tombstone for this id, so the freshly-added
        // title is not later suppressed by the recovery skip / union subtract and the next push stops
        // carrying the stale removal. Mirrors installAddon's AddonTombstones.forget on a fresh install.
        if let addedId = meta["id"] as? String { LibraryTombstones.forget(addedId) }
        dispatchCtx(["action": "AddToLibrary", "args": meta])
        NSLog("[CoreBridge] AddToLibrary dispatched for %@", (meta["id"] as? String) ?? "?")
    }

    /// Return the exact ready engine meta for the open detail page when it is still resident. A
    /// `meta_details` event and the SwiftUI detail update are asynchronous, however, so that state
    /// can briefly be unavailable even while `metaDetails` has already rendered the title. The engine's
    /// `MetaItemPreview` accepts id/type/name (optional poster), therefore the decoded detail is a safe
    /// final fallback rather than making a deliberate Library button tap a silent no-op.
    private func detailMetaPreview() -> [String: Any]? {
        let selectedID = metaDetails?.meta?.id
        var ready: [LibraryWatchedMutationPolicy.MetaPreview] = []
        if let data = stateData("meta_details"),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let metaItems = object["metaItems"] as? [[String: Any]] {
            for entry in metaItems {
                guard let loadable = entry["content"] as? [String: Any],
                      loadable["type"] as? String == "Ready",
                      let meta = loadable["content"] as? [String: Any] else { continue }
                guard let id = meta["id"] as? String,
                      let type = meta["type"] as? String,
                      let name = meta["name"] as? String else { continue }
                ready.append(.init(id: id, type: type, name: name, poster: meta["poster"] as? String))
            }
        }
        let catalog = selectedID.flatMap(rawMetaPreview(forId:)).flatMap(Self.mutationPreview)
        let decoded = metaDetails?.meta.map {
            LibraryWatchedMutationPolicy.MetaPreview(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster)
        }
        return LibraryWatchedMutationPolicy.detailPreview(
            targetID: selectedID, ready: ready, catalog: catalog, decoded: decoded
        )?.dictionary
    }

    private static func mutationPreview(_ raw: [String: Any]) -> LibraryWatchedMutationPolicy.MetaPreview? {
        guard let id = raw["id"] as? String,
              let type = raw["type"] as? String,
              let name = raw["name"] as? String else { return nil }
        return .init(id: id, type: type, name: name, poster: raw["poster"] as? String)
    }

    /// Remove the open detail-page title from the library, mirroring the removal to each connected external
    /// provider's watchlist FIRST. The shared chokepoint both detail surfaces (iOS + tvOS) call for their
    /// "remove from library" action, so the watchlist mirror stays out of `removeFromLibrary(id:)` itself
    /// (which is also the Continue-Watching dismiss, not a watchlist intent). Fail-soft + gated + a no-op
    /// with empty creds inside the coordinator.
    func removeDetailFromLibrary() {
        guard let meta = metaDetails?.meta else { return }
        ScrobbleCoordinator.shared.removedFromLibrary(
            PlaybackMeta(libraryId: meta.id, videoId: meta.id, type: meta.type,
                         name: meta.name, poster: meta.poster, season: nil, episode: nil))
        removeFromLibrary(id: meta.id)
    }

    /// Add a catalog item to the library. Round-trips the engine's own `MetaItemPreview` JSON (found by id
    /// in whichever catalog field holds it) so the shape is exactly what the engine expects back.
    func addToLibrary(metaId: String) {
        guard ProfileStore.shared.activeUsesEngineHistory else {
            // Overlay profile: save to the profile's private overlay, never the account library.
            if let info = overlayDisplayInfo(forId: metaId) {
                ProfileStore.shared.addLibraryEntry(metaId: metaId, name: info.name,
                                                    type: info.type, poster: info.poster)
            }
            return
        }
        guard let raw = rawMetaPreview(forId: metaId) else { return }
        LibraryTombstones.forget(metaId)   // explicit add supersedes a prior removal tombstone (see addDetailToLibrary)
        dispatchCtx(["action": "AddToLibrary", "args": raw])
    }

    /// Add a fully-formed meta object (e.g. a Cinemeta title resolved from a played magnet/link, #81) to
    /// the library, honouring the per-profile invariant. The dict must be a real catalog meta (a `tt…` /
    /// `tmdb…` id), never a synthetic magnet item, or it poisons official-client account sync.
    func addRawMetaToLibrary(_ meta: [String: Any]) {
        guard let id = meta["id"] as? String, !id.isEmpty else { return }
        guard ProfileStore.shared.activeUsesEngineHistory else {
            // Overlay profile: save to the profile's private overlay, never the account library.
            ProfileStore.shared.addLibraryEntry(metaId: id,
                                                name: meta["name"] as? String ?? id,
                                                type: meta["type"] as? String ?? "movie",
                                                poster: meta["poster"] as? String)
            return
        }
        LibraryTombstones.forget(id)   // explicit add supersedes a prior removal tombstone (see addDetailToLibrary)
        dispatchCtx(["action": "AddToLibrary", "args": meta])
    }

    /// Add a real Cinemeta catalog title to the ACCOUNT (engine) library, used when a dashboard
    /// add-to-library targets the OWNER profile (whose library is the account itself, not a per-profile
    /// overlay), regardless of which profile is active locally. Resolves the full meta (the engine wants
    /// the full object, like addDetailToLibrary) and dispatches it. The id must be a real catalog id.
    ///
    /// Returns `true` only when the meta resolved and the AddToLibrary dispatch was made, so a caller that
    /// records "already added" state (e.g. `LibraryAutoAdd`) can gate on a confirmed add and retry a failed one
    /// on the next play. `@discardableResult` keeps fire-and-forget callers unchanged.
    @MainActor
    @discardableResult
    func addCatalogItemToAccount(id: String, type: String, stampIntent: Bool = true,
                                 target: PlaybackMutationTarget? = nil) async -> Bool {
        let target = target ?? PlaybackMutationTarget.capture(core: self)
        guard target.stillOwnsCurrentContext(core: self) else { return false }
        let safeType = (type == "series") ? "series" : "movie"
        let safeId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let url = URL(string: "https://v3-cinemeta.strem.io/meta/\(safeType)/\(safeId).json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = obj["meta"] as? [String: Any], (meta["id"] as? String)?.isEmpty == false,
              target.stillOwnsCurrentContext(core: self) else { return false }
        // An explicit user/dashboard add-to-library targeting the owner stamps the add so it supersedes a prior
        // removal on every device (stampIntent: true, the default). The cold-device library recovery passes
        // stampIntent: false: recovery is a machine re-add of account-owned titles, and stamping an addedAt
        // there could mint a machine timestamp that beats a real removal this device has not folded yet,
        // durably resurrecting a removed title.
        if stampIntent { LibraryTombstones.forget(id) }
        dispatchCtx(["action": "AddToLibrary", "args": meta])
        return true
    }

    /// Mark a catalog item watched / unwatched without opening its detail page first. `MetaItemMarkAsWatched`
    /// creates a temporary library item if one doesn't exist, which is exactly this discover use case.
    func setCatalogWatched(metaId: String, _ isWatched: Bool) {
        guard ProfileStore.shared.activeUsesEngineHistory else {
            overlaySetWatchedById(metaId, isWatched)   // overlay profile: private history only
            return
        }
        guard let raw = rawMetaPreview(forId: metaId) else { return }
        dispatchCtx(["action": "MetaItemMarkAsWatched", "args": ["meta_item": raw, "is_watched": isWatched]])
    }

    /// The raw `MetaItemPreview` JSON for a catalog item id, pulled verbatim from whichever catalog field
    /// currently holds it (board / discover / search). `MetaItemPreview` deserializes through a legacy
    /// shape, so we hand the engine back its own serialization rather than reconstruct it.
    private func rawMetaPreview(forId metaId: String) -> [String: Any]? {
        for field in ["board", "discover", "search"] {
            guard let data = stateData(field),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let found = Self.findMetaPreview(in: object, id: metaId) { return found }
        }
        return nil
    }

    /// Depth-first search for a meta preview (`{id, type, name, …}`) with the given id inside an engine
    /// state object: catalog state nests previews under `content` arrays a few levels down.
    private static func findMetaPreview(in node: Any, id: String) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if dict["id"] as? String == id, dict["type"] is String, dict["name"] is String { return dict }
            for value in dict.values { if let found = findMetaPreview(in: value, id: id) { return found } }
        } else if let array = node as? [Any] {
            for value in array { if let found = findMetaPreview(in: value, id: id) { return found } }
        }
        return nil
    }

    // MARK: - Live playback progress (engine Player)

    /// Load the engine Player for the picked stream, so it records progress against the right library
    /// item. Built from the raw meta_details JSON (the engine wants back the exact Stream + the stream
    /// and meta requests it gave us). Best-effort: a shape mismatch is a silent no-op, never a crash.
    func loadEnginePlayer(for stream: CoreStream) {
        guard let data = stateData("meta_details"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let metaItems = object["metaItems"] as? [[String: Any]] ?? []
        let metaRequest = (metaItems.first { ($0["content"] as? [String: Any])?["type"] as? String == "Ready" }
                           ?? metaItems.first)?["request"]
        let metaPath = ((metaRequest as? [String: Any])?["path"] as? [String: Any])
        let metaType = metaPath?["type"] as? String
        var rawStream: [String: Any]?
        var streamRequest: Any?
        var firstReadyStream: [String: Any]?
        var firstReadyRequest: Any?
        for group in (object["streams"] as? [[String: Any]] ?? []) {
            guard let content = group["content"] as? [String: Any],
                  content["type"] as? String == "Ready",
                  let streams = content["content"] as? [[String: Any]] else { continue }
            if firstReadyStream == nil, let s = streams.first { firstReadyStream = s; firstReadyRequest = group["request"] }
            let requestPath = ((group["request"] as? [String: Any])?["path"] as? [String: Any])
            let requestVideoID = requestPath?["id"] as? String ?? metaPath?["id"] as? String ?? ""
            let requestType = requestPath?["type"] as? String ?? metaType
            let isEpisode = EpisodePlaybackIdentity.isEpisodicContext(
                type: requestType, season: nil, episode: nil, videoID: requestVideoID
            )
            if let match = streams.first(where: { streamMatches($0, stream, isEpisode: isEpisode) }) {
                rawStream = match; streamRequest = group["request"]; break
            }
        }
        // Fallback: if the EXACT stream wasn't matched (the played URL was proxied to 127.0.0.1, came from
        // the AVPlayer/DV path, or is a reconstructed object), still load the Player with ANY ready stream +
        // this meta's request. The library item + its time_offset key on the META, not the specific stream,
        // so Continue Watching + resume + progress track correctly regardless of which stream object we hand
        // the engine. Without this, a match miss silently skipped the Player load -> no library item -> CW
        // never updated and progress was lost (the "CW stopped working / progress not tracked" report).
        // A torrent is identified by the full (infoHash,fileIdx) pair. Falling back to an arbitrary ready
        // torrent after an exact miss can bind a different episode from the same season pack. Direct sources
        // keep the historical fallback because proxy/reconstruction can legitimately obscure their URL.
        // A3: that wrong-episode risk exists ONLY for an episodic title. A movie has a single video, so an
        // arbitrary ready torrent cannot be the "wrong episode"; skipping the fallback for a movie whose picked
        // source is a torrent-origin debrid link (isTorrent==true, plays via a direct RD URL) just left it with
        // no library item, so CW + progress stopped tracking after a suspend / re-resolve. Gate the skip on the
        // episodic context, not the source type, so a movie always binds while an episode keeps the guard.
        let titleIsEpisode = EpisodePlaybackIdentity.isEpisodicContext(
            type: metaType, season: nil, episode: nil, videoID: metaPath?["id"] as? String ?? ""
        )
        if rawStream == nil, !(titleIsEpisode && (stream.isTorrent || stream.isUsenet)) {
            rawStream = firstReadyStream
            streamRequest = firstReadyRequest
        }
        guard let rawStream, let streamRequest, let metaRequest else {
            DiagnosticsLog.log("cw", "loadEnginePlayer no-op (meta_details/stream/metaRequest missing); CW + progress will not track for this item")
            return
        }
        let selected: [String: Any] = [
            "stream": rawStream,
            "streamRequest": streamRequest,
            "metaRequest": metaRequest,
            "subtitlesPath": NSNull(),
        ]
        dispatch(action: ["action": "Load", "args": ["model": "Player", "args": selected]], field: "player")
    }

    /// Re-point the engine Player to a KNOWN episode id SYNCHRONOUSLY, without waiting for that episode's
    /// stream add-ons to re-answer into `meta_details`. The plain `loadEnginePlayer(for:)` scrapes the resident
    /// stream groups for the `streamRequest`, so during a binge auto-advance (the next episode's streams have
    /// not landed yet) it either grabs the PREVIOUS episode's request or no-ops on a slow add-on. The engine
    /// keys `TimeChanged`'s video_id off `selected.stream_request.path.id`, so a stale request means every
    /// progress tick and watched mark lands on the wrong episode (or un-advances the one MarkVideoAsWatched just
    /// moved). This overload CONSTRUCTS the stream request from `videoId` (+ the add-on `base` carried from the
    /// preload) and serialises the already-resolved `stream`, so the engine attributes to THIS episode from the
    /// first tick. The meta request is still read from the resident `meta_details` (series-stable across a binge).
    /// Returns true when the Player was dispatched; the caller uses that to set its progress-attribution gate.
    @discardableResult
    func loadEnginePlayer(for stream: CoreStream, videoId: String, base: String?,
                          resolvedURL: URL? = nil) -> Bool {
        guard let data = stateData("meta_details"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let metaItems = object["metaItems"] as? [[String: Any]] ?? []
        guard let metaRequest = (metaItems.first { ($0["content"] as? [String: Any])?["type"] as? String == "Ready" }
                                 ?? metaItems.first)?["request"] else {
            DiagnosticsLog.log("cw", "loadEnginePlayer(videoId:) no-op (meta request missing); engine progress will not re-point")
            return false
        }
        // The add-on base for the stream request: the preload-carried base first, else any resident stream
        // group's base, else the meta's own base. The base does not drive video_id attribution (path.id does),
        // but the engine's Player wants a well-formed ResourceRequest, so give it the truest base available.
        let residentBase = (object["streams"] as? [[String: Any]])?
            .compactMap { ($0["request"] as? [String: Any])?["base"] as? String }.first
        guard let effectiveBase = base ?? residentBase ?? (metaRequest as? [String: Any])?["base"] as? String else {
            DiagnosticsLog.log("cw", "loadEnginePlayer(videoId:) no-op (no add-on base); engine progress will not re-point")
            return false
        }
        // A stream the engine cannot deserialise (e.g. a usenet/nzb source that only carried name+description,
        // no url / ytId / infoHash / sources / externalUrl) would be dropped engine-side while the caller still
        // opens the attribution gate for videoId (a FALSE re-point confirmation). Degrade to nil exactly like
        // the missing-base path: no-op here, the caller sets enginePlayerVideoId = nil, and the gated writers
        // skip the wrong-episode engine write until the resident-scrape poll re-points.
        // This overload constructs a series episode request. A raw torrent without fileIdx is ambiguous.
        // When native debrid already resolved it, bind the concrete direct URL that will play. Never turn a
        // provider-local file offset into a Stremio torrent selector. A direct stream may legitimately carry
        // infoHash provenance, so only `isTorrent` enters this guard.
        guard let bindingSource = EpisodePlaybackIdentity.engineBindingSource(
            isRawTorrent: stream.isTorrent,
            fileIdx: stream.fileIdx,
            resolvedURL: resolvedURL?.absoluteString
        ) else {
            DiagnosticsLog.log("cw", "loadEnginePlayer(videoId:) no-op (episode torrent missing fileIdx and resolved URL); engine progress will not re-point")
            return false
        }
        let raw: [String: Any]
        switch bindingSource {
        case .original:
            raw = rawStreamDict(stream)
        case .resolvedDirectURL(let url):
            var direct: [String: Any] = ["url": url]
            if let name = stream.name { direct["name"] = name }
            if let description = stream.description { direct["description"] = description }
            raw = direct
        }
        let hasSource = raw["url"] != nil || raw["ytId"] != nil || raw["infoHash"] != nil
            || raw["sources"] != nil || raw["externalUrl"] != nil
        guard hasSource else {
            DiagnosticsLog.log("cw", "loadEnginePlayer(videoId:) no-op (stream has no source-bearing key); engine progress will not re-point")
            return false
        }
        // extra: [] matches the shape loadMeta dispatches for a stream path (the engine accepts an empty extra).
        let streamRequest: [String: Any] = [
            "base": effectiveBase,
            "path": ["resource": "stream", "type": "series", "id": videoId, "extra": []],
        ]
        let selected: [String: Any] = [
            "stream": raw,
            "streamRequest": streamRequest,
            "metaRequest": metaRequest,
            "subtitlesPath": NSNull(),
        ]
        dispatch(action: ["action": "Load", "args": ["model": "Player", "args": selected]], field: "player")
        return true
    }

    /// Serialise a resolved `CoreStream` back to the engine's raw stream shape. `StreamSource` is untagged +
    /// flattened, so the source fields (url / ytId / infoHash / fileIdx / sources / externalUrl) sit at the top
    /// level exactly as they were decoded; re-emitting the same keys round-trips into the engine's `Stream`.
    /// The library item keys on the META, not the specific stream (see `loadEnginePlayer(for:)`), so this only
    /// needs to deserialise as a valid Stream, which any single source field satisfies.
    private func rawStreamDict(_ s: CoreStream) -> [String: Any] {
        var raw: [String: Any] = [:]
        if let url = s.url { raw["url"] = url }
        if let yt = s.ytId { raw["ytId"] = yt }
        if let hash = s.infoHash { raw["infoHash"] = hash }
        if let idx = s.fileIdx { raw["fileIdx"] = idx }
        if let sources = s.sources { raw["sources"] = sources }
        if let ext = s.externalUrl { raw["externalUrl"] = ext }
        if let name = s.name { raw["name"] = name }
        if let desc = s.description { raw["description"] = desc }
        if let nzb = s.nzbUrl { raw["nzbUrl"] = nzb }
        if let include = s.fileMustInclude { raw["fileMustInclude"] = include }
        return raw
    }

    /// Tear down the engine Player so a stale Player from a previous title cannot absorb the next title's
    /// TimeChanged ticks (downloads, paste-a-link, and direct CW resume play without loading their own
    /// Player). Call ONLY from a player cover's onClose, never a load path. Mirrors `unloadMeta`.
    func unloadEnginePlayer() {
        dispatch(action: ["action": "Unload"], field: "player")
        // A10-i: reset the probe's player fields at this definitive teardown. They otherwise freeze at their
        // last live values, so the heartbeat kept reporting player=playing for minutes after playback ended.
        VXProbeState.shared.clearPlayer()
    }

    private func streamMatches(_ raw: [String: Any], _ stream: CoreStream, isEpisode: Bool) -> Bool {
        if let url = stream.url { return raw["url"] as? String == url }
        if stream.infoHash != nil {
            return EpisodePlaybackIdentity.torrentMatches(
                rawInfoHash: raw["infoHash"] as? String,
                rawFileIdx: raw["fileIdx"] as? Int,
                selectedInfoHash: stream.infoHash,
                selectedFileIdx: stream.fileIdx,
                isEpisode: isEpisode
            )
        }
        if let nzb = stream.nzbUrl {
            guard raw["nzbUrl"] as? String == nzb else { return false }
            if let include = stream.fileMustInclude {
                return raw["fileMustInclude"] as? String == include
            }
            return true
        }
        if let yt = stream.ytId { return raw["ytId"] as? String == yt }
        return false
    }

    /// Report the playback position to the engine Player (in ms), so Continue Watching reflects it live.
    func reportProgress(timeSeconds: Double, durationSeconds: Double,
                        target: PlaybackMutationTarget? = nil) {
        let target = target ?? PlaybackMutationTarget.capture(core: self)
        guard target.stillOwnsCurrentContext(core: self) else { return }
        // Overlay profiles never feed the engine Player: it would write their progress into the
        // ACCOUNT library bucket and sync it, which is exactly what profile separation prevents.
        guard target.overlayProfileID == nil else { return }
        guard durationSeconds.isFinite, timeSeconds.isFinite, durationSeconds > 0, timeSeconds >= 0 else { return }
        #if os(tvOS)
        let device = "tvOS"
        #else
        let device = "iOS"
        #endif
        let payload: [String: Any] = ["time": Int(timeSeconds * 1000),
                                      "duration": Int(durationSeconds * 1000),
                                      "device": device]
        dispatch(action: ["action": "Player", "args": ["action": "TimeChanged", "args": payload]],
                 field: "player")
    }

    private func dispatchMetaDetails(_ action: [String: Any]) {
        dispatch(action: ["action": "MetaDetails", "args": action], field: "meta_details")
    }

    /// Is `ctx.profile.auth` present? (auth serializes as an object when signed in, null otherwise.)
    func isLoggedIn() -> Bool {
        guard let data = stateData("ctx"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = object["profile"] as? [String: Any] else { return false }
        return profile["auth"] is [String: Any]
    }

    /// The signed-in account's uid (`ctx.profile.auth.user._id`), nil when signed out or the ctx is
    /// unavailable. Used to detect when an account switch has actually landed. This is the SAME
    /// identity the engine stamps into its persisted library buckets (`LibraryBucket.uid` is
    /// `Profile::uid()`, the auth user id), so it is internal (not private): `WatchedIndex` gates
    /// its bucket-file reads on it (#111 review).
    func currentUID() -> String? {
        guard let data = stateData("ctx"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = object["profile"] as? [String: Any],
              let auth = profile["auth"] as? [String: Any],
              let user = auth["user"] as? [String: Any] else { return nil }
        return (user["_id"] as? String) ?? (user["email"] as? String)
    }

    /// Dispatch an `Action::Ctx(...)` to the whole model (field = nil).
    private func dispatchCtx(_ ctxAction: [String: Any]) {
        dispatch(action: ["action": "Ctx", "args": ctxAction])
    }

    // MARK: Dispatch

    /// Dispatch an action. `field` targets one model field (nil broadcasts to the whole model).
    /// `action` is the engine's `Action` JSON, e.g.
    /// `["action": "Load", "args": ["model": "CatalogsWithExtra", "args": ["type": NSNull(), "extra": []]]]`.
    func dispatch(action: [String: Any], field: String? = nil) {
        let payload: [String: Any] = ["field": field ?? NSNull(), "action": action]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        // [engine] narrate every dispatched action (its name + the field it targets) so the log shows
        // what we asked the engine to do. Gated + autoclosure: shipping builds build no string.
        VXProbe.log("engine", "dispatch \(Self.actionName(action))\(field.map { " -> \($0)" } ?? "")")
        json.withCString { stremiox_core_dispatch($0) }
    }

    /// Compact human name for a dispatched action, for the [engine] probe. Reports the top-level
    /// action plus a nested model/sub-action where the engine nests them (Load->model,
    /// Ctx->inner action, CatalogsWithExtra->sub-action), so the log distinguishes the many
    /// same-named dispatches. Cheap string reads only; never touches the engine.
    private static func actionName(_ action: [String: Any]) -> String {
        let top = (action["action"] as? String) ?? "?"
        guard let args = action["args"] as? [String: Any] else { return top }
        if let model = args["model"] as? String { return "\(top) \(model)" }   // Load -> model
        if let inner = args["action"] as? String { return "\(top) \(inner)" }   // Ctx / model sub-action
        return top
    }

    // MARK: State

    /// Raw JSON bytes for a model field (e.g. "board", "continue_watching_preview"). Heavy fields
    /// (library, catalogs) serialize on the calling thread, prefer a background queue for those.
    func stateData(_ field: String) -> Data? {
        let quoted = "\"\(field)\"" // get_state expects a JSON field name
        guard let ptr = quoted.withCString({ stremiox_core_get_state($0) }) else { return nil }
        defer { stremiox_core_string_free(ptr) }
        return Data(bytes: ptr, count: strlen(ptr))
    }

    /// Decode a model field into a Codable type.
    func decode<T: Decodable>(_ type: T.Type, field: String) -> T? {
        guard let data = stateData(field) else { return nil }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            NSLog("%@", "[CoreBridge] decode \(field) failed: \(error)")
            return nil
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    /// A cheap content fingerprint over EVERY byte of a raw engine-state field (length folded in first as
    /// a fast discriminator). Used to suppress a redundant decode + republish when the engine re-announces
    /// a field whose serialized bytes are byte-identical to the last publish. Because it hashes the whole
    /// payload, any real change to the field changes the fingerprint, so a comparison against it can only
    /// drop a genuine no-op, never a real change. `Hasher` is seeded per process, which is all this needs:
    /// a fingerprint is only ever compared against another taken in the same run.
    private static func fieldFingerprint(_ data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data.count)
        data.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }

    // MARK: Event callback (invoked from a Rust worker thread)

    fileprivate func handleEvent(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else { return }
        guard name == "NewState", let fields = object["args"] as? [String] else {
            return // "CoreEvent" (auth results, errors, …) handled in a later step.
        }
        // Did ANY branch below actually republish (or schedule a republish)? `revision` is the coarse "the
        // engine changed something" signal every screen observes, and it used to bump on every NewState even
        // when each per-field guard had suppressed its own work: the engine re-announces `discover` (and
        // friends) as changed on every library tick for free, so an idle device woke every `revision` observer
        // several times a minute to re-render identical state. Bump only when something was really published.
        var published = false

        // Legacy authKey migration + account-switch completion both depend on `ctx` landing while logged in.
        // Their state (awaitingAuthMigration, switchInFlight, switchFromUID) is ALSO written on the MAIN thread
        // (bootstrapAuth / switchAccount + its 6s backstop), so read+write it on main here too rather than on
        // this Rust worker thread, matching the decode branches below. Otherwise switchInFlight could latch
        // stuck-true (the switched account never reloads) through an unsynchronized cross-thread write.
        if fields.contains("ctx") {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.awaitingAuthMigration, self.isLoggedIn() {
                    self.awaitingAuthMigration = false
                    NSLog("[CoreBridge] authKey migrated -> pulling addons + syncing library")
                    self.refreshFromAPI()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.loadBoard() }
                }
                if self.switchInFlight, self.isLoggedIn(), self.currentUID() != self.switchFromUID {
                    self.switchInFlight = false
                    self.switchFromUID = nil
                    NSLog("[CoreBridge] account switch complete -> reloading")
                    self.refreshFromAPI()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.loadBoard() }
                }
            }
        }

        // Decode the changed screens off the main thread, then publish on main.
        if fields.contains("continue_watching_preview") {
            // Publish the engine preview UNIONED with the OwnerResumeStore recovery, not the bare preview, so a
            // migrated / cold device (whose preview is empty at time 0) still fills the rail (#149).
            rebuildContinueWatching()
            published = true
        }
        // The board needs ctx (addon manifests) for row titles, so rebuild on either change. Coalesced: a
        // launch/page-land burst of `board` events collapses into a single trailing rebuild instead of N
        // full decodes + republishes (the on-open lag). The rebuild itself still decodes off-main.
        if fields.contains("board") || fields.contains("ctx") {
            scheduleBoardRebuild()   // [engine] board row count is logged there (coalesced, one per burst)
            published = true
        }
        if fields.contains("ctx") {
            VXProbe.log("engine", "ctx/settings changed addons=\(decode(CoreCtx.self, field: "ctx")?.profile.addons.count ?? 0)")
            DispatchQueue.main.async { [weak self] in self?.addonNamesCache = nil }   // addon set changed → rebuild name map
            refreshAddons()
            published = true
            // MID-SEARCH RE-PLAN. A profile/addon change mid-search runs `Internal::ProfileChanged`, which
            // in `catalogs_with_extra.rs` calls `catalogs_update(..., range: None, ...)`: every planned
            // catalog still parked at a nil content is re-seeded to a nil content again WITH NO fetch
            // effect. A newly planned catalog at an in-range index then sits at nil forever and holds the
            // search spinner (`hasLoadingPages` counts an in-range nil content as loading) until the next
            // user keystroke. Re-dispatch the SAME `LoadRange` search() uses so those re-seeded catalogs
            // get fetched. `catalogs_update` reuses any catalog that already has content untouched, so this
            // only fills the holes: no re-load of settled results, no flicker. Gated on `searchLoaded` so
            // it never fires with no search loaded, and idempotent (a settled range emits nothing via the
            // engine's `eq_update`). The app is re-issuing its OWN query, not mirroring engine state.
            if searchLoaded { loadSearchRange() }
        }
        if fields.contains("meta_details") {
            // Coalesce a source-search burst into one trailing decode+diff (see metaDetailsWork). The heavy
            // 1757-stream decode used to run on this worker thread on every re-emit; now it runs once per
            // burst, and the diff drops the republish when nothing the UI / streamGroups needs has changed.
            scheduleMetaDetailsRepublish()
            published = true
        }
        if fields.contains("discover") {
            // NO-OP SUPPRESSION. The engine re-announces `discover` as changed on every LibraryChanged for
            // free (`catalog_with_filters.rs`: `LibraryChanged(_) => Effects::none()`, changed-but-nothing-
            // different), so this branch fires on every ~20-90s library tick. Unlike `meta_details` (which
            // decodes then diffs) and `library` (eq-guarded after decode), `discover` had NO guard: it
            // re-decoded its full catalog and re-wrote the `@Published` var every tick, changing nothing.
            // Fingerprint the RAW field bytes and skip the decode + republish when they are byte-identical
            // to the last publish. `get_state` has already paid the serde serialize (unavoidable, the bytes
            // are the comparison input), but the large-payload JSONDecoder pass and the main-queue write
            // are pure waste on a no-op. The fingerprint covers `selected` and every catalog item, so a
            // genuine change always re-publishes; it is a change-detection fingerprint, not a cached copy
            // of engine state. `stateData` is called once and the decode reads that same buffer, so a real
            // change still costs exactly one `get_state`, same as before.
            if let data = stateData("discover") {
                let fingerprint = Self.fieldFingerprint(data)
                // NEVER suppress while a next-page load is in flight. The settle that clears
                // `discoverPageInFlight` (and latches `discoverExhausted` for a cursorless catalog) can
                // arrive with bytes byte-identical to the last publish and WITHOUT an intervening
                // isLoadingPage=true emit; swallowing it would wedge `discoverPageInFlight` true (further
                // paging blocked) and never latch exhausted. `discoverPageInFlight` is the exact flag this
                // branch clears on settle, so gating on it makes the paging path provably safe rather than
                // relying on the interim "Loading" emit differing. Read here on the worker thread; it is a
                // plain Bool written on main/UI well before the engine round-trips a page emit back, so the
                // read is benign (matches the `playerActive` cross-thread convention in this file). The
                // ordinary idle re-announce (in flight false) is still suppressed, which is the whole point.
                if fingerprint != discoverPublishedFingerprint || discoverPageInFlight {
                    discoverPublishedFingerprint = fingerprint
                    published = true
                    let value: CoreDiscover?
                    do { value = try Self.decoder.decode(CoreDiscover.self, from: data) }
                    catch { NSLog("%@", "[CoreBridge] decode discover failed: \(error)"); value = nil }
                    VXProbe.log("engine", "discover changed items=\(value?.items.count ?? 0)")
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        // End-stop (#95): a next-page load that has FULLY settled (no page still loading)
                        // without growing the list means there are no more pages, whether the catalog was
                        // cursorless or its cursor went nil mid-catalog. Gate on !isLoadingPage so the
                        // interim "Loading" emit (same count, more coming) never latches exhausted early.
                        if self.discoverPageInFlight, let v = value, !v.isLoadingPage, v.items.count <= self.discoverCountAtLoad {
                            self.discoverExhausted = true
                        }
                        self.discover = value
                        // Clear the in-flight flag only once the load has settled, so onAppear bursts during
                        // the page fetch can't fire a duplicate load (the interim "Loading" emit keeps it set).
                        if value?.isLoadingPage != true { self.discoverPageInFlight = false }
                    }
                    // A null first load derives the default catalog before the selectable is refreshed from
                    // addons, so it can land with catalogs available but nothing selected (Discover stuck on
                    // the spinner). If so, load the first catalog to unstick it.
                    if let value, value.items.isEmpty,
                       !value.selectable.types.contains(where: { $0.selected }),
                       let first = value.selectable.types.first {
                        selectDiscover(first.request)
                    }
                }
            }
        }
        if fields.contains("library") {
            let value = decode(CoreLibrary.self, field: "library")
            VXProbe.log("engine", "library changed n=\(value?.catalog.count ?? 0)")
            DispatchQueue.main.async { [weak self] in self?.library = value }
            published = true
            // A library change can change which owner titles belong in Continue Watching: the cold-recovery
            // re-add lands at time 0 and NEVER fires a continue_watching_preview event, and a newly-synced
            // offset (refreshOwnerResumeCache) can qualify a title. Rebuild the rail from the engine preview
            // UNION OwnerResumeStore. Skipped during playback: the rail is not visible then, and a real
            // progress save emits its own continue_watching_preview event (which rebuilds), so nothing is lost
            // while sparing the ~20s progress-save churn (#147).
            if !playerActive { rebuildContinueWatching() }
            // AddToLibrary / RemoveFromLibrary dispatch emits `library` but NOT `meta_details`.
            // If a detail page is open, re-read meta_details so detailInLibrary (the In-Library
            // button state) reflects the change immediately without waiting for a page reload.
            // Decoded unconditionally: reading the @Published var on this Rust worker thread
            // would race main-thread writes; the main-queue guard below decides alone, and it
            // republishes only when the library-derived bits actually changed, because `library`
            // also fires on every ~20s progress save and re-ranking a detail page that often
            // was its own performance bug.
            //
            // SKIP entirely while a player is up: the In-Library button this feeds is not visible during
            // playback, and the full 1757-stream decode on every ~20s progress save was the main-thread
            // saturation that stalled the video. The detail page re-derives In-Library state from the
            // coalesced meta_details republish when the player closes, so nothing is lost. Reading the
            // @Published `playerActive` here is safe: it is written only on the main actor and a stale
            // read at worst defers the In-Library refresh by one library emit, which the diff below
            // (or the next meta_details republish) then catches.
            guard !playerActive else { return }
            let details = decode(CoreMetaDetails.self, field: "meta_details")
            DispatchQueue.main.async { [weak self] in
                guard let self, let current = self.metaDetails else { return }
                let changed = current.libraryItem?.id != details?.libraryItem?.id
                    || current.libraryItem?.removed != details?.libraryItem?.removed
                    || current.libraryItem?.temp != details?.libraryItem?.temp
                    // An account/sync refresh can exchange one episode id for another while
                    // preserving the count. Comparing the count made the open detail page retain
                    // its old tick set until a reload, falsely appearing to undo a successful mark.
                    || LibraryWatchedMutationPolicy.watchedMembershipChanged(current.watchedVideoIds, details?.watchedVideoIds)
                if changed { self.metaDetails = details }
            }
        }
        if fields.contains("search") {
            let board = decode(CoreBoardState.self, field: "search")
            let catalogs = board?.catalogs ?? []
            let pages = catalogs.flatMap { $0 }
            // GATE ON `selected` FIRST. The engine re-announces `search` as changed on every
            // LibraryChanged whether or not anything ever searched, and a field with NO search loaded
            // (never searched, or Unloaded by the clear path in `search`) decodes to zero catalogs.
            // Without this gate an emptiness test reads that idle field as "loading". That is the
            // permanent `results=0 loading=true` line in the log, and it is sticky: every later
            // re-announce re-asserts it, so a 1-character query, which deliberately never dispatches a
            // Load, parked the screens on "Searching..." with nothing whatsoever in flight.
            //
            // ITERATE CATALOGS, NOT FLATTENED PAGES. `catalogs` is one inner array per PLANNED catalog,
            // so the outer index is the catalog index the engine's LoadRange range-checks; flattening
            // throws that index away. Two things ride on keeping it:
            //
            //   * Zero planned catalogs (no installed add-on offers a searchable catalog) is SETTLED, not
            //     in flight. The engine plans `selected` and `catalogs` inside the SAME `Load` update, so
            //     a non-nil `selected` with an empty plan can never be a half-built one: there is nothing
            //     to search and the UI must be allowed to say "No results" instead of spinning forever.
            //   * A catalog past `searchLoadRangeEnd` was planned but deliberately never requested (see
            //     the constant), so the engine parks it at a nil content for the life of the search. In
            //     range, a nil content means "seeded by Load, fetch still pending" and IS loading; past
            //     the range it means "will never be fetched" and is not. `wasRequested` is that
            //     distinction, and it is the app's own knowledge of what it dispatched, not a cached copy
            //     of engine state. A past-range page that somehow carries an explicit `Loading` is still
            //     counted, so the engine widening its own fetching cannot make us report settled early.
            //
            // The `selected` gate and the per-catalog walk are only correct together: `selected` stays
            // non-nil for the WHOLE in-flight window (set by the same `Load` that seeds the pages, before
            // the LoadRange that fetches them), so the seeded-but-unfetched instant still reports loading
            // and no "No results" flashes.
            let hasLoadingPages = board?.selected != nil && catalogs.indices.contains { index in
                let wasRequested = index <= Self.searchLoadRangeEnd
                return catalogs[index].contains { page in
                    guard let content = page.content else { return wasRequested }
                    return content.isLoading
                }
            }
            let items = pages.compactMap { $0.content?.ready }.flatMap { $0 }
            var seen = Set<String>(); var unique: [CoreMeta] = []
            for item in items where seen.insert(item.id).inserted { unique.append(item) }
            VXProbe.log("engine", "search changed results=\(unique.count) loading=\(hasLoadingPages)")
            published = true
            DispatchQueue.main.async { [weak self] in
                self?.searchIsLoading = hasLoadingPages
                if !hasLoadingPages || !unique.isEmpty {
                    self?.searchResults = unique
                }
            }
        }
        if fields.contains("local_search") {
            let value = decode(CoreLocalSearchState.self, field: "local_search")
            DispatchQueue.main.async { [weak self] in self?.searchSuggestions = value?.searchResults ?? [] }
            published = true
        }

        // `changedFields` is written unconditionally (it describes the newest event, and it is not
        // @Published so writing it invalidates nothing); only the bump is gated. Observers read the set in
        // reaction to the bump, so the two stay consistent: a suppressed event published nothing for anyone
        // to read. WatchedIndex's fields (ctx / library / continue_watching_preview) all mark published.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changedFields = Set(fields)
            if published { self.revision &+= 1 }
        }
    }

    // MARK: meta_details coalesce + diff

    /// Coalesce a burst of `meta_details` emits into ONE trailing decode+diff. Called from the worker
    /// thread on every emit; it hops to the main actor (where the debounce state lives), cancels any
    /// pending work, and schedules a single decode ~90 ms after the last emit. The decode runs off-main;
    /// it republishes `metaDetails` ONLY when something the UI or `streamGroups(forStreamId:)` actually
    /// needs has changed (the loaded meta id, the ready-stream set, or the library/watched bits), so an
    /// identical re-emit of the same 1757-row payload during source search republishes nothing. An
    /// episode switch or a fresh Load changes the meta id / stream set, so its republish always lands
    /// within one debounce window, keeping in-player next-episode / binge auto-advance intact.
    private func scheduleMetaDetailsRepublish() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.metaDetailsWork?.cancel()
            let refreshGenerationAtSchedule = self.appleCWMetaRefreshRequest?.generation
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { return }
                    let details = self.decode(CoreMetaDetails.self, field: "meta_details")
                    if VXProbe.enabled {
                        // Count ready streams across every source group so the log shows when streams
                        // actually ARRIVED (not just that meta_details re-emitted). On a non-zero arrival
                        // also stamp the heartbeat via note("streams N"). Ready-only pass, no per-item log.
                        let readyStreams = (details?.allStreamGroups ?? []).reduce(0) { $0 + ($1.content?.ready?.count ?? 0) }
                        VXProbe.log("engine", "metaDetails changed meta=\(VXProbeRedaction.identityToken(details?.meta?.id)) streamGroups=\(details?.allStreamGroups.count ?? 0) streams=\(readyStreams)")
                        if readyStreams > 0 { VXProbeState.shared.note("streams \(readyStreams)") }
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        // The decoded payload belongs to the request generation that was active when this
                        // debounce work was scheduled. If teardown cancelled that generation, or a
                        // replacement player installed another one, discard the stale work before it can
                        // republish meta or drive the replacement's invalidation/load state.
                        guard self.appleCWMetaRefreshRequest?.generation == refreshGenerationAtSchedule else {
                            return
                        }
                        if Self.metaDetailsNeedsRepublish(current: self.metaDetails, next: details) {
                            // Compute the streams-only diff BEFORE the assignment, then bump the
                            // source-list epoch only when the ready-stream set (or the loaded meta)
                            // really changed, so a library/progress-only republish never triggers a
                            // source-list rebuild.
                            let streamsChanged = Self.metaDetailsStreamsChanged(current: self.metaDetails, next: details)
                            self.metaDetails = details
                            if streamsChanged { self.streamsEpoch &+= 1 }
                        }
                        // Re-find sources: the minimal Unload -> nil -> Load arm, independent of the Apple CW
                        // authoritative refresh. The Unload's nil meta_details receipt is the only thing that
                        // opens the exact Load (a same-ID ready re-emit is NOT invalidation). One-shot: clear
                        // the request as the Load is dispatched, then the ordinary republish above refills the
                        // source list from the fresh sources as they land.
                        if let refind = self.refindRequest, refind.awaitingInvalidation, details == nil {
                            self.refindRequest = nil
                            self.dispatch(
                                action: self.metaLoadAction(
                                    type: refind.type, id: refind.id,
                                    streamType: refind.streamType, streamId: refind.streamID
                                ),
                                field: "meta_details"
                            )
                        }
                        guard let request = self.appleCWMetaRefreshRequest,
                              let refreshGenerationAtSchedule,
                              AppleCWMetaRefreshGenerationFence.owns(
                                  capturedGeneration: refreshGenerationAtSchedule,
                                  activeGeneration: request.generation
                              ) else { return }
                        let settledForRequest = Self.appleCWMetaRefreshIsSettled(
                            details, libraryID: request.libraryID, streamID: request.streamID
                        )
                        switch request.phase {
                        case .awaitingInvalidation:
                            // A same-ID ready re-emit is explicitly NOT invalidation. Leave the request
                            // pending so an unrelated event cannot turn a Load no-op into proof. Only the
                            // explicit Unload's nil meta_details receipt opens the exact Load phase.
                            guard details == nil else { return }
                            self.appleCWMetaRefreshRequest?.phase = .awaitingLoadSettlement
                            self.dispatch(
                                action: self.metaLoadAction(
                                    type: request.type, id: request.libraryID,
                                    streamType: request.streamType, streamId: request.streamID
                                ),
                                field: "meta_details"
                            )
                        case .awaitingLoadSettlement:
                            guard settledForRequest else { return }
                            self.appleCWMetaRefreshReceipt = AppleCWMetaRefreshReceipt(
                                requestGeneration: request.generation,
                                selectedMetaID: details?.selectedMetaID,
                                loadedMetaID: details?.meta?.id,
                                settled: true,
                                requestedStreamID: request.streamID
                            )
                            self.appleCWMetaRefreshDetails = details
                            self.appleCWMetaRefreshRequest = nil
                        }
                    }
                }
            }
            self.metaDetailsWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.metaDetailsDebounce, execute: work)
        }
    }

    private static func appleCWMetaRefreshIsSettled(_ details: CoreMetaDetails?,
                                                    libraryID: String, streamID: String) -> Bool {
        details?.appleCWTerminalFullMeta(for: libraryID, streamID: streamID) != nil
    }

    /// True when the newly decoded meta_details differs from the stored one in a way the UI or the
    /// in-player episode-switch path (which reads `streamGroups(forStreamId:)` off the stored value)
    /// would observe: the selected request id, metadata resolution, loaded meta id, per-group
    /// ready-stream signature (so a new episode's streams or newly landed sources always republish),
    /// or the library/watched bits behind the In-Library button and watched dots. A pure re-emit of
    /// the identical loaded payload returns false, which drops the redundant source-search republishes.
    private static func metaDetailsNeedsRepublish(current: CoreMetaDetails?, next: CoreMetaDetails?) -> Bool {
        // Presence flips always republish (spinner -> loaded, or unload).
        guard let current, let next else { return (current != nil) != (next != nil) }
        // `meta` is nil while an add-on is loading and after every add-on has failed. Publish both
        // the selection change and pending-to-unresolved transition so detail recovery sees the
        // terminal state even when the ready meta and stream signatures remain empty.
        if current.selectedMetaID != next.selectedMetaID { return true }
        if current.metaResolution != next.metaResolution { return true }
        if current.meta?.id != next.meta?.id { return true }
        if current.libraryItem?.id != next.libraryItem?.id
            || current.libraryItem?.removed != next.libraryItem?.removed
            || current.libraryItem?.temp != next.libraryItem?.temp
            // Playback-state progress MUST re-publish: engineResumeSeconds reads libraryItem.state.timeOffset +
            // videoId at player open, so without these the resume position latched at the open-time value (~10s)
            // no matter how long you watched, and only a back-to-Home re-entry re-seeded it (0.3.11 regression).
            // This only re-publishes the already-decoded value (no extra decode); the ~90s engine library push
            // cadence keeps it cheap, and during source search timeOffset does not change so the search-churn
            // suppression this predicate exists for is unaffected.
            || current.libraryItem?.state.timeOffset != next.libraryItem?.state.timeOffset
            || current.libraryItem?.state.videoId != next.libraryItem?.state.videoId
            || current.libraryItem?.state.duration != next.libraryItem?.state.duration
            // A manual "Mark as Watched" on a movie (or one whose position never advanced, e.g. flagged
            // watched with no active offset) flips ONLY flaggedWatched/timesWatched: timeOffset, duration,
            // videoId, libraryItem.id/removed/temp and watchedVideoIds.count all stay exactly as they were.
            // Without comparing these two fields, that mark landed on the engine (Library tab / Continue
            // Watching, which decode fresh every event) but `core.metaDetails` never republished, so the
            // open detail page's own watched checkmark (state.timesWatched > 0) stayed stuck on the stale
            // value until an unrelated field changed or the page reloaded.
            || current.libraryItem?.state.flaggedWatched != next.libraryItem?.state.flaggedWatched
            || current.libraryItem?.state.timesWatched != next.libraryItem?.state.timesWatched
            || WatchedMembershipPolicy.changed(current.watchedVideoIds, next.watchedVideoIds) {
            return true
        }
        // Signature over BOTH stream surfaces: the meta-embedded groups (metaStreams, the HTTP/HLS
        // add-on shape, #122) land on the meta republish, and without them in the diff that arrival
        // looked like "nothing changed" and the source list never rebuilt.
        return streamSetSignature(current.allStreamGroups) != streamSetSignature(next.allStreamGroups)
    }

    /// True when a republish changed something the SOURCE LIST derives from: presence, the loaded
    /// meta id, or the per-group ready-stream signature. Library/watched/progress-only republishes
    /// return false, so `streamsEpoch` (the source-list rebuild key) never bumps on a ~20s progress
    /// save while the stream set is unchanged.
    private static func metaDetailsStreamsChanged(current: CoreMetaDetails?, next: CoreMetaDetails?) -> Bool {
        guard let current, let next else { return (current != nil) != (next != nil) }
        if current.selectedMetaID != next.selectedMetaID { return true }
        if current.meta?.id != next.meta?.id { return true }
        // Both surfaces, matching metaDetailsNeedsRepublish: a metaStreams arrival must bump streamsEpoch.
        return streamSetSignature(current.allStreamGroups) != streamSetSignature(next.allStreamGroups)
    }

    /// A cheap signature of the ready streams per source group: the group's path id plus its ready
    /// stream count. It changes when new sources land for the current episode, when a group errors in,
    /// or when a different episode's streams arrive (a new path id), which is exactly when the source
    /// list / episode-switch poll needs the fresh value. It does NOT change on an identical re-emit.
    private static func streamSetSignature(_ groups: [CoreStreamGroup]) -> [String] {
        // Encode the LOADED STATE, not just the ready count. A group in .loading and a group in .err both have
        // ready==nil, so keying on the count alone made a loading->err transition invisible: when the LAST
        // unresolved add-on errored, metaDetails was not republished, streamLoadProgress stayed at N-1/N, and
        // the source-list spinner + the resolveSettled auto-pick waited out the settle timeout. Distinguish
        // ready(count) vs loading vs err so that transition republishes at once.
        groups.map { g -> String in
            let marker: String
            switch g.content {
            case .ready(let r)?: marker = "r\(r.count)"
            case .loading?:      marker = "L"
            case .err?:          marker = "E"
            case .none:          marker = "-"
            }
            return "\(g.request.path.id)#\(marker)"
        }
    }

    // MARK: Board assembly

    /// Coalesce a burst of `board` / `ctx` emits into ONE board rebuild. Called from the worker thread on every
    /// such emit; it hops to the main actor (where the debounce state lives), cancels any pending rebuild, and
    /// schedules a single trailing one ~80 ms after the last emit. The rebuild's heavy JSON decode
    /// (`buildBoardRows`) runs off the main thread; only the `boardRows` assignment lands on main. Net effect:
    /// the launch/page-land storm that used to fire N full decodes + N republishes now fires exactly one.
    private func scheduleBoardRebuild() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.boardRebuildWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Decode + assemble off the main thread (same as the old inline path, which also ran off-main).
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { return }
                    let rows = self.buildBoardRows()
                    let boardState = self.decode(CoreBoardState.self, field: "board")
                    // [engine] one board line per coalesced rebuild (catalogs the engine holds -> visible rows).
                    VXProbe.log("engine", "board changed catalogs=\(boardState?.catalogs.count ?? 0) rows=\(rows.count)")
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.reconcileBoardRowPagination(boardState)   // #95: settle per-row horizontal pagination
                        self.boardCatalogTotal = boardState?.catalogs.count ?? 0
                        self.boardRows = rows
                        self.boardPageInFlight = false
                        // The board emit is the authoritative raw total. If an explicit order is
                        // already stored, close any gap left by an interim ctx manifest count.
                        if !CatalogPrefsStore.order().isEmpty {
                            self.ensureCatalogOrderRangeLoaded(installedCatalogTotal: 0)
                        }
                    }
                }
            }
            self.boardRebuildWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.boardRebuildDebounce, execute: work)
        }
    }

    /// Build titled board rows: merge each catalog's ready pages into one item list and resolve a
    /// human title from the installed-addon manifests. Rows with no loaded items are skipped, so they
    /// appear as their content arrives (no empty placeholders).
    private func buildBoardRows() -> [CoreBoardRow] {
        guard let board = decode(CoreBoardState.self, field: "board") else { return [] }
        let titles = catalogTitleMap()
        let disabledAddons = ProfileStore.activeDisabledAddons()   // per-profile add-on set, hoisted once
        // Removed-but-engine-retained add-ons (see `tombstonedBases`): their rows must not render on
        // Home, matching the catalog manager filter, or a removed add-on's rows would ghost with no
        // manager entry left to hide them (#121).
        let ghostBases = Self.tombstonedBases(in: decode(CoreCtx.self, field: "ctx")?.profile.addons ?? [])
        var rows: [CoreBoardRow] = []
        for (engineIndex, catalog) in board.catalogs.enumerated() {
            guard let request = catalog.first?.request else { continue }
            guard !disabledAddons.contains(request.base) else { continue }
            guard !ghostBases.contains(AddonTombstones.normalize(request.base)) else { continue }
            let items = catalog.compactMap { $0.content?.ready }.flatMap { $0 }
            guard !items.isEmpty else { continue }
            let key = Self.catalogKey(base: request.base, type: request.path.type, id: request.path.id)
            if CatalogPrefsStore.isHidden(key) { continue }   // user hid this catalog row (catalog manager)
            rows.append(CoreBoardRow(id: key, title: titles[key] ?? request.path.id,
                                     type: request.path.type, items: items, engineIndex: engineIndex))
        }
        // Apply the user's catalog order; unlisted catalogs keep the engine's relative order after the listed ones.
        return rows.enumerated().sorted { a, b in
            let ra = CatalogPrefsStore.rank(a.element.id), rb = CatalogPrefsStore.rank(b.element.id)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// One catalog an installed add-on provides, for the catalog manager editor.
    struct CatalogInfo: Identifiable {
        let key: String
        let title: String
        let addonName: String
        let type: String
        var id: String { key }
    }

    /// Every catalog the installed add-ons provide (deduped by key), titled the same way the board is.
    /// Excludes the catalogs of REMOVED add-ons the engine still holds (see `tombstonedBases`), so the
    /// catalog manager never lists a ghost entry for an add-on the user uninstalled (#121).
    var allCatalogs: [CatalogInfo] {
        installedCatalogs(includeTombstoned: false, includeDisabled: false)
    }

    /// Normalized transport URLs of engine-ctx add-ons the user REMOVED (durable `AddonTombstones`)
    /// that are still present in the engine collection. In the pull-only default (mirror OFF with a
    /// live Stremio session) `uninstallAddon`/`refreshAddons` intentionally leave the engine collection
    /// (and the user's Stremio account) intact and only suppress the add-on from the published `addons`
    /// list, so every other ctx-derived read surface (the Home board rows, the catalog manager list)
    /// must subtract this set too, or a removed add-on's catalogs ghost forever (#121). Read-side only:
    /// stored hide/order prefs for a ghost key stay intact, so a genuine reinstall gets the user's old
    /// catalog prefs back. PROTECTED stubs (Cinemeta, Local Files) are never suppressed; a removable
    /// official add-on the user deleted IS, mirroring `refreshAddons` (#137).
    private static func tombstonedBases(in addons: [CoreDescriptor]) -> Set<String> {
        let removed = AddonTombstones.all()
        guard !removed.isEmpty else { return [] }
        var out = Set<String>()
        for addon in addons where !addon.isProtected {
            let key = AddonTombstones.normalize(addon.transportUrl)
            if removed.contains(key) { out.insert(key) }
        }
        return out
    }

    /// The enumeration behind `allCatalogs`. `includeTombstoned: true` keeps the catalogs of removed
    /// add-ons the engine still holds, and `includeDisabled: true` keeps the catalogs of add-ons the
    /// active profile disabled: `ensureLiveCatalogsLoaded` needs that RAW count because both kinds of
    /// catalog still occupy engine board indices, so widening the board by a filtered count could
    /// leave trailing live catalogs outside the range-loaded window.
    private func installedCatalogs(includeTombstoned: Bool, includeDisabled: Bool) -> [CatalogInfo] {
        guard let ctx = decode(CoreCtx.self, field: "ctx") else { return [] }
        var out: [CatalogInfo] = []
        var seen = Set<String>()
        let disabledAddons: Set<String> = includeDisabled ? [] : ProfileStore.activeDisabledAddons()   // per-profile add-on set, hoisted once
        let ghostBases: Set<String> = includeTombstoned ? [] : Self.tombstonedBases(in: ctx.profile.addons)
        for addon in ctx.profile.addons {
            guard !disabledAddons.contains(addon.transportUrl) else { continue }
            guard !ghostBases.contains(AddonTombstones.normalize(addon.transportUrl)) else { continue }
            for catalog in addon.manifest.catalogs {
                let key = Self.catalogKey(base: addon.transportUrl, type: catalog.type, id: catalog.id)
                guard seen.insert(key).inserted else { continue }
                out.append(CatalogInfo(key: key,
                                       title: Self.displayCatalogTitle(name: catalog.name ?? catalog.id, type: catalog.type),
                                       addonName: addon.manifest.name, type: catalog.type))
            }
        }
        return out
    }

    /// Rebuild the board (e.g. after a catalog-preference change) and republish on the main queue.
    func rebuildBoardRows() {
        let rows = buildBoardRows()
        DispatchQueue.main.async { [weak self] in self?.boardRows = rows }
    }

    /// The Home board rows whose content type is Live TV (tv / channel / events), for the Live
    /// surface. Derived from the already-published `boardRows`, so it tracks the engine's catalog
    /// state live without a second decode and stays correct as add-ons are installed/removed.
    var liveBoardRows: [CoreBoardRow] {
        boardRows.filter { LiveTypes.contains($0.type) }
    }

    /// `{base|type|id → "Catalog name"}` from the installed addons' manifests. The addon's own catalog
    /// name is already descriptive (e.g. "Debridio TMDB - Trending Movies"), so we don't prefix the
    /// addon name.
    private func catalogTitleMap() -> [String: String] {
        guard let ctx = decode(CoreCtx.self, field: "ctx") else { return [:] }
        var map: [String: String] = [:]
        for addon in ctx.profile.addons {
            for catalog in addon.manifest.catalogs {
                let key = Self.catalogKey(base: addon.transportUrl, type: catalog.type, id: catalog.id)
                map[key] = Self.displayCatalogTitle(name: catalog.name ?? catalog.id, type: catalog.type)
            }
        }
        return map
    }

    /// Distinguish same-named movie/series catalogs, addons routinely name both "Trending", which renders
    /// as two identical "Trending" rows. Append the content type unless the name already says it (so an
    /// already-descriptive "… Trending Movies" isn't doubled).
    private static func displayCatalogTitle(name: String, type: String) -> String {
        let lower = name.lowercased()
        let t = type.lowercased()
        let label: String
        switch t {
        case "movie":   label = "Movies"
        case "series":  label = "Shows"
        case "channel": label = "Channels"
        case "tv":      label = "TV"
        default:        return AddonTerms.localize(name)
        }
        // Capture the add-on's category name + content-type label and localize each against our own term
        // dictionary (Stremio does the same); unknown add-on names pass through unchanged.
        if lower.contains(t) || lower.contains(label.lowercased()) { return AddonTerms.localize(name) }
        // Prefer a real whole-phrase translation ("Popular Shows" -> fr "Séries populaires") before
        // falling back to word-wise concatenation. Concatenating the individually-localized words
        // keeps English adjective/noun order ("Populaires émissions"), which is wrong in French and
        // other adjective-after-noun languages; the phrase key preserves natural grammar, and the
        // nil fallback keeps locales without a phrase byte-identical to the old output (#203).
        let phrase = "\(name) \(label)"
        if let whole = AddonTerms.localizeWhole(phrase) { return whole }
        return "\(AddonTerms.localize(name)) \(AddonTerms.localize(label))"
    }

    private static func catalogKey(base: String, type: String, id: String) -> String {
        "\(base)|\(type)|\(id)"
    }

    /// The engine's persisted-state directory: the SINGLE source of truth for where stremio-core
    /// keeps its buckets. `start()` hands this exact directory to the engine; `WatchedIndex` reads
    /// the persisted library buckets (library_recent.json / library.json) from it. Any reader must
    /// consume THIS, never re-derive the path, so relocating it here can never silently strand a
    /// reader on the old path (#111 review).
    static let storageDirURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("stremio-core", isDirectory: true)

    /// Create-if-needed and return the engine-facing path for a directory URL (the C init takes
    /// plain paths).
    private static func makeDir(at url: URL) -> String {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private static func makeDir(_ directory: FileManager.SearchPathDirectory, _ name: String) -> String {
        let base = FileManager.default.urls(for: directory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }
}

// MARK: - Search suggestions

extension CoreBridge {
    /// Autocomplete titles for `.searchSuggestions`, shared between tvOS and iOS/macOS search.
    ///
    /// Priority order:
    /// 1. Continue-watching titles that substring-match (personal, small, high signal).
    /// 2. Engine suggestion catalog, interleaved movie/series (may be empty depending on addons).
    /// 3. Current search results, interleaved by type (primary source when engine catalog is empty).
    /// 4. Home board rows as a last-resort fallback.
    ///
    /// All sources are filtered to titles that contain `query` as a case/diacritic-insensitive
    /// substring. The engine's suggestion API does fuzzy/related matching and can return unrelated
    /// titles; the substring guard drops them client-side. Results are capped at 10.
    func searchSuggestionTitles(for query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var seen = Set<String>()
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        func keep(_ title: String) -> Bool {
            title.caseInsensitiveCompare(trimmed) != .orderedSame
                && title.range(of: trimmed, options: opts) != nil
                && seen.insert(title).inserted
        }

        func interleaved<T>(from items: [T], typeAt: KeyPath<T, String>, nameAt: KeyPath<T, String>) -> [String] {
            let filtered = items.filter { keep($0[keyPath: nameAt]) }
            let movies = filtered.filter { $0[keyPath: typeAt] == "movie" }
            let series = filtered.filter { $0[keyPath: typeAt] == "series" }
            let other  = filtered.filter { $0[keyPath: typeAt] != "movie" && $0[keyPath: typeAt] != "series" }
            var mixed: [String] = []
            for i in 0..<max(movies.count, series.count) {
                if i < movies.count { mixed.append(movies[i][keyPath: nameAt]) }
                if i < series.count { mixed.append(series[i][keyPath: nameAt]) }
            }
            return mixed + other.map { $0[keyPath: nameAt] }
        }

        let watching     = continueWatching.map(\.name).filter { keep($0) }
        let engineMixed  = interleaved(from: searchSuggestions, typeAt: \.type, nameAt: \.name)
        let resultsMixed = interleaved(from: searchResults,     typeAt: \.type, nameAt: \.name)
        let board        = boardRows.flatMap(\.items).filter { keep($0.name) }.map(\.name)

        return Array((watching + engineMixed + resultsMixed + board).prefix(10))
    }
}

/// Top-level C callback (no captures allowed). `ctx` is deliberately unused: resolving the
/// process-lifetime singleton directly is always safe, while dereferencing an unretained
/// pointer from a Rust worker thread would be a use-after-free if the bridge were ever
/// deallocated.
private func coreEventCallback(ctx: UnsafeMutableRawPointer?, data: UnsafePointer<UInt8>?, len: Int) {
    guard let data, len > 0 else { return }
    let bytes = Data(bytes: data, count: len) // copy synchronously, `data` is only valid during this call
    CoreBridge.shared.handleEvent(bytes)
}
