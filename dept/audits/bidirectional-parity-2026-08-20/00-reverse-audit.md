# Bidirectional parity audit

Date: 2026-08-20
Status: complete, read-only audit record
Baseline: `ab168e5e957b7113b73e6e98939ba1893c02875d`
Scope: Android-to-Apple confirmation against the shared Apple-to-Android capability ledger

## Decision and release meaning

This report records the reverse-direction audit and its evidence. It does not grant release
approval and it does not create a second backlog. The authoritative row inventory remains the
[Android ↔ Apple parity closure synthesis](../android-parity-2026-08-20/00-synthesis.md). That
synthesis is the source of truth for the 379 unique status-bearing rows, their normalized status,
severity, owner path, and lane assignment. This report checks that the same rows are interpreted
consistently when the direction is reversed, Android capability claims are not mistaken for
Apple-equivalent behavior, and platform-specific N/A rows are not counted as gaps.

The reverse audit confirms that Android is not release-ready for a parity release. The current
department release decision therefore stands: Beta 19 is Apple-only, Android parity is preserved
for the next release, and Android must not be used to manufacture a Beta 19 artifact or appcast
entry. This is a no-Beta19-blocker conclusion for the reverse audit, not a claim that Android has
no work remaining. The Apple Beta 19 gates are tracked separately in the department handoff.

Continuation contract: [Android next-release runbook](../../ANDROID-NEXT-RELEASE-RUNBOOK.md). The
runbook requires every applicable row to reach `PRESENT`, with zero `PARTIAL` and zero `ABSENT`
except evidence-backed true `N/A`, followed by physical-device and release checks.

## Exact accounting

The counts below are copied without reinterpretation from the synthesis. Percentages use the 375
applicable rows, not the 379 raw rows.

| Measure | Count | Calculation or meaning |
|---|---:|---|
| Raw status-bearing rows | 379 | All rows in the 12 lane reports |
| N/A | 4 | Platform-specific and excluded from the applicable denominator |
| Applicable rows | 375 | `379 - 4` |
| PRESENT | 241 | Full parity, including the one player-controls superset |
| PARTIAL | 93 | Some behavior exists, but the end-to-end contract is incomplete |
| ABSENT | 41 | No complete Android path was evidenced |
| Non-PRESENT applicable rows | **134** | `93 + 41` |
| Strict parity | 64.3% | `241 / 375 = 64.266…%` |
| Weighted parity | 76.7% | `(241 + 0.5 × 93) / 375 = 76.666…%` |

The row arithmetic is exact: `241 + 93 + 41 = 375`, and `375 + 4 = 379`. Severity arithmetic
also reconciles: 2 Blocker + 3 Critical + 82 High/Major + 43 Medium/Minor + 4 Low = 134. The
134 number is therefore not “134 additional Android features” and must not be added to the 379
row total again. It is the union of the 93 `PARTIAL` and 41 `ABSENT` rows already present in the
ledger.

### Per-lane reconciliation

| Lane | PRESENT | PARTIAL | ABSENT | N/A | Applicable |
|---|---:|---:|---:|---:|---:|
| 01 Home/catalogs | 16 | 3 | 1 | 0 | 20 |
| 02 Discover/search/navigation | 14 | 9 | 0 | 0 | 23 |
| 03 Detail/metadata | 24 | 13 | 3 | 0 | 40 |
| 04 Sources/add-ons/debrid | 26 | 1 | 7 | 0 | 34 |
| 05 Playback runtime | 13 | 13 | 4 | 2 | 30 |
| 06 Player controls | 21 | 5 | 1 | 0 | 27 |
| 07 Subtitles/trickplay/skip | 17 | 10 | 6 | 0 | 33 |
| 08 Audio | 16 | 8 | 2 | 2 | 26 |
| 09 Settings/sync/backup | 31 | 12 | 1 | 0 | 44 |
| 10 Account/library/profiles | 20 | 4 | 7 | 0 | 31 |
| 11 Integrations/media | 31 | 6 | 7 | 0 | 44 |
| 12 Cross-cut/platform | 12 | 9 | 2 | 0 | 23 |
| **Total** | **241** | **93** | **41** | **4** | **375** |

### N/A reconciliation

The four N/A rows are confined to two lanes:

- Playback runtime, lane 05: 2 N/A rows.
- Audio, lane 08: 2 N/A rows.
- Every other lane: 0 N/A rows.

N/A means the row is not a comparable cross-platform requirement under the normalized contract.
It is neither a silent pass nor a permission to omit evidence. If a future implementation changes
the platform contract, the row must be reclassified with a dated decision and evidence rather than
being counted as `PRESENT`.

## What the reverse pass established

The reverse pass found a consistent pattern: Android has real implementations in several areas,
but a number of those implementations are foundation-only, one flavor or surface only, or lack
the persistence, lifecycle, security, cancellation, or device evidence required for `PRESENT`.
That is why the strict result is lower than a source-file existence check would suggest.

The following are representative strict rows. They are references into the existing 134-row
inventory, not additional rows. Each ID remains counted exactly once in the synthesis.

| Existing row | Normalized status | Android evidence | Apple counterpart / reverse interpretation |
|---|---|---|---|
| 04 A13 | ABSENT | `android/app/src/main/kotlin/com/vortx/android/engine/AddonManifestFetcher.kt:27-57` fetches, validates, and bounds a manifest, but does not provide a production JavaScript provider runtime or bridge. | The synthesis records this as the add-on runtime gap at `00-synthesis.md:101-106`. A manifest fetch is not equivalent to executing a provider and returning a playable source. |
| 04 S10 | ABSENT | The synthesis identifies the Android source-index owner surfaces at `00-synthesis.md:101-107`; an Android source-list model alone does not prove a live pooled index path. | The reverse check keeps source-index availability separate from ordinary local add-on results. The result must be measured at provider resolve, URL handoff, and first progress, not at list construction. |
| 05 6 | PARTIAL | `android/app/src/main/kotlin/com/vortx/android/player/PlayerEngineRouter.kt:60-77` has construction-time fallback from the primary engine to the alternate engine. | The synthesis marks runtime native failure demotion as partial at `00-synthesis.md:109-118`; construction fallback is not the same as a bounded, observable, in-playback demotion with state preservation. |
| 06 PC-17 | ABSENT | The synthesis assigns the missing direct previous/next episode control to `android/app/src/main/kotlin/com/vortx/android/player/PlayerChrome.kt` and phone/TV hosts at `00-synthesis.md:126-131`. | Apple’s player contract treats episode progression as a control and host callback, so a previous/next action must work before EOF, at EOF, and across phone and TV focus paths. |
| 07 SUB-10 | ABSENT | `android/app/src/main/kotlin/com/vortx/android/player/subtitles/SubtitlePoolClient.kt:16-25` explicitly describes a foundation client and says a later integration pass must wire it into the player subtitle list and offset slider. | `app/SourcesShared/SubtitlePoolClient.swift:3-18` carries the same pool contract and documents the required integration seam. A network client without player publication is not pooled subtitle parity. |
| 07 SUB-12 | ABSENT | The Android client exposes the pool wire contract, but the synthesis keeps player fetch, seed, and offset synchronization as separate missing integration rows at `00-synthesis.md:132-140`. | The reverse pass therefore does not count the shared endpoint or matching constants as proof that Android can fetch, mount, seed, and publish a pooled subtitle. |
| 09 S-04 | PARTIAL | `android/app/src/main/kotlin/com/vortx/android/backup/SettingsBackup.kt:53-57` states that whole-domain backup and the export/import file UI are deliberately not ported. | `app/SourcesShared/SettingsBackup.swift:3-23` defines the portable app-domain envelope and its restore contract. Android roster-envelope parity is useful, but it does not close whole-domain backup behavior. |
| 09 K-05 | ABSENT | `android/app/src/main/kotlin/com/vortx/android/backup/SettingsBackup.kt:20-30` documents the historical carrier/value mismatch and the need to preserve owner-account semantics. | Apple’s profile model carries an explicit own-account distinction in `app/SourcesShared/Profiles.swift:5-18` and uses it in the account/session path. A matching roster key alone is insufficient. |
| 10 PR-03 | ABSENT | `android/app/src/main/kotlin/com/vortx/android/ui/screens/ProfilesScreen.kt:70-74` says newly created Android profiles are shared profiles and separate per-profile sign-in is not wired. | Apple exposes own-account binding in `app/SourcesShared/Profiles.swift:5-18` and `:276-309`. The reverse result remains absent until Android can switch and isolate the separate account session end to end. |
| 11 I13 | ABSENT | The synthesis assigns external resume/history integration at `00-synthesis.md:182-189`, including the row and its integration/Home owner surfaces. | A local history or player callback is not equivalent to a successful external write, retry, credential boundary, and user-visible receipt. The reverse audit keeps that distinction. |
| 12 C20 | ABSENT | The synthesis assigns crash-marker and diagnostics lifecycle behavior at `00-synthesis.md:197-205`, including the row and its diagnostics/runtime owner surface. | `app/SourcesShared/VortXCrashReporter.swift` is the Apple privacy-safe diagnostics boundary. Android must provide equivalent consent, capture, persistence, and upload/redaction behavior before `PRESENT`. |
| 02 NAV-02 | PARTIAL | The synthesis records that phone detail removes shell/navigation ownership at `00-synthesis.md:76-84`; this is a route/focus lifecycle gap, not a missing screen file. | The reverse check treats shell restoration and deep-link focus as behavior, not static navigation declarations. |

These examples explain the apparent mismatch between “Android has a class with the same name” and
“Android is at full parity.” The audit contract counts a capability only when the public behavior,
state ownership, lifecycle, failure path, and relevant surface are all evidenced.

## Root-cause clusters and closure lanes

The synthesis groups the 134 rows into eight causes. The reverse audit accepts these clusters as
the correct non-overlapping planning units:

| Cluster | Failure shape | Required closure evidence |
|---|---|---|
| R1 State convergence | Account library, add-on roster, credentials, settings dirtiness, deletion, and profile application are not all owned and replay-safe on Android. | Versioned records, owner-qualified secrets, per-key clocks or baselines, tombstones, deterministic apply ordering, and two-device restart tests. |
| R2 Provider/source lifecycle | Manifest or source-list code exists without the complete runtime, identity mapping, bounded resolution, pairing hardening, or first-progress proof. | Isolated provider execution, bounded transport, cancellation, redacted stage trace, malformed-input recovery, and resolve-to-first-progress evidence. |
| R3 Playback resilience | Routing and engines cover some cases but not every failure, memory, pause, seek, stall, format, flavor, and lifecycle path. | Pure policy tests, Full and Play build matrices, physical-device playback samples, retry/demotion budgets, and preserved viewer intent. |
| R4 Episode progression | Previous/next, EOF, pre-EOF warming, up-next, countdown, cancellation, series end, and stale-generation behavior are not one shared transaction. | Phone and TV tests for every boundary, including stale callbacks and cancelled transitions. |
| R5 Media enrichment | Metadata, trailers, subtitles, trickplay, chapters, and skip behavior are present only in slices or one engine. | Sparse metadata, localized selection, fallback retrieval, pool fetch/seed, capture/upload, chapter correction, and player publication tests. |
| R6 Audio route correctness | Route changes, realized sample rate, output fallback, and explicit selection continuity are incomplete. | HDMI/eARC, wired, Bluetooth, cast, route swap, realized-rate, and audio-failure-preserves-video tests. |
| R7 Shell/lifecycle/diagnostics | Foreground recovery, offline behavior, deep links, diagnostics, accessibility, and phone presentation diverge. | Cold/warm links, foreground/background, offline, consent, redaction, screen-reader semantics, and focus restoration tests. |
| R8 Integrations/downloads | External history/rating/check-in, direct/provider/torrent/HLS/season downloads, and reclaim behavior are incomplete. | Provider read/write/retry receipts, source handoff, watched-episode identity, denied-notification behavior, and reclaim tests. |

The eight implementation lanes in the continuation runbook map one-to-one to these clusters:
identity/state, provider runtime, playback, episode progression, detail/subtitles, audio, shell/
lifecycle, and integrations/downloads. A future change must claim the existing row ID and cluster;
it must not open a duplicate “reverse” row for the same behavior.

## Acceptance tests for closing the audit

The reverse report is closed as a report, but parity is not closed in product code. The following
checks are the acceptance contract for a future Android release candidate:

1. Re-run all 12 lane audits from the release candidate and reproduce `379` raw, `4` N/A,
   `375` applicable, `241` present, `93` partial, and `41` absent before implementation work.
2. Require every existing non-PRESENT row to move by ID to `PRESENT` or to a reviewed true N/A.
   The post-closure arithmetic must be `375 PRESENT + 4 N/A = 379`, with zero `PARTIAL` and zero
   `ABSENT`. No new row may be introduced solely because the direction was reversed.
3. Verify unique row IDs and per-lane sums. The total must reconcile both by status and by the
   eight root-cause clusters; a row may belong to one cluster only.
4. Exercise account/state behavior on two physical Android devices: change, clear, delete,
   offline/online, restart, owner switch, cold restore, library, add-ons, credentials, progress,
   tombstones, and profile selection. No deleted item may resurrect and no owner’s credential may
   cross into another account.
5. Exercise provider behavior from manifest install through ranked source, bounded resolution,
   headers/subtitles, cancellation, malformed-pair recovery, redacted stage trace, URL handoff,
   selected engine, and first rendered progress.
6. Exercise Full and Play playback paths on physical devices, including ordinary containers,
   adaptive streams, Dolby Vision/Atmos policy, pause, seek, stall, engine failure, background,
   foreground, low memory, PiP where supported, and source retry. The test must show why a route
   was selected and that an in-playback failure does not strand the viewer.
7. Exercise phone and TV episode progression, subtitle publication, audio route changes, shell
   restoration, deep links, accessibility semantics, diagnostics consent/redaction, integrations,
   downloads, and notification-denied behavior.
8. Run the release checks from the continuation runbook, including both Android flavors, physical
   device evidence, signing receipt, and appcast validation. A build that compiles but lacks those
   receipts is not a release-ready parity result.

## Residual risks and handoff

- Android still has 134 non-PRESENT applicable rows under the strict current inventory: 93
  `PARTIAL` and 41 `ABSENT`.
- Several Android branches and checkpoints remain preservation or review-gated work according to
  the continuation runbook. Their labels are not release evidence.
- Android signing and physical-device release receipts remain separate gates. This report does
  not assert that an Android artifact exists or is publishable.
- The four N/A rows are a controlled reconciliation, not a shortcut. Any future platform contract
  change must re-open the row with evidence.
- Beta 19 remains an Apple-only release decision. Android parity is a next-release objective and
  is not a blocker for the Apple-only Beta 19 cut. Apple playback, tvOS focus/layout, add-on,
  integration/build, release-workflow, and live distribution receipt gates remain outside this
  reverse report.

Decision required: none.

## Verification of this document

- Base checked: `ab168e5e957b7113b73e6e98939ba1893c02875d`.
- The linked synthesis was checked for the exact count table at
  `dept/audits/android-parity-2026-08-20/00-synthesis.md:11-45` and root-cause table at `:55-61`.
- The N/A placement and per-lane sums were checked against the synthesis table at `:31-45`.
- The Beta 19 scope and next-release continuation were checked against
  `dept/ANDROID-NEXT-RELEASE-RUNBOOK.md:1-30` and `dept/HANDOFF.md:299-313`.
- Representative source citations were checked with numbered source output from the base tree,
  including `app/SourcesShared/SubtitlePoolClient.swift:3-18`,
  `app/SourcesShared/SettingsBackup.swift:3-23`,
  `android/app/src/main/kotlin/com/vortx/android/engine/AddonManifestFetcher.kt:27-57`,
  `android/app/src/main/kotlin/com/vortx/android/player/subtitles/SubtitlePoolClient.kt:16-25`,
  `android/app/src/main/kotlin/com/vortx/android/backup/SettingsBackup.kt:20-57`, and
  `android/app/src/main/kotlin/com/vortx/android/ui/screens/ProfilesScreen.kt:70-74`.
- This report is documentation only. No product, test, build, release, or department-status file
  was changed.
