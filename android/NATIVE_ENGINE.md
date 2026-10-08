# Native repository integration (experimental, default off)

The shipping default remains `EngineStremioRepository`. `-Pvortx.nativeEngine=true`
sets `BuildConfig.NATIVE_ENGINE_ENABLED` and selects `NativeCatalogRepository` for
both application repository seams. In that mode the application never falls back
to Stremio or preview data, and direct construction of the legacy repository fails.

The host must explicitly call `VortXApplication.activateNativeAccount` with an
authenticated account ID and its immutable native owner-profile ID. The account
must match the current account-manager identity and generation. There is no
production bootstrap UI yet. An absent checkpoint requires explicit creation;
legacy ProfileStore/SharedPreferences are never imported automatically. Production
enablement, account bootstrap and migration remain separate gates.

`VortxNativeSession` requires the resource-host ABI and the additive
`bind_sync_scope`/`nativeSync` kernel contract. Missing or old artifacts fail
explicitly. Every mutation clones the current full state, applies the native
actions, validates account/owner/schema, writes an encrypted checkpoint, verifies
the full readback, then swaps the published runtime. A failed action, write or
readback never publishes its candidate runtime. Full checkpoints preserve the
native sync carrier, membership tombstones and watch contexts without draining
deltas or publishing shadow state to cloud storage.

Checkpoints live in Android's `noBackupFilesDir/native-state`. Android Keystore
holds a non-exportable AES-256 key per scope. The sealed payload is
`nonce(12) + ciphertext + GCM tag(16)`, authenticated with UTF-8
`accountID + NUL + ownerProfileID`. Filenames use SHA-256 of that same scope.
Writes flush the temporary file, atomically rename within the directory, flush
the directory and authenticate/read back the result. Only a missing file counts
as absence. Key/decrypt/access/malformed-state failures do not create an empty
account. Account bearer tokens and passwords are not accepted by the session.

The real repository currently supports:

- Board catalogs, Discover selection/genre/skip pagination and search from native
  add-on responses, decoded by the existing Android presentation decoders.
- Metadata, streams (including metadata-embedded streams) and the native subtitle
  projection. Subtitle loading is an explicit native repository API; player-side
  subtitle-service replacement remains part of the player gate.
- Durable per-profile standard library membership, library export, individual
  movie/episode watched changes, Continue Watching reads/dismissal, and explicitly
  identified local-playback progress callbacks.
- Watch Stats reads the native active-profile history/resume projection and cached
  native metadata genres. It never reads legacy JNI or disk buckets in native
  mode; unavailable ownership produces an explicit UI error. Native watch time is
  an estimate from retained durations/positions, not a cumulative time ledger.
- Installed add-on reads/install/remove/order/visibility, native profile listing,
  add/delete/rename/switch, and typed native-sync merge.

Each resource consumer has its own cancellation/generation slot. Publication
checks the completed request identity after parsing. Profile/registry changes,
account revocation, closure and same-account reopening revoke earlier ownership.
The application retires the previous checkpoint writer before activating another.

Still unsupported, exposed as errors rather than success/no-op: Stremio login,
player/source/direct-link/magnet resolution, streaming-player lifecycle without an
explicit identity, legacy migration, Home pagination, whole-series/season bulk
watched mutation, add-on URL replacement, PIN verification and parental resource
filtering. Profile-selection Compose screens still use the legacy ProfileStore;
the native profile APIs are ready for a separately reviewed UI migration. Source
ordering does not yet implement `rememberedQuality`/`wantedAddon` continuity.
Native auth state remains signed out. No durable watched receipt authorizes
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
Resource bytes in that test are local fixtures; the test does not prove live
provider behavior. The host ABI test creates/frees a resource host without loading
network resources.
