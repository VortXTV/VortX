# Native bridge integration boundary

The 0.5 source shipping paths select the native state/resource engine, account/session facades
and presentation adapters. Apple uses the native-generated project; Android defaults to the native
repository. `CoreBridge` is the Apple compatibility facade, not evidence that its legacy Stremio
branch is active. The retained legacy Apple project and Android non-native selection are explicit
comparison paths. A native streaming server is a separate capability from the native data engine.

## Integration status — 9 October 2026

Native source selection is already enabled in the shipping configuration; it is not a claim of
complete migration, provider, packaging or device parity. Source and artifact acceptance must be
kept separate, and a passing fixture never substitutes for the exact app/package being shipped.

- Future Apple/Android workflow checkouts and post-checkout assertions now agree on private
  source `7b368f447a3dfc46bd68905acef19fa5c136240d`, independently accepted with Linux/macOS
  CI run `37907843106`. Fresh SDKs and final combined app/package receipts for that revision
  remain required. Existing generated SDKs are not relabelled by changing a workflow pin.
- The immutable `v0.5.0-beta.1` source at `844782d29a93ae51991bfadc639d50bc3619d40b` keeps
  its original `7e3e68be5bf2b11c65d158c1823be94bd1608d1b` pin and artifacts. This document
  describes future source; it does not modify the release tag, draft, run or installed apps.
- Native account checkpoint recovery, profile/host-preference projection, own-account linking,
  website sparse events, provider intent/ACK handling and add-on replacement are integrated.
  A source UID or successful login alone cannot relabel history from another account.
- Metadata-backed watched migration and sealed pending-evidence retry are wired. Incomplete
  original-source inventory, ambiguous ownership or insufficient causal evidence remain explicit
  reconciliation states, never successful empty history or a legacy-engine fallback.
- Library membership, Watchlist and viewing history remain distinct. Native playback context,
  exact episode resume, bulk watched transactions and source-selection fences are integrated;
  current provider availability and physical decoder behavior still require runtime evidence.
- The native transport path is selected without booting Node in native mode. Local NZB playback
  supports raw video, stored RAR and COPY 7z under advertised capability checks. Compressed,
  encrypted or repair-required archives require an admitted supported route or another source.
- Apple remains arm64-only on Mac, with a separate native daemon; Full iOS/TV use the embedded
  server and Lite has no embedded server. Android ships its three declared ABIs. Universal Mac,
  broader archive support and physical-device parity are not established by the source tests.

See [native-release-packaging.md](native-release-packaging.md) for the unchanged feature sets,
player input, SDK/cache verification and final artifact gates.

## Implemented and independently exercisable

- Swift/Kotlin serialize every kernel-handle call, hydrate captured state, retain the previous
  handle after failed hydration, drain deltas and free handles once. Persistence and account
  migration remain the caller's responsibility; a drained delta is not a durable-write receipt.
- Native resource calls run off the UI thread. Cancellation handles outlive the blocking call;
  replacement, cancellation and owner invalidation revoke late result publication.
- Every accepted result matches request ID, generation, full resource path/extras and source IDs.
  Projection rejects a registry that relabels a response with a replacement transport URL.
- Catalog pages, metadata, embedded episode streams, source groups and all subtitle choices
  project into the existing app read shapes. Raw provider payloads, headers, file indices, binge
  hints and integer sizes are retained. Empty metadata is terminal, not `Ready(null)`.
- Bridges do not persist credentials or configured addon URLs. Resource/projection snapshots are
  memory-only. Callers must check `accepts(snapshot)` again at their UI publication boundary.

The Apple native session stores full state only in a separate AES-256-GCM encrypted checkpoint,
using the host-supplied secure account key and account/owner identity as authenticated data. It seals,
syncs and verifies a staged file, atomically renames it, syncs the directory and reads back before
publication. An ambiguous post-rename failure is `checkpointUncertain`: no later mutation can
overwrite it until the session is reopened and checked. Neither account tokens nor encryption keys
enter kernel actions or checkpoint metadata. Same-account sessions have one in-process writer,
including attempted replacement with a different owner-profile identifier;
replacement must await shutdown before opening another session.

State changes clone the runtime, apply a FIFO action transaction, verify owner/nativeSync/watch-context
retention, checkpoint and then publish. Failed actions do not change the published runtime. Synchronous
revocation waits for an in-flight commit and prevents later outgoing-account writes. Catalog, search,
discover, metadata and subtitle slots are independent and generation-fenced. Legacy roster/watch
documents retain a read-only carrier; arbitrary nonempty legacy data still blocks fresh-state fallback.
The separate pure authenticated Apple extractor feeds the typed native one-time importer explicitly.

`VORTX_NATIVE_DATA_ENGINE` selects the actual Apple `CoreBridge.start/dispatch/stateData` branch:
that branch does not initialize/call Stremio and rejects unsupported actions. It needs an explicitly
installed, authenticated session. The native-generated shipping targets set this condition;
the retained comparison project does not. Production
bootstrap now lives inside `VortXSyncManager`, where the account key remains private: launch,
credential changes, profile changes and the existing addon-hydration entry point open a validated
encrypted checkpoint, bind the captured account namespace and merge a freshly decrypted top-level
`nativeSync` carrier. The exact owner comes from the authenticated full account roster, not the
global local profile cache. On an absent checkpoint only, the full authenticated account document is
projected by the reviewed typed importer (or its existing nativeSync is adopted by a pristine peer)
before the first atomic checkpoint. The first checkpoint includes the sealed credential-free source
archive and native import receipt. Failed/decrypt-failed account pulls, invalid owner
attribution and unavailable artifact queries fail closed; there is no empty-account fallback.
Unresolved source attribution (including unproven own-account overlays, ambiguous episode/type/alias evidence,
and unreflected dashboard edits) requires reconciliation. Offline reopening uses an account-key-authenticated
checkpoint, archived roster and owner locator; it does not provision a fresh account from an unavailable
cloud response. New-account admission additionally requires a complete authenticated local checkpoint
inventory. A missing installation index key does not prevent recovery with the existing account key,
but cannot establish that an unknown account has no prior state.

Every cold open, native-peer adoption and warm native pull/push reprojects the authenticated legacy
material (including the pending-profile-edit completeness check). An existing/adopted runtime must
already carry a matching `legacyImport` receipt; the kernel's idempotent importer verifies it on a
detached candidate or inside the merge/checkpoint transaction. The shared legacy reducer admits changes
with its required source-clock evidence and preserves the original import archive/receipt; ambiguous
or unclocked changes still fail closed before persistence. Unrelated unknown document preferences do
not enter that projection. Sparse website intents require the newer website reconciliation contract;
they must not be restamped as an authoritative whole-roster snapshot.

CoreBridge exposes awaited shutdown and generation-checked installation. Owner boundaries revoke
both installed sessions and candidates still awaiting installation. Native mutations use the same
FIFO as remote sync merges. The freshly pulled carrier is merged before exporting only `nativeSync`
at the top level of the existing encrypted account document; full host preferences/legacy fields
remain adjacent. Local acknowledged mutations schedule sync; read-only export/remote merge does not
self-echo. Profile/configuration changes resolve the kernel's ordered `installed_addons` query and
rebind the accepted own/shared registry automatically; no restart or raw-token import is involved.
Native push returns the freshly pulled document plus `nativeSync` only; it does not rebuild legacy
settings/roster/watch/addon/library carriers from native or global mirrors. Native pull does not replay
legacy overlay/tombstone/profileEdit mutations after accepting the native transaction. Outbound host
preferences and provider credentials use separately versioned register carriers. Provider writes retain
durable prepared intent, complete OAuth tuples, explicit clears and exact event acknowledgements;
account/session replacement cannot publish or clear an earlier captured event. Credentials never enter
the native kernel or bootstrap archive. Website sparse host edits must also prove the exact independent
host-register base before an atomic native/host commit; the reviewed Apple transaction is integrated.
Pending legacy settings/order edits and explicit legacy-source override refuse a native-only push;
their dirty acknowledgement cannot be cleared by a carrier that did not export them.

Apple compatibility currently covers board/search Load + LoadRange, default/specific Discover loads,
metadata/episode streams, subtitles, default library reads, standard AddToLibrary/RemoveFromLibrary,
title/episode watched intents, Player selection/progress attribution and explicit native profile/state
actions. Loading groups use the shipping read shape. Unsupported action variants return false;
there is no silent Stremio fallback. The native library projection covers standard saved titles,
with playback history and Continue Watching queried separately; magnet/playlist presentation still
needs its own coverage rather than being inferred from title membership tests.
The main Home/Library read paths use native active-profile data for secondary profiles too, and
native Continue Watching never unions legacy owner caches. The shared `profile_playback` query
consumer projects exact-millisecond selected episode rows, keeps history separate from saved
membership and uses whole-title watched counts instead of counting episode IDs. Unknown-type rows
are not invented as movies. The playback query is mandatory: an unsupported/malformed query
prevents installation, and projection failure after an acknowledged mutation retires the facade
until reopen; neither path is reported as successful empty history. The current exact native fixture
exercises this query and metadata-enriched progress. Watched/statistics readers use native projections;
end-to-end recommendations and remaining overlay mutation callsites still require parity verification.

Native playback targets capture the exact credential epoch and immutable installed-session generation for every profile, including
historical owner IDs. Native `StremioAccount` resume/progress entry points use kernel reads/writes
instead of overlay caches or the optional legacy network mirror. Synchronous resume reads consume
the kernel-provided `resumeById` map; unknown IDs use the same kernel `resume_point` query asynchronously.
The facade fences explicit profile progress/marks under its mutation-admission lock. Detail/card
library actions, individual episode/movie watched actions, and CW dismissal have native branches.
Native automatic library adds resolve metadata through the accepted registry in a separate request
slot, then acknowledge the durable profile-scoped FIFO save before stamping the account/profile
auto-add ledger. Legacy machine recovery can confirm an existing save, not resurrect a native removal.
Apple bulk-season/series marks resolve the exact metadata-returned inventory in an isolated resource
slot and await one durable batch. A card action does not replace visible detail navigation; missing
inventory, registry replacement or stale ownership rejects the operation. These adapters do not invent
episode IDs or claim unavailable future episodes were watched.
The shipping player can produce both a selected-player progress tick and an explicit metadata save;
the kernel treats repeated completion as one watched count, but duplicate durable commits remain an
optimization opportunity. No audible playback/device receipt is claimed by source tests.
Same-account A→B→A and same-profile reopen invalidate old launch targets permanently; unavailable
launches never acquire a later session. The existing owner-gated external scrobble fanout remains
after this target validation, independently of whether selected-player engine writes are allowed.

The historical retained schema-4 C-ABI facade/playback receipt used private source `5c93b9d`, library
SHA-256 `8eaa51e9e3b5098a60019ef83b9840d2a70101a1d3dd1168ab9a4330ea470e65` and header
`f7e277e197c8c72d230be633db5395234a19ff73ec645f971b0d3e88da376672`, with unchanged before/after
hashes. That covered real kernel queries/mutations and localhost resources, not full app packaging
or a fresh artifact built from the current future pin.

## Artifact gate

Native checkpoints now dual-read old sealed raw runtime snapshots and write an atomic sealed
`vortx-native-checkpoint-v1` envelope containing `state` plus optional `bootstrap` archive bytes.
The archive carries exact typed `legacyImportMaterial` (including fractional clocks), full
noncredential `hostDocument` fields, and explicit `excludedCredentialPaths`; it is never hydrated
into the kernel or exported as `nativeSync`. Original raw cloud documents remain unchanged in the
existing encrypted transport. This archive is not advertised as a byte-identical raw backup.
Known auth/token/password/API-key carriers, including nested settings `kcfallback.*`, are excluded.
SettingsBackup JSON/base64/binary-plist, structured base64 strings under arbitrary preference keys,
and inspectable nested Data are inspected recursively (with a depth bound) without
dropping unrelated preference keys. Unknown credential-like carriers or opaque preference Data fail
closed for reconciliation. Configured addon URL strings and ordinary library `key` fields retain
their exact values. Existing encrypted bootstrap material survives every acknowledged rewrite.

Root integration must update the exact private-core pin, copied header, feature set, required
symbols and cache keys together. Existing release pins must not acquire calls into absent exports.

Apple's live bindings compile only with `VORTX_ENGINE_STATE_BRIDGE` and
`VORTX_ENGINE_RESOURCE_HOST`, respectively, plus `canImport(VortxEngine)`. The native shipping
generator enables them together with `VORTX_NATIVE_DATA_ENGINE`. The builder's `--resource-host`
mode runs header/symbol verification and selects `resource-host` for kernel-only slices or
`server,resource-host` for embedded-server slices, with default Cargo features disabled.
Android's native default and explicit shipping properties select `jni,server,resource-host`;
an explicit non-native comparison retains `jni,server`. Live transport requires native resource
ABI version 1. A resource library alone does not select a repository or prove app provenance.

Run `scripts/verify-native-engine-abi.sh apple <xcframework> resource-host` and
`scripts/verify-native-engine-abi.sh android <libvortx_ffi.so> resource-host` (set `READELF` to the
NDK tool). Kernel-only builds need the `state` audit. Do not link the arm64-only Mac framework
into a universal Mac target; provide and verify both slices first.

## Verification

`bash scripts/test-native-cutover-bridges.sh` runs strict Swift lifecycle, projection and cancellation
fixtures plus canonical engine-source resolution checks. Android runs
`:app:testPlayDebugUnitTest --tests com.vortx.android.engine.VortxNativeBridgeTest`, excluding native
build tasks when testing the pure bridge. Both consume `test/fixtures/native-resource-contract.json`.

`bash scripts/test-native-cutover-live-abi.sh` links the actual native library selected by
`VORTX_FFI_HEADER` and `VORTX_FFI_LIBRARY`, hash-fences both artifacts, proves cold hydration/deltas,
and fetches deterministic catalog/meta/stream/subtitle fixtures over loopback. It also runs the real
Apple facade, bound nativeSync scope, standard library membership, FIFO profile/progress actions,
native installed-addon materialization, automatic profile registry rebind, top-level sync export/merge
and encrypted exact-state cold reopen with episode watch contexts. It launches no
app or media player. The fixture server requires Node 22+ lossless JSON source support.

## Remaining coverage and release gates

| Owner lane | Remaining boundary despite native source selection |
| --- | --- |
| Apple facade | Standard saved-title library projection is implemented; magnet/playlist presentation and remaining rejected action variants need explicit consumer coverage. Verify the final app's profile/history/Watchlist, source, download and external-player routes together. |
| Android facade | Native catalog DI and separate streaming-auth/own-account services are wired. Verify remaining interface defaults, player subtitle consumers and all Full/Play route combinations against actual packages; do not treat source-only or JNI fixtures as device proof. |
| State and migration | Supported clocked legacy reconciliation, website events, own-account binding and watched-evidence retries exist. Unattributed overlays, missing metadata inventory and unsupported/conflicting edits remain pending/fail-closed. Full live mixed-client convergence for every cohort is not established. |
| Sources/playback | Provider/debrid, source-preserving resume, episode/binge and download paths require current end-to-end regression receipts under account/profile replacement, failure and recovery. Source tests are not availability, audible playback or physical decoder proof. |
| Native server | Only advertised archive capabilities are admissible; compressed/encrypted/repair-required cases are not newly supported by the retention pin. Preserve paired-server ownership and Lite's no-embedded-server boundary. |
| Packaging | Build fresh SDKs from the exact future pin, check all Apple slices/headers/exports and Android ABIs/flavors, then verify optimized apps, signing, provenance, final packages and devices. Mac remains deliberately arm64-only; this change does not supply universal slices. |

Passing bridge tests establishes the adapter and lifetime boundary. It does not establish the full
application cutover or physical playback parity.

## Apple watched-history migration journal

Authenticated bootstrap/pull and explicit independent-account connection prepare opaque watched
bitmaps with the original source's addon inventory. The exact token-free capture is reused for
metadata evidence and the typed importer. Raw metadata/source bytes stay device-local under
`authenticatedSourceArchive.hostDocument.nativeWatchedMigrationEvidence` and
`nativeWatchedMigrationPending`, as immutable base64 sidecars. Historical bytes are union-retained;
only evidence for the exact account/owner/profile/UID/source digest/row resolves a pending display.
They are not an independent kernel receipt and are never exported as cloud preferences.

An existing native session commits sidecars with its unchanged native state through the same FIFO
and source-generation fence. A first-run unresolved import instead saves an account/owner-AEAD
`native-migration-draft-v1-<scope digest>.sealed` draft with durable staging and exact prior-draft
CAS. This cannot mount a session or establish an owner locator. Cancelled/retired preparations
cannot write it. Cold retries can reuse exact evidence without metadata requests.

The strict first import still requires every watched bitmap's episode inventory: an unavailable
original addon postpones that import rather than manufacturing empty history. The published
`nativeWatchedMigrationPending` profile IDs and `nativeCheckpointStatus ==
"watched_migration_pending"` expose this condition; `retryNativeWatchedMigration()` retries
authenticated pull for a mounted session or bootstrap otherwise. Existing mounted profiles stay
usable. `ProfilesView` includes the explanation and retry action; startup shells must display the
same state when they cannot yet reach the picker.

`scripts/test-native-own-account-producer.sh` with the frozen actual ABI additionally tests draft
crash/reopen, no fabricated checkpoint/locator, cancelled and stale draft writes, exact cold replay,
foreign-account refusal, and FIFO source-sidecar retirement. No live provider requests are made.

## Native Watchlist host registers

Watchlist is a separate want-to-watch ledger, never an engine-library mutation. Host schema 1
stores each item at `profiles[UUID].fields["watchlist.<type>.<id>"]`, where type is `movie` or
`series` and id is canonical unpadded base64url of the UTF-8 catalog id. A live register value is
`{id,type,name?,poster?,addedAt}` with finite nonnegative epoch **seconds**; null is an explicit
retained removal. The normal host Lamport clock/actor comparison applies independently per item.
Local additions at 1,000 live entries refuse without evicting older entries. Larger peer unions
remain visible and removals remain possible; tombstones are not pruned to satisfy a display cap.

Only an authenticated account's profile-qualified legacy settings array seeds missing registers,
at clock 0 with an immutable content-derived actor, inside the accepted candidate after merging remote host state.
Existing live registers and tombstones always win over that old array. Unqualified local arrays,
unknown-profile or malformed old arrays, and unknown dirty settings remain preserved and visibly
unsynchronized. They neither acquire a fabricated account attribution nor block unrelated supported
settings; successful uploads clear only dirty keys actually represented by the native export.

The acknowledged Watchlist API requires `PlaybackMutationTarget` captured synchronously at the
gesture, before any Task is scheduled. Legacy synchronous mutators cannot bypass native admission.
The Apple `vortx.quickViewEnabled` and Android `vortx.cinema.quickView` Boolean preferences retain
their separate names and defaults; accepting both does not synthesize an alias edit or clock.

The baseline actor is the first 32 hexadecimal characters of SHA-256 over the shared
JavaScript-canonical JSON object `{domain:"vortx-watchlist-baseline-v1",profileId,field,value}`,
formatted as lowercase UUID `8-4-4-4-12` without changing version bits. `profileId` is uppercase
canonical UUID; `field` is the canonical per-item key. The value omits missing/null optional name
and poster and preserves Unicode and finite binary64 seconds through the canonicalizer. Differing
unversioned authenticated baselines therefore converge as distinct immutable clock-0 events, while
any explicit native add/removal at clock 1 or higher dominates both. No deployed zero-actor carrier
is migrated or re-clocked by this rule.

Historical watched migration retries read the sealed pending snapshot, not the newest cloud
document or current streaming credential. Matching includes account, owner, profile, streaming
UID, exact source digest and row locator; distinct UIDs may legitimately share source bytes.
Retry returns evidence archives only, never current-import rows. The host unions those archives
with every original pending snapshot before preparing the current source, then commits that union
under the same captured source fence. Changed/removed current rows cannot acquire old watched
state, and successful historical metadata recovery clears the pending notice without deleting
the original raw history or claiming it was imported into a different current source.
