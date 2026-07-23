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
    private var started = false
    /// Coalesces the Home-board rebuild. The engine emits a BURST of `board` events during launch and while a
    /// catalog page lands (one per catalog settling), and each event used to trigger a full `buildBoardRows()`
    /// JSON decode + a `boardRows` republish + a hero reseed, which was a real main-thread stall on open. This
    /// timer collapses a burst into a single trailing rebuild ~80 ms after the last event, so the board still
    /// updates but only once per burst. Touched only on the main actor.
    private var boardRebuildWork: DispatchWorkItem?
    private static let boardRebuildDebounce: TimeInterval = 0.08
    /// Coalesces the `meta_details` re-decode+publish. Source search for a high-source title emits a BURST
    /// of `meta_details` events as stream batches land (GoT: ~11 re-emits of the same 1757-row payload as it
    /// grows), and each used to run a full off-main decode + a main-thread republish, invalidating every
    /// view subscribed to CoreBridge (including the presented player). This timer collapses a burst into one
    /// trailing decode ~90 ms after the last emit, and the decode then DIFFS against the stored value so an
    /// identical re-emit republishes nothing. An episode switch still lands within one debounce window (well
    /// inside the in-player 20s / 250ms poll), so next-episode / binge is unaffected. Touched only on main.
    private var metaDetailsWork: DispatchWorkItem?
    private static let metaDetailsDebounce: TimeInterval = 0.09
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
        // Home board rebuild consumer (H1). A reorder from ANY channel posts
        // `VortXSyncManager.addonOrderChangedNote`: an in-app reorder (applyInAppAddonOrder), a remote pull
        // that carried a newer order (syncDown), or an account transition (bindAddonOrderOwner). Re-sort and
        // republish the ALREADY-published board rows so an open Home reflects the new order immediately, and
        // widen the load window so a promoted add-on's off-window catalogs hydrate (H4). Without this the
        // published Home rows kept the old order until an unrelated rebuild. queue:.main -> the block runs on
        // the main thread, where boardRows is published. The open source list re-sorts through its OWN
        // observer of the same note (SourceListModel, H2).
        NotificationCenter.default.addObserver(forName: VortXSyncManager.addonOrderChangedNote,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.handleAddonOrderChanged()
        }
    }

    /// React to an add-on order change (local reorder, remote pull, or account switch). Widens the board so a
    /// promoted off-window catalog can appear at all (H4), then re-sorts and republishes the currently-loaded
    /// rows now (H1). Idempotent and cheap when no order is applied.
    private func handleAddonOrderChanged() {
        ensureReorderedCatalogsLoaded()
        rebuildBoardRows()
    }

    /// When the user has an applied add-on reorder, make sure the Home board's LoadRange window is wide enough
    /// to cover EVERY installed catalog, so a promoted add-on whose catalogs sit at raw engine slot 31+ (past
    /// the default 30-row initial window) actually hydrate and can then be sorted to the front by
    /// `buildBoardRows`. Without this, `buildBoardRows` drops the promoted add-on's unloaded (empty) rows, so a
    /// reordered add-on stays ABSENT (not merely "not first") until old-order infinite scroll happens to widen
    /// the range (H4 / the raw-LoadRange window). Reuses the exact proven widen mechanism as
    /// `ensureLiveCatalogsLoaded`. No-op when there is no applied order (the shipping default: zero extra
    /// startup / network cost) or once the window already covers every catalog. ACCEPTED COST: an account WITH
    /// a reorder loads its full catalog window up front instead of paginating it in; bounded (a real account
    /// has a few dozen catalogs) and idempotent.
    func ensureReorderedCatalogsLoaded() {
        guard !VortXSyncManager.appliedAddonOrder.isEmpty else { return }
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
    /// installer every UI routes through) calls `AddonTombstones.forget` on a successful explicit install,
    /// so the URL leaves the set before the engine re-emits ctx and is therefore NOT suppressed here.
    private func refreshAddons() {
        let typed = decode(CoreCtx.self, field: "ctx")?.profile.addons ?? []
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
            DispatchQueue.main.async { [weak self] in
                self?.addons = survivingTyped
                self?.rawAddonsByUrl = publishedRaw
            }
            return
        }
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

    /// Install an add-on from its manifest URL. Stremio add-on URLs ARE the manifest.json URL; we fetch
    /// it, build the full Descriptor the engine's InstallAddon action expects (mirroring UninstallAddon's
    /// contract), and dispatch it. The engine's ctx event then refreshes `addons`. Returns a user-facing
    /// error string on failure, nil on success.
    /// Normalize a pasted add-on URL the way installAddon does (trim + ensure a /manifest.json suffix),
    /// so AddonsView can detect an already-installed URL and offer to UPDATE it instead of erroring.
    /// Nil if it is not a valid http(s) URL.
    func normalizedAddonURL(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        if !url.absoluteString.lowercased().hasSuffix("manifest.json") {
            url = url.appendingPathComponent("manifest.json")
        }
        return url.absoluteString
    }

    @MainActor
    func installAddon(urlString: String, replacingExisting: Bool = false) async -> String? {
        guard let normalized = normalizedAddonURL(urlString), let url = URL(string: normalized) else {
            return "Enter a valid add-on URL (https://…/manifest.json)."
        }
        let alreadyInstalled = addons.contains(where: { $0.transportUrl == normalized })
        if alreadyInstalled, !replacingExisting { return "That add-on is already installed." }
        // SSRF guard: fetch through AddonURLGuard, which validates the host + every RESOLVED address (and each
        // redirect hop) against the private/loopback/link-local/CGNAT/ULA ranges and refuses a private target.
        // A pasted or QR-relayed URL can never point the install fetch at 127.0.0.1 / a LAN service / a cloud
        // metadata endpoint. Fail-closed for private targets; normal public manifests are unaffected.
        switch await AddonURLGuard.fetch(url) {
        case .failure(let rejection):
            return rejection.message
        case .success(let (data, _)):
            guard let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  manifest["id"] != nil, manifest["name"] != nil else {
                return "That URL did not return a valid add-on manifest."
            }
            // Update in place: drop the existing descriptor ONLY now that the new manifest is fetched +
            // validated, so a flaky fetch / bad manifest can never leave the user with NEITHER the old nor
            // the new add-on (the install-first invariant the Change-URL path also holds). The engine
            // processes Uninstall before Install, so the freshly-fetched manifest replaces the old one.
            if alreadyInstalled, let existing = rawAddonsByUrl[normalized] {
                dispatchCtx(["action": "UninstallAddon", "args": existing])
            }
            // An EXPLICIT install supersedes any prior removal tombstone for this URL: clear it so the
            // freshly-installed add-on is not instantly re-uninstalled by refreshAddons' tombstone
            // enforcement, and so the next sync push stops carrying the stale removal in the account doc.
            // A genuine fresh install of a previously-deleted add-on therefore works on every device.
            AddonTombstones.forget(url.absoluteString)
            let descriptor: [String: Any] = [
                "transportUrl": url.absoluteString,
                "manifest": manifest,
                "flags": ["official": false, "protected": false],
            ]
            dispatchCtx(["action": "InstallAddon", "args": descriptor])
            return nil
        }
    }

    /// Result of validating a pasted / QR-relayed manifest URL WITHOUT installing it. Used by the
    /// Install-by-QR pairing view to show "Install <name>?" and to know whether a URL is already
    /// installed, using the SAME fetch + validation `installAddon` performs (same normalization, same
    /// 200 + `id`/`name` manifest check). This never mutates engine state; `installAddon` stays the
    /// one and only installer, so its validation is not bypassed or weakened.
    struct AddonManifestPreview: Equatable {
        let normalizedURL: String
        let name: String
        let alreadyInstalled: Bool
    }

    /// Fetch + validate a manifest URL the way `installAddon` does, returning its name (for a confirm
    /// prompt) without installing. Returns nil when the URL is invalid or the manifest fails validation.
    /// The actual install still goes through `installAddon`, which re-fetches and re-validates.
    @MainActor
    func previewAddonManifest(urlString: String) async -> AddonManifestPreview? {
        guard let normalized = normalizedAddonURL(urlString), let url = URL(string: normalized) else { return nil }
        let alreadyInstalled = addons.contains(where: { $0.transportUrl == normalized })
        // SSRF guard: same private-address gate `installAddon` uses (the QR confirm resolves the name here),
        // so a manifest URL pointing at a private/loopback/LAN address never even previews. Fail-soft to nil.
        guard case let .success((data, _)) = await AddonURLGuard.fetch(url),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              manifest["id"] != nil,
              let name = manifest["name"] as? String, !name.isEmpty else { return nil }
        return AddonManifestPreview(normalizedURL: normalized, name: name, alreadyInstalled: alreadyInstalled)
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
    /// flags}`, camelCase) — the engine mutates `ctx.profile.addons` LOCALLY with no api.strem.io call.
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
            // profile) so a signed-out Home is a real, browsable landing screen — backdrop hero + rails
            // — not an empty "please sign in" page. Discover already loads signed-out; Home should too.
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
    /// data OR no stream add-on, re-establish the session from the token — the engine then pulls
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
                    NSLog("%@", "[CoreBridge] degraded session (\(noStreamAddon ? "no stream add-on" : "no account data")) with a stored token — hydrated account add-ons, now re-authenticating to reconcile from Stremio")
                    self.switchAccount(token: key)
                } else {
                    NSLog("[CoreBridge] degraded session with no Stremio token — recovered from the VortX account doc")
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
    /// next library sync — and nothing scheduled one after playback, so the Home dashboard's Continue
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
            self.library = nil
            self.metaDetails = nil
        }
    }

    /// Load the Home board: every catalog of every installed addon, then fetch the first `rows`.
    /// (Targets the `board` field specifically, `search` is also a CatalogsWithExtra.)
    func loadBoard(rows: Int = 30) {
        boardRowsLoaded = rows
        boardPageInFlight = false
        boardRowPageInFlight = [:]   // catalogs reload from page 1, so engine indices reset (#95)
        boardRowExhausted = []
        dispatch(action: ["action": "Load",
                          "args": ["model": "CatalogsWithExtra",
                                   "args": ["type": NSNull(), "extra": []]]],
                 field: "board")
        dispatch(action: ["action": "CatalogsWithExtra",
                          "args": ["action": "LoadRange", "args": ["start": 0, "end": rows]]],
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

    /// True while the last board load filled its requested window, so there may be more catalogs to show.
    /// Once the engine returns fewer rows than asked, every catalog is on screen and this goes false.
    var boardHasNextPage: Bool { boardRows.count >= boardRowsLoaded }

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

    /// Load the next page of the current Discover catalog (infinite scroll). The engine appends the
    /// page to `discover.catalog` and clears `next_page` at the end. No-op at the end or while a page
    /// is already in flight. Previously missing entirely — the catalog stopped at its first page, which
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

    /// Search across the installed addons (engine `search` field = CatalogsWithExtra with a search
    /// extra). Results land in `searchResults`, flattened and de-duplicated into one grid.
    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        setSearchLoading(trimmed.count >= 2)
        guard trimmed.count >= 2 else {
            DispatchQueue.main.async { [weak self] in self?.searchResults = [] }
            return
        }
        dispatch(action: ["action": "Load",
                          "args": ["model": "CatalogsWithExtra",
                                   "args": ["type": NSNull(), "extra": [["search", trimmed]]]]],
                 field: "search")
        dispatch(action: ["action": "CatalogsWithExtra",
                          "args": ["action": "LoadRange", "args": ["start": 0, "end": 30]]],
                 field: "search")
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

    /// Load a title's meta + streams. For a series episode, pass the episode's video id as the stream
    /// path so the engine fetches that episode's streams.
    func loadMeta(type: String, id: String, streamType: String? = nil, streamId: String? = nil) {
        var args: [String: Any] = [
            "metaPath": ["resource": "meta", "type": type, "id": id, "extra": []],
            "guessStream": true,
        ]
        if let streamType, let streamId {
            args["streamPath"] = ["resource": "stream", "type": streamType, "id": streamId, "extra": []]
        } else {
            args["streamPath"] = NSNull()
        }
        dispatch(action: ["action": "Load", "args": ["model": "MetaDetails", "args": args]], field: "meta_details")
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
        // SOURCE DISPLAY / GROUP ORDER: the engine hands these groups back in raw `profile.addons` order (the
        // `AggrRequest::AllOfResource` walk), which the add-on reorder never rewrites. Re-order them by the
        // user's applied priority so a reordered add-on's streams APPEAR FIRST in the source list. This is the
        // single chokepoint feeding every stream consumer, so ordering here moves the DISPLAYED order of all
        // of them at once. Whether the AUTO-SELECTED "Watch Now" source follows this order is a SEPARATE,
        // explicit choice: `StreamRanking.best` honors this group order only when the user's
        // `SourcePreferences.useAddonOrder` is on; on the shipping default it still scores globally for the
        // best-quality source (see StreamRanking). So this controls which add-on appears first, not the
        // engine's internal request priority (DIS-05, out of scope) and not the default auto-pick. Groups are
        // keyed by `id` == the add-on transport base; an empty applied order is a no-op (engine order
        // preserved), and add-ons the user has not placed keep their engine order at the end.
        return AddonPriorityOrder.order(groups, applied: VortXSyncManager.appliedAddonOrder, base: { $0.id })
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
    /// for `EmptyContent` (the add-on returned an empty list — not an error). Tagged-enum shapes:
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
        if overlayMarkWatched(isWatched, videoIds: { meta in (meta.videos ?? []).map(\.id) }) { return }
        // MarkAsWatched(false) did not clear the per-video watched state the episode
        // ticks read from, so "Mark Whole Series Unwatched" left every tick in place.
        // Clear each video explicitly (the same path single-episode unwatch uses) so
        // the ticks actually drop; watched stays the efficient aggregate action.
        if isWatched {
            dispatchMetaDetails(["action": "MarkAsWatched", "args": true])
            return
        }
        guard let videos = metaDetails?.meta?.videos, !videos.isEmpty else {
            dispatchMetaDetails(["action": "MarkAsWatched", "args": false]); return
        }
        for v in videos {
            var payload: [String: Any] = ["id": v.id]
            if let season = v.season { payload["season"] = season }
            if let episode = v.episode { payload["episode"] = episode }
            dispatchMetaDetails(["action": "MarkVideoAsWatched", "args": [payload, false]])
        }
    }

    /// Mark every episode of a season watched/unwatched.
    func markSeasonWatched(_ season: Int, _ isWatched: Bool) {
        if overlayMarkWatched(isWatched, videoIds: { meta in
            (meta.videos ?? []).filter { $0.season == season }.map(\.id)
        }) { return }
        dispatchMetaDetails(["action": "MarkSeasonAsWatched", "args": [season, isWatched]])
    }

    /// Mark a single episode watched/unwatched. The engine's `Video` only needs `id`.
    func markVideoWatched(_ video: CoreVideo, _ isWatched: Bool) {
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
    func markPlaybackWatched(_ meta: PlaybackMeta, allowEngineWrite: Bool = true) {
        // External sync (Trakt/SIMKL): the definitive watch signal fans out from this shared chokepoint
        // (the 90% marker, the EOF path, and manual in-player marks all route here). Additive + fail-soft +
        // gated + once-latched inside the coordinator (owner profile only; a no-op with empty creds). It
        // never touches an engine libraryItem field, honoring the poison invariant.
        ScrobbleCoordinator.shared.watched(meta)
        guard ProfileStore.shared.activeUsesEngineHistory else {
            ProfileStore.shared.markWatched(meta: meta)   // overlay profile: private history only
            return
        }
        // Scrobble and overlay-profile state above are keyed by the explicit PlaybackMeta and remain safe even
        // when an episodic engine re-point failed. Only the owner-engine dispatch depends on confirmed Player
        // attribution; callers close this leg rather than suppressing the correct external watched signal.
        guard allowEngineWrite else { return }
        if meta.usesSeriesLifecycle {
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
        if engine > 0 { return engine }                                    // freshest local play wins
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
        if engine > 0 { return engine }                                    // freshest local play wins
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
    /// here at the data layer is the single backstop that covers all of them for every surface (tvOS Home
    /// and iOS/Mac both render `continueWatching` directly), so no view needs to change. `CoreCWItem.isFinished`
    /// defines "finished" per type (movies: watched-flag or >= 0.9 progress; series: current episode >= 0.9,
    /// so a mid-series roll-forward with a fresh low-progress episode is preserved).
    static func pruneFinished(_ items: [CoreCWItem]) -> [CoreCWItem] {
        items.filter { !$0.isFinished }
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
        let engine = Self.pruneFinished(decode(CoreCWPreview.self, field: "continue_watching_preview")?.items ?? [])
        let library = decode(CoreLibrary.self, field: "library")?.catalog ?? []
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let items = ProfileStore.shared.activeUsesEngineHistory
                ? Self.unionOwnerContinueWatching(engine: engine, library: library)
                : engine
            VXProbe.log("engine", "continueWatching rebuilt n=\(items.count) (engine=\(engine.count))")
            self.continueWatching = items
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
        var seen = Set(engine.map(\.id))
        var synthesized: [CoreCWItem] = []
        for item in library {
            // Real saved titles only: skip removed / temp markers, and skip anything the engine already
            // surfaces with a live offset (dedup, engine wins).
            guard !(item.removed ?? false), !(item.temp ?? false), !seen.contains(item.id) else { continue }
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
            seen.insert(item.id)
        }
        return engine + pruneFinished(synthesized)
    }

    /// Drop a finished title (a movie, or the last episode of a series) out of Continue Watching by
    /// rewinding its saved position to zero. `is_in_continue_watching()` is just `time_offset > 0`, so a
    /// title finished at its end position would otherwise linger forever. Rewind keeps the library entry
    /// (still marked watched) and its new-episode notifications, unlike a full removal.
    func finishedWatching(libraryId: String) {
        guard ProfileStore.shared.activeUsesEngineHistory else {
            ProfileStore.shared.finishedWatching(metaId: libraryId)   // overlay profile
            return
        }
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
        guard ProfileStore.shared.activeUsesEngineHistory else {
            // Overlay profile: save to the profile's private overlay, never the account library.
            if let meta = metaDetails?.meta {
                ProfileStore.shared.addLibraryEntry(metaId: meta.id, name: meta.name,
                                                    type: meta.type, poster: meta.poster)
            }
            return
        }
        guard let data = stateData("meta_details"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metaItems = object["metaItems"] as? [[String: Any]] else { return }
        for entry in metaItems {
            // Loadable serializes adjacently tagged: {"type":"Ready","content":{...meta...}}.
            // (Looking for a lowercase "ready" key here made this function a silent no-op,
            // which is why the Library button never saved from a detail page.)
            if let loadable = entry["content"] as? [String: Any],
               loadable["type"] as? String == "Ready",
               let meta = loadable["content"] as? [String: Any] {
                // An explicit add supersedes any prior removal tombstone for this id, so the freshly-added
                // title is not later suppressed by the recovery skip / union subtract and the next push stops
                // carrying the stale removal. Mirrors installAddon's AddonTombstones.forget on a fresh install.
                if let addedId = meta["id"] as? String { LibraryTombstones.forget(addedId) }
                dispatchCtx(["action": "AddToLibrary", "args": meta])
                NSLog("[CoreBridge] AddToLibrary dispatched for %@", (meta["id"] as? String) ?? "?")
                return
            }
        }
        NSLog("[CoreBridge] AddToLibrary found no ready meta in meta_details")
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
    func addCatalogItemToAccount(id: String, type: String, stampIntent: Bool = true) async -> Bool {
        let safeType = (type == "series") ? "series" : "movie"
        let safeId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let url = URL(string: "https://v3-cinemeta.strem.io/meta/\(safeType)/\(safeId).json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = obj["meta"] as? [String: Any], (meta["id"] as? String)?.isEmpty == false else { return false }
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
        if rawStream == nil, !stream.isTorrent, !stream.isUsenet {
            rawStream = firstReadyStream
            streamRequest = firstReadyRequest
        }
        guard let rawStream, let streamRequest, let metaRequest else {
            DiagnosticsLog.log("cw", "loadEnginePlayer no-op (meta_details/stream/metaRequest missing) — CW + progress will not track for this item")
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
    func reportProgress(timeSeconds: Double, durationSeconds: Double) {
        // Overlay profiles never feed the engine Player: it would write their progress into the
        // ACCOUNT library bucket and sync it, which is exactly what profile separation prevents.
        guard ProfileStore.shared.activeUsesEngineHistory else { return }
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

    // MARK: Event callback (invoked from a Rust worker thread)

    fileprivate func handleEvent(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else { return }
        guard name == "NewState", let fields = object["args"] as? [String] else {
            return // "CoreEvent" (auth results, errors, …) handled in a later step.
        }

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
        }
        // The board needs ctx (addon manifests) for row titles, so rebuild on either change. Coalesced: a
        // launch/page-land burst of `board` events collapses into a single trailing rebuild instead of N
        // full decodes + republishes (the on-open lag). The rebuild itself still decodes off-main.
        if fields.contains("board") || fields.contains("ctx") {
            scheduleBoardRebuild()   // [engine] board row count is logged there (coalesced, one per burst)
        }
        if fields.contains("ctx") {
            VXProbe.log("engine", "ctx/settings changed addons=\(decode(CoreCtx.self, field: "ctx")?.profile.addons.count ?? 0)")
            DispatchQueue.main.async { [weak self] in self?.addonNamesCache = nil }   // addon set changed → rebuild name map
            refreshAddons()
        }
        if fields.contains("meta_details") {
            // Coalesce a source-search burst into one trailing decode+diff (see metaDetailsWork). The heavy
            // 1757-stream decode used to run on this worker thread on every re-emit; now it runs once per
            // burst, and the diff drops the republish when nothing the UI / streamGroups needs has changed.
            scheduleMetaDetailsRepublish()
        }
        if fields.contains("discover") {
            let value = decode(CoreDiscover.self, field: "discover")
            VXProbe.log("engine", "discover changed items=\(value?.items.count ?? 0)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // End-stop (#95): a next-page load that has FULLY settled (no page still loading) without
                // growing the list means there are no more pages, whether the catalog was cursorless or its
                // cursor went nil mid-catalog. Gate on !isLoadingPage so the interim "Loading" emit (same
                // count, more coming) never latches exhausted early.
                if self.discoverPageInFlight, let v = value, !v.isLoadingPage, v.items.count <= self.discoverCountAtLoad {
                    self.discoverExhausted = true
                }
                self.discover = value
                // Clear the in-flight flag only once the load has settled, so onAppear bursts during the
                // page fetch can't fire a duplicate load (the interim "Loading" emit keeps it set).
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
        if fields.contains("library") {
            let value = decode(CoreLibrary.self, field: "library")
            VXProbe.log("engine", "library changed n=\(value?.catalog.count ?? 0)")
            DispatchQueue.main.async { [weak self] in self?.library = value }
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
                    || (current.watchedVideoIds?.count ?? 0) != (details?.watchedVideoIds?.count ?? 0)
                if changed { self.metaDetails = details }
            }
        }
        if fields.contains("search") {
            let board = decode(CoreBoardState.self, field: "search")
            let pages = board?.catalogs.flatMap { $0 } ?? []
            let hasLoadingPages = pages.isEmpty || pages.contains { page in
                guard let content = page.content else { return true }
                return content.isLoading
            }
            let items = pages.compactMap { $0.content?.ready }.flatMap { $0 }
            var seen = Set<String>(); var unique: [CoreMeta] = []
            for item in items where seen.insert(item.id).inserted { unique.append(item) }
            VXProbe.log("engine", "search changed results=\(unique.count) loading=\(hasLoadingPages)")
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
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changedFields = Set(fields)
            self.revision &+= 1
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
                        if Self.metaDetailsNeedsRepublish(current: self.metaDetails, next: details) {
                            // Compute the streams-only diff BEFORE the assignment, then bump the
                            // source-list epoch only when the ready-stream set (or the loaded meta)
                            // really changed, so a library/progress-only republish never triggers a
                            // source-list rebuild.
                            let streamsChanged = Self.metaDetailsStreamsChanged(current: self.metaDetails, next: details)
                            self.metaDetails = details
                            if streamsChanged { self.streamsEpoch &+= 1 }
                        }
                    }
                }
            }
            self.metaDetailsWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.metaDetailsDebounce, execute: work)
        }
    }

    /// True when the newly decoded meta_details differs from the stored one in a way the UI or the
    /// in-player episode-switch path (which reads `streamGroups(forStreamId:)` off the stored value)
    /// would observe: the loaded meta id, the per-group ready-stream signature (so a new episode's
    /// streams or newly landed sources always republish), or the library/watched bits behind the
    /// In-Library button and watched dots. A pure re-emit of the identical loaded payload returns false,
    /// which is what drops the ~11 redundant source-search republishes for a high-source title.
    private static func metaDetailsNeedsRepublish(current: CoreMetaDetails?, next: CoreMetaDetails?) -> Bool {
        // Presence flips always republish (spinner -> loaded, or unload).
        guard let current, let next else { return (current != nil) != (next != nil) }
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
            || (current.watchedVideoIds?.count ?? 0) != (next.watchedVideoIds?.count ?? 0) {
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
                        self.boardRows = rows
                        self.boardPageInFlight = false
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
            // Carry the TYPED add-on base (`request.base`) on the row, so the priority sort ranks by the real
            // add-on identity instead of reverse-parsing it back out of the composite key string.
            rows.append(CoreBoardRow(id: key, title: titles[key] ?? request.path.id,
                                     type: request.path.type, items: items, engineIndex: engineIndex,
                                     addonBase: request.base))
        }
        // Apply the user's order. The EXPLICIT per-catalog order (catalog manager, `CatalogPrefsStore.rank`)
        // still wins where set; among catalogs the user has not explicitly placed, the add-on PRIORITY order
        // (the reorder) groups each add-on's catalogs together so a reordered add-on's catalogs appear first on
        // Home, not just in the list; the engine catalog index is the final stable tiebreak. Previously the
        // fallback was raw engine order, so the reorder never touched Home at all. Ranks by the row's TYPED
        // `addonBase` (canonicalized inside orderCatalogRows), never a pipe-split of the composite key.
        return AddonPriorityOrder.orderCatalogRows(
            rows,
            applied: VortXSyncManager.appliedAddonOrder,
            base: { $0.addonBase },
            catalogRank: { CatalogPrefsStore.rank($0.id) },
            engineIndex: { $0.engineIndex })
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
