# Native repository integration (experimental, default off)

The shipping default remains `EngineStremioRepository`. `-Pvortx.nativeEngine=true`
sets `BuildConfig.NATIVE_ENGINE_ENABLED` and selects `NativeCatalogRepository` for
both application repository seams. In that mode the application never falls back
to Stremio or preview data, and direct construction of the legacy repository fails.

`VortXSyncManager` now activates `NativeAccountCoordinator` after its captured
account lease has authenticated/decrypted a successful backup response. Scope is
`account.<canonical lowercase account UUID>`, with the exact historical owner UUID
from the authenticated full roster (not the lossy dashboard summary or global
ProfileStore). Existing checkpoints reopen; a first import uses the shared
`import_legacy_sync` reducer and its durable, idempotent receipt. A changed legacy
carrier after import requires explicit reconciliation, not an automatic overwrite.
404, malformed success, network/key/decrypt failure and missing full rosters never
create a blank account. New-account/no-backup provisioning remains a separate gate.
Logout/account replacement retires the writer and clears native profile/UI state;
reopening waits for retired transactions before touching the account checkpoint.

`VortxNativeSession` requires the resource-host ABI and the additive
`bind_sync_scope`/`nativeSync`, `import_legacy_sync`, `installed_addons` and
`profile_playback` kernel contracts. Missing or old artifacts fail
explicitly. Every mutation clones the current full state, applies the native
actions, validates account/owner/schema, writes an encrypted checkpoint, verifies
the full readback, then swaps the published runtime. A failed action, write or
readback never publishes its candidate runtime. Full checkpoints preserve the
native sync carrier, membership tombstones and watch contexts without draining
deltas. Full avatar/playback/discovery/email preferences remain in the encrypted
checkpoint's adjacent `hostProfilePreferences`, never in the kernel carrier.
Exact credential-free typed import input (including fractional source clocks) is
retained beside it as `legacyImportMaterial` in the same atomic encrypted checkpoint.
`hostDocument` retains the authenticated document's noncredential fields and nested
settings, with path-only `excludedCredentialPaths` recording the known credential
carriers omitted from this local copy. None of these adjacent fields is hydrated
into the kernel or exported as `nativeSync`. Credential-shaped unknown fields and
uninspectable settings fail closed. The original credential-bearing account
document remains encrypted in the existing cloud carrier and is only held
transiently for authenticated merge; keys stay in their existing secure stores.
Native sync derives from a freshly authenticated full cloud document, merges only
the native carrier and full roster/settings fields it owns, preserves unknown and
credential-store fields, and uses the existing encrypted optimistic-concurrency
push. Active profile selection is never exported in `nativeSync`.

Checkpoints live in Android's `noBackupFilesDir/native-state`. Android Keystore
holds a non-exportable AES-256 key per scope. The sealed payload is
`nonce(12) + ciphertext + GCM tag(16)`, authenticated with UTF-8
`accountID + NUL + ownerProfileID`. Filenames use SHA-256 of that same scope.
Writes flush the temporary file, atomically rename within the directory, flush
the directory and authenticate/read back the result. Only a missing file counts
as absence. Key/decrypt/access/malformed-state failures do not create an empty
account. Account bearer tokens and passwords are not accepted by the session.

The real repository currently supports:

- Board catalogs and per-row skip pagination, Discover selection/genre/skip pagination and search from native
  add-on responses, decoded by the existing Android presentation decoders.
- Metadata, streams (including metadata-embedded streams) and the native subtitle
  projection. Subtitle loading is an explicit native repository API; player-side
  subtitle-service replacement remains part of the player gate.
- Durable per-profile standard library membership, library export, individual
  movie/episode watched changes, Continue Watching reads/dismissal, and explicitly
  identified offline/native-streaming playback progress callbacks.
- Watch Stats reads the native active-profile history/resume projection and cached
  native metadata genres. It never reads legacy JNI or disk buckets in native
  mode; unavailable ownership produces an explicit UI error. Native watch time is
  an estimate from retained durations/positions, not a cumulative time ledger.
- Installed add-on reads/install/remove/order/visibility, native profile listing,
  add/delete/rename/switch, and typed native-sync merge.
- Existing profile UI commands use native durable CRUD/selection behind the gate;
  full host preferences are projected around the authoritative native subset.
- Native source selection produces an immutable owner/episode playback context.
  Direct HTTP(S), credential-scoped debrid/Usenet, and the own JNI torrent server
  resolve through a separate host resolver, never a legacy engine instance. Missing
  server/provider capabilities are explicit errors. Pasted links/magnets have no
  history identity. Late or replaced source selections release their playback lease.
  Native hero playback bypasses the legacy debrid fast path so the issued immutable
  playback context is retained. Exact video-ID resume points come from the kernel.

Each resource consumer has its own cancellation/generation slot. Publication
checks the completed request identity after parsing. Profile/registry changes,
account revocation, closure and same-account reopening revoke earlier ownership.
The application retires the previous checkpoint writer before activating another.
Watch-only/idempotent cloud merges preserve an active playback lease; actual
profile, registry and host-preference changes revoke it. A cached detail offset
cannot overwrite the kernel's exact resume offset or explicit reset-to-zero.

Still unsupported, exposed as errors rather than success/no-op: Stremio login,
unresolved own-Stremio-account migration, ambiguous or incomplete legacy carriers,
new-account/no-backup provisioning, continuous old-client reconciliation,
whole-series/season bulk watched mutation, add-on URL replacement and parental
resource filtering. The existing profile UI verifies projected salted PINs before
selection; stale projected profiles are rejected. Direct repository PIN switching
remains blocked rather than bypassing that gate. Source
ordering does not yet implement `rememberedQuality`/`wantedAddon` continuity.
Native auth state reflects successfully mounted VortX accounts. No durable watched receipt authorizes
download deletion. None of these gates is evidence of full product cutover.

Silent verification uses both `compilePlayDebugKotlin` and
`compileFullDebugKotlin`, then the focused `VortxNative*Test` JVM suites with
`cargoNdkBuild`, `cargoNdkBuildVortxFfi` and mpv `externalNativeBuildDebug`
excluded. Set `VORTX_JNI_LIBRARY` to a reviewed host JNI library to execute the
otherwise skipped real-JNI hydration/resource-ABI test. No test starts a player,
provider request, application or device session. Android Keystore and final APK
ABI packaging/signing still require device/release gates.

With the reviewed native-sync artifact, also set `VORTX_JNI_SYNC=1` to execute
the real JNI session test: bind scope, mutate library/profile/progress, checkpoint,
reopen, reject a foreign account document and render repository resource fixtures.
The additional JNI lifecycle fixture imports an authenticated historical-owner
backup, performs profile CRUD, preserves full adjacent preferences, reopens the
encrypted checkpoint and rejects changed legacy material and stale account epochs.
Resource bytes in that test are local fixtures; the test does not prove live
provider behavior. The host ABI test creates/frees a resource host without loading
network resources.
