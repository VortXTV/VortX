# Native Android repository integration (0.5 native default)

`android/app/build.gradle.kts` defaults `vortx.nativeEngine` to true, and
`vortx.nativeResourceHost` follows that selection unless independently overridden.
`VortXApplication.catalogRepository` selects `NativeCatalogRepository` in native
mode; its `authRepository` selects the separate `NativeStreamingAuthRepository`
described below. Native catalog access never falls back to the legacy engine or
preview data, and direct construction of `EngineStremioRepository` is guarded.
The legacy implementation remains available only for explicit non-native comparison
selection. Source selection is not a claim that every 0.5 runtime/release gate has passed.

## Android native 0.5 build and artifact contract

Native is the source default; the workflows also select it explicitly at the Gradle
invocation boundary:

```text
./gradlew <release-or-debug-tasks> -Pvortx.nativeEngine=true -Pvortx.nativeResourceHost=true
```

`android/app/build.gradle.kts` resolves those properties (with the matching
`VORTX_NATIVE_ENGINE` / `VORTX_NATIVE_RESOURCE_HOST` environment variables as a
local-tooling fallback) before Android variants are configured. Gradle properties
take precedence over environment values; an explicit false/blank native selection
chooses comparison mode even over an exported native environment value. With no
separate resource-host override it follows the native flag. Resolved native mode
with resource-host disabled fails configuration; a native application must compile
the `jni,server,resource-host` `vortx-ffi` feature set. `BuildConfig.NATIVE_ENGINE_ENABLED`
comes from that same resolved native flag, so a server-only/resource-host artifact
cannot be presented as a native application by accident. Non-native builds retain
the existing explicit `jni,server` feature set.

Both `.github/workflows/android.yml` and `.github/workflows/android-release.yml`
pass both Gradle properties for their engine-required builds. Their APK/AAB gates
inspect each shipped `arm64-v8a`, `armeabi-v7a`, and `x86_64` slice with the pinned
NDK `llvm-readelf`, require callable JNI exports and the resource-host ABI, and
inspect packaged DEX with Android build-tools `dexdump` for
`BuildConfig.NATIVE_ENGINE_ENABLED=true` (`classes*.dex` in APKs and
`base/dex/classes*.dex` in AABs). The reusable
`scripts/verify-android-native-build-config.sh` parser tracks the target static
field/value pair and stops at whitespace-tolerant class boundaries. The signed candidate lane also retains
`scripts/verify-native-android-artifacts.sh` before upload. A release artifact that
contains a resource-host library but advertises `BuildConfig.NATIVE_ENGINE_ENABLED=false` is rejected.

Native `preBuild` schedules `cargoNdkBuildVortxFfi`, not the legacy `cargoNdkBuild`.
The legacy JNI output directory is attached only in comparison mode, and native
packaging explicitly excludes `libstremiox_core.so`. The workflows invoke
`verify-native-android-artifacts.sh --native-only`: it rejects that legacy library,
requires exactly one VortX engine slice for each shipped ABI, checks callable
resource-host/server JNI and ELF architecture, and compares packaged bytes with
fresh staged bytes after the same pinned strip normalization. The verifier's
default two-engine mode remains a comparison contract, not the native workflow gate.

Both Android workflows now pin `VortXTV/vortx-core` to
`7b368f447a3dfc46bd68905acef19fa5c136240d` for future builds. They also
retain a `VortXTV/stremiox-core` checkout at
`31c66611822043e089f5819ad232a5df93975873` for comparison/tooling; checkout presence
does not mean it is built or packaged in native variants. These exact source pins
replace the former pending-candidate description, but do not prove that the
latest host's complete native server capability contract is in a freshly built,
signed Android artifact. Compatible real SDK slices, successful CI/artifact
readback, signing and device/runtime gates must be evidenced separately; older or
missing capabilities fail explicitly rather than selecting the legacy engine.
This pin has independently accepted Linux/macOS source CI (run `37907843106`);
this is not an Android SDK, APK/AAB or device receipt. The immutable
`v0.5.0-beta.1` source remains at `844782d29a93ae51991bfadc639d50bc3619d40b`
with its original `7e3e68be5bf2b11c65d158c1823be94bd1608d1b` engine pin.
No existing tag, release draft or artifact is replaced by this future-only update.

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
transaction as native merge. Missing native-carrier import receipts and malformed
source material fail closed. Supported immutable website profile/add-on events
have their own validation, pending journals and kernel receipts; historical
`profileEdits` is handled by its narrow original-baseline path, never folded by the
broad importer or re-clocked as a new local edit. Unsupported/conflicting events
remain pending rather than being falsely acknowledged. Unchanged
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

Each upload is derived from its freshly pulled backup revision: an exact revision
`N` produces `N + 1`, and authoritative absence alone produces create-only revision
zero. Rejection causes another pull and rebuild; wall-clock time, a local high-water
mark and a rejected PUT's echo cannot confer authority on an older payload. Malformed,
fractional or overflowing revisions fail closed.

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
storage and encrypted cloud documents. Native selection is now the source default;
local fixtures still do not establish Android Keystore, actual provider or device behavior.

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

## Streaming authentication and own-account migration

Mounted VortX account authority is separate from optional Main-profile Stremio
authentication. The application's native `authRepository` uses
`NativeStreamingAuthRepository`, with a captured management revision/account epoch
and the unlocked Main/PIN gate. Connect/disconnect verifies and publishes that
optional credential state; it does not relabel the VortX owner, sign out the VortX
account or replace native saved data. Direct `NativeCatalogRepository` Stremio
sign-in operations still fail explicitly; they are not the application's auth seam.

Non-owner own-account setup/linking uses `NativeAccountCoordinator` and
`NativeStreamingAccountLink`, not a legacy engine instance. It verifies the source
UID and obtains that source's independent library/add-on material under the exact
captured account, profile, binding revision and transaction. A verified UID alone
does not attribute an old root overlay to the newly signed-in source. Tokens and
link intents require confirmed encrypted credential-store readback; they are not
written into `nativeSync`, native checkpoints or host source archives.

`pending_own`, own-account A-to-B replacement and return to shared mode are durable
account-slot transitions. Histories remain source-qualified: an unresolved non-owner
slot never borrows Main's original Library/history or another UID's records.
Supported migration requires exact source/overlay evidence and complete watched
evidence. Missing, stale, uncertain or incomplete evidence retains the sealed
candidate/pending intent for retry, rather than acknowledging a partial import.
Credential, source and binding readback must pass before publication. This is an
implemented guarded path, not universal legacy-migration, provider or device proof.

## Native repository and playback behavior

The real repository currently supports:

- Board catalogs and per-row skip pagination, Discover selection/genre/skip pagination and search from native
  add-on responses, decoded by the existing Android presentation decoders.
- Metadata, streams (including metadata-embedded streams) and the native subtitle
  projection. Subtitle loading is an explicit native repository API; player-side
  subtitle-service replacement remains part of the player gate.
- Durable per-profile standard library membership, library export, individual
  movie/episode watched changes, Continue Watching reads/dismissal, and explicitly
  identified offline/native-streaming playback progress callbacks.
  History, Library and Watchlist remain distinct: native Watchlist intent/migration
  retains per-profile removals, and ambiguous source attribution stays pending rather
  than borrowing another account's membership.
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
- Configured Newznab indexers participate in native streams through
  `NzbSourceAggregator`. The factory requires an actual projected active profile
  (`active?.id`, never an Owner fallback) and an account/profile-qualified indexer
  store matching the captured native owner. Searches use approved exact metadata
  and the selected episode; ordered indexer results append after the captured add-on
  groups. Disabled/empty configuration is a no-op, individual failures do not erase
  working add-ons, and indexer-only success is supported. Parental admission and
  exact request/configuration/owner/coroutine fences run before cache or source-token
  publication; appended sources retain the same immutable playback context.

Native Usenet routing retains ordered NZB mirrors, add-on server lists and explicit
selection hints. Positively confirmed cached TorBox material may route without NNTP;
otherwise add-on servers precede the captured saved provider, with TorBox used only
when its configured policy admits that mirror. A capability or provider failure is
not evidence of cache readiness. The local control endpoint is literal-loopback,
proxy-free and redirect-free; compatible operation-cancellation and file-selection
capabilities are required, and older/missing contracts fail explicitly. Returned
provider/enclosure URLs alone are not playable-media or live-provider proof.

Each resource consumer has its own cancellation/generation slot. Publication
checks the completed request identity after parsing. Profile/registry changes,
account revocation, closure and same-account reopening revoke earlier ownership.
The application retires the previous checkpoint writer before activating another.
Watch-only/idempotent cloud merges preserve an active playback lease; actual
profile, registry and host-preference changes revoke it. A cached detail offset
cannot overwrite the kernel's exact resume offset or explicit reset-to-zero.

Pending resolution and handed-off playback have different fences. Pending admission
checks the captured caller Job, mounted session/owner, exact source binding and resolve
sequence; final admission repeats those checks and closes a denied returned lease.
Retired admission becomes a handled failure only while the caller remains active;
genuine coroutine cancellation stays terminal. The Usenet playback-lifetime callback
checks only the captured session identity/native owner, supplemented by the transport's
captured credential/provider revision. It excludes the completed caller Job, mutable
source map and later prewarm sequence, so new source reads do not retire current
playback. A pending timeout closes its retained operation; after handoff, operation
monitoring closes the owned lease on explicit close or authority retirement.

Still unsupported or explicitly gated: ambiguous or incomplete legacy carriers,
legacy changes without the shared reducer's required causal evidence, unsupported
website payloads, unscoped legacy OAuth ownership attribution,
global settings outside the explicit shared SettingsBackup type whitelist (and legacy
flat native-profile theme changes). The existing profile UI verifies projected salted PINs before
selection; stale projected profiles are rejected. Direct repository PIN switching
remains blocked rather than bypassing that gate. Source
ordering does not yet implement `rememberedQuality`/`wantedAddon` continuity.
Native account authorization reflects successfully mounted VortX accounts; optional
Main authentication is verified separately and never borrowed from a child UID.
Terminal playback can issue a one-use owner/session-bound watched receipt only when
a fresh authenticated checkpoint query
confirms a new exact-video completion. Cleanup rechecks that same persisted watch clock and owner;
the existing download coordinator still separately requires decoder/lease release and the user's
auto-delete setting. Final cleanup admission holds the download lifecycle, native session, captured
account epoch and mounted-account fence in that order, so logout cannot race an admitted deletion
and download bookkeeping cannot invert the authentication lock. Partial playback, failed persistence, unwatch, reopen and profile switches
cannot authorize cleanup. None of these gates is evidence of full product cutover.

Silent verification uses both `compilePlayDebugKotlin` and
`compileFullDebugKotlin`, then the focused `VortxNative*Test` JVM suites with
`cargoNdkBuild`, `cargoNdkBuildVortxFfi` and mpv `externalNativeBuildDebug`
excluded. Set `VORTX_JNI_LIBRARY` to a reviewed host JNI library to execute the
otherwise skipped real-JNI hydration/resource-ABI test. No test starts a player,
provider request, application or device session. Android Keystore and final APK
ABI packaging/signing still require device/release gates.
An actual-JNI acceptance receipt must show that these tests executed with zero
skips and retain the exact public source, native artifact/header fingerprints and
command. Excluding native build tasks is a host-test technique, not a fresh Android
SDK build or packaged-artifact receipt.

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

Workflow declarations and passing host tests do not establish a terminal CI build,
fresh source-matched SDK slices for every shipped ABI, signed APK/AAB readback,
Keystore/device behavior, physical playback or live account/provider success.
Those gates remain separate, including compatibility with the native Usenet control
contract. Source continuity (`rememberedQuality`/`wantedAddon`) remains unimplemented;
this document makes no complete-parity, published-Beta or release-acceptance claim.
