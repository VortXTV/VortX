# Profile preparation and recovery audit — 17 October 2026

Status: source work only; no new application build, release, deployment, installation,
device launch, real-account write, sign-out, reset, or checkpoint modification.
Base application source: `82cc8387222469d36dfbb7fc09881c375e36de45`.

## What the supplied log establishes

The supplied `vortx-diag 4-1.log` is 2,633,150 bytes, SHA-256
`64a824daf7d6373d7eff17d779de1393acc7a09f43e85a0982bf4b8f8dcd8fc1`.
It is a tvOS capture with multiple process periods and an appended older excerpt.
Cached update metadata mentioning 0.5.5.274 is not a running-build header.

In the relevant sequence, a session mounted at 13:40:14, a replacement restore began
about two seconds later, a profile-open attempt was superseded at 13:40:27 while the
checkpoint was restoring, and the replacement mounted at 13:40:49. Thus that tap
failed roughly 21 seconds before preparation finished. The log does not establish
which caller initiated the replacement. It does not show the older archive-inspection
or missing-own-credential failure at this point. Pending membership receipts are
retained evidence, not a count of profiles that failed.

## Implemented and checked source changes

- The shared Apple picker shows “Preparing your profiles—please wait…” during an
  active preparation, suppresses terminal load-error presentation during that state,
  and remembers the latest selected profile until successful preparation.
- Automatic opening resolves the current authenticated roster and PIN again. Account
  changes, deletion, leaving the picker, Edit/Add/account navigation, and a terminal
  restore failure cancel the waiting intent. Background completion waits for the
  foreground. A genuine failed profile/checkpoint mutation is not silently retried.
- A pending-own profile keeps its parent picker alive while presenting sign-in. The
  picker completes only after the original account/profile has a certified own binding
  and confirmed sign-in; cancellation or a failed connection leaves the picker available.
- Delayed startup and credential-change hydration use the certified-session path
  rather than unconditionally replacing a ready native session. The credential
  observer retains and rechecks its original account capture across shutdown.
- The legacy preparation probe now supplies the installation key. A healthy indexed
  checkpoint for account A no longer makes an absent account B look like an
  unauthenticated directory. The negative bare-probe case remains rejected.
- Strict JSON string parsing copies unescaped UTF-8 runs into a byte buffer instead
  of repeatedly rebuilding an accumulated scalar view. Escape, surrogate, UTF-8,
  duplicate-key, numeric, depth, and credential checks remain enforced.
- Native Library projection builds one first-wins Continue Watching index, reuses the
  projected rows, and shares a local date formatter within each complete pass.
  Complete projected JSON is compared with the previous implementation.
- Site and webapp tab keys are bound to the exact account and session descriptor.
  Another tab cannot combine a different account/token with this tab's encryption key.
  Bare unbound legacy tab keys require sign-in again; an embedded, owned legacy
  descriptor/key pair can migrate. Revision floors and encryption ratchets are retained.
- Website backup replacement rejects invalid UTF-8/JSON, non-object documents, and
  invalid/foreign public native projection before making an account request. Native
  host/provider carriers require the app's admission path and are refused by the
  website. Accepted plaintext and unknown fields are not normalized or rewritten.
- Termination diagnostics start a fresh process receipt after folding the prior one,
  preserve the scene phase across heartbeats, and mark both explicit TV restarts as
  intentional. Late callbacks cannot undo termination. Actual crash markers win;
  missing crash evidence is described as an uncertain cause, not proof of jetsam.

## Missing-own-account first import

This is a separate failure from the transient restore sequence in the supplied log.
The source candidate imports a confirmed missing secondary sign-in as an isolated,
empty local-only profile, then applies a pending-own binding in the initial atomic
action batch before the first durable checkpoint. It never borrows the owner's
credential or declares the secondary profile shared. Unattributed profile bytes are
retained separately and cannot authenticate a later sign-in by UUID alone.

Actual-C-ABI checks pass for atomic failure, first commit, tombstones, isolated buckets,
reconnect origin policy, quarantine union and encrypted restart. Independent review
found and the integrated source corrected two retry-boundary defects:

1. A scoped, strictly typed original-missing disposition now survives an unresolved
   watched draft, encrypted reopen and later credential availability. Its profile still
   imports isolated; a later explicit independent-source CAS can connect it without
   changing the global legacy baseline or consuming the unattributed journal.
2. Draft pending-action recovery is restricted to an account with no validated native
   state. An established account uses its committed host map, so an old draft cannot
   resurrect a pending action that a reconnect already consumed. Immutable evidence
   and quarantine still append-union.

Independent Astra source review is GO for the bounded import/retry changes. The final
unchanged own-account runner exits 0, including the new encrypted-draft/reconnect and
journal-survival assertions. Manager missing-only admission, credential-generation
rechecks and legacy-only initial CAS are checked by static wiring contracts; the
complete manager and the system Keychain are not exercised by that draft fixture.

## Verification and performance evidence

- Picker: 36 source-extracted event journeys compiled with the real presentation and
  deferred-selection implementations. Collaborators and callback delivery are synthetic;
  this is not a SwiftUI rendering or physical-device test.
- Diagnostics: 29 pure policy assertions, five crash-marker snapshot checks, and an
  independent runtime extraction with disposable storage and 100 concurrent late
  callbacks pass. UIKit/MetricKit registration and a complete target build are not
  covered by the runtime extraction.
- Profile propagation, presentation, preparation, layout/PIN contracts, bootstrap
  archive inspection, and the complete legacy material suite pass. Two stale test
  assertions were updated to match pre-existing save/switch parameter additions;
  layout tests now check the credential-bound PIN block rather than its old one-line
  spelling.
- The own-account fixture used an isolated library built offline from engine source
  pin `af29b22e4c45740a1f5b6cb415b81f8430f55b9f`. Its library SHA-256 is
  `0b9af7ac61351929df75849937916cebe1a2e23852ceacef92c2fbaf3169ebc8`;
  header SHA-256 `f7e277e197c8c72d230be633db5395234a19ff73ec645f971b0d3e88da376672`.
  This is source/ABI test evidence, not the published SDK binary or device acceptance.
- Synthetic optimized 1,048,880-byte watched preparation: old 56.922791 seconds,
  new 0.030909 seconds. Retention/validation: old 14.507575 seconds, new 0.044940
  seconds. Accepted evidence/archive sizes are unchanged. These are host timings,
  not measurements of the supplied user's launch.
- Native projection: 203 full JSON/library/search comparisons pass. With 5,000 saved
  titles, 5,000 Continue Watching entries and 5,000 history entries, the complete
  synthetic projection fell from 3.3768 to 0.0736 seconds on the test host.
- Website: all 211 tests pass. Webapp library tests: all 133 pass. Transport/storage
  tests use synthetic sessions and mocked requests, never real accounts.
- Final profile routing/propagation and foreground-sync runners pass, including
  cancellation, exact transport ACKs, pending edits and cold synthetic checkpoint
  continuity. A runner-tail failure from editing a running script was retained; the
  final stable script passes syntax checks and its complete C ABI run exits 0.

## Remaining confirmed or strongly supported findings

These are not fixed merely because startup or source tests now pass:

| Priority | Area | Finding / required work |
| --- | --- | --- |
| P1 | Apple watched migration | Full source bytes are repeated per receipt. A valid 1,050,720-byte source with 24 successful series receipts produces 33,653,246 bytes, exceeding the 32 MiB archive cap. Preserve exact source once by digest with dual-read compatibility; do not just remove the cap. |
| P1 | Android watched migration | The same source-per-row amplification can exceed the 16 MiB witness limit; retained-array bounds and lookup indexing also need attention. |
| P1 | Android TV first import | Missing-own credential setup/retry is available on phone but unreachable from the unmounted TV picker. Preserve source and expose the independent setup path. |
| P1 | Android settings | Global-only edits mark dirty stamps but do not arm native upload; a library edit in an existing test masks this. A reviewed patch and four regressions are retained but not integrated because the isolated Kotlin compiler/classes are unavailable. No APK build was substituted. |
| P1 | Android reconciliation | Boolean failure is discarded and the dialog closes early. The same reviewed, uncompiled Android patch retains the card and checks the outcome; it is not an executed fix yet. |
| P1 | Browser reset continuity | Account-only revision floors outlive a backup/key reset and can reject a new generation. Requires authenticated key-generation ownership, not blindly clearing rollback protection. |
| P1 | Android list import | Redirects are followed after validating only the initial host. Validate each hop; the MDBList authenticated URL fallback also needs a credential-exposure review. These are source findings, not a live exploit test. |
| P2 | Apple first paint | Cold restore still waits for a remote read before admitting a local checkpoint. Local-first work must preserve account attribution and reconciliation, not bypass unreadable data. |
| P2 | Apple recommendations | A failed For You fetch can retain its collection key and suppress retry for unchanged inputs. |
| P2 | Apple localization | Transport failures can persist as negative metadata entries without retry expiry. |
| P2 | Browser projection | Repeated per-item scans and sorts remain quadratic on larger native libraries. |

The strict source parser also has a 2 MiB limit while account transport has a larger
response allowance. The server's actual plaintext admission limit and end-to-end memory
bounds must be checked before changing this limit. Unresolved watched metadata still
holds the first import; partial admission requires its own conservation/provenance review.

## Coverage and release boundary

The current inventory includes 491 Apple source Swift files, 531 main Android Kotlin
files, 40 webapp TypeScript/TSX/Svelte files and 31 site TypeScript/Astro files. This pass
focused on startup, migration, profile ownership, persistence, sync, account recovery,
Library projection, settings and related diagnostics. It is not an every-line review
of all those files and is not a claim that the whole application is bug-free.

The existing 0.5.5 packages, tag, feeds, download router and production backend are
unchanged. No new app build is authorized by this source repair. A future reviewed
build and affected-device checks remain necessary before calling issue #262 resolved.
The website safety change is committed locally as `f0687ce`; it has not been pushed,
built or deployed. The existing production website is unchanged.

## 18 October follow-up: settings inspection and silent restore admission

A newer diagnostic export repeatedly reports an opaque preference inside the settings
payload before native preparation. Its masked path does not identify the customer's
exact value. An old server-stop entry is followed by a later server boot; it is not proof
that the current failure is a loopback-server outage.

The current producer accepts literal profile names and single-grapheme avatars which
can begin with `[` or `{`. The inspector now recognizes only the actual settings-domain
JSON-Data roster, UUID/name/avatar-shaped rows, and their direct display fields. Decoded
containers, unrelated fields and provider-authored identities retain ordinary inspection.
Unknown noncredential values survive; original inputs are unchanged. Archived roster
Data contains the inspected re-encoding, not uninspected duplicate-key source bytes.

Issue 265's early restore guards now report fixed, non-sensitive admission reasons.
Backup history distinguishes certified absence from unavailable storage. Certified `1`
needs no new write; only certified missing permits initial receipt creation. Unknown or
invalidated secure state is not overwritten or treated as permission to seed an empty
account. A bounded process-local observation floor is denial-only, not durable ACK.
Persisted invalidation still requires a separately verified recovery path; it is not
silently cleared. No installation/account key or checkpoint is reset.

A separate structured-JSON admission check rejects duplicate decoded keys, including
escaped and canonically equivalent Unicode collisions, before returning an archive.
A shared temporary UTF-8 view lets Foundation and this check inspect valid UTF-16/32
carriers consistently, including encodings the raw platform decoder rejects. Stored
noncredential String/Base64 bytes are not replaced by that inspection view.
Unambiguous authenticated source String/Base64 bytes and their hashes stay exact.
The scanner adds an explicit raw-JSON depth limit of 128; this also rejects excessively
deep credential subtrees which the old dictionary sanitizer could discard without
traversal. Rejection preserves the original input rather than truncating or replacing it.
It adds no byte-size, numeric-magnitude or numeric-token limit. Foundation still parses
the inspection view first, so this is not a complete memory/CPU bound. Completely
untranscodable malformed Unicode, plist ambiguity and already-materialized external
duplicates remain outside this bounded check's guarantee.

Selected source gates use `scripts/test-native-migration-phase-a.sh` with `bootstrap`,
`restore`, `publication` or `parse`. Each stage retains immutable inputs and command
receipts and runs serially at low priority. Restore has 218 focused synthetic checks;
publication has 57 source-wiring checks. Bootstrap passes 192 structured-carrier
permutations, 50 normalized fragment journeys, ten object encoding/BOM combinations,
duplicate/credential/depth/byte-conservation controls and the prior profile/archive
groups. Raw Foundation accepted 41/50 fragments and 9/10 objects on the test host;
these observations do not replace the unconditional normalized-production checks.
Parse is syntax only, not target/SDK typechecking.
No new app build, real-account operation, device acceptance or issue closure is implied.
