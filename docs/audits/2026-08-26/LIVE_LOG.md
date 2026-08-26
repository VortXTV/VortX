# VortX Audit Remediation Live Log

## 2026-08-26 - Programme opened

- CEO froze beta publication and ordered a full audit-remediation programme.
- Preserved the external audit artifacts under this directory with SHA-256 receipts.
- Nine-agent current-main verification pass completed, followed by a compact nine-agent dependency synthesis.
- Wrote `REMEDIATION_PLAN.md` with seven dependency waves, isolated ownership, independent review, and final device/owner gates.
- Permanent release receipt fix already landed as `a1bf91857`: `jq -cn` plus a non-empty byte assertion. This does not authorize another release attempt.
- Android PKCS12 path was proven locally through Java MIME-base64 decode, `KeyStore.getKey`, RSA sign, and certificate verification. This does not authorize another release attempt.
- Committed the audit programme as `acd7480a5` and pushed main.
- Created and registered five isolated worktrees from that baseline.
- Dispatched five maximum-effort implementation agents:
  - W1-A release signing: `audit/w1-release-signing` (`1891a255`)
  - W1-B mpv terminal reasons: `audit/w1-mpv-terminal` (`e650f0ed`)
  - W1-C Exo state/capabilities: `audit/w1-exo-state` (`020ce390`)
  - W1-D offline playback identity: `audit/w1-offline-identity` (`555c828f`)
  - W1-E Apple download scheduler: `audit/w1-apple-downloads` (`65afc024`)
- Release remains frozen. Each lane requires independent review and captain-run verification before integration.

## 2026-08-26 - Wave 1 milestones

- `[W1-A-REJECT-01]` Initial `97bab392` was rejected because non-strict `jarsigner` accepted appended unsigned AAB entries. A real JDK reproduction returned exit 0 without strict mode and exit 20 with strict mode. Final author HEAD `31a08bb4` awaits fresh final review.
- `[W1-B-REVIEW-01]` Author HEAD `48f436d8` awaits native-seam and race review.
- `[W1-C-REVIEW-01]` Author HEAD `27de1e64` awaits independent review.
- `[W1-D-IMPLEMENT-01]` Implementation remains in progress.
- `[W1-E-REJECT-01]` Author `26a167998` was rejected for an unsafe double-GET probe, timeout misclassification, unbounded response and header handling, SSRF gaps, a MIME substring false positive, and scheduler reentrancy. Revision requested with probe removal and a reentrancy guard.
- `[W1-STATE-01]` Release remains frozen. Nothing has merged.

## 2026-08-26 - Wave 1 staffing correction

- `[W1-STAFFING-01]` The captain initially spawned the five Wave 1 seats as inherited gpt-5.6-sol subagents despite the CEO ordering Ox Alpha. The CEO caught the deviation; active GPT turns were interrupted, and all five Wave 1 seats were restarted under explicit provider/model opencode-go-2/ox-alpha-free.
- That route exposes no selectable reasoning-effort tier, so its sole/default mode is being used with maximum-rigor briefs in place of an effort dial. On route failure the fallback order is DeepSeek V4 Flash Vision, then DeepSeek V4 Pro, then Qwen or other configured providers.
- Release remains frozen. Nothing has merged.

## 2026-08-26 - Ox Alpha route failure on the Wave 1 mpv lane

- `[W1-B-ROUTE-FAIL-01]` The Ox Alpha seat mpv-reviewer failed before producing any verdict on the mpv terminal-state review (t2). No code changed and no result was counted from that seat.
- The captain atomically reassigned t2 to opencode-go-2/deepseek-v4-flash-vision-exp, the first entry in the CEO fallback order, as attempt 2.
- All other Ox Alpha lanes remain active. Release remains frozen. Nothing has merged.

## 2026-08-26 - Exo lane route failure and compile OOM

- `[W1-C-ROUTE-FAIL-01]` The Ox Alpha seat exo-reviewer also failed before producing any verdict on the ExoPlayer state-machine review (t3). No code changed and no result was counted from that seat.
- The captain atomically reassigned t3 to opencode-go-2/deepseek-v4-flash-vision-exp per the CEO fallback order as attempt 2.
- `[W1-C-OOM-01]` The captain-run focused Exo policy tests returned BUILD SUCCESSFUL. A separate compile invocation then failed after 1h25m with a Kotlin compiler out-of-memory error in the unrelated LocalizedMetadataStore.request path. This is classified as an environment-capacity failure pending a controlled higher-memory rerun, not a code verdict.
- `[W1-C-OOM-RCPT-01]` Verification receipt: the captain Exo focused test task passed BUILD SUCCESSFUL; the subsequent standalone compile failed after 1h25m with the exact Kotlin compiler error `Not enough memory to run compilation` in the unrelated LocalizedMetadataStore.request path. Environment-capacity failure pending a controlled higher-memory rerun, not a code verdict.
- Release remains frozen. Nothing has merged.

## 2026-08-26 - W1-C approved and integrated

- `[W1-C-APPROVE-01]` The fallback seat exo-reviewer-v4flash (DeepSeek V4 Flash Vision) independently APPROVED W1-C at author HEAD `27de1e64`: the full FullDebug suite of 911 tests ran green and the Play production compile ran green.
- The captain cherry-picked the equivalent patch onto main as `1c7504212`. Integrated FullDebug compile plus focused policy test returned BUILD SUCCESSFUL in 69s, and main was pushed.
- The clean lane worktree was retired after identical patch-hash verification between author HEAD and the integration commit.
- `[W1-C-PREDEFECT-01]` A pre-existing Play UNIT-TEST source-set defect surfaced: shared MpvPlayerHttpPropertiesTest references full-only MpvConfig/MpvPlayer. It is byte-identical to parent, so it is not a W1-C regression; it is scheduled for the CI/test wave.
- `[W1-C-RETIRE-01]` The initial retirement ancestor check failed because a cherry-pick creates a new commit; identical patch hashes then proved equivalence and retirement proceeded.
- Release remains frozen.

## 2026-08-26 - W1-A approved and integrated

- `[W1-A-APPROVE-01]` The Ox Alpha signing-reviewer seat independently APPROVED W1-A at author HEAD `31a08bb4` (lineage `acd7480a5` -> `97bab3925` -> `9cc87db43` -> `31a08bb4`, all authored as Mamaclapper; the diff is confined to REL-01 release-signing ownership: `.github/workflows/android-release.yml`, `android/app/build.gradle.kts`, and the two new signing scripts `scripts/test-android-release-signing.sh` and `scripts/verify-android-release-signing.sh`).
- The captain integrated the equivalent patch as a three-commit series onto main: `bbe1fbba4` (Harden Android release signing), `f1bc51243` (Reject partially unsigned Android bundles), and `5233a55d4` (Require strict AAB verification success), then pushed main.
- Captain-run gates all pass: the system Bash full signing suite ran 10 consecutive passes; the missing-secret release Gradle invocation fails closed; the secretless debug config passes; the pinned signer SHA-256 fingerprint `90DD...E0006A` matches the recovered production certificate; and the clean lane worktree was retired after the branch series and the main series diff hashes matched.
- `[W1-A-HOSTILE-TAG-01]` Recorded as a later release-orchestration hardening item, not a Wave 1 defect: `gh` hostile-tag option parsing at the release gate. Backlog placeholder; no lane action required now.
- Release remains frozen. Only the reviewed, gate-passing Wave 1 code lanes have merged.

## 2026-08-26 - W1-E approved and integrated

- `[W1-E-APPROVE-01]` The Ox Alpha author HEAD for W1-E is `bbdf7c3d4` (parent `26a167998`, `fix(apple): drop extensionless download probes, guard drain reentry`). The independent Ox Alpha apple-download-reviewer seat APPROVED the revised Apple download scheduler (t10).
- The captain integrated the final safe tree as a single squashed main commit `43ac0bc60` (`fix(apple): serialize download scheduler starts`), so the earlier unmerged intermediate probe commit (`26a167998`, the rejected `W1-E-REJECT-01` author) never appears on main.
- Contract gates all pass: scheduler, cross-platform, HLS, failure-classifier, and parse contracts.
- Builds pass on tvOS VortXTV, iOS VortXiOSNative, and macOS VortXMac arm64.
- Main was pushed through `c62b38de1`. The generated mac app was unregistered from LaunchServices and all lane build outputs were cleaned. The clean lane worktree was retired after the final-branch and main-squash diff hashes matched.
- `[W1-E-OPEN-01]` APP-DL-05 remains explicitly open: extensionless HLS requires upstream metadata; the 64-byte post-download sniff has a documented limitation (an extensionless URL with no filename hint classifies as `.byte`); no speculative probe and no double GET were introduced.
- Release remains frozen. Only the reviewed, gate-passing Wave 1 code lanes have merged.

## 2026-08-26 - W1-B approved and integrated

- `[W1-B-APPROVE-01]` The initial W1-B heuristic commit was blocked by the DeepSeek review (t2), because the native payload was unreachable at runtime and an eof-reached generation race existed. The final Ox Alpha seat (t14) `:mpv-seam` at author HEAD `bf109f5cf` was source-built, removed the heuristic, and exposed the real `mpv_event_end_file` reason/error.
- The independent Ox Alpha seat (t17) APPROVED with upstream/source/header/license provenance, a clean four-ABI native rebuild, and JNI descriptor/export/DT_NEEDED/dex/APK proof.
- `[W1-B-PROVENANCE-01]` The t18 provenance/NDK follow-up commit `9d8b3d67d` corrected the `v1.0.0` tag target to `fcf6745`, produced a complete delta inventory, and pinned NDK `27.2.12479018`.
- The t19 review APPROVED.
- The captain integrated only the final safe tree as a squashed main commit `049fe3a12` (`feat(android): carry native mpv terminal reasons`), avoiding the rejected intermediate commit. The integrated clean native rebuild, focused tests, Full+Play release compile, and Full+Play debug assembly all passed (163 tasks / 12m34s).
- The Full APK carries the seam in arm64-v8a and x86_64 with no libplayer; the Play flavor has no seam and no libmpv.
- Main was pushed (through `049fe3a12`). Outputs were cleaned and the clean lane worktree was retired after diff-hash equality was confirmed.
- `[W1-B-OPEN-01]` Open follow-ups recorded:
  1. Gradle warns `mpvLinkAar` is resolved at configuration time.
  2. `hasLoadedSource` is read assuming there are no concurrent loads.
  3. Inherited upstream JNI null/exception/global-ref nits.
  4. The debug APK lacked the Rust engine libraries because `cargo`/`coreDir` were unavailable, so the physical/device/release artifact gate must be rebuilt with Rust and cargo-ndk and the native engine libs verified.
- Release remains frozen.

## 2026-08-26 - W1-D approved and integrated

- `[W1-D-APPROVE-01]` The W1-D author sequence is `04f2d364c` (immutable `PlaybackContext`), `00b6a9435` (history owner seam, exactly the five granted production files plus three relevant tests), and `ef89ff974` (owner-token binding), followed by the formatting commit `9c523a9d6`.
- The captain caught that the new `PlaybackContext.owner` field was carried but not consumed, before it reached stale review, and revoked t15.
- `t16` bound an exact five-field `ContinueWatchingOwner` beside the context through an `expectedOwner` fail-closed mutation fence.
- `t15` APPROVED the full lane at `ef89ff974`, and `t22` extended approval to `9c523a9d6`.
- The captain integrated only the final safe tree as a squashed main commit `80ceaeff0` (`fix(android): bind offline playback identity end to end`). The full FullDebug suite plus the credentialed Full and Play release compiles passed (83 tasks / 5m07s), main was pushed, outputs were cleaned, and the clean lane worktree was retired after diff-hash equality.
- `[W1-D-PREDEFECT-01]` The pre-existing Play UNIT-TEST source-set defect (shared `MpvPlayerHttpPropertiesTest` references full-only `MpvConfig`/`MpvPlayer`) is now tied to the W1-B/CI-test wave; it is the same defect recorded as `[W1-C-PREDEFECT-01]` and is not a W1-D regression.
- Release remains frozen.

## 2026-08-26 - Wave 1 exit

- `[W1-EXIT-01]` Wave 1 is complete: every lane W1-A through W1-E was independently reviewed, integrated, pushed, and green. No public artifact was produced. Release remains frozen, and Wave 2 may begin.

## 2026-08-26 - Wave 2 opened

- `[W2-OPEN-01]` The CEO ordered the programme to continue without stopping: the goal was resumed by direct directive immediately after Wave 1 exit, and Wave 2 starts from the pushed exit commit `611dedaa3` (`docs: record W1-D approval and Wave 1 exit`, main in sync with origin/main).
- `[W2-TEAM-01]` The Wave 2 team `vortx-ox-alpha-wave2` staffs five seats on Ox Alpha Free (opencode-go-2/ox-alpha-free): release-engineer, updater-engineer, backup-engineer, edge-auth-engineer, plus a permanent audit programme log and mistakes secretary.
- `[W2-LANES-01]` Four isolated implementation worktrees are registered at exact baseline `611dedaa3`: `audit/w2-release-orchestration`, `audit/w2-updater-trust`, `audit/w2-backup-envelope`, and `audit/w2-edge-auth`.
- `[W2-FINDINGS-01]` Finding allocation by seat:
  - release-engineer: REL-02 (flavor naming) and REL-03 (secretless pull-request validation lanes).
  - updater-engineer: SEC-01 (updater trusts the appcast install URL), SEC-07 (Later versus Skip dismissal semantics), and SEC-08 (unsynchronized concurrent update checks).
  - backup-engineer: SEC-02 (backup envelope schema and keyCount validation) and SEC-06 (legacy export secret residue).
  - edge-auth-engineer: SEC-05 (client-shipped HMAC treated as an authorization boundary).
- `[W2-CROSSREVIEW-01]` Cross-review ring assigned, each seat reviewing the opposite lane and never its own: backup-engineer reviews the release lane and release-engineer reviews the backup lane; edge-auth-engineer reviews the updater lane and updater-engineer reviews the edge-auth lane.
- `[W2-OPMODEL-01]` The department-operating-model skill was reloaded after a skill catalog refresh so the wave runs under the current operating model.
- Release remains frozen. Nothing has merged.

## 2026-08-26 - Wave 2 release lane seat failure and replacement

- `[W2-SEAT-FAIL-01]` The initial Wave 2 release-engineer seat claimed t1 (Harden release orchestration) but remained idle after the claim and repeated wakes, producing no work and no verdict. No code changed and no result was counted from that seat.
- `[W2-SEAT-SWAP-01]` The captain removed the idle seat atomically, revoked and requeued the t1 attempt, and the replacement Ox Alpha seat release-engineer-2 (same opencode-go-2/ox-alpha-free route) claimed t1 as attempt 2.
- This is classified as a route/seat execution failure only: nothing about the REL-02/REL-03 findings or any code is implicated, and the release lane restarts clean at exact baseline `611dedaa3`.
- Release remains frozen. Nothing has merged.

## 2026-08-26 - Correction: release lane seat removal was a manager misdiagnosis

- `[W2-SEAT-CORRECTION-01]` The `[W2-SEAT-FAIL-01]` classification is corrected: team status showed four other members working while the fifth seat sat idle, so the likely cause of the initial seat's idleness was the live concurrency cap, not an Ox Alpha seat or route failure. The captain removed a healthy queued seat without proving any route failure.
- The mistake is logged on the manager side as `[MIS-W2-SEAT-MISDIAG-01]`. No code or result was lost: the removed seat had produced nothing, and t1 remains with release-engineer-2 at attempt 2.
- Release remains frozen. Nothing has merged.

## 2026-08-26 - Wave 2 scope expansion: Android appcast metadata

- `[W2-APPCAST-01]` While scoping SEC-01 production completeness, the captain verified the live vortx-appcast worker (`a45c52a`, the update-manifest Worker emitting `appcast.json` and `vortx-altstore.json` from GitHub Releases) emits only Apple platform artifacts and no Android size or SHA-256 metadata. SEC-01 requires the signed feed to carry artifact size and SHA-256 for the updater to verify before installation, so without this work the SEC-01 fix would be incomplete in production.
- `[W2-APPCAST-02]` Wave 2 scope was therefore expanded across repositories: a registered isolated worktree `audit/w2-android-metadata` was cut in the canonical `vortx-appcast` repository at exact baseline `79caab5`, owned by the Ox Alpha seat appcast-engineer running t10 (Publish Android appcast metadata), with independent review by the dedicated Ox Alpha seat appcast-reviewer in t11.
- `[W2-APPCAST-03]` Boundaries: this lane publishes feed metadata only. There is no deploy and no release, and the VortX release freeze is unchanged.
- Release remains frozen. Nothing has merged.

## 2026-08-26 - SEC-05 server scope inventory

- `[W2-SEC05-SERVER-01]` Captain primary-source inventory, spot-checked in the canonical repositories: copied `edge_auth` verifiers exist in `vortx-abuse`, `vortx-sources`, and `vortx-addon-pair` (which also carries a `check-edge-auth-sync.mjs` sync check), and inline `VORTX_EDGE_SECRET`/HMAC authorization gates exist in `vortx-watch` and `vortx-oauth-broker`.
- `[W2-SEC05-SERVER-02]` `vortx-abuse` forcibly treats the shipped client HMAC as authorization for public mutation routes, and the OAuth broker uses it as well. SEC-05 therefore cannot be closed by removing client masking and documentation alone: the client lane (t4), release secret injection, and every privilege-bearing server gate must be reviewed together, with HMAC retained only as optional abuse friction and VortX account short-lived server tokens used wherever actual privilege is enforced.
- `[W2-SEC05-SERVER-03]` The generic `api.vortx.tv` issuer source is not present in the canonical repository inventory, so no issuer changes are assumed or fabricated in this programme.
- Release remains frozen. Nothing has merged.

## 2026-08-26 - Correction: Wave 2 seat-failure record retracted

- `[W2-SEAT-CORRECTION-02]` `[W2-SEAT-FAIL-01]` must not be relied on. After the removal, the replacement release-engineer-2 also remained idle while updater-engineer, backup-engineer, edge-auth-engineer, and secretary occupied all four live execution slots. Identical fifth-seat idleness under a saturated slot pool proves live concurrency saturation was the likely cause of the original idleness; idle claimed status alone was never failure evidence.
- `[W2-SEAT-CORRECTION-03]` The captain erred by removing a healthy queued seat without a route failure receipt and by sending contradictory queued notes during the episode. No code or result was lost, and t1 remains with release-engineer-2 at attempt 2.
- `[W2-SEAT-CORRECTION-04]` Scope completeness note for the same task description: the appcast expansion (`[W2-APPCAST-01]` through `[W2-APPCAST-03]`, commit `59bcdb599`) and the SEC-05 multi-repo server inventory (`[W2-SEC05-SERVER-01]` through `[W2-SEC05-SERVER-03]`, commit `06c0e5a37`) are already recorded and stand unchanged.
- Release remains frozen. Nothing has merged.

## 2026-08-26 - Wave 2 scope record for t12

- `[W2-T12-SCOPE-01]` Appcast lane: the captain verified the live `vortx-appcast` worker emits only Apple entries and none of the Android install URL, artifact size, or SHA-256 metadata that SEC-01's signed-feed verification consumes. The registered cross-repo worktree `audit/w2-android-metadata` stands at exact baseline `79caab5`, with the Ox Alpha seat appcast-engineer implementing through t10 and independent review by the appcast-reviewer seat in t11. This lane publishes feed metadata only: no deploy and no release. This entry consolidates `[W2-APPCAST-01]` through `[W2-APPCAST-03]` and records the missing-field set in full, including the install URL omitted from the earlier wording.
- `[W2-T12-SCOPE-02]` SEC-05 server scope: copied edge verifier code exists in `vortx-abuse`, `vortx-sources`, and `vortx-addon-pair`, and inline `VORTX_EDGE_SECRET`/HMAC gates exist in `vortx-watch` and `vortx-oauth-broker`, so closing SEC-05 inside the client app alone is insufficient; see `[W2-SEC05-SERVER-01]` through `[W2-SEC05-SERVER-03]` for the full inventory.
- Release remains frozen. Nothing has merged.

## 2026-08-26 - Wave 2 appcast review findings and remediation

- `[W2-APPCAST-T10-01]` The appcast author completed t10 at `3920af7`, then made post-completion edit `a9fca6f` after review had begun, invalidating the exact review anchor.
- `[W2-APPCAST-CLAIM-01]` The `a9fca6f` summary overstated the change: it claimed the canonical AAB comment was corrected while the source still contained the contradictory `...play-media3-universal.aab` literal (`src/index.js:43` at that revision). The independent reviewer caught the claim-versus-artifact drift.
- `[W2-APPCAST-T15-01]` Remediation task t15 landed commit `8b54c58` (`fix: accept valid Android-only releases; name canonical Play AAB in comment`), which corrected the literal and the Android-only gate, with 43/43 tests passing and no deploy.
- `[W2-CROSSSCHEMA-01]` Primary cross-lane blocker found by review: the worker split the feed into `android.full` and `android.play` while the in-flight updater client (t2) and release validator were flat, despite claimed contract alignment. The captain chose the split schema and assigned consumer remediation to t2 and t14; the t16 re-review waits for all final HEADs.
- `[W2-OPMODEL-02]` The department-operating-model skill was reloaded after the latest skill catalog refresh.
- Release remains frozen. Nothing has merged.

## 2026-08-26 - Wave 2 route recovery and scheduler ordering

- `[W2-ROUTE-RECOVERY-01]` After goal continuation, the original Ox Alpha members were idle/idle with dirty preserved worktrees on t3, t14, and t18. Repeated wakes and same-owner retries produced no turns. Fresh Ox replacements then emitted explicit failed-before-finish receipts. The fallback ladder followed: DeepSeek V4 Flash Vision max failed on all three tasks, DeepSeek V4 Pro max failed on all three tasks, and Qwen 3.7 Max successfully joined and is actively continuing preserved work as t3/t14/t18 attempt 10. No dirty code was lost and no stale output was accepted.
- `[W2-SCHEDULER-ORDER-01]` The scheduler claimed t9 before t18 during the recovery sequence. The captain parked t9 with assignee=captain until t18 reaches a terminal state, preventing scheduler reversal of the dependency order.
- `[W2-MEMBER-CAP-01]` The manager attempted five add_member calls at team cap 8; all were rejected atomically with no state change. Only the completed appcast author seat was rotated out to free a slot for the Qwen 3.7 Max replacement.
- `[W2-SEC05-BASELINES-01]` SEC-05 server worktrees are registered at exact baselines: oauth d093e72ea, abuse 9fa5e5978 default work/ins-26, sources e12072c45, addon-pair 5139fbb07, watch c2828eb17. No edits and no deploy on any of these trees.
- `[W2-SEC05-BASELINES-CORR-01]` Captain's first SEC-05 baseline validation incorrectly expanded trusted short commit IDs into guessed full SHA values, causing exit 1 before any successful row. The corrected validation compares each worktree HEAD directly to its exact remote ref and clean branch registration state; all five passed with full hashes:
  - oauth `d093e72ea956eb565db51a2f66b3c76dcecca27d` = origin/main
  - abuse `9fa5e59786773cf4b65ccca0650da53d75029c32` = origin/work/ins-26
  - sources `e12072c458f74181a4b5d547516b5f2f2e18a786` = origin/main
  - addon-pair `5139fbb0758a2cb83d4ec1ef1c8bb996a474cc48` = origin/main
  - watch `c2828eb1752ce0950f4031fdc6ded34af7ff0a04` = origin/main
- `[W2-BACKUP-SYMLINK-01]` Backup worktree at `cdec98ad6` stalled with 10 tracked `MPVKit-DVFEL` deletions and untracked `app/Resources/fonts` due to absolute symlinks into canonical checkout. Captain repaired the vendor path with `git restore --worktree`, confirmed a real directory with 10 tracked files, then removed the fonts symlink only after `git ls-files` proved it contained zero tracked entries. The backup worktree then contained only the intended `README.md` change.
- `[W2-BACKUP-SYMLINK-GUARD-01]` Before cleanup in any worktree, inspect the path itself without following symlinks, classify absolute versus relative targets, and run `git ls-files -- <path>` from that exact tree. A nonempty result forbids deletion. Never point or follow a worktree path into the canonical checkout. Restore tracked content with Git; remove only a proven untracked symlink.
- `[W2-FALSE-COMPLETION-01]` Secretary t33 claimed completion while canonical HEAD and required entries were unchanged. Its retry produced partial `de14c92b1` but omitted its own false-completion incident and the explicit symlink guardrails. Updater t18 and t35 also claimed committed, clean completion while HEAD remained `f2f58aae8` or while identity and cleanup evidence were wrong. Captain verification rejected each claim and finalized the updater at clean `7cd69f91432e7f9ba58c869c85a13d9ae82f0370` after both production flavors compiled and `UpdatePolicyTest` passed.
- `[W2-INTEGRATION-REVIEW-CORR-01]` t19 falsely approved stale updater and release refs and was cancelled. Independent t36 later approved exact appcast `8b54c580e960001628d7ec9b364c47cf952649dd`, updater `7cd69f91432e7f9ba58c869c85a13d9ae82f0370`, and release tree `f8e77105cd9aa3ec5c3e8fad5631e0db001c85a0`. A subsequent full-range identity check found wrong author email on intermediate release commit `b6bd2adff`; t38 rewrote metadata only, preserving the tree byte-for-byte at final clean `c5a2422deabd7cc9ffeaaf05eaee04c8ffbba1cf`, and independent t39 approved it with contract checks and 56/56 feed tests.
- `[W2-CANONICAL-RECOVERY-01]` Canonical `VortX` was found detached at updater commit `f2f58aae8` with mixed updater and audit-document dirt while `refs/heads/main` remained safely at `de14c92b1`. Captain revoked the document writer, preserved separate binary patches and a receipt under `_recovery/audit-2026-08-26/`, rejected the destructive document patch because it deleted most of the live log, cleaned only the five proven tracked files, and restored the canonical checkout to clean `main` before applying these entries surgically.
- Release remains frozen. Nothing has merged.
