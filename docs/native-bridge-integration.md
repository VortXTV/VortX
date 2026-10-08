# Native bridge integration boundary

The app contains additive native state/resource bindings and presentation adapters. Shipping
`CoreBridge` and `EngineStremioRepository` remain the active data engine. There is no new user
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
`VORTX_FFI_HEADER` and `VORTX_FFI_LIBRARY`, proves cold hydration/deltas, and fetches deterministic
catalog/meta/stream/subtitle fixtures over loopback. It launches no app or media player.

## Remaining default-cutover gates

| Owner lane | Required behavior before selecting native by default |
| --- | --- |
| Apple facade | Route existing CoreBridge actions/state events through native host; preserve loading, paging, search/discover, publication fences and all profile/account leases. |
| Android facade | Implement all CatalogRepository/AuthRepository/history interfaces; remove direct Stremio calls from stats and other consumers only after equivalent behavior is tested. |
| Native state integration | Copy/read back existing account/profile/addon/library/watch state, verify owner and sync schema, use acknowledged persistence, reject malformed snapshots without creating empty accounts. |
| Sources/playback | Integrate provider/debrid resolution, full subtitle options, current source preferences, source-preserving resume, episode/binge selection and download admission. |
| Native server | Advertise/test NNTP/archive capabilities before changing Node routes; unsupported archives require the supported fallback. |
| Packaging | Exact reviewed core pin, both Android flavors and all ABIs, Apple slice/header/export checks, universal Mac and Lite decisions, device verification. |

Passing bridge tests establishes the adapter and lifetime boundary. It does not establish the full
application cutover or physical playback parity.
