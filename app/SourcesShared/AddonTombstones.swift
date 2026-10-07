import Foundation

/// Local reconciliation receipts belong to one account, not to whichever account signs in next.
/// Legacy unowned receipts are quarantined behind a single authenticated-owner claim.
enum AddonOwnerStorage {
    static let legacyKeys = ["stremiox.addons.removedAt", "stremiox.addons.addedAt",
                             "stremiox.addons.deleted", "vortx.sync.appliedAddonOrder",
                             "vortx.sync.addonBaselineStampedV2"]
    private static let claimKey = "vortx.sync.addons.legacyClaim.v2"
    private static let migrationLock = NSLock()
    private struct Claim: Codable, Equatable {
        let format: Int
        let namespace: String
    }

    static func key(_ legacy: String, namespace: String) -> String {
        "vortx.sync.addonOwner.v2.\(namespace).\(legacy)"
    }

    static func currentKey(_ legacy: String) -> String {
        key(legacy, namespace: CredentialScopeRegistry.shared.capture().namespace)
    }

    /// The session boundary supplies eligibility only after authenticating its exact capture.
    /// Same-owner retry is allowed; a second owner, guest, or malformed marker cannot consume it.
    @discardableResult
    static func migrateLegacy(namespace: String, authenticated: Bool,
                              defaults: UserDefaults = .standard) -> Bool {
        guard authenticated, namespace.hasPrefix("account.") else { return false }
        migrationLock.lock()
        defer { migrationLock.unlock() }
        let claim = Claim(format: 1, namespace: namespace)
        if let raw = defaults.object(forKey: claimKey) {
            guard let data = raw as? Data,
                  (try? JSONDecoder().decode(Claim.self, from: data)) == claim else { return false }
        } else {
            guard let data = try? JSONEncoder().encode(claim) else { return false }
            defaults.set(data, forKey: claimKey)
            guard defaults.data(forKey: claimKey) == data else { return false }
        }
        for legacy in legacyKeys {
            let target = key(legacy, namespace: namespace)
            if legacy.hasSuffix("removedAt") || legacy.hasSuffix("addedAt") {
                var merged = finiteMap(defaults.dictionary(forKey: target) ?? [:])
                for (url, time) in finiteMap(defaults.dictionary(forKey: legacy) ?? [:]) {
                    merged[url] = max(merged[url] ?? 0, time)
                }
                TombstonePersistence.setMapIfChanged(merged, forKey: target, defaults: defaults)
                guard finiteMap(defaults.dictionary(forKey: target) ?? [:]) == merged else { return false }
            } else if legacy.hasSuffix("deleted") {
                let merged = Set((defaults.stringArray(forKey: target) ?? []) + (defaults.stringArray(forKey: legacy) ?? []))
                    .map(AddonTombstones.normalize).filter { !$0.isEmpty && $0.count <= 2048 }.sorted()
                TombstonePersistence.setArrayIfChanged(Array(Set(merged)).sorted(), forKey: target, defaults: defaults)
            } else if defaults.object(forKey: target) == nil, let value = defaults.object(forKey: legacy) {
                defaults.set(value, forKey: target)
                guard let actual = defaults.object(forKey: target),
                      (actual as AnyObject).isEqual(value) else { return false }
            }
        }
        return true
    }

    private static func finiteMap(_ raw: [String: Any]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (rawURL, value) in raw {
            let url = AddonTombstones.normalize(rawURL)
            guard !url.isEmpty, url.count <= 2048, let number = value as? NSNumber,
                  number.doubleValue.isFinite, number.doubleValue >= 0 else { continue }
            result[url] = max(result[url] ?? 0, number.doubleValue)
        }
        return result
    }
}

/// Durable cross-device REMOVE tombstones for add-ons, the add-on analogue of
/// `ProfileStore`'s `deletedProfiles` set. The app OWNS this set (it lives in
/// `doc.vortx.deletedAddons`, the app's namespace) so an add-on the user removed on one device can
/// never be resurrected by a peer device's UNION hydrate or a stale pre-removal cloud blob.
///
/// Today add-on hydration is install-only (UNION): `hydrateEngineFromOwnedAddons` reinstalls every
/// owned descriptor and `vortxSummary` re-unions the engine set into `doc.vortx.addons`, so a removal
/// on device A is silently undone on device B (and re-unioned back into the doc). This tombstone set
/// closes that gap exactly the way `deletedProfiles` closes it for profiles:
///
///  - WRITE on an in-app Remove (`CoreBridge.uninstallAddon`) so the removal syncs.
///  - PUSH the EFFECTIVE removed set into `doc.vortx.deletedAddons` from `vortxSummary`, and SUBTRACT it
///    from the `doc.vortx.addons` UNION so a removed add-on is never re-unioned back in.
///  - FOLD an incoming `doc.vortx.deletedAddons` (plus its `doc.vortx.deletedAddonsTs` companion, and a
///    web-authored `doc.webAddonRemovals`) into the local state on a SUCCESSFUL `.doc` pull, then
///    UNINSTALL any still-installed EFFECTIVELY-removed add-on from the engine.
///  - EXCLUDE effectively-removed URLs from `ownedAddons(from:)` so the hydrate path never reinstalls them.
///
/// LAST-WRITER-WINS model. Each transportUrl carries two per-entry timestamps: `removedAt` (stamped by
/// `tombstone`) and `addedAt` (stamped by `forget`). A URL is EFFECTIVELY removed iff `removedAt > addedAt`.
/// Entries are never deleted and each stamp only ever moves forward (local writes and the merge fold both
/// take the per-id MAX), so the set stays a monotone, union-style structure; the only extra bit over a plain
/// set is the recency of the last install versus the last removal, which is what lets a genuine reinstall
/// out-race a stale removal instead of a peer actively re-UNINSTALLING the reinstalled add-on.
///
/// WIRE COMPATIBILITY. `doc.vortx.deletedAddons` keeps its old shape (an array of URLs), now computed as the
/// EFFECTIVE removed set, so the dashboard and older app builds keep reading it exactly as before. The new
/// companion `doc.vortx.deletedAddonsTs` (url -> {removedAt, addedAt}) carries the stamps; clients that do not
/// know the field ignore it. An incoming URL that appears only in the legacy array (including the web-authored
/// `doc.webAddonRemovals`, which is stamp-less) with NO stamp entry is folded at the migration epoch, so any
/// real later reinstall out-races it. Mixed-fleet caveat: an older client's genuine re-removal is
/// indistinguishable from its stale re-emit until that client updates.
///
/// SAFETY: PROTECTED stubs (Cinemeta, Local Files: protected=true) are NEVER tombstoned (a logout resets
/// the engine to exactly those, so tombstoning one would wrongly suppress an essential default forever, and
/// the UI has no Remove for them). A REMOVABLE official add-on (YouTube, WatchHub, Public Domain,
/// OpenSubtitles: official=true, protected=false) CAN be tombstoned: the engine re-seeds OFFICIAL_ADDONS on
/// every reset, so without a tombstone a user's deletion of one is resurrected on the next launch (#137).
/// The state only ever changes from EXPLICIT install/remove intent, never from an inferred diff, and the
/// apply step is gated behind a SUCCESSFUL account pull.
enum AddonTombstones {
    /// Per-entry removal / install timestamps (milliseconds since epoch), the b172 last-writer-wins stores.
    private static let removedAtKey = "stremiox.addons.removedAt"
    private static let addedAtKey = "stremiox.addons.addedAt"
    /// Pre-b172 plain removal array. Folded into `removedAt` at the migration epoch on every load, and rewritten
    /// with the current effective removed set on every save so a b171 downgrade still reads live removals.
    private static let legacyDeletedKey = "stremiox.addons.deleted"

    /// A migrated legacy removal, or any wire URL that carries no stamp, folds in at this fixed low epoch, so
    /// any genuine later reinstall (a real wall-clock millisecond, orders of magnitude larger) always
    /// out-races it.
    static let migrationEpochMs: Double = 1

    /// Bound the stores so an oversized peer doc can never grow them without limit. `maxEntries` counts
    /// distinct URLs; oversized URLs are dropped by `maxIDLength`.
    private static let maxEntries = 10_000
    private static let maxIDLength = 2048

    /// Normalize a transportUrl for tombstone identity: trim + lowercase. The engine keys add-ons by the
    /// exact transportUrl, so the same trim/lowercase is applied on both the write side (when recording a
    /// removal) and the apply side (when matching an installed add-on against the set), keeping identity
    /// stable across the descriptor's casing.
    static func normalize(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The current durable removal set (normalized transportUrls that are EFFECTIVELY removed). Read fresh
    /// from UserDefaults so every surface (CoreBridge write, vortxSummary push, syncDown fold/apply) sees the
    /// same authority.
    static func all(defaults: UserDefaults = .standard) -> Set<String> {
        effectiveRemoved(load(defaults: defaults))
    }

    /// The per-url timestamp map for the wire (`doc.vortx.deletedAddonsTs`). Carries BOTH stamps for every
    /// tracked url, not just the effectively-removed ones, so a peer folding this learns a genuine reinstall's
    /// `addedAt` and stops re-emitting a stale removal. Clients that do not know the field ignore it.
    static func timestampsForSync(defaults: UserDefaults = .standard) -> [String: [String: Double]] {
        let state = load(defaults: defaults)
        let urls = Set(state.removedAt.keys).union(state.addedAt.keys)
        var out: [String: [String: Double]] = [:]
        out.reserveCapacity(urls.count)
        for url in urls {
            var entry: [String: Double] = [:]
            if let r = state.removedAt[url] { entry["removedAt"] = r }
            if let a = state.addedAt[url] { entry["addedAt"] = a }
            if !entry.isEmpty { out[url] = entry }
        }
        return out
    }

    /// Legacy settings blobs carry these maps as ordinary preferences. Preserve per-entry maxima when
    /// applying cloud settings; a stale/partial blob must not erase a known install or removal receipt.
    /// Manual backup-file restore remains an explicit replacement and does not call this wrapper.
    static func preservingLocalSyncStamps<T>(_ restore: () throws -> T) rethrows -> T {
        let capture = CredentialScopeRegistry.shared.capture()
        let addons = timestampsForSync()
        let library = LibraryTombstones.timestampsForSync()
        defer {
            if CredentialScopeRegistry.shared.isCurrent(capture) {
                merge(legacyIDs: [], stampsRaw: addons)
                LibraryTombstones.merge(legacyIDs: [], stampsRaw: library)
            }
        }
        return try restore()
    }

    /// Record an add-on removal so it sticks across devices. Idempotent for the caller. Returns true when the
    /// url becomes NEWLY effectively-removed. Callers MUST guard PROTECTED before calling (a protected stub is
    /// never a real removal); a removable official add-on is a legitimate removal and IS tombstoned (#137).
    @discardableResult
    static func tombstone(_ transportUrl: String, defaults: UserDefaults = .standard) -> Bool {
        let key = normalize(transportUrl)
        guard !key.isEmpty, key.count <= maxIDLength else { return false }
        var state = load(defaults: defaults)
        let wasRemoved = isRemoved(key, in: state)
        // Move the removal high-water mark forward so this removal out-races an older install on any peer.
        state.removedAt[key] = max(state.removedAt[key] ?? 0, nowMs())
        save(state)
        return !wasRemoved && isRemoved(key, in: state)
    }

    /// Forget a removal tombstone, so an EXPLICIT fresh install of the same add-on later is honored instead of
    /// being suppressed forever by an old removal. Called from `CoreBridge.installAddon` on a successful
    /// install (the single hardened installer every UI routes through): an explicit user install is intent to
    /// have the add-on, which supersedes a prior removal. Idempotent for the caller. Returns true when the url
    /// flips from effectively-removed to present.
    ///
    /// Why this is safe against a stale-doc re-resurrection: `vortxSummary` rewrites `doc.vortx.addons` from
    /// the live engine set (which now includes the re-installed add-on), `doc.vortx.deletedAddons` from the
    /// EFFECTIVE removed set (which no longer lists this url) and `doc.vortx.deletedAddonsTs` with the newer
    /// `addedAt`, so the account doc carries an install that out-races the tombstone on every peer. A
    /// concurrently web-authored `doc.webAddonRemovals` for the same URL carries no stamp and folds at the
    /// migration epoch, so this real install out-races it too until the web lane learns the stamp fields.
    @discardableResult
    static func forget(_ transportUrl: String, defaults: UserDefaults = .standard) -> Bool {
        let key = normalize(transportUrl)
        guard !key.isEmpty, key.count <= maxIDLength else { return false }
        var state = load(defaults: defaults)
        let wasRemoved = isRemoved(key, in: state)
        // Move the install high-water mark forward so this install out-races an older removal on any peer.
        state.addedAt[key] = max(state.addedAt[key] ?? 0, nowMs())
        save(state)
        return wasRemoved && !isRemoved(key, in: state)
    }

    /// Fold an incoming peer's add-on tombstones. `legacyIDs` is the back-compat `doc.vortx.deletedAddons`
    /// array plus any web-authored `doc.webAddonRemovals` (both stamp-less effective removed sets); `stampsRaw`
    /// is the raw `doc.vortx.deletedAddonsTs` map ({removedAt, addedAt} per url) written by builds that know
    /// the field. Both fold by per-id MAX timestamp, so the merge stays a monotone union-style fold: an
    /// incoming removed stamp can only push `removedAt` forward and an incoming install stamp can only push
    /// `addedAt` forward. A legacy url with NO stamp entry folds at the migration epoch, so any real later
    /// install out-races it. Returns true when the EFFECTIVE removed set changed (which now includes a peer
    /// reinstall flipping a url back to present, the last-writer-wins point of this set): the caller then
    /// uninstalls only the URLs that remain effectively removed.
    ///
    /// `webIDs` is the stamp-less web-authored `doc.webAddonRemovals`, and ONLY syncDown passes it (the single
    /// mint chokepoint). A web url is minted a `removedAt = now` ONLY IF it carries no published stamp AND we
    /// hold no `removedAt` for it locally: the web array is persistent and re-emitted every push, so folding it
    /// at fold-time now unconditionally would let a month-old stale entry beat a recent reinstall. The minted
    /// stamp is published in `deletedAddonsTs` on the next push, so every later folder adopts it and no device
    /// re-mints. Once the web lane emits its own stamps, those arrive via `stampsRaw` and minting stops firing.
    @discardableResult
    static func merge(legacyIDs: [String], stampsRaw: [String: Any], webIDs: [String] = [],
                      defaults: UserDefaults = .standard) -> Bool {
        // Timestamps are wall-clock milliseconds, the only frame comparable across devices. The fold takes the
        // per-id MAX, so a stamp dated far in the future wins until real time reaches it: a device with a
        // grossly wrong-future clock pins a url's state until then. Bounded on purpose (docs are per-account
        // and E2E, so the only stamp source is the user's own devices); a bounded future-stamp clamp is queued
        // for a later build.
        var state = load(defaults: defaults)
        let before = effectiveRemoved(state)
        let futureThresholdMs = nowMs() + 48 * 60 * 60 * 1000   // surface a clock-skewed peer before the b173 clamp
        var maxFutureSeen: Double = 0

        var stamped = Set<String>()
        for (rawURL, rawEntry) in stampsRaw {
            let url = normalize(rawURL)
            guard !url.isEmpty, url.count <= maxIDLength, let entry = rawEntry as? [String: Any] else { continue }
            var applied = false
            if let r = (entry["removedAt"] as? NSNumber)?.doubleValue, r.isFinite {
                if r > futureThresholdMs { maxFutureSeen = max(maxFutureSeen, r) }
                state.removedAt[url] = max(state.removedAt[url] ?? 0, r)
                applied = true
            }
            if let a = (entry["addedAt"] as? NSNumber)?.doubleValue, a.isFinite {
                if a > futureThresholdMs { maxFutureSeen = max(maxFutureSeen, a) }
                state.addedAt[url] = max(state.addedAt[url] ?? 0, a)
                applied = true
            }
            // Only suppress the legacy epoch fold for a url that actually carried a finite stamp. An empty or
            // non-finite Ts entry must NOT mask the legacy removed array, or a peer-deleted url present in the
            // legacy deletedAddons array would skip its migration-epoch fold and get re-unioned back in.
            if applied { stamped.insert(url) }
        }
        for rawURL in legacyIDs {
            let url = normalize(rawURL)
            guard !url.isEmpty, url.count <= maxIDLength, !stamped.contains(url) else { continue }
            state.removedAt[url] = max(state.removedAt[url] ?? 0, migrationEpochMs)
        }
        for rawURL in webIDs {
            let url = normalize(rawURL)
            guard !url.isEmpty, url.count <= maxIDLength else { continue }
            // Mint removedAt=now ONLY for a url this device has never tracked: a published stamp, an existing
            // removedAt, OR a local install (addedAt present) all block the mint. A stamp-less web array cannot
            // distinguish "installed then web-removed" from "web-removed then reinstalled", so minting now over a
            // known local install (addedAt) would uninstall an add-on the user installed after the web removal.
            // Per the sanctioned design a stamp-less removal folds below any real install and never uninstalls it;
            // a genuine web removal of an installed add-on takes effect once the web lane emits stamps via stampsRaw.
            guard !stamped.contains(url), state.removedAt[url] == nil, state.addedAt[url] == nil else { continue }
            state.removedAt[url] = nowMs()
        }

        save(state)
        if maxFutureSeen > 0 {
            DiagnosticsLog.log("sync", "add-on tombstone fold saw a stamp \(Int(maxFutureSeen)) beyond now+48h (peer clock skew)")
        }
        return effectiveRemoved(state) != before
    }

    // MARK: - State

    private struct State {
        let namespace: String
        let defaults: UserDefaults
        var removedAt: [String: Double]
        var addedAt: [String: Double]
    }

    private static func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    private static func isRemoved(_ url: String, in state: State) -> Bool {
        (state.removedAt[url] ?? 0) > (state.addedAt[url] ?? 0)
    }

    private static func effectiveRemoved(_ state: State) -> Set<String> {
        var out = Set<String>()
        out.reserveCapacity(state.removedAt.count)
        for (url, removed) in state.removedAt where removed > (state.addedAt[url] ?? 0) {
            out.insert(url)
        }
        return out
    }

    private static func load(defaults: UserDefaults = .standard) -> State {
        let namespace = CredentialScopeRegistry.shared.capture().namespace
        var removedAt = loadMap(AddonOwnerStorage.key(removedAtKey, namespace: namespace), defaults: defaults)
        let addedAt = loadMap(AddonOwnerStorage.key(addedAtKey, namespace: namespace), defaults: defaults)
        // Fold this OWNER's compatibility array at the migration epoch. Unowned pre-upgrade arrays are
        // consumed only at the authenticated migration boundary, never on guest/another account reads.
        if let legacy = defaults.stringArray(forKey: AddonOwnerStorage.key(legacyDeletedKey, namespace: namespace)) {
            for raw in legacy.prefix(maxEntries) {
                let url = normalize(raw)
                guard !url.isEmpty, url.count <= maxIDLength else { continue }
                removedAt[url] = max(removedAt[url] ?? 0, migrationEpochMs)
            }
        }
        return State(namespace: namespace, defaults: defaults, removedAt: removedAt, addedAt: addedAt)
    }

    private static func save(_ state: State) {
        let bounded = capped(state)
        TombstonePersistence.setMapIfChanged(bounded.removedAt, forKey: AddonOwnerStorage.key(removedAtKey, namespace: bounded.namespace), defaults: bounded.defaults)
        TombstonePersistence.setMapIfChanged(bounded.addedAt, forKey: AddonOwnerStorage.key(addedAtKey, namespace: bounded.namespace), defaults: bounded.defaults)
        // Keep the compatibility array within this owner scope. The old unowned keys stay quarantined;
        // dual-writing them would leak the current account's removals into a later account's migration.
        TombstonePersistence.setArrayIfChanged(
            TombstonePersistence.canonicalLegacy(effectiveRemoved(bounded)),
            forKey: AddonOwnerStorage.key(legacyDeletedKey, namespace: bounded.namespace), defaults: bounded.defaults
        )
    }

    /// One-shot baseline used on the first b172 run: stamp `addedAt = now` for a set of currently-installed
    /// add-ons, so a stale pre-b172 peer array (which for a b171-reinstalled add-on carries a removal but no
    /// `addedAt`) cannot re-uninstall an add-on the user demonstrably has. The once-guard and the empty-engine
    /// retry live in the caller. Accepted trade-off: a genuine new removal made on a still-b171 peer will not
    /// beat these baseline stamps until that peer updates.
    static func baselineInstalled(_ transportUrls: [String]) {
        guard !transportUrls.isEmpty else { return }
        var state = load()
        let now = nowMs()
        for raw in transportUrls {
            let url = normalize(raw)
            guard !url.isEmpty, url.count <= maxIDLength else { continue }
            // Baseline exists only to out-race a STAMP-LESS migration-epoch removal (removedAt == migrationEpochMs)
            // carried by a pre-b172 peer array for an add-on the user has reinstalled. It must NOT manufacture
            // install-intent over a genuine wall-clock removal a b172 peer folded in, or that peer's deletion is
            // resurrected. Skip any url whose folded removedAt is a real, post-epoch removal.
            if let removed = state.removedAt[url], removed > migrationEpochMs { continue }
            state.addedAt[url] = max(state.addedAt[url] ?? 0, now)
        }
        save(state)
    }

    private static func loadMap(_ key: String, defaults: UserDefaults = .standard) -> [String: Double] {
        guard let raw = defaults.dictionary(forKey: key) else { return [:] }
        var out: [String: Double] = [:]
        out.reserveCapacity(raw.count)
        for (url, value) in raw {
            if let number = value as? NSNumber { out[url] = number.doubleValue }
        }
        return out
    }

    /// Enforce the size cap by keeping the most-recently-touched URLs (by the later of their two stamps) and
    /// dropping the oldest. URLs are evicted WHOLE (both stamps together), so a half-drop can never flip an
    /// installed add-on back to removed.
    private static func capped(_ state: State) -> State {
        let urls = Set(state.removedAt.keys).union(state.addedAt.keys)
        guard urls.count > maxEntries else { return state }
        let keep = Set(urls.sorted { lhs, rhs in
            let l = max(state.removedAt[lhs] ?? 0, state.addedAt[lhs] ?? 0)
            let r = max(state.removedAt[rhs] ?? 0, state.addedAt[rhs] ?? 0)
            return l > r
        }.prefix(maxEntries))
        var removedAt: [String: Double] = [:]
        var addedAt: [String: Double] = [:]
        for url in keep {
            if let v = state.removedAt[url] { removedAt[url] = v }
            if let v = state.addedAt[url] { addedAt[url] = v }
        }
        return State(namespace: state.namespace, defaults: state.defaults, removedAt: removedAt, addedAt: addedAt)
    }
}
