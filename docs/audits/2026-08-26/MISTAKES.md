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

Guardrails:

1. An out-of-memory or long-build failure in an unrelated module remains an environment-capacity observation until a controlled higher-memory rerun completes; never book it as a code verdict.
2. Record pass and fail evidence side by side, here focused tests BUILD SUCCESSFUL against the compile OOM, so later readers cannot mistake capacity noise for a lane rejection.
