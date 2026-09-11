# Apple playback and state audit — 11 September 2026

Scope: the 12,234-line diagnostic spanning 10–11 September, including its duplicated always-on and server tails. Four disjoint log reviews covered every line. This is not the earlier diagnostic with the same filename. Raw logs and account/provider identifiers are not included in this repository.

## Implemented

- **tvOS receipt storage:** successful source contributions previously persisted up to 40,000 SHA-256 receipts in UserDefaults, exceeding tvOS's 1 MiB preferences limit. Six SIGABRTs in the diagnostic immediately follow successful contribution replies. The store now uses an atomic file, verifies legacy migration before retiring the large defaults key, and retains a small marker so an OS cache purge cannot silently reset deduplication. The actual device receipt count and complete assertion text were not recorded, so the platform-limit defect is established but the exact crash assertion still needs device confirmation.
- **Player-switch resume:** the current episode's active origin now wins over immutable launch arguments. The diagnostic showed a switch near 30 seconds remounting at zero, and another episode's switch near 15 seconds incorrectly reusing the original CW offset near 2,590 seconds.
- **Remux display range:** mounting a remux no longer automatically requests Dolby Vision. The display request follows actual DV signaling or PQ/HLG/SDR metadata; explicit HDR fallback remains HDR.
- **CW episode refresh:** a valid empty unloaded model now completes the invalidation phase, including when Unload emits no event. Malformed snapshots are not treated as unload receipts. Refresh and re-find callbacks are generation-fenced.
- **Canonical episode metadata:** both CW launch and EOF navigation refresh accept a canonical metadata ID for the exact selected request and episode. This does not grant title-finality authority or remove a series from CW.
- **Watched marks during refresh:** temporarily missing metadata no longer immediately discards an episode-completion intent. A bounded five-minute queue retains the exact episode and account/profile owner, replays on matching metadata, and respects subsequent explicit unwatch actions. Series completion never substitutes a whole-title watched mutation.
- **Add-on/source order:** loaded source groups now use the same persisted order as the add-on UI. Reordering invalidates the live source-list cache. New/unlisted add-ons remain visible in stable order.
- **Add-on roster snapshots:** typed and raw descriptors come from one engine snapshot; decoding failure retains the last valid roster instead of publishing an empty one.
- **Cross-device order echoes:** an unrelated push previously overwrote a freshly fetched peer order with this device's stale applied order, and a partial engine snapshot could shrink that order. Only an explicit, account-scoped reorder now overrides the cloud field. Persisted nonce-bearing intents survive network failures and restart; acknowledgements clear only the sent intent, so a newer edit or undo remains pending. Derived pushes are serialized per credential scope, and remote-only entries are preserved. Concurrent explicit reorders use last-successfully-pushed-intent precedence; older unpatched clients can still overwrite the field, and the existing backend version high-water is not a true conditional-write CAS.
- **Removal/reinstall receipt rollback:** cloud settings restore used to replace add-on and library timestamp maps as scalar preferences before the semantic fold. It now preserves local per-entry maxima across the restore, including when an older blob contains empty/stale maps. Manual file import remains an explicit restore. Cloud add-on descriptor unions now deduplicate using the same normalized URL identity as order and removal records.
- **Preview lookup storm:** the diagnostic's 1,057 repeated missing-runtime lookups during one CW run are replaced by an in-flight fence and failure backoff. Real player duration supersedes provisional runtime, and stale tasks cannot reconfigure a replacement load.
- **File backup restore:** profile state is reloaded before catalog/discovery projections, preventing the stale live profile from overwriting restored row order. The account-sync roster-union path is unchanged.
- **Decoder diagnostics:** use mpv's real codec and pixel-format properties and sample at video reconfiguration. This improves evidence for software fallback; it does not claim to fix unsupported decoding or frame drops.

## Verification

Production-linked standalone tests passed for source contribution persistence/migration/cache purge, remux resume/display policy, CW refresh/rollover, episode identity and alias matching, watched-mutation admission, add-on ordering, preview request cancellation/backoff, and hardware-decoder policy/wiring. Full unsigned Debug builds passed for tvOS and iOS after regenerating the Xcode project from the current manifest. The old generated local project was missing an existing source file; no older source or release artifact was restored.

Read-only reviews used Cline Pass GLM 5.3 for storage, resume, preview, ordering, and backup changes, followed by a native Terra final review of consequential playback/state changes. The cache-purge issue raised during review was corrected and tested. Command Code's bounded DeepSeek reviews exhausted their response caps; OpenCode Go rejected requests missing its session-routing header. Those failures were not counted as approvals.

The follow-up cross-device patch has 17 production-linked order-intent regressions and real-store tombstone restoration tests. Terra found no blocker in its source review. The user's signed-in ChatGPT 6 Pro reviewed sanitized sync pseudocode independently; it confirmed the explicit-intent/acknowledgement design and mixed-client limitation. That design review is not treated as repository inspection or a build approval.

## Still open — do not describe as fixed by this patch

- Source-specific hardware-decoder fallback, the observed first presented frame near ten seconds, and physical Apple TV frame pacing.
- The broader AVPlayer stall/pause/DV-fallback and repeated-subtitle reports require verification against the new code on-device; this diagnostic does not establish a universal cause for them.
- General add-on/account convergence and disappearing CW/history beyond the specific snapshot, order, metadata, and watched-intent defects above.
- The separate iOS pre-player crash report, tvOS Customize Catalogs crash, and failing catalog feed need a reproducible crash/payload; this patch must not be advertised as resolving them without that evidence.
- Trakt-only artwork currently uses a private warm-cache path. Restoring external artwork requires preserving the intended privacy boundary, not simply removing that guard.
- Android report review found existing refind-generation, exact-episode request, and idempotent release protections. A rejected duplicate refresh is intentional, and a missing optional contributor ID does not erase the HTTP add-on's explicit episode ID. No Android fix or Shield runtime verification is claimed here.

No release or public issue closure is implied by these source changes. Device verification should cover CW resume → seek → pause/resume → engine switch → next/previous/EOF, repeated re-find, watched/unwatched during metadata refresh, source ordering before/after a remote reorder, and catalog-order backup restore.
