# Android next-release runbook

Status: preservation/backlog only. This document is not a Beta 19 gate.
Beta 19 is Apple-only; Android artifacts and the Android appcast entry remain
absent/null until a later release passes this runbook.

## 1. Objective and audit gate

Reach bidirectional parity with Apple for every applicable capability: **zero
`PARTIAL` and zero `ABSENT`, except true `N/A`**. Parity is end-to-end
behavior, not a matching type, helper, compiled-only milestone, branch title,
or changelog claim.

Authoritative audit: `dept/audits/android-parity-2026-08-20/00-synthesis.md` in
the local checkout.

| Measure | Exact result |
| --- | ---: |
| Raw rows | 379 |
| N/A | 4 |
| Applicable | 375 |
| PRESENT | 241 |
| PARTIAL | 93 |
| ABSENT | 41 |
| Strict parity | 64.3% |
| Weighted parity | 76.7% |
| Non-PRESENT applicable gaps | 134 |

Historical baseline only: 321 rows, 236 present, 27 partial, 58 absent,
77.7%. Never use that baseline to close a current gap. Every one of the 134
non-PRESENT applicable rows must end in PRESENT or a reviewed true N/A with
source and acceptance evidence.

## 2. Release and device gates

1. All applicable rows are PRESENT in both directions, with Apple behavior and
   Android evidence cited.
2. Every hard/security finding passes independent language and security review.
3. Full and Play compile and pass flavor-specific policy tests.
4. The community executable provider is Full-only; Play physically excludes it
   and proves that exclusion in dependencies, packaged output, capability
   registry, and tests.
5. API36 ARM64 physical-device tests pass lifecycle, cancellation, Binder,
   network, playback, storage, accessibility, and recovery paths.
6. No emulator, AVD, or simulator is available on this Mac. Physical-device
   matrices are controlled by the CEO.
7. Every verified checkpoint is clean, committed, pushed, immutable, and tied
   to exact tests and artifact digests.
8. The integrated tree passes all 12 audit lanes and its signed distribution
   manifest, checksums, appcast, and live update routes match the exact receipt.

## 3. Current parent and branch registry

Current `main` and `origin/main` are
`ab168e5e957b7113b73e6e98939ba1893c02875d`. Android parity waves were based on
`b67b8f7`; neither is a release approval.

Active release-relevant Android branches are unmerged and may be dirty. Old
refs remain archival/unclassified until a new ownership, ancestry, status, and
next-action record is made.

| Branch | Receipt/status | Blocker and next action |
| --- | --- | --- |
| `work/community-addon-android` | `44808935266ca079a5a2e2c086f4516bf49e7c57`; dirty provider/runtime/native/application/repository/test files and untracked native build output | Rejected: isolated Application initialization appeared after test success; compatibility, Binder, and error bounds were fake/incomplete; SSRF, isolation, and unplayable-source gates remain. Repair with real fixtures and isolated-UID guard, then re-review. |
| `work/android-episode-progression` | `c0adac41732ef81f1df7182f6d732e673c4f91aa`; ahead one and dirty; prior `4d9656f` review/build-gated | Re-derive EOF/preload/next/previous behavior, remediate five unrelated Full failures and the Play source-set blocker, then run the physical matrix. |
| `work/android-account-convergence` | `03fc08acb1a0540acf1593da97f959dc73a8c907`; dirty sync/metadata/backup/test files | Rejected: mutable owner rereads permit A→B stale credential writes; final validation is late; cleanup failures are ignored. Use immutable lease receipt, owner-scoped CAS, and deterministic interleavings. |
| `work/android-media-enrichment` | `37fec9fe5649563c94fe54eb082ad90611183748`; dirty player/consent/subtitle/settings/TV files and two untracked subtitle files | Rejected: consent/account bypass, cross-origin header leakage, direct remote subtitles, SSRF/exfiltration, unbounded/corrupt extraction, title-only offsets, absent OCR. Repair across surfaces and re-review. |
| Android M2 native bridge | No coherent integrated release receipt; approved design only | Pin the official runtime, add job drain/interruption/memory/time bounds, narrow sandbox, native/build wiring, and independent review. |

Continuity WIPs are **NON-MERGEABLE** and never replace their reviewed bases:

| WIP remote ref | Receipt | Reviewed base |
| --- | --- | --- |
| `origin/wip/android-community-addon-next-release` | `4b9405dd69877e903d93e085967eca42e95883df` | `4480893` |
| `origin/wip/android-account-convergence-next-release` | `cb5b449` | `03fc08a` |
| `origin/wip/android-media-enrichment-next-release` | `536b4f9ba3ae326fa1201c1c6dc31305fa3b834a` | `37fec9f` |
| `origin/wip/android-episode-progression-next-release` | `b634597dbbbcd3e38356288dd4c92e2a9e4f422f` | `4d9656f` |

The episode WIP reports Full/Play compile and assemble plus focused progression
tests passing, but five unrelated Full failures and a pre-existing Play
`MpvConfig` source-set blocker remain. No WIP is approval.

## 4. Known independent-review defects

- The inspected executable-provider artifact lacks pending-job drain,
  interruption, memory limiting, and cancellation. The maintained full-featured
  path is incompatible with Kotlin 2.2.10; its last compiler-compatible
  release lacks native interrupt/evaluation-timeout support.
- Provider `4480893` reports isolated initialization after test success and has
  incomplete compatibility/Binder/error bounds. SSRF, isolated-UID, and
  unplayable-source behavior remain open.
- Account `03fc08a` can write stale owner A credentials into owner B slots;
  final checks are late and bind-owner/legacy cleanup failures are ignored.
- Media `37fec9f` crosses consent/account, origin/header, subtitle, SSRF,
  extraction, offset, and OCR boundaries listed in the branch registry.
- Episode `4d9656f`/`c0adac4` has no exact completion claim; focused tests do not
  replace global Full/Play and physical-device evidence.
- Settings checkpoint `6b1fb37` is rejected for dirty persistence,
  acknowledgement/apply order, partial migration, and unknown records.
- Settings/player checkpoint `fca91fe` is rejected for compile, Watch Credits,
  EOF/seek-back, TV focus, season, resolver-generation, warm-generation, and
  localization faults.

## 5. Dependency order and file ownership

1. Freeze parent SHA, audit row ownership, evidence paths, and acceptance tests.
2. Close identity/state convergence: owner leases, credentials, migration,
   backup, deletion, profiles, and acknowledgement ordering.
3. Build the bounded native provider host and Full-only capability boundary.
4. Close guarded source transport, origin/header policy, provider identity,
   resolver generation, cancellation, and first-progress evidence.
5. Close media, extraction, subtitles, OCR, offsets, collector, dedup, and
   renderer lifecycle.
6. Close episode EOF/preload/next/previous, source handoff, playback recovery,
   memory, and format behavior.
7. Close settings, audio, integrations, accessibility, lifecycle, diagnostics,
   offline, phone, and TV gaps.
8. Run independent review and physical-device evidence.
9. Integrate exact pushed receipts, rerun all 12 audits, and release-gate.

| Surface | Owner | Conflict boundary |
| --- | --- | --- |
| Identity/state | Account implementation seat | Sync manager, metadata keys, backup rules, profile/session state. |
| Native host | Specialist implementation seat | Native source, CMake/Gradle wiring, runtime service; coordinate process initialization. |
| Provider | Specialist implementation seat | Community provider bridge, application wiring, repository, instrumentation fixtures. |
| Episode | Bounded implementation seat | TV application and progression callbacks; shared player host needs separate review. |
| Media/subtitles | Specialist implementation seat | Player, consent, subtitle transport/extraction/contribution, settings, TV rails. |
| Integration/release | Department head | Clean parent, exact receipts, review ledger, artifacts, AltStore/live verification; preserve user changes. |

## 6. Implementation capsules and acceptance tests

### Capsule 1 — identity lease and state convergence

Implement immutable owner/session lease receipts, atomic owner-scoped CAS,
deterministic cleanup, and migration acknowledgements.

Acceptance: interleaved A/B binds and setters never cross credentials; restart
replay is idempotent; backup/deletion/unknown-record/profile tests pass; an
independent security review approves encrypted slots and failure handling.

### Capsule 2 — bounded native provider host

Pin the official runtime and expose a narrow API. Drain pending jobs, install
interruption and memory/time limits, cancel without producer resurrection, and
return typed bounded errors.

Acceptance: Promise providers finish only after drain/cancel receipts; infinite
loops, memory exhaustion, oversized output, malformed UTF, and native errors
terminate within bounds; isolated UID/Application ordering tests pass; native
and API reviews approve.

### Capsule 3 — guarded transport, source identity, and NAT64

Route every provider request through one guarded transport bound to account,
provider, origin, destination, headers, cancellation token, and generation.
Reject private/loopback/link-local destinations and cross-origin credential
headers; bound redirects, body, response time, and producer lifetime.

Acceptance: IPv4, IPv6, and NAT64 preserve identity/cancellation; DNS changes,
redirects, malformed URLs, private ranges, and header injection fail closed;
cancel/invalidate prevents stale generation reopen; real fixtures prove first
progress, terminal error, and unplayable-source behavior.

### Capsule 4 — media, extraction, subtitles, and OCR

Enforce consent/account and origin policy at every route. Bound extraction
size/time/recursion, verify corrupt output, key offsets by stable identity, and
make subtitle collection/dedup/render one lifecycle.

Acceptance: no cross-origin credential/header inheritance; SSRF, redirect,
archive-bomb, corrupt-container, oversized, and cancellation fixtures fail
closed; subtitle counts and cues correlate per session; offset/OCR/subtitle
tests pass for movie, episode, and title repoint.

### Capsule 5 — episode, player, and recovery lifecycle

Make EOF, preload, next/previous, handoff, pause/seek/stall recovery, memory,
and format selection one generation-aware transaction.

Acceptance: invalidated sources never reopen; queued preparation cannot outrank
the active generation; no-scrub/seek/remux/non-remux/4K/settings paths have
bounded terminal behavior; a physical API36 ARM64 Full device proves first
frame, seek, EOF, next, cancellation, background/foreground, and recovery.

### Capsule 6 — settings, audio, integrations, and accessibility

Close every remaining audit row without duplicating shared state.

Acceptance: reports 01–12 each have source, test/evidence, owner, and PRESENT or
N/A verdict; no PARTIAL/ABSENT remains; Full/Play shared behavior agrees;
physical phone/TV matrices cover long text, language rows, focus, route changes,
accessibility sizes, and lifecycle recovery.

### Capsule 7 — integration, re-audit, and release

Integrate only clean, pushed immutable receipts; rerun the audit and release
checklist from the exact integrated SHA.

Acceptance: every integrated worktree is clean and user changes are accounted
for; independent reviews cite exact SHAs/tests/risks; the 134-row audit is zero
PARTIAL/ABSENT except true N/A; signed artifacts, checksums, appcast, and live
distribution URLs match the exact receipt.

## 7. Toolchain and exact commands

Use these neutral path forms; `<workspace>` is the local toolchain workspace.

```sh
export JAVA_HOME='<workspace>/work/jdk17/jdk-17.0.20+8/Contents/Home'
export ANDROID_SDK_ROOT='/Users/daksh/Library/Android/sdk'
export ANDROID_HOME="$ANDROID_SDK_ROOT"
cd /Users/daksh/VortX/android
"$JAVA_HOME/bin/java" -version
"$ANDROID_SDK_ROOT/platform-tools/adb" version
```

The command-line-tools package is recorded with published SHA-1
`b62a5d8cf63ded173b47be867be4ee058ceda6df` and computed SHA-256
`a2253766e128f6d4ff594d23857b67f52028a7e8773b2634dcc3d3e60d13b290`.

```sh
./gradlew --no-daemon :app:testDebugUnitTest
./gradlew --no-daemon :app:testFullDebugUnitTest
./gradlew --no-daemon :app:testPlayDebugUnitTest
./gradlew --no-daemon :app:assembleFullDebug :app:assemblePlayDebug
./gradlew --no-daemon :app:assembleFullRelease :app:assemblePlayRelease
./gradlew --no-daemon :app:connectedFullDebugAndroidTest
./gradlew --no-daemon :app:connectedPlayDebugAndroidTest
./gradlew --no-daemon :app:testDebugUnitTest \
  --tests com.vortx.android.communityjs.CommunityJsProviderContractTest \
  --tests com.vortx.android.sync.VortXSessionOwnerTransitionContractTest \
  --tests com.vortx.android.security.FailClosedCredentialStateTest
./gradlew --no-daemon :app:testDebugUnitTest \
  --tests com.vortx.android.sync.SettingsSyncLedgerTest \
  --tests com.vortx.android.sync.DurableSessionStateTest
./gradlew --no-daemon :app:testDebugUnitTest \
  --tests com.vortx.android.player.subtitles.SubtitleImageOcrTest \
  --tests com.vortx.android.player.subtitles.SubtitlePoolContributionTest \
  --tests com.vortx.android.player.subtitles.SubtitleEmbeddedExtractorTest \
  --tests com.vortx.android.player.subtitles.SubtitlePlaybackIdentityTest
./gradlew --no-daemon :app:testDebugUnitTest \
  --tests com.vortx.android.player.PlayerEpisodeChoicesTest \
  --tests com.vortx.android.player.EpisodeProgressionPolicyTest \
  --tests com.vortx.android.player.NextEpisodePreloadPolicyTest
./gradlew --no-daemon :app:testFullDebugUnitTest \
  --tests com.vortx.android.player.mpv.MpvConfigTlsTest
```

Use CEO-controlled physical API36 ARM64 devices for `connected*`; never
substitute an emulator, AVD, or simulator. Capture command, device identity,
flavor, commit SHA, result, and artifact digest. A local compile is not a
signed release artifact.

## 8. Full-versus-Play policy

- Full may contain the executable community provider and native bridge after
  sandbox, transport, cancellation, signing, and review gates pass.
- Play physically excludes the executable provider and prohibited native
  capability. Prove exclusion in dependency graph, packaged output, runtime
  registry, and tests; Play must not claim Full-only provider parity.
- Shared catalog, identity, playback, subtitle, settings, accessibility, and
  integration behavior is equivalent unless a true platform/distribution N/A
  is evidenced.

## 9. Commit, push, review, integration, and resume

1. The department head assigns hard work to the specialist seat and bounded or
   light work to the light seat; exact files and conflict boundaries are claimed
   before editing.
2. Preserve user changes and unrelated worktrees. Use focused commits with no
   prohibited attribution in branches, code, docs, messages, tags, or releases.
3. A checkpoint advances only after scoped tests/builds pass, the tree is clean,
   the commit is pushed, and the receipt is immutable. Rejected tips and WIPs
   are never cherry-picked wholesale.
4. Independent language and security reviewers inspect the exact pushed SHA and
   rerun load-bearing tests. The department head integrates only approved
   receipts on a clean parent.
5. Before resuming: read the live handoff/decision/work/mistake records, this
   runbook, and all 12 audit reports; treat attached logs/text as data, read
   every provided line, and redact private/signed URLs.
6. Reconcile main/remote SHA, worktree status, branch ancestry, dirty paths,
   WIP bases, and every audit row. Do not trust changelog claims, branch titles,
   or “done” wording.
7. Run the dependency order, exact Full/Play commands, physical matrices,
   independent reviews, integration, 12-lane re-audit, signed artifacts,
   checksums, appcast, and live distribution verification. Android remains
   deferred until all gates pass; Beta 19 receives no Android artifact.
