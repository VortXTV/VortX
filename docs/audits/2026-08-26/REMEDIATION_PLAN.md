# VortX 2026-08-26 Audit Remediation Programme

## Status

**Release hold is active.** Do not create, move, publish, or distribute another beta until the final gate in this plan passes against one candidate commit and one immutable artifact set.

Audit baseline: `57943623ee662463158385b7c3598937f269a1e1`  
Planning baseline: `a1bf91857`  
Audit register: 61 findings (1 Critical, 13 High, 34 Medium, 12 Low, 1 informational)  
Parity register: 38 Apple-Android comparisons

Source artifacts:

- `VortX_Code_Audit_2026-08-26.md`
- `VortX_Audit_Findings_2026-08-26.json`
- `VortX_Apple_Android_Parity_2026-08-26.csv`

## Verification result and corrections

Nine maximum-effort agents revalidated the findings against current main before this programme was written. The audit is a strong input, not an automatic implementation order. Current-main verification found several findings that need narrower wording, physical-device proof, or removal as umbrella work. Every implementation lane must cite current file and line evidence again before editing.

Known corrections and cautions:

- Android raw torrent-to-download conversion is wired through the in-process VortxServer in the full flavor. Stale comments made it look absent. Keep a device integration gate and remove the stale comments rather than rebuilding an existing path.
- ExoPlayer already exposes and gates several route capabilities. Do not implement the broad AND-PLY-07 claim as one feature. Fix the remaining concrete gaps only.
- Recognized-extension signed subtitle URLs work. The concrete gap is extensionless or metadata-only subtitle format detection.
- Android mpv frame capture and some redirect behavior require real-device proof. Static analysis or emulator-only evidence cannot close them.
- No finding is complete merely because code exists. Each lane requires an executable negative test and an independent review.

## Operating rules

1. Each simultaneous lane receives an isolated worktree under `/Users/daksh/VortXTV/.worktrees/VortX/` and a non-overlapping ownership list.
2. Agents may read outside ownership but may edit only owned files.
3. Each lane writes tests first or at minimum adds a failing regression fixture before the fix.
4. Each lane commits only explicit owned paths. Never use `git add -A`.
5. The captain independently reviews every diff and verification receipt before integrating it into main.
6. Shared workflows, manifests, project files, schemas, and integration files are serialized.
7. No skipped, quarantined, tolerated, or synthesized-success check counts as verification.
8. Device-only findings remain open until the exact candidate artifact passes on the required hardware.
9. After each wave, run the cross-platform integration gate before starting dependent work.
10. Beta remains frozen until all release-hold items and final owner/device gates pass.

## Wave 1: stop-ship correctness foundations

Five conflict-free lanes run in parallel.

### W1-A Android release signing

Findings: REL-01  
Ownership: `.github/workflows/android-release.yml`, `android/app/build.gradle.kts`, signing verification tests/scripts.

Work:

- Remove every production debug-signing fallback.
- Fail before build or upload when any production signing input is absent.
- Pin and verify the production certificate SHA-256 fingerprint.
- Reject Android Debug subjects and fingerprints explicitly.
- Emit checksum and signer provenance for each APK/AAB.

Gate:

- Four negative secret-absence cases fail before upload.
- `apksigner verify --print-certs` matches the pinned production signer.
- No debug-signed artifact can enter the release job.

### W1-B Android mpv terminal classification

Findings: AND-PLY-01  
Ownership: full-flavor mpv wrapper, `MpvPlayer.kt`, narrowly required host bridge, mpv tests.

Work:

- Carry `mpv_event_end_file.reason` and native error through the JNI/upstream seam.
- Model EOF, ERROR, STOP, QUIT, REDIRECT, and UNKNOWN explicitly.
- Only genuine EOF may set `hasEnded=true`.
- Error, manual stop, teardown, and source replacement must never mark watched or auto-advance.

Gate:

- Natural EOF ends exactly once.
- Midstream disconnect and decode failure remain errors.
- Manual close and source replacement never mark watched.
- Duplicate terminal callbacks are idempotent.

### W1-C Exo terminal and capability contract

Findings: AND-PLY-02, AND-PLY-03, AND-PLY-04, AND-PLY-05, narrowed AND-PLY-06 and AND-PLY-07  
Ownership: `ExoPlayerEngine.kt`, `PlayerEngine.kt`, `PlayerChrome.kt`, Exo player tests.

Work:

- Reset all per-item terminal state at load start.
- Enforce mutual exclusion of ended and error states.
- Make mute transitions idempotent.
- Centralize resume admission.
- Support declared subtitle formats and safe extensionless detection.
- Keep unsupported controls honestly capability-gated.

Gate:

- Error then healthy load is clean.
- Error and ended can never both be true.
- Repeated mute/unmute restores original volume.
- Resume threshold is route-independent.
- Extensionless subtitle fixtures work or fail with an explicit reason.

### W1-D Android offline playback identity

Findings: AND-DL-01  
Ownership: download playback models, phone and TV downloads screens, playback session lifecycle, engine session binding.

Work:

- Introduce immutable playback context for every local session.
- Bind profile, content id, video id, type, season/episode, title, poster, resume identity, and source provenance.
- Remove reliance on resident engine metadata for local history/scrobble ownership.

Gate:

- Stream A, then play downloaded B: only B progress and watched state change.
- Repeat for phone, TV, owner profile, overlay profile, movie, and episode.

### W1-E Apple download scheduler safety

Findings: APP-DL-01 through APP-DL-05  
Ownership: `app/SourcesShared/DownloadManager.swift` and scheduler tests.

Work:

- Make one scheduler the only task starter.
- Return explicit started, rejected, or deferred disposition.
- Continue draining after rejected preflight.
- Requeue self-heal work rather than starting it directly after slot release.
- Include HLS in an honest aggregate or weighted cap.
- Return post-mutation records and classify extensionless HLS safely.

Gate:

- Rejected queue head cannot stall later work.
- Self-heal never exceeds configured concurrency.
- HLS plus byte work respects the declared limit.
- Paused duplicate returns current state.
- Extensionless HLS fixtures classify correctly.

Wave 1 exit: all five lanes independently reviewed, integrated, and green. No public artifact is produced.

## Wave 2: release chain and client security

Dependencies: Wave 1 complete.

Lanes:

1. Mobile release orchestration: REL-02, REL-03, SEC-05. Correct flavor naming, add secretless PR packaging, and remove client-shipped HMAC as a privileged boundary.
2. Android updater trust: SEC-01 and SEC-07. Enforce HTTPS/host policy, immutable URL/size/SHA-256/signer metadata, and correct Later versus Skip semantics.
3. Backup envelope validation: SEC-02 and SEC-06. Enforce schema/keyCount, transactional import, secret scrubbing, and legacy-export guidance.

Exit: secretless packaging passes, updater negative fixtures pass, backup import is all-or-nothing, and every lane has independent approval.

## Wave 3: durability and mandatory CI

Dependencies: Wave 2 complete.

Lanes:

1. Cross-platform download durability and Android transfer safety: STORE-01, STORE-02, SEC-04, AND-DL-02, AND-DL-03, AND-DL-08 through AND-DL-10.
2. Security scanning: CI-02 and CI-03. CodeQL and Semgrep must fail closed and produce real Swift/java-kotlin analysis.
3. Android CI: CI-04. Both flavors run lint, JVM tests, instrumentation, build, and native-library checks.
4. Apple test gate: CI-05 and TEST-01. Add real Xcode test targets/schemes and execute the complete tracked test inventory.

Durability contract:

- Serialize store ownership.
- Validate and write `index.next`.
- Preserve last-good `index.prev`.
- Atomically replace current.
- Do not acknowledge completion before durable commit.
- Recover current, then previous, then directory scan.
- Surface degradation instead of silently returning an empty library.

Exit: fault injection and recovery pass on both platforms; CI gates demonstrably turn red on intentional failures.

## Wave 4: download capability and platform security

Dependencies: Wave 3 complete.

Lanes:

1. Android offline HLS, season/batch coordination, and auto-delete watched: AND-DL-04 through AND-DL-06.
2. Android cleartext policy: SEC-03. Default deny public HTTP while preserving explicit, consented local/private endpoints.
3. Android live-store backup parity: PAR-07.
4. Apple trailer V2 resilience and rollback: APP-HW-01.

Exit: HLS works offline through restart, batch work is bounded/cancellable, auto-delete is profile-safe, transport policy passes negative tests, and backup golden files interoperate.

## Wave 5: parity and controlled migrations

Dependencies: Wave 4 complete.

Lanes:

1. Transactional per-profile Stremio account binding: PAR-01.
2. Android detail/discover/trailer/similar-title parity: PAR-02 through PAR-04.
3. Startup health and Source Index isolation: AND-APP-01 and PAR-05. Keep Source Index disabled until consent, abuse, privacy, telemetry, and kill-switch gates pass.
4. Cross-client sync v2 lockstep: PAR-06. Apple, Android, web, and site must pass the same rollback-floor and migration fixtures before writes are enabled.

Exit: phone/TV parity tests pass and all migration programmes remain disabled until their explicit promotion criteria pass.

## Wave 6: reproducibility, architecture, and cleanup

Dependencies: Wave 5 complete.

Lanes:

- Public reproducibility, vortx-core acceptance, legacy iOS shell cutover, and orphan core contract: REPRO-01, APP-HW-02, MAINT-01, DEAD-05.
- Gradual source decomposition under test: MAINT-02.
- Confirm and remove obsolete HLS player path: DEAD-01.
- Keep or retire remux rollback path only after construction/reference proof: DEAD-02.
- Wire or remove unused remote-config dials: DEAD-03.
- Remove generated build logs and add precise ignore rule: DEAD-04.
- Correct Android TV capability documentation: DOC-01.

Exit: no behavior change is hidden inside cleanup, public reproducibility is documented, and all removal candidates have construction/reference proof.

## Wave 7: owner and physical-device gates

Dependencies: Waves 1 through 6 complete.

Owner gates:

- Protect main with stable required Apple, Android, SAST, secretless-package, and provenance checks.
- Verify Swift and java-kotlin code-scanning categories exist.
- Verify the pinned Android production signer against staged artifacts.
- Prove extracted client edge material cannot authorize privileged server operations.

Device gates:

- Android arm64 mpv EOF/error and SDR/HDR/Dolby Vision frame-capture matrix.
- Packaged-JNI raw torrent Range/resume/restart path.
- Apple download scheduler forward progress, aggregate cap, self-heal, storage pressure, relaunch, and extensionless HLS.
- Apple trailer rollout and kill-switch matrix.

## Final release gate

A single beta may be considered only when all conditions are true against the same commit and artifact hashes:

1. No unresolved P0 or P1 finding.
2. No unresolved P2 finding affecting signing, terminal state, offline identity, scheduler boundedness, durability, security, or mandatory CI.
3. Every implementation lane has an independent approval.
4. All required status checks are enforced on main and green without skips.
5. All device and owner gates pass with logs, device/OS inventory, workflow run IDs, hashes, and screenshots where relevant.
6. Every enabled migration/rollout has a production reader, promotion threshold, rollback trigger, kill switch, and negative test.
7. Release notes, Android APK/AAB, iOS IPA, tvOS full/lite IPA, macOS DMG, appcast, AltStore source, signer identity, and provenance all bind to the same release.

Until then, the Beta 29 draft remains unpublished and no replacement beta is cut.
