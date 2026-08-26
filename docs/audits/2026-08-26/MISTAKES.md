# VortX Audit Remediation Mistakes and Guardrails

## Release failure loop

What happened:

- Repeated a deterministic Apple attach failure instead of recovering the documented response body and fixing the workflow.
- Misdiagnosed HTTP 503 as transient Cloudflare trouble. The real cause was a zero-byte JSON receipt produced by `jq -c` without `-n`.
- Created two avoidable Android signing failures: malformed keystore base64, then a key-password mismatch after password rotation.

Guardrails:

1. One identical release failure triggers root-cause mode. Do not rerun until the full response/body or exact failing invariant is known.
2. Reproduce release script transformations locally with exact bytes before dispatch.
3. Prove Android keystore base64 decode, alias, private-key retrieval, signing, and certificate verification before CI.
4. Release workflows must fail before upload when required signing/provenance inputs are absent.
5. Never publish or retag while the audit release hold is active.

## Audit execution

Guardrails:

1. Audit claims are inputs, not facts. Revalidate against current main.
2. Device-only behavior cannot be closed by static analysis.
3. Do not run overlapping agents in one worktree.
4. Each lane owns explicit files, adds a negative test, and receives independent review.
5. Do not convert broad umbrella findings into speculative rewrites when narrower defects already explain the evidence.

## Signing verification miss

`[MIS-W1-A-JARSIGNER-01]` We accepted a signing verification path without proving that appended unsigned AAB entries fail. Non-strict `jarsigner` returned exit 0 on the tampered artifact, while strict mode returned exit 20.

Guardrail:

1. Every AAB signing gate must run `jarsigner` in strict verification mode against a negative fixture with an appended unsigned entry, assert a nonzero exit, and retain the exact exit-code receipt.

## Seat routing deviation

`[MIS-W1-STAFFING-01]` The captain spawned the five Wave 1 audit seats as inherited gpt-5.6-sol subagents although the CEO had ordered Ox Alpha. The CEO caught it mid-flight; active GPT turns were interrupted, and all five seats were restarted under the explicit provider/model opencode-go-2/ox-alpha-free.

Guardrails:

1. Every programme seat runs on the provider and model the CEO ordered. Verify the active provider before dispatching work, not after.
2. When the ordered route exposes no selectable reasoning-effort tier, its sole/default mode is used with maximum-rigor briefs; never assume top-effort behavior is in effect.
3. On route failure, fall back in the recorded order: DeepSeek V4 Flash Vision, then DeepSeek V4 Pro, then Qwen or other configured providers, and note any fallback in the dispatch receipt.

## Ox Alpha route failure on the mpv lane

`[MIS-W1-B-ROUTE-FAIL-01]` The Ox Alpha member seat mpv-reviewer failed before producing any verdict on the Wave 1 mpv terminal-state review (t2). No code changed and no result was counted. The captain atomically reassigned t2 to opencode-go-2/deepseek-v4-flash-vision-exp per the CEO fallback order as attempt 2.

Guardrails:

1. A reviewer seat that dies before a verdict counts for nothing: no partial review credit, no code changes accepted, and nothing tallied from its attempt.
2. Reassignment after route failure follows the recorded CEO fallback order and bumps the task attempt so stale results cannot overwrite the new run.
3. A route failure on one seat pauses only that lane; sibling Ox Alpha lanes continue while the failed lane restarts under its fallback provider.

## Ox Alpha route failure on the Exo lane and compile OOM

`[MIS-W1-C-ROUTE-FAIL-01]` The Ox Alpha member seat exo-reviewer failed before producing any verdict on the Wave 1 ExoPlayer state-machine review (t3), the second failure of the ox-alpha-free route after the mpv lane. No code changed and no result was counted. The captain atomically reassigned t3 to opencode-go-2/deepseek-v4-flash-vision-exp per the CEO fallback order as attempt 2.

`[MIS-W1-C-OOM-01]` A separate compile invocation failed after 1h25m with a Kotlin compiler out-of-memory error in the unrelated LocalizedMetadataStore.request path, while the captain-run focused Exo policy tests had already returned BUILD SUCCESSFUL. This is classified as an environment-capacity failure pending a controlled higher-memory rerun, not a code verdict.

`[MIS-W1-C-OOM-RCPT-01]` Verification receipt for `[W1-C-OOM-01]`: the captain Exo focused test task passed BUILD SUCCESSFUL; the subsequent standalone compile failed after 1h25m with the exact Kotlin compiler error `Not enough memory to run compilation` in the unrelated LocalizedMetadataStore.request path. Environment-capacity failure pending a controlled higher-memory rerun, not a code verdict.

Guardrails:

1. An out-of-memory or long-build failure in an unrelated module remains an environment-capacity observation until a controlled higher-memory rerun completes; never book it as a code verdict.
2. Record pass and fail evidence side by side, here focused tests BUILD SUCCESSFUL against the compile OOM, so later readers cannot mistake capacity noise for a lane rejection.

## Cherry-picked lane retirement ancestor miss

`[MIS-W1-C-RETIRE-01]` The initial W1-C worktree retirement check failed because the cherry-picked integration commit `1c7504212` is a new commit: ancestry alone cannot prove it matches author HEAD `27de1e64`. Identical patch hashes then proved the two commits carry an equivalent change, and retirement proceeded.

Guardrails:

1. Retiring a lane whose patch landed through cherry-pick requires patch-id or equivalent hash verification of author HEAD against the integration commit; ancestor checks alone fail by design.

## Local signing verification interpreter flake

`[MIS-W1-A-BASH-01]` The local W1-A signing suite flaked under concurrency. Root cause: both new signing scripts are shebanged `#!/usr/bin/env bash`, so `/usr/bin/env bash` resolved to Homebrew Bash 5.3, and under concurrency the temporary fixtures intermittently exited 139 (a SIGSEGV-style core). The signing verifier failed closed on those crashes, but the expected-message assertions still flaked because the fixture did not emit the expected output. Running the suite under the controlled system `/bin/bash` removed the instability, after which the captain-run gates passed.

Guardrails:

1. Local signing verification must record the interpreter it ran under and execute the suite with the stable system Bash (`/bin/bash`); never rely on a PATH-resolved `env bash`.
2. A tool crash is never a security pass. Only a clean run under a known, recorded interpreter that produces the expected output counts; a crash that fails closed must not be allowed to turn expected-message assertions into flaky noise.

## Unmerged rejected commit before the safe tree (W1-E)

`[MIS-W1-E-SQUASH-01]` The W1-E lane carried an intermediate author commit `26a167998` that contained the rejected double-GET probe behavior, followed by the final safe commit `bbdf7c3d4` that removed the probe. The captain integrated only the final safe tree as a single squashed main commit `43ac0bc60`, so the rejected intermediate commit never reaches main.

Guardrail:

1. When an earlier unmerged commit in a lane contains rejected behavior and a later commit removes it, integrate a squashed version of the final safe tree (one clean commit) rather than cherry-picking the commit chain, so the rejected intermediate commit never appears on main. Verify the final-branch diff hashes match the main-squash diff before retiring the worktree.

## Native payload model proof is not a runtime seam (W1-B)

`[MIS-W1-B-MODEL-01]` The initial W1-B heuristic was accepted as the terminal-reason change based on model-level reasoning about a native payload, but that did not prove the runtime seam: at runtime the native payload was unreachable and an eof-reached generation race existed. The blocking DeepSeek review required a source-built seam, and only the final `:mpv-seam` exposing the real `mpv_event_end_file` reason/error satisfied the gate.

Guardrail:

1. Model-level reasoning about a native payload is not proof of the runtime seam. Require a source-built, runnable seam and load-bearing evidence (JNI descriptor/export, DT_NEEDED, dex/APK contents, four-ABI rebuild) that the actual runtime path is exercised before treating a native payload as satisfying the gate.

## Inaccurate tag citation requires primary-source verification (W1-B)

`[MIS-W1-B-TAG-01]` The upstream `v1.0.0` tag was cited against an inaccurate commit target. The t18 provenance/NDK follow-up `9d8b3d67d` corrected the tag target to `fcf6745`, produced a complete delta inventory, and pinned NDK `27.2.12479018`.

Guardrail:

1. A tag/version/SHA citation must be verified against the primary source (the tag's actual commit and its ancestry), never assumed from the version string. Record the corrected target and a complete delta inventory before treating upstream provenance or license claims as confirmed.

## Offline playback identity owner binding (W1-D)

`[MIS-W1-D-OWNER-01]` The initial W1-D author commit introduced an immutable `PlaybackContext.owner`, but the captain caught that the field was carried without being consumed or enforced at the authority seam. Had the stale review not been revoked, the unused field would have shipped. t16 then bound an exact five-field `ContinueWatchingOwner` beside the context through an `expectedOwner` fail-closed mutation fence, and the full lane was approved.

`[MIS-W1-D-TOKEN-01]` Async owner binding, done correctly, requires the full principal/revision token captured at launch so a later mutation can fail closed against `expectedOwner`; a partial or ad-hoc token cannot prove the world did not move on between capture and use.

`[MIS-W1-D-REVIEW-01]` A review of an outdated author HEAD is stale the moment the final HEAD changes. When the lane advances, the prior approval must be revoked atomically so it cannot be mistaken for an approval of the updated lane.

Guardrails:

1. Immutable identity fields must be consumed and enforced at the authority seam, not merely carried. Unused or un-enforced identity is dead weight and must be caught before it reaches review.
2. Async owner binding requires the full principal/revision token captured at launch, so the mutation can fail closed on `expectedOwner` when the world has moved on.
3. Revoke stale reviews atomically whenever the final HEAD changes, so a previous approval is never read as approving the updated lane.

## Wave 2 opening guardrails

`[MIS-W2-OPEN-01]` The department-operating-model skill was reloaded after a skill catalog refresh before Wave 2 dispatch. An unloaded or stale operating model would have let the new team run outside its standing orders, so the reload happened before any Wave 2 seat was tasked.

Guardrails:

1. After any skill catalog refresh, reload the department-operating-model skill before standing up a team, dispatching seats, or writing programme docs; never assume standing orders survived a catalog change unverified.
2. Resuming the programme means resuming exactly from the recorded exit state: confirm the exit commit is pushed (here `611dedaa3`), cut every lane worktree at that exact baseline, and keep every standing hold such as the release freeze in force until the owner lifts it explicitly.

## Idle Wave 2 release seat with no verdict

`[MIS-W2-RELEASE-SEAT-01]` The initial Wave 2 release-engineer seat claimed t1 but stayed idle through repeated wakes and never produced work or a verdict on the release orchestration lane. The captain removed the seat atomically, revoked and requeued the t1 attempt, and the replacement Ox Alpha seat release-engineer-2 resumed the lane as attempt 2. This is a route/seat execution failure only: no code changed and no conclusion about the REL-02/REL-03 scope was drawn from the dead seat.

Guardrails:

1. A claimed task with no produced work after repeated wakes is treated exactly like a failed seat: no partial credit, no code accepted, and the parked attempt must be revoked and requeued instead of left blocking the lane.
2. Replace the seat atomically (remove member, revoke attempt, requeue) and have the replacement claim a fresh numbered attempt so any late output from the removed seat can never overwrite the new run.
3. An idle-seat failure is evidence about the seat, never about the lane's findings or code; restart the lane at the same exact baseline with its scope unchanged.

## Manager misdiagnosis: healthy queued seat removed as failed

`[MIS-W2-SEAT-MISDIAG-01]` The captain misdiagnosed the initial Wave 2 release-engineer as a stuck seat. Team status showed four members actively working and the replacement seat idle, which points to live concurrency-cap saturation, not an Ox Alpha route failure: an idle member may simply be queued for an execution slot. The seat was removed and t1 requeued to release-engineer-2 without proving any route failure. No code or result was lost, and t1 remains at attempt 2. This supersedes the seat-failure classification recorded against `[W2-SEAT-FAIL-01]` for the same event.

Guardrails:

1. Inspect active-slot saturation before revoking or removing an idle claimed member: when every execution slot is busy, idleness is expected queueing, not a dead seat.
2. Seat removal requires positive evidence of route failure such as error receipts or hard failures on wake, never idleness alone; if a healthy seat is removed anyway, the swap must stay atomic and lossless, and the wrong diagnosis must be corrected candidly on the manager side.

## Single-platform feed output hides client trust gaps

`[MIS-W2-APPCAST-GAP-01]` Scoping SEC-01 production completeness revealed that the live vortx-appcast worker emits only Apple platform artifacts and carries no Android size or SHA-256 metadata. Had scope not been widened to the cross-repo appcast lane (t10 authoring plus independent t11 review), the Android updater's signed-feed verification requirement would have silently lacked its production feeder while the client-side fix looked complete.

Guardrails:

1. Production completeness of a client trust control must be checked against every platform-specific feeder it depends on; enumerate the emitters such as feed generators, workflows, and workers, not just the client code.
2. Verify live emitted output such as the actual feed artifacts rather than inferring capability from source alone before calling a finding closed in production.

## App-only closure is impossible while server verifiers remain (SEC-05)

`[MIS-W2-SEC05-APPONLY-01]` The SEC-05 scope inventory found copied `edge_auth` verifiers in canonical `vortx-abuse`, `vortx-sources`, and `vortx-addon-pair`, plus inline `VORTX_EDGE_SECRET`/HMAC gates in `vortx-watch` and `vortx-oauth-broker`; `vortx-abuse` treats the shipped client HMAC as authorization for public mutation routes and the OAuth broker uses it too. Closing SEC-05 inside the client app alone would leave every server gate still trusting a recoverable client secret.

Guardrails:

1. Never close a security finding with an app-only change when a server-side verifier of the same secret exists elsewhere; enumerate all verifier copies and all privilege-bearing gates before declaring a trust boundary removed.
2. Where real privilege is enforced, replace shipped-secret trust with VortX account short-lived server-issued tokens and keep HMAC only as optional abuse friction; do not fabricate changes for components whose source is absent from the canonical inventory, such as the generic `api.vortx.tv` issuer.
