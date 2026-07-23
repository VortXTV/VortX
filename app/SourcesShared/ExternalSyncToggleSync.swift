import Foundation

/// Cross-surface carriage for the six Trakt / SIMKL toggles declared in `ExternalSyncToggle`: trakt
/// scrobble / watchlist / importWatched, simkl scrobble / watchlist / importWatched. Plus the per-service
/// connection mirror the dashboard needs to render them honestly.
///
/// WHAT WAS ACTUALLY BROKEN (read this before "fixing" the sync again). These toggles were NOT missing from
/// sync, and they DO survive a reinstall on Apple. They are plain `UserDefaults` keys under the app's own
/// domain, and `SettingsBackup.makeBackup()` sweeps that WHOLE domain (SettingsBackup.swift:135-141, kept by
/// `isSyncable` at :47-49 = an app pref that is not device-local) into the account's `doc.settings` blob,
/// which `VortXSyncManager.syncUp` pushes (:797-798) and `syncDown` restores (:921-927). No key ever had to
/// be registered anywhere for that to happen, and none of the five is in `SettingsBackup.deviceLocalKeys`
/// (:37-44), so all five have been riding `doc.settings` all along.
///
/// What they never reached is the WEB DASHBOARD and ANDROID. `doc.settings` is a base64 binary property list,
/// which is opaque to a browser: that is exactly why `VortXSyncManager.vortxSummary` exists ("a small JSON
/// view of local state the website dashboard can read"). The JSON view never carried these five, so the
/// dashboard could not show them and Android could not agree with them. That cross-surface gap is the real
/// defect and is what this file closes. It is a VIEW plus an EDIT channel, NOT a new source of truth.
///
/// SOURCE OF TRUTH IS DELIBERATELY UNCHANGED. `doc.settings` stays authoritative for Apple. This file adds:
///   - `doc.vortx.integrations`  APP-authoritative JSON mirror, so the dashboard / Android can RENDER the
///                               five plus each service's connection state. Lives under `doc.vortx` because
///                               that block is what the app rebuilds and overwrites on every push, which is
///                               correct for a mirror of live local state.
///   - `doc.integrations`        WEB-authoritative SIBLING key, so those surfaces can CHANGE the five. It has
///                               to be a sibling for the same reason `doc.profileEdits` is one: the app
///                               overwrites `doc.vortx` wholesale every push, so an edit written there would
///                               be destroyed before any device read it.
///
/// THE WIRE SHAPE IS NOT MINE TO CHOOSE. The dashboard already reads and writes these two keys
/// (vortx-site/src/lib/vault.ts: `readIntegrations` :979-992, `saveIntegrationToggles` :1001-1008), and its
/// Integrations page renders from them. This file is written to MATCH that contract byte for byte:
///
///     doc.vortx.integrations = { "protocol": 1,
///                                "trakt": { "connected": Bool, "scrobble": Bool, "watchlist": Bool,
///                                           "importWatched": Bool },
///                                "simkl": { "connected": Bool, "scrobble": Bool, "watchlist": Bool,
///                                           "importWatched": Bool } }
///     doc.integrations       = { "editedAt": <epoch ms>,
///                                "trakt": { "scrobble": Bool, "watchlist": Bool, "importWatched": Bool },
///                                "simkl": { "scrobble": Bool, "watchlist": Bool, "importWatched": Bool } }
///
/// SIMKL gained its OWN watched import (`SIMKLWatchedShadow`) so it now carries `importWatched` too, on the
/// same wire name and default (OFF) as Trakt's. The emit is additive and degrades gracefully ahead of the
/// dashboard: `vault.ts` does not yet read/write `simkl.importWatched`, so an app-emitted value is ignored
/// there until the matching one-line vault.ts addition lands, and no dashboard edit ever sends it back
/// meanwhile (union-safe). Across Apple devices it already converges through `doc.settings` like the rest.
///
/// A flat `traktScrobble` vocabulary here instead of the nested per-service one there would be the SAME
/// class of defect as the `playback.safetyMode` app/web enum drift: two surfaces writing different words
/// into a shared doc, each silently ignoring the other. One contract, stated once, in both files.
///
/// `protocol` IS LOAD-BEARING, NOT DECORATION. The dashboard gates its live switches on
/// `vx.protocol >= 1` (vault.ts:961) and otherwise shows an honest "manage on a device" state, because a
/// switch that silently does nothing is the exact defect that page exists to fix. Emitting this key is the
/// app announcing "I consume doc.integrations". So it MUST be emitted only by a build that actually applies
/// the edits: publishing the mirror without wiring `applyEdits` into syncDown would light up switches that
/// do nothing.
///
/// BACK-COMPAT. Both keys are purely additive. An UNFIXED shipping client ignores them and keeps converging
/// through `doc.settings` exactly as it does today, so a doc written by a fixed client stays readable by an
/// old one. A dashboard edit does not reach an unfixed device directly, but the moment ANY fixed device
/// applies it that device's next push carries the new value inside `doc.settings`, which every old client
/// already reads. So the channel degrades to "slower", never to "wrong".
enum ExternalSyncToggleSync {

    /// The capability number the dashboard gates on (vault.ts:961 requires a real JSON number >= 1).
    /// Bump only for a BREAKING wire change; adding a key is not breaking (both readers pick by name).
    static let protocolVersion = 1

    /// The two peer services. Same shape, same weight, neither nested under the other.
    enum Service: String, CaseIterable { case trakt, simkl }

    /// One toggle: which service's block it sits in, its key WITHIN that block, its `UserDefaults` key,
    /// and its default.
    ///
    /// `defaultOn` MUST match BOTH that key's `@AppStorage` default in `ExternalServicesSettingsView`
    /// (:87-89 for Trakt, :178-179 for SIMKL) AND the `default:` every `ExternalSyncToggle.isOn` call site
    /// passes, or a never-touched switch and its runtime read would disagree. It must ALSO match
    /// `INTEGRATION_DEFAULTS` in vault.ts:935-938, or the dashboard paints a state the device does not have.
    /// Kept as ONE table so the emit path, the apply path, and the defaults cannot drift from each other.
    struct Toggle {
        let service: Service
        /// The key inside the service block: "scrobble" | "watchlist" | "importWatched".
        let wire: String
        let key: String
        let defaultOn: Bool
    }

    static let toggles: [Toggle] = [
        Toggle(service: .trakt, wire: "scrobble",  key: ExternalSyncToggle.traktScrobble,  defaultOn: true),
        Toggle(service: .trakt, wire: "watchlist", key: ExternalSyncToggle.traktWatchlist, defaultOn: true),
        // Default OFF, unlike the scrobble/watchlist four: importing another service's history into the read
        // path is opt-in. BOTH services now carry it (SIMKL gained its own watched import via
        // SIMKLWatchedShadow), so the key is emitted on both blocks, same wire name and same default.
        Toggle(service: .trakt, wire: "importWatched", key: ExternalSyncToggle.traktImportWatched, defaultOn: false),
        Toggle(service: .simkl, wire: "scrobble",  key: ExternalSyncToggle.simklScrobble,  defaultOn: true),
        Toggle(service: .simkl, wire: "watchlist", key: ExternalSyncToggle.simklWatchlist, defaultOn: true),
        Toggle(service: .simkl, wire: "importWatched", key: ExternalSyncToggle.simklImportWatched, defaultOn: false),
    ]

    static func toggles(for service: Service) -> [Toggle] { toggles.filter { $0.service == service } }

    // MARK: - Emit (app -> doc.vortx.integrations)

    /// The JSON view for `doc.vortx.integrations`.
    ///
    /// Emits the RESOLVED effective value of all five rather than only the keys the user has touched. The
    /// `doc.settings` blob keeps its absent-means-default semantics (a never-set key is simply not in the
    /// persistent domain), but a rendering mirror cannot: the dashboard has to paint each switch in the right
    /// position, and leaving a key out would force every non-Apple surface to re-derive the defaults table
    /// above from a surface that cannot see it. That duplication is precisely how the webapp enum drift
    /// (playback.safetyMode and friends) happened, so this view is self-describing instead.
    ///
    /// CONNECTED IS ACCOUNT-WIDE, NOT PER-DEVICE, and the caller must pass it that way. The Trakt / SIMKL
    /// tokens ride the encrypted `doc.apiKeys` channel (VortXSyncManager.swift:831-839 pushes them,
    /// :960-966 adopts them via `adoptTokens`), so a connection made on ANY device follows the account. The
    /// caller therefore derives each flag from the READ-MERGED apiKeys dict (local token OR the pulled
    /// doc's), never from this device's Keychain alone: a freshly-signed-in device that has not yet pulled
    /// would otherwise publish `connected: false` over a peer's live connection and the dashboard would say
    /// "Not connected" while the account plainly is. See the D5 handoff for the exact call site.
    ///
    /// No `devices` key is emitted. The dashboard tolerates that (it skips the "Connected on" row when the
    /// array is absent or empty, integrations.astro:127), and a per-device list would be a LIE about this
    /// model: the tokens sync, so the connection is not a property of one device. Nothing in the app
    /// produces a device name today either.
    ///
    /// Toggle values need no union: they are account-wide via `doc.settings`, so this device's resolved
    /// value IS the account's value. Not gated on whether the service is connected: the preference exists
    /// either way, and gating would make it vanish from the doc whenever a token lapsed.
    static func summary(traktConnected: Bool, simklConnected: Bool) -> [String: Any] {
        let connected: [Service: Bool] = [.trakt: traktConnected, .simkl: simklConnected]
        var out: [String: Any] = ["protocol": protocolVersion]
        for svc in Service.allCases {
            var block: [String: Any] = ["connected": connected[svc] ?? false]
            for t in toggles(for: svc) { block[t.wire] = ExternalSyncToggle.isOn(t.key, default: t.defaultOn) }
            out[svc.rawValue] = block
        }
        return out
    }

    // MARK: - Apply (doc.integrations -> app)

    /// Apply a web-authored `doc.integrations` payload. Returns true when a value actually changed, so the
    /// caller can fold it into syncDown's `restored` flag.
    ///
    /// Only keys PRESENT in the payload are written, so a partial edit never resets a toggle it does not
    /// mention (same union-safe rule as `applyProfileEdits`). `editedAt` is ignored here: the LWW gate is the
    /// caller's, mirroring how `syncDown` gates `profileEdits` on its persisted per-account high-water mark
    /// (VortXSyncManager.swift:92-96, :1129-1136). That gate is REQUIRED, not optional: without it a stale
    /// web edit would be re-applied on every pull and would keep reverting a newer on-device change.
    ///
    /// CALLER CONTRACT (both requirements are load-bearing):
    ///   1. Call INSIDE syncDown's `withRemoteApplySuppressed` block. These are `UserDefaults` writes, and
    ///      without suppression each one fires the global didChange observer, which re-arms a push and echoes
    ///      the just-applied value straight back up.
    ///   2. Call AFTER `SettingsBackup.restore`. Restore rewrites these exact same keys from the pushing
    ///      device's blob, so an edit applied before it would be overwritten by that device's stale value.
    @discardableResult
    static func applyEdits(_ edits: [String: Any]) -> Bool {
        var changed = false
        let defaults = UserDefaults.standard
        for svc in Service.allCases {
            guard let block = edits[svc.rawValue] as? [String: Any] else { continue }
            for t in toggles(for: svc) {
                guard let want = boolValue(block[t.wire]) else { continue }
                // Compare against the RESOLVED value, not `defaults.bool(forKey:)`: an unset key reads false
                // there, so an edit setting a default-ON toggle to true would look like a change and
                // pointlessly write.
                guard ExternalSyncToggle.isOn(t.key, default: t.defaultOn) != want else { continue }
                defaults.set(want, forKey: t.key)
                changed = true
            }
        }
        return changed
    }

    /// Tolerate the shapes a boolean can arrive in from a browser-authored, JSONSerialization-parsed payload
    /// (`true`, `1`, `"true"`) instead of trusting a single Codable-style cast. Anything unrecognized returns
    /// nil, which `applyEdits` treats as "not mentioned" and leaves the local value alone: a malformed edit
    /// must never be read as `false` and silently switch a user's scrobbling off.
    static func boolValue(_ raw: Any?) -> Bool? {
        switch raw {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        default: return nil
        }
    }
}
