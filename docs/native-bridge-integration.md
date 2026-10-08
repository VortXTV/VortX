# Native bridge integration boundary

The app contains additive native state/resource bindings, an Apple account/session facade and
presentation adapters. Shipping `CoreBridge` and `EngineStremioRepository` remain the active data engine. There is no new user
selector. A native streaming server is a separate capability from the native data engine.

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
enter kernel actions or checkpoint metadata. Same-scope sessions have one in-process writer;
replacement must await shutdown before opening another session.

State changes clone the runtime, apply a FIFO action transaction, verify owner/nativeSync/watch-context
retention, checkpoint and then publish. Failed actions do not change the published runtime. Synchronous
revocation waits for an in-flight commit and prevents later outgoing-account writes. Catalog, search,
discover, metadata and subtitle slots are independent and generation-fenced. Legacy roster/watch
documents have a read-only import carrier; nonempty legacy data blocks fresh-state fallback. This is
not yet the lossless legacy importer.

`VORTX_NATIVE_DATA_ENGINE` selects the actual Apple `CoreBridge.start/dispatch/stateData` branch:
that branch does not initialize/call Stremio and rejects unsupported actions. It needs an explicitly
installed, authenticated session. No target sets this compilation condition. At this checkpoint the
production account/key bootstrap is still a separate gate; merely enabling the flag leaves the bridge
unbound, not an empty native account. CoreBridge exposes awaited shutdown and generation-checked
session installation plus addon-registry rebind after profile/configuration changes.

Apple compatibility currently covers board/search Load + LoadRange, default/specific Discover loads,
metadata/episode streams, subtitles, default library reads, standard AddToLibrary/RemoveFromLibrary,
title/episode watched intents, Player selection/progress attribution and explicit native profile/state
actions. Loading groups use the shipping read shape. Unsupported pagination/filter/sort/player actions
return false; there is no silent Stremio fallback. The native library projection currently covers standard
saved titles, not native magnet/playlist presentation or full Continue Watching/history parity.

## Artifact gate

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
registry rebind and encrypted exact-state cold reopen with episode watch contexts. It launches no
app or media player. The fixture server requires Node 22+ lossless JSON source support.

## Remaining default-cutover gates

| Owner lane | Required behavior before selecting native by default |
| --- | --- |
| Apple facade | Production authenticated bootstrap/import; horizontal and Discover pagination; genre/filter options; full library/CW/history and overlay profile integration; remaining player actions. Gated callsites and current supported actions are implemented, not a default cutover. |
| Android facade | Implement all CatalogRepository/AuthRepository/history interfaces; remove direct Stremio calls from stats and other consumers only after equivalent behavior is tested. |
| Native state integration | Lossless authenticated legacy account/profile/addon/library/watch import and nativeSync transport in the existing encrypted account envelope. Apple scoped acknowledged checkpointing is implemented; absence/decrypt failure never creates an empty account. |
| Sources/playback | Integrate provider/debrid resolution, full subtitle options, current source preferences, source-preserving resume, episode/binge selection and download admission. |
| Native server | Advertise/test NNTP/archive capabilities before changing Node routes; unsupported archives require the supported fallback. |
| Packaging | Exact reviewed core pin, both Android flavors and all ABIs, Apple slice/header/export checks, universal Mac and Lite decisions, device verification. |

Passing bridge tests establishes the adapter and lifetime boundary. It does not establish the full
application cutover or physical playback parity.
