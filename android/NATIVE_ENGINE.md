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
`import_legacy_sync` reducer and its durable, idempotent receipt. Later observed
legacy carriers use `reconcile_legacy_sync` with the retained typed baseline, not
an automatic overwrite. The kernel applies only changed fields/events with sufficient
causal evidence; missing/regressing/ambiguous clocks reject the full transaction.
Every authenticated route, including existing checkpoints and native carriers,
reprojects the current legacy material and reconciles its receipt in the same atomic
transaction as native merge. Pending/malformed website `profileEdits` and missing
native-carrier import receipts fail closed before checkpoint publication. Unchanged
legacy material and acknowledged ancestors remain no-ops after native edits; unsupported differing material never silently
mounts an older native state. The exact account/mount is checked again after UI projection.
An authenticated never-backed account can provision a deterministic Main/A11C baseline
only after a proven missing backup and acknowledged create-only version-zero PUT.
The candidate stays detached until acceptance; collisions re-pull the winner before
mounting, including a different historical owner. Unknown outcomes leave no provisional
checkpoint. A persistent account-scoped backup-seen marker prevents later 404s from
resetting an account, including backups stored at version zero. Malformed success,
network/key/decrypt failures and incomplete rosters never create blank accounts.
Logout/account replacement retires the writer and clears native profile/UI state;
reopening waits for retired transactions before touching the account checkpoint.

`VortxNativeSession` requires the resource-host ABI and the additive
`bind_sync_scope`/`nativeSync`, `import_legacy_sync`, `reconcile_legacy_sync`, `installed_addons` and
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
Recognizable encoded and quoted JSON/plist/backup carriers are inspected recursively.
Older checkpoints' adjacent host fields are checked before hydration; detected
credentials or malformed encoded carriers reject the original file without rewriting
it. Fresh typed import material is checked without sanitizing or changing its receipt.
Native sync derives from a freshly authenticated full cloud document and replaces
only `nativeSync` and the separate `nativeHostPreferences` carrier, preserving the original legacy roster/settings/library/watch
baseline and all unknown/credential fields. Rewriting that baseline from native
projections would invalidate the import receipt on the next pull. Unsupported dirty
global settings or changed host credentials block push rather than reporting an upload
or clearing unapplied intent. Existing
host credential/global-settings restoration on pull is retained. Native profile,
library and watch changes still synchronize through the native carrier using the
existing encrypted optimistic-concurrency push. Active profile selection is never
exported in `nativeSync`.
Host-only profile preferences (including avatar, playback and discovery settings)
use shared schema-one per-field registers: `{clock,actor,value}`, ordered by safe-integer
Lamport clock then lowercase UUID actor. Null is explicit deletion; equal-event unequal
values are rejected. Profile and global buckets both wrap `fields`; native authority,
device selection and credentials are forbidden. Unknown safe fields survive without
being applied. Known nested profile/global types are validated before commit.
`nativeHostPreferenceState` atomically retains the local actor/counter, merged carrier
and pending state adjacent to the kernel. Only the carrier is uploaded; an exact accepted
generation is acknowledged, so edits during PUT remain pending across cold restart.
Old `hostProfileSyncPending` intent migrates only against an authenticated baseline.
Native-owned name/PIN/parental/theme fields remain pushable through `nativeSync`.
Native provider credentials use the shared `nativeProviderCredentials` schema-1
account-scoped register carrier. The seven metadata/debrid keys and complete Trakt/SIMKL
OAuth tuples use safe-integer Lamport clocks, canonical UUID actors, explicit null clears,
and exact-event acknowledgements. Equal stamps with different values are rejected.
One confirmed encrypted account record is both the actual credential backing and its
pending sync journal: OAuth tuple publication cannot succeed separately from durable
intent. A captured account epoch and selected credential event fence asynchronous OAuth
publication, including same-account sign-out/reopen. Secure pending events re-arm sync
after process death; edits during PUT remain pending. Metadata aliases are mirrored in
both existing cloud locations while unknown `apiKeys` fields survive.

Authenticated legacy cloud keys remain a secure fallback only while no native register
exists; they are not promoted to register authority and cannot resurrect native clears.
Existing explicitly account-qualified metadata/debrid slots can supply the initial local
fallback. Unscoped legacy OAuth tuples require reauthentication; they are not assigned to
the current account. The credential carrier is excluded entirely from local host archives
and native checkpoints. Native provider backing stays solely in encrypted credential
storage and encrypted cloud documents. Default native selection remains off; local
fixtures do not establish Android Keystore, actual provider or device behavior.

Checkpoints live in Android's `noBackupFilesDir/native-state`. Android Keystore
holds a non-exportable AES-256 key per scope. The sealed payload is
`nonce(12) + ciphertext + GCM tag(16)`, authenticated with UTF-8
`accountID + NUL + ownerProfileID`. Filenames use SHA-256 of that same scope.
Writes flush the temporary file, atomically rename within the directory, flush
the directory and authenticate/read back the result. Only a missing file counts
as absence. Key/decrypt/access/malformed-state failures do not create an empty
account. An independently sealed account-to-owner locator supports offline recovery with
the verified persisted account lease, including historical owner UUIDs. It is published
after the full checkpoint; missing/corrupt/unindexed prior state is not fresh-account
authority. Cached global registers and archived settings project under the same lease
before network access. Account bearer tokens and passwords are not accepted by the session.

The real repository currently supports:

- Board catalogs and per-row skip pagination, Discover selection/genre/skip pagination and search from native
  add-on responses, decoded by the existing Android presentation decoders.
- Metadata, streams (including metadata-embedded streams) and the native subtitle
  projection. Subtitle loading is an explicit native repository API; player-side
  subtitle-service replacement remains part of the player gate.
- Durable per-profile standard library membership, library export, individual
  movie/episode watched changes, Continue Watching reads/dismissal, and explicitly
  identified offline/native-streaming playback progress callbacks.
- Atomic series/season watched/reset over the complete returned metadata inventory, and
  exact episode membership checks (no synthetic episode identities or inferred episodes).
  The isolated mutation lookup does not replace visible detail navigation. Missing/ambiguous
  inventory, a changed owner, failed action or mismatched candidate playback projection
  rejects the whole transaction before its checkpoint is committed.
- Parental admission runs native catalog/meta queries on raw provider objects before
  presentation decoding, including Home/Discover/search/pages and embedded streams.
  Unknown certifications fail closed. A certified series cannot authorize a foreign
  episode ID. Pagination advances by raw counts, and empty filtered Home pages expose
  a native-only Continue catalog button on phone/TV, one bounded page per user action.
  Supplemental host-generated Home rails also pass final owner-bound admission;
  items without current raw native certification evidence stay hidden under restrictions.
- Watch Stats reads the native active-profile history/resume projection and cached
  native metadata genres. It never reads legacy JNI or disk buckets in native
  mode; unavailable ownership produces an explicit UI error. Native watch time is
  an estimate from retained durations/positions, not a cumulative time ledger.
- Validated custom add-on endpoint replacement atomically installs/removes/reorders and
  rekeys affected explicit profile visibility/order preferences. The original descriptor
  survives lookup/validation/checkpoint failure; official/protected endpoints cannot change.
  Candidate installed-add-on readback verifies order, flags and unchanged peer descriptors.
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

Still unsupported (repository operations fail explicitly): Stremio login,
unresolved own-Stremio-account migration, ambiguous or incomplete legacy carriers,
legacy changes without the shared reducer's required causal evidence (including pending
website profile patches), unscoped legacy OAuth ownership attribution,
global settings outside the explicit shared SettingsBackup type whitelist (and legacy
flat native-profile theme changes). The existing profile UI verifies projected salted PINs before
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
Native-carrier regressions cover pending website edits, changed legacy roster/library
input and missing receipts across warm, cold and first adoption; unchanged native-native
updates pass. Delayed projection tests reject retirement before install reports success.
Resource bytes in that test are local fixtures; the test does not prove live
provider behavior. The host ABI test creates/frees a resource host without loading
network resources.
