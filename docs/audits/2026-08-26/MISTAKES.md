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
