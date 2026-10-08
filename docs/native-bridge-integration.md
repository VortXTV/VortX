# Native bridge integration boundary

The app contains additive native state/resource bindings, an Apple account/session facade and
presentation adapters. Shipping `CoreBridge` and `EngineStremioRepository` remain the active data engine. There is no new user
selector. A native streaming server is a separate capability from the native data engine.

## Integration status — 8 October 2026

The public integration branch is `beta/native-engine-integration-20261008` (remote branch
`beta-native-engine-integration-20261008`). Native defaults are still off; neither a passing
fixture nor this document authorizes the default flip. The installed/public release is separate.

- Reviewed Apple provider intent/ACK handling, account checkpoint recovery, add-on replacement,
  card-level series/season watched actions and library filter retention are integrated.
- Reviewed Android provider intent/ACK handling, atomic authoritative watched batches,
  ordered add-on replacement and Cinema touch navigation are integrated.
  Library viewing history uses authoritative watched history plus partial Continue Watching,
  not saved membership. CW cards use a typed, one-shot resume intent and fall back to details
  when the device has no matching saved stream.
- Reviewed Apple website native/host transactions are integrated and passed the combined live
  C-ABI suite plus focused checkpoint/conflict/replay tests. They use private source `286a26c`,
  immutable library SHA-256 `a99af5d5d3148c0ca77299a18c43e11917a5f5d5e22f5b6553c70db509d8bea5`.
  Earlier provider/API receipts use source `b6de6b86`, library
  `34c900f1c64537f275e6eca835925a2e4e8328c4fd801a0986bfbc7e04d7a061`.
  The reviewed own-account import kernel `cf693ddb` has a separate fresh fixture,
  `7e9d73ce43987f4f690421d4d98305c904f66eaff53d68cbc0e7bb2299e3f719`;
  authenticated host fetch, own-account rebinding and final packaging remain separate gates.
  Do not run newer actions against older fixtures or infer package provenance from these tests.
- Own-streaming-account profile migration and projection remain functional cutover blockers,
  not permission to clear that preference or run those profiles under the owner's identity.
- Android website transactions and durable downloaded-watch cleanup are separately reviewed
  integration lanes; their acceptance must include the final account/lifecycle/download lock order.
- Fresh native-flag Apple Mac/iOS/tvOS compilation succeeded using unsigned, unoptimized
  diagnostic builds. Optimized signed packages, current full Android flavor/ABI packages,
  physical playback and rendered UI verification remain distinct release gates.
- A fresh MPVKit rebuild is staged separately. The previous package failed the intended
  FFmpeg/TLS content contract; source and artifact validation now run before promotion.
  The installed Mac application has not been restarted or replaced.

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
installed, authenticated session. No target sets this compilation condition. The gated production
bootstrap now lives inside `VortXSyncManager`, where the account key remains private: launch,
credential changes, profile changes and the existing addon-hydration entry point open a validated
encrypted checkpoint, bind the captured account namespace and merge a freshly decrypted top-level
`nativeSync` carrier. The exact owner comes from the authenticated full account roster, not the
global local profile cache. On an absent checkpoint only, the full authenticated account document is
projected by the reviewed typed importer (or its existing nativeSync is adopted by a pristine peer)
before the first atomic checkpoint. The first checkpoint includes the sealed credential-free source
archive and native import receipt. Failed/decrypt-failed account pulls, invalid owner
attribution and unavailable artifact queries fail closed; there is no empty-account fallback.
Unresolved source attribution (including own streaming accounts, ambiguous episode/type/alias evidence,
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

The current local C-ABI facade/playback fixture passed against integrated private source `b6de6b86`, library
SHA-256 `34c900f1c64537f275e6eca835925a2e4e8328c4fd801a0986bfbc7e04d7a061` and header
`f7e277e197c8c72d230be633db5395234a19ff73ec645f971b0d3e88da376672`, with unchanged before/after
hashes. That covers real kernel queries/mutations and localhost resources, not full app packaging.

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
`VORTX_ENGINE_RESOURCE_HOST`, respectively, plus `canImport(VortxEngine)`. No target enables these
conditions yet. The optional builder flags `--state-bridge` and `--resource-host` run header and
symbol verification. The latter uses the separable native resource host, without QuickJS.
Android's opt-in integration feature is `VORTX_NATIVE_RESOURCE_HOST=1` or
`-Pvortx.nativeResourceHost=true`. Its live transport requires native resource ABI version 1.
Neither option changes the selected app repository.

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

## Remaining default-cutover gates

| Owner lane | Required behavior before selecting native by default |
| --- | --- |
| Apple facade | Own-streaming-account profile identity, migration and projection; remaining reachable unsupported actions and full-app parity verification. Offline authenticated checkpoint recovery, native profile CRUD/preferences, authoritative playback/history/stat readers and reviewed Apple bulk watched/add-on actions are implemented behind the gate, not a default cutover. |
| Android facade | Integrate and verify website edits, native downloaded-watch receipt and own-streaming-account profiles. Authoritative whole-series/season/individual watch inventory and add-on URL replacement are integrated. Verify remaining interface defaults at their real consumers; a deliberately unused legacy login method is not itself a native auth gap. |
| Native state integration | Website immutable sparse events, independent host causal bases, atomic receipt/state/host persistence, exact CAS acknowledgements, native-aware website projection, and own-account/ambiguous source cohorts. Shared clocked legacy reconciliation is implemented; that alone does not establish website convergence. |
| Sources/playback | Integrate provider/debrid resolution, full subtitle options, current source preferences, source-preserving resume, episode/binge selection and download admission. |
| Native server | Advertise/test NNTP/archive capabilities before changing Node routes; unsupported archives require the supported fallback. |
| Packaging | Exact reviewed core pin, both Android flavors and all ABIs, Apple slice/header/export checks, universal Mac and Lite decisions, device verification. |

Passing bridge tests establishes the adapter and lifetime boundary. It does not establish the full
application cutover or physical playback parity.
