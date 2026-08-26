# VortX Public-Repository Code Audit

**Audit date:** 2026-08-26  
**Pinned commit:** `57943623ee662463158385b7c3598937f269a1e1`  
**Repository:** `VortXTV/VortX`  
**Evidence basis:** public source and GitHub Actions/configuration at the pinned commit; issue-tracker reports were not used as findings.

## Executive conclusion

The product is much more complete on Android than the repository documentation sometimes suggests: the major account, catalog, TV, media-server, IPTV, external-sync and player surfaces exist on both platforms. The largest parity deficits are narrower but important—Android offline playback identity, offline HLS/batch downloads, per-profile account binding, several settings with no consumers, Source Index being hard-disabled, and route-specific ExoPlayer limitations.

The most urgent problems are not cosmetic:

1. Android releases can be publicly published with the debug signing key.
2. Android libmpv discards the `END_FILE` reason and can treat a midstream failure as a successful natural ending.
3. Android offline playback does not reliably bind progress to the downloaded title.
4. Apple’s download queue can stall after disk preflight failure and can exceed its concurrency cap during self-heal.
5. ExoPlayer can retain an error state across later successful loads.
6. Both download stores silently swallow persistence failures.
7. The repository’s apparent test/security coverage is substantially stronger on paper than in enforced CI.

**Finding count:** Critical: 1, High: 13, Medium: 34, Low: 12, Info: 1.

## Scope and limits

This was a repository-wide static audit plus deep control-flow tracing of high-risk runtime paths: Apple and Android players, download/storage systems, profiles/account boundaries, sync/backup, updater/deep links, feature wiring, project generation, release workflows and security checks. I also scanned for TODO/FIXME/not-wired/no-consumer/dormant paths and cross-checked feature implementations between Apple and Android.

This is not a claim that every executable line was dynamically exercised. The public checkout does not include all private engine/framework inputs and release credentials, so a fully reproducible build and device test matrix was not possible. Findings marked **Confirmed** follow directly from code/configuration. Findings marked as a **risk** need an integration/device test to establish exploitability or exact device impact.

## Severity model

- **Critical:** release integrity, signing lineage or a failure mode capable of causing broad irreversible user impact.
- **High:** likely wrong user-visible state, data loss, incorrect watched/progress behavior, security trust failure, or a missing quality gate over core code.
- **Medium:** material parity gap, reliability/security weakness or misleading user-facing behavior.
- **Low:** limited correctness issue, dormant/dead code, stale documentation or maintainability debt.
- **Info:** scope/reproducibility fact rather than a direct defect.
## Priority findings
### REL-01 — The release workflow falls back to the Android debug key when production signing secrets are absent, but still proceeds to publish the APKs. The filename gains a debug-signed suffix; publication itself is not blocked.

**Severity:** Critical  
**Type:** Incorrectly done / release integrity  
**Platform:** Android  
**Confidence:** Confirmed  
**Location:** `.github/workflows/android-release.yml`

**Impact:** A publicly installed debug-signed build cannot be upgraded in-place by a later production-signed build. This can strand users on an incompatible signing lineage and destroys confidence in release provenance.

**Recommended fix:** Fail the release job unless every signing secret is present. After signing, run apksigner verify --print-certs, reject the Android Debug certificate, compare the SHA-256 certificate digest with a pinned release fingerprint, and publish only after that gate. Keep debug-signed artifacts in a separate non-release workflow.
### AND-DL-01 — Offline playback launches a local Playable without a port of Apple's PlaybackMeta/media identity. The code explicitly states that progress may be attributed to whatever engine item the session currently points at.

**Severity:** High  
**Type:** Bug / parity  
**Platform:** Android  
**Confidence:** Confirmed by explicit production comment  
**Location:** `android/app/src/main/kotlin/com/vortx/android/ui/screens/DownloadsScreen.kt; ui/tv/TvDownloadsScreen.kt`

**Impact:** Watching a downloaded movie or episode can update progress, watched state, scrobbling, or auto-next context for the wrong title—especially after another streamed item was active earlier in the session.

**Recommended fix:** Create a platform-neutral PlaybackContext carrying contentId, videoId, media type, season/episode, profile owner, title and poster. Build it from DownloadRecord and require PlayerScreen/session creation to receive it before local playback starts. Add a regression test that plays downloaded B after streamed A and proves only B changes.
### AND-PLY-01 — The libmpv wrapper forwards only the raw MPV_EVENT_END_FILE event id. MpvPlayer cannot read mpv_event_end_file.reason, so it classifies every end event after playback has once started as natural EOF.

**Severity:** High  
**Type:** Bug  
**Platform:** Android  
**Confidence:** Confirmed  
**Location:** `android/app/src/full/kotlin/com/vortx/android/player/mpv/MPVLib.kt; MpvPlayer.kt`

**Impact:** A decoder error, network failure, reconnect exhaustion, stop, or other non-EOF terminal event after the first frame can be reported as hasEnded=true. The host may mark the title watched and auto-advance instead of showing an error or retrying.

**Recommended fix:** Fork or extend the JNI seam to expose END_FILE reason and error. Set hasEnded only for MPV_END_FILE_REASON_EOF; map ERROR to hasError with the native error code; ignore or separately handle STOP/QUIT/REDIRECT. Add tests for EOF, manual stop, midstream network failure, decode failure, and source replacement.
### AND-PLY-02 — onPlayerError sets hasError=true, but load does not reset hasError for the next item.

**Severity:** High  
**Type:** Bug  
**Platform:** Android  
**Confidence:** Confirmed  
**Location:** `android/app/src/main/kotlin/com/vortx/android/player/ExoPlayerEngine.kt`

**Impact:** After one failed stream, a later healthy stream can inherit a permanent error state and keep the error UI/retry logic active.

**Recommended fix:** Reset all per-item terminal state at the start of load, ideally by constructing a fresh PlayerState. Ensure onPlayerError clears hasEnded and buffering. Add error-then-success and source-switch tests.
### APP-DL-01 — startNextQueued marks the head record downloading and calls startTask. If storageShortfall fails, startTask marks that record failed and returns without continuing to the next queued item.

**Severity:** High  
**Type:** Bug  
**Platform:** Apple  
**Confidence:** Confirmed by control flow  
**Location:** `app/SourcesShared/DownloadManager.swift — startNextQueued/startTask/storageShortfall`

**Impact:** A single queued item that fails disk preflight can leave free slots unused and stall later valid downloads until another unrelated lifecycle event drains the queue.

**Recommended fix:** Make startTask return a StartDisposition. On preflight/URL rejection, keep draining in a bounded loop. Prefer one fillAvailableSlots owner rather than recursive start-next calls. Add a queue test: head fails preflight, second item must start immediately.
### APP-DL-02 — The -3000 self-heal path calls clearTask, which immediately starts the next queued download, then directly restarts the failed record with startTask.

**Severity:** High  
**Type:** Bug  
**Platform:** Apple  
**Confidence:** Confirmed by control flow  
**Location:** `app/SourcesShared/DownloadManager.swift — didCompleteWithError/clearTask`

**Impact:** The retry can exceed maxConcurrentDownloads by one and violates the queue ordering/concurrency contract precisely during an error path.

**Recommended fix:** Do not directly restart after clearTask. Requeue the retry at the head with a retry marker, then let fillAvailableSlots be the only starter. Add an invariant assertion and a test that active byte tasks never exceed the configured cap during self-heal.
### CI-01 — main has no enforced required status checks.

**Severity:** High  
**Type:** Incorrectly done / process  
**Platform:** All  
**Confidence:** Confirmed  
**Location:** `GitHub branch protection for main`

**Impact:** A broken build, failed security analysis, or untested release change can land on main without any repository-level gate.

**Recommended fix:** Require platform build, unit test, lint/static analysis, secrets scan, and release-artifact verification checks. Require them on pull requests and block force-push/bypass except a tightly controlled emergency role.
### CI-02 — The custom CodeQL workflow excludes Swift and Kotlin, while the Java/Kotlin autobuild for the audited commit failed because NDK 27.0.12077973 was not installed.

**Severity:** High  
**Type:** Incorrectly done / security coverage  
**Platform:** Android + Apple  
**Confidence:** Confirmed  
**Location:** `.github/workflows/codeql.yml and current CodeQL run`

**Impact:** Neither mobile codebase has dependable CodeQL coverage, despite workflow presence suggesting otherwise.

**Recommended fix:** Use manual CodeQL build mode. Install the exact JDK/SDK/NDK, run the real Gradle compile tasks, add Swift analysis where supported, and make missing-language analysis a failing required check rather than a tolerated gap.
### CI-03 — Semgrep is run with failure suppression, and a missing SARIF file is replaced with an empty SARIF result.

**Severity:** High  
**Type:** Incorrectly done / fail-open security  
**Platform:** All  
**Confidence:** Confirmed  
**Location:** `.github/workflows/semgrep.yml`

**Impact:** Scanner failure can be reported as a successful empty scan. A green workflow does not prove analysis ran.

**Recommended fix:** Remove failure suppression, validate that SARIF contains a Semgrep invocation/result set, upload it only after a successful scan, and make scanner startup/configuration failures fatal.
### CI-04 — The Android workflow assembles APKs but does not execute the substantial JVM test corpus, the instrumentation suite, or a lint task. lint is configured as fatal in Gradle, but assemble is not lint.

**Severity:** High  
**Type:** Incorrectly done / missing verification  
**Platform:** Android  
**Confidence:** Confirmed  
**Location:** `.github/workflows/android.yml; android/app/build.gradle.kts`

**Impact:** Many repository tests and lint rules provide no merge protection. Player, profile, download, sync and catalog regressions can compile and ship.

**Recommended fix:** Add lintFullDebug, lintPlayDebug, testFullDebugUnitTest, testPlayDebugUnitTest and connected/device tests. Publish reports and make all required. Add release-variant tests where release-only behavior exists.
### CI-05 — app/Tests contains a large contract/security test corpus, but project.yml defines no Xcode test target or test scheme. The standalone harness compiles only a small hand-selected subset and is not wired into the release workflow.

**Severity:** High  
**Type:** Half-wired tests  
**Platform:** Apple  
**Confidence:** Confirmed  
**Location:** `app/project.yml; app/Tests; .harness/run-suites.sh`

**Impact:** Most Apple tests are non-executable in the generated Xcode project and do not protect releases.

**Recommended fix:** Add VortXTests targets for each applicable platform in XcodeGen, attach app sources through testable modules, create schemes, and run xcodebuild test in a secretless PR workflow. Retain standalone harnesses only for intentionally dependency-free contracts.
### SEC-01 — The updater trusts an install URL from the appcast and opens it directly. There is no host allow-list or artifact digest verification in the client.

**Severity:** High  
**Type:** Security hardening / incorrectly done  
**Platform:** Android  
**Confidence:** Confirmed design weakness  
**Location:** `android/app/src/main/kotlin/com/vortx/android/update/UpdateChecker.kt; UpdateUi.kt`

**Impact:** A compromised or incorrectly signed feed path can direct users to an unexpected APK location. Stable signing mitigates installation of a different signer, but the release workflow currently also permits debug signing.

**Recommended fix:** Allow-list HTTPS release hosts, reject redirects outside the allow-list, include SHA-256 and size in the signed feed, verify the downloaded artifact before launching installation, and pin the expected signing certificate after download.
### STORE-01 — Download index persistence failures are swallowed. In-memory records are updated even when atomic write/rename/fallback persistence fails.

**Severity:** High  
**Type:** Bug / durability  
**Platform:** Apple + Android  
**Confidence:** Confirmed  
**Location:** `app/SourcesShared/DownloadStore.swift; android/.../downloads/DownloadStore.kt`

**Impact:** The UI can report a durable state that disappears after restart. Completed downloads may become orphan files, and queued/paused records can vanish without an actionable error.

**Recommended fix:** Return or publish persistence failures, preserve the last-good index, write a checksum/versioned backup, and retry on a serialized store actor. Do not acknowledge terminal completion until the record is durably committed.
## Complete finding register
| ID | Severity | Type | Platform | Confidence | Location | Finding | Impact | Recommended fix |
|---|---|---|---|---|---|---|---|---|
| REL-01 | Critical | Incorrectly done / release integrity | Android | Confirmed | `.github/workflows/android-release.yml` | The release workflow falls back to the Android debug key when production signing secrets are absent, but still proceeds to publish the APKs. The filename gains a debug-signed suffix; publication itself is not blocked. | A publicly installed debug-signed build cannot be upgraded in-place by a later production-signed build. This can strand users on an incompatible signing lineage and destroys confidence in release provenance. | Fail the release job unless every signing secret is present. After signing, run apksigner verify --print-certs, reject the Android Debug certificate, compare the SHA-256 certificate digest with a pinned release fingerprint, and publish only after that gate. Keep debug-signed artifacts in a separate non-release workflow. |
| AND-DL-01 | High | Bug / parity | Android | Confirmed by explicit production comment | `android/app/src/main/kotlin/com/vortx/android/ui/screens/DownloadsScreen.kt; ui/tv/TvDownloadsScreen.kt` | Offline playback launches a local Playable without a port of Apple's PlaybackMeta/media identity. The code explicitly states that progress may be attributed to whatever engine item the session currently points at. | Watching a downloaded movie or episode can update progress, watched state, scrobbling, or auto-next context for the wrong title—especially after another streamed item was active earlier in the session. | Create a platform-neutral PlaybackContext carrying contentId, videoId, media type, season/episode, profile owner, title and poster. Build it from DownloadRecord and require PlayerScreen/session creation to receive it before local playback starts. Add a regression test that plays downloaded B after streamed A and proves only B changes. |
| AND-DL-02 | High | Security risk | Android | High-confidence risk; runtime behavior should be integration-tested | `android/app/src/main/kotlin/com/vortx/android/downloads/DownloadWorker.kt` | Downloads enable automatic redirects while applying arbitrary source request headers, but there is no explicit cross-host redirect policy that strips credentials or origin-bound headers. | Referer, Authorization, cookies, proxy headers, or add-on tokens may follow a redirect to a different host depending on HttpURLConnection behavior and header type. | Handle redirects manually. Resolve each Location, enforce HTTPS/host policy, and drop Authorization/Cookie/Proxy-Authorization plus add-on-sensitive headers on origin change unless an explicit trusted redirect policy permits them. |
| AND-PLY-01 | High | Bug | Android | Confirmed | `android/app/src/full/kotlin/com/vortx/android/player/mpv/MPVLib.kt; MpvPlayer.kt` | The libmpv wrapper forwards only the raw MPV_EVENT_END_FILE event id. MpvPlayer cannot read mpv_event_end_file.reason, so it classifies every end event after playback has once started as natural EOF. | A decoder error, network failure, reconnect exhaustion, stop, or other non-EOF terminal event after the first frame can be reported as hasEnded=true. The host may mark the title watched and auto-advance instead of showing an error or retrying. | Fork or extend the JNI seam to expose END_FILE reason and error. Set hasEnded only for MPV_END_FILE_REASON_EOF; map ERROR to hasError with the native error code; ignore or separately handle STOP/QUIT/REDIRECT. Add tests for EOF, manual stop, midstream network failure, decode failure, and source replacement. |
| AND-PLY-02 | High | Bug | Android | Confirmed | `android/app/src/main/kotlin/com/vortx/android/player/ExoPlayerEngine.kt` | onPlayerError sets hasError=true, but load does not reset hasError for the next item. | After one failed stream, a later healthy stream can inherit a permanent error state and keep the error UI/retry logic active. | Reset all per-item terminal state at the start of load, ideally by constructing a fresh PlayerState. Ensure onPlayerError clears hasEnded and buffering. Add error-then-success and source-switch tests. |
| APP-DL-01 | High | Bug | Apple | Confirmed by control flow | `app/SourcesShared/DownloadManager.swift — startNextQueued/startTask/storageShortfall` | startNextQueued marks the head record downloading and calls startTask. If storageShortfall fails, startTask marks that record failed and returns without continuing to the next queued item. | A single queued item that fails disk preflight can leave free slots unused and stall later valid downloads until another unrelated lifecycle event drains the queue. | Make startTask return a StartDisposition. On preflight/URL rejection, keep draining in a bounded loop. Prefer one fillAvailableSlots owner rather than recursive start-next calls. Add a queue test: head fails preflight, second item must start immediately. |
| APP-DL-02 | High | Bug | Apple | Confirmed by control flow | `app/SourcesShared/DownloadManager.swift — didCompleteWithError/clearTask` | The -3000 self-heal path calls clearTask, which immediately starts the next queued download, then directly restarts the failed record with startTask. | The retry can exceed maxConcurrentDownloads by one and violates the queue ordering/concurrency contract precisely during an error path. | Do not directly restart after clearTask. Requeue the retry at the head with a retry marker, then let fillAvailableSlots be the only starter. Add an invariant assertion and a test that active byte tasks never exceed the configured cap during self-heal. |
| CI-01 | High | Incorrectly done / process | All | Confirmed | `GitHub branch protection for main` | main has no enforced required status checks. | A broken build, failed security analysis, or untested release change can land on main without any repository-level gate. | Require platform build, unit test, lint/static analysis, secrets scan, and release-artifact verification checks. Require them on pull requests and block force-push/bypass except a tightly controlled emergency role. |
| CI-02 | High | Incorrectly done / security coverage | Android + Apple | Confirmed | `.github/workflows/codeql.yml and current CodeQL run` | The custom CodeQL workflow excludes Swift and Kotlin, while the Java/Kotlin autobuild for the audited commit failed because NDK 27.0.12077973 was not installed. | Neither mobile codebase has dependable CodeQL coverage, despite workflow presence suggesting otherwise. | Use manual CodeQL build mode. Install the exact JDK/SDK/NDK, run the real Gradle compile tasks, add Swift analysis where supported, and make missing-language analysis a failing required check rather than a tolerated gap. |
| CI-03 | High | Incorrectly done / fail-open security | All | Confirmed | `.github/workflows/semgrep.yml` | Semgrep is run with failure suppression, and a missing SARIF file is replaced with an empty SARIF result. | Scanner failure can be reported as a successful empty scan. A green workflow does not prove analysis ran. | Remove failure suppression, validate that SARIF contains a Semgrep invocation/result set, upload it only after a successful scan, and make scanner startup/configuration failures fatal. |
| CI-04 | High | Incorrectly done / missing verification | Android | Confirmed | `.github/workflows/android.yml; android/app/build.gradle.kts` | The Android workflow assembles APKs but does not execute the substantial JVM test corpus, the instrumentation suite, or a lint task. lint is configured as fatal in Gradle, but assemble is not lint. | Many repository tests and lint rules provide no merge protection. Player, profile, download, sync and catalog regressions can compile and ship. | Add lintFullDebug, lintPlayDebug, testFullDebugUnitTest, testPlayDebugUnitTest and connected/device tests. Publish reports and make all required. Add release-variant tests where release-only behavior exists. |
| CI-05 | High | Half-wired tests | Apple | Confirmed | `app/project.yml; app/Tests; .harness/run-suites.sh` | app/Tests contains a large contract/security test corpus, but project.yml defines no Xcode test target or test scheme. The standalone harness compiles only a small hand-selected subset and is not wired into the release workflow. | Most Apple tests are non-executable in the generated Xcode project and do not protect releases. | Add VortXTests targets for each applicable platform in XcodeGen, attach app sources through testable modules, create schemes, and run xcodebuild test in a secretless PR workflow. Retain standalone harnesses only for intentionally dependency-free contracts. |
| SEC-01 | High | Security hardening / incorrectly done | Android | Confirmed design weakness | `android/app/src/main/kotlin/com/vortx/android/update/UpdateChecker.kt; UpdateUi.kt` | The updater trusts an install URL from the appcast and opens it directly. There is no host allow-list or artifact digest verification in the client. | A compromised or incorrectly signed feed path can direct users to an unexpected APK location. Stable signing mitigates installation of a different signer, but the release workflow currently also permits debug signing. | Allow-list HTTPS release hosts, reject redirects outside the allow-list, include SHA-256 and size in the signed feed, verify the downloaded artifact before launching installation, and pin the expected signing certificate after download. |
| STORE-01 | High | Bug / durability | Apple + Android | Confirmed | `app/SourcesShared/DownloadStore.swift; android/.../downloads/DownloadStore.kt` | Download index persistence failures are swallowed. In-memory records are updated even when atomic write/rename/fallback persistence fails. | The UI can report a durable state that disappears after restart. Completed downloads may become orphan files, and queued/paused records can vanish without an actionable error. | Return or publish persistence failures, preserve the last-good index, write a checksum/versioned backup, and retry on a serialized store actor. Do not acknowledge terminal completion until the record is durably committed. |
| AND-APP-01 | Medium | Incorrect observability | Android | Confirmed | `android/app/src/main/kotlin/com/vortx/android/VortXApplication.kt` | Initialization failures for multiple subsystems are caught and can silently disable profiles, sync, media, downloads or updates. | A partially initialized app can look healthy while important functionality is absent. | Record structured startup health, expose degraded-mode diagnostics, retry recoverable components, and fail closed when identity/security-critical initialization fails. |
| AND-DL-03 | Medium | API correctness | Android | Confirmed | `android/app/src/main/kotlin/com/vortx/android/downloads/DownloadManager.kt` | The Android download API has the same stale-return behavior when an existing paused record is resumed. | Immediate UI and coordinator decisions can use the wrong state. | Return DownloadStore.record(id) after resume/requeue, or expose an async/state-flow API rather than returning snapshots. |
| AND-DL-04 | Medium | Feature parity | Android | Confirmed | `android/app/src/main/kotlin/com/vortx/android/downloads/DownloadManager.kt` | Offline HLS asset downloading is not implemented on Android. | Segmented streams that are downloadable on iPhone/iPad cannot be downloaded on Android. | Use Media3 DownloadService/DownloadManager with HLS stream keys, persistent requirements, DRM policy and local playback integration. |
| AND-DL-05 | Medium | Feature parity | Android | Confirmed | `DownloadManager.kt` | The season/batch download coordinator available on iOS is absent on Android. | Android users must resolve and queue episodes one at a time; source continuity and quality policy are not shared. | Port the platform-neutral batch plan and source-ranking inputs, then use Android's queue as the executor. Keep profile/title identity explicit. |
| AND-DL-06 | Medium | Half-wired | Android | Confirmed | `DownloadManager.kt` | The auto-delete-watched preference is persisted but the deletion behavior is not wired. | The settings UI promises storage reclamation that never occurs. | Observe the profile-scoped finished-watched signal, guard against active playback/live tasks, and delete only completed local records. Add profile-switch and currently-playing tests. |
| AND-DL-07 | Medium | Half-wired | Android | Confirmed | `DownloadManager.kt` | Raw torrent-to-download conversion remains unwired. | Some torrent sources can play through the streaming server but cannot be converted into durable offline files. | Define one supported path—debrid resolve to stable HTTP, or a foreground local-server transfer with resumability—and reject unsupported torrent downloads before creating a misleading record. |
| AND-DL-08 | Medium | Incorrect failure handling | Android | Confirmed | `android/.../downloads/DownloadWorker.kt` | Failure to promote the worker to foreground execution is ignored while the large download continues. | The OS can stop the work under background limits while the UI still expects durable transfer behavior. | Treat foreground promotion as a required precondition for large/long transfers, or explicitly downgrade to a constrained/retry state with a user-visible reason. |
| AND-PLY-03 | Medium | Bug | Android | Confirmed | `android/app/src/main/kotlin/com/vortx/android/player/ExoPlayerEngine.kt — setMuted` | setMuted is not idempotent. Repeating setMuted(true) can overwrite the saved pre-mute volume with zero. | Unmuting can restore silence rather than the user's prior volume. | Store previous volume only on the false-to-true transition; restore only on true-to-false. Track mute state explicitly and test repeated mute/unmute calls. |
| AND-PLY-04 | Medium | Incorrect state transition | Android | Confirmed | `ExoPlayerEngine.kt; PlayerEngine.kt` | The PlayerState contract says hasError and hasEnded are mutually exclusive, but ExoPlayer's error path can set hasError without clearing hasEnded. | The UI can simultaneously treat playback as ended and failed, producing incorrect auto-next/retry behavior. | Centralize terminal transitions in a reducer and assert exclusivity. Every error transition must clear ended; every EOF transition must clear error. |
| AND-PLY-06 | Medium | Bug / compatibility | Android | Confirmed | `ExoPlayerEngine.kt — external subtitle MIME detection` | External subtitle mounting depends on a recognizable URL extension. Extensionless or signed URLs can be silently skipped. | Valid add-on/community subtitles fail on common CDN URLs whose type is carried by content-type or query parameters. | Use declared subtitle format when available, otherwise bounded-fetch/probe content type and signatures. Default safely to text/vtt or application/x-subrip only after validation. |
| AND-PLY-07 | Medium | Feature parity / half-wired | Android | Confirmed | `ExoPlayerEngine.kt` | Several PlayerEngine controls are implemented as no-ops or restricted on the Exo fallback route: subtitle delay, audio delay, audio output policy, full chapter support, DV/Atmos capture, and community trickplay capture. | The same Android UI exposes capabilities whose behavior changes materially when routing falls back from mpv to ExoPlayer. | Publish explicit engine capabilities and hide/disable unsupported controls. Port what Media3 supports; clearly label route-limited functions and add parity tests for capability/UI consistency. |
| AND-PLY-08 | Medium | Half-wired / validation gap | Android | Confirmed by code comment; device impact unverified | `android/app/src/full/kotlin/com/vortx/android/player/mpv/MpvPlayer.kt` | Frame capture on the Surface-direct hardware-decoding path is knowingly unverified and may produce null or near-black images. | Scrub thumbnails and community trickplay contribution can fail on the main high-performance playback route. | Add device-matrix capture tests. Prefer a verified libmpv render API/readback path or a decoder-image route; gate contribution on luminance/variance validation rather than accepting black frames. |
| APP-DL-03 | Medium | API correctness | Apple | Confirmed | `app/SourcesShared/DownloadManager.swift — download` | Tapping Download on an existing paused record calls resume but returns the stale pre-resume DownloadRecord value. | Callers can immediately render or reason from paused state even though the store changed to downloading/queued. | Return the post-mutation store record, or make resume return the updated record/state. |
| APP-DL-04 | Medium | Incorrect queue semantics | Apple | Confirmed | `DownloadManager.swift — HLS asset path` | HLS asset downloads bypass the byte-download concurrency cap and queue. | The user's max-concurrent setting is not a true global limit; multiple HLS and byte tasks can exceed the intended network/storage pressure. | Use a shared scheduler with per-transport slots or clearly rename the setting to byte downloads only. Prefer a weighted global cap. |
| APP-DL-05 | Medium | Compatibility bug | Apple | Confirmed | `DownloadManager.swift — isHLSPlaylistURL/isHLSRecord` | HLS detection is based on path extension or substring '.m3u8'. | Extensionless signed manifests are missed, while unrelated URLs containing the substring can be misclassified. | Use source metadata/content type when available; otherwise perform a bounded HEAD/range sniff and recognize #EXTM3U. |
| APP-HW-01 | Medium | Half-wired | Apple | Confirmed | `app/SourcesShared/YouTubeDirectResolver.swift` | The V2 YouTube resolver/hardening path is compiled but disabled by default; client identities remain hard-coded with a TODO for remote configuration. | The newer resilience path is not protecting normal users, and hard-coded client identities are brittle when upstream behavior changes. | Finish staged remote configuration, telemetry and rollback; enable for a small cohort and remove the obsolete path after measured parity. |
| APP-HW-02 | Medium | Half-wired migration | Apple | Confirmed | `app/SourcesShared/VortxBridge.swift; app/project.yml` | The new vortx-core engine is linked only into the native iOS target and runs only as a default-off shadow ranker. Swift remains authoritative and no result reaches the UI. | A substantial migration surface ships without product effect while maintaining two ranking implementations. | Define acceptance metrics, automate divergence reports, link equivalent targets, and remove one implementation once the new engine passes deterministic parity fixtures. |
| MAINT-01 | Medium | Maintainability / half migration | Apple | Confirmed | `app/project.yml` | Two iOS product architectures remain: a WKWebView host and VortXiOSNative. The legacy host is retained pending native parity/cutover. | Release, entitlements, routing and feature work can diverge between two app shells. | Maintain a cutover checklist and telemetry, stop adding features to the legacy host, and remove it once the native target meets explicit parity gates. |
| MAINT-02 | Medium | Maintainability | Apple + Android | Confirmed by file size | `CoreBridge.swift, CredentialScope.swift, DebridResolver.swift, EngineStremioRepository.kt, PlayerScreen.kt, PlayerChrome.kt and others` | Several core files are extremely large and mix transport, state, policy, persistence and UI concerns. | Review becomes non-local, tests require broad fixtures, and merge conflicts encourage accidental coupling. | Split around explicit state machines and interfaces: identity/session, transport, persistence, ranking, player terminal reducer, chrome capability model and platform adapters. Enforce size/complexity budgets gradually. |
| PAR-01 | Medium | Feature parity / half-wired | Android | Confirmed | `ui/screens/WhosWatchingScreen.kt; ui/tv/TvWhosWatchingScreen.kt; ProfileStore` | Profile selection supports PIN/Kids overlays, but per-profile own-account sign-in/switching is not wired. Switch outcomes are ignored and the current session carries over. | Profiles are not equivalent account boundaries on Android; selecting another profile may still use the previous Stremio account. | Make profile selection transactional: resolve account binding, require sign-in where needed, swap engine/session credentials, then publish active profile. Never ignore SwitchAccount/NeedsSignIn outcomes. |
| PAR-02 | Medium | Half-wired UI | Android | Confirmed | `ui/prefs/HomeDiscoverPreferences.kt; ui/screens/HomeDiscoverSettingsScreen.kt` | Several visible Home/Discover/detail toggles have no runtime consumer: curated rails, collections hub, detail financials, spoiler-safe/blur behavior, and poster-label visibility. One comment also incorrectly says mergeDiscoverSearch has no consumer even though VortXApp uses it. | Users can change settings that do nothing, while stale comments make future work error-prone. | Create a generated preference-to-consumer registry/test. Hide incomplete rows behind a development flag or wire each consumer before release. Remove stale annotations. |
| PAR-03 | Medium | Feature parity | Android | Confirmed | `android/app/src/main/kotlin/com/vortx/android/model/TrailerRequest.kt` | The Apple trailer metadata factory is not ported; Android's meta model lacks trailerStreams/trailerYouTubeID and callers must construct requests manually. | Trailer discovery and identity behavior can vary by caller and miss metadata available on Apple. | Move trailer request derivation into shared model/domain code and make all detail surfaces use it. |
| PAR-05 | Medium | Half-wired / dormant | Android | Confirmed | `android/app/src/main/kotlin/com/vortx/android/singularity/SourceIndexClient.kt` | The Source Index/Singularity implementation is compiled but hard-disabled with isEnabled=false. | Remote config and supporting MOAT/identity code exist, but Android cannot contribute to or consume the community source pool. | Either remove/hide the dormant surface or complete consent, rollout, abuse controls, tests and remote kill-switch wiring before enabling it. |
| PAR-06 | Medium | Half-wired security migration | Apple | Confirmed intentional deferral | `app/SourcesShared/VortXSyncManager.swift` | v2 sync document writes are disabled pending rollback ratchets and per-account version floors. | The hardened format is not the authoritative write path; migration remains incomplete. | Complete monotonic version-floor storage, rollback rejection, migration telemetry and cross-device compatibility tests, then enable staged v2 writes through remote config. |
| PAR-07 | Medium | Feature parity | Android | Confirmed | `android/app/src/main/kotlin/com/vortx/android/backup/SettingsBackup.kt` | Android settings backup is primarily a profile-roster carrier; whole-domain settings export/import and the fuller Apple workflow are deliberately not ported. | Moving devices or restoring Android loses more configuration than Apple, despite shared key names. | Define a cross-platform backup schema with explicit domain allow-lists, secret exclusions, migrations and round-trip conformance fixtures. |
| REL-02 | Medium | Incorrect release metadata | Android | Confirmed | `.github/workflows/android-release.yml; android/app/build.gradle.kts; AndroidManifest.xml` | Release staging labels the full flavor as phone and the play flavor as TV, although these flavors primarily describe engine/distribution and both packages include phone and TV activities. | Users and maintainers can select the wrong artifact and misunderstand feature differences. | Name artifacts by actual dimensions (full-mpv, play-media3, ABI, universal) and document device support separately. |
| REL-03 | Medium | Missing release validation | Apple + Android | Confirmed | `release workflows` | Privileged release workflows lack equivalent secretless pull-request validation lanes. | The first complete exercise of packaging/signing-specific scripts can happen only after merge or during release. | Factor reusable build/test workflows and run unsigned/ad-hoc packaging on PRs. Keep signing/notarization as a thin protected final stage. |
| SEC-02 | Medium | Incorrect validation | Apple + Android | Confirmed | `app/SourcesShared/SettingsBackup.swift; android/.../backup/SettingsBackup.kt` | Backup envelope decoders do not strictly enforce the supported schema version and declared keyCount consistency. | Future or malformed payloads can be accepted under assumptions the importer does not actually support. | Require exact supported schema (or a defined migration path), verify keyCount, enforce duplicate-key and size limits, and reject unknown critical fields. |
| SEC-03 | Medium | Security hardening | Android | Confirmed | `android/app/src/main/res/xml/network_security_config.xml; AndroidManifest.xml` | Cleartext traffic is enabled broadly for compatibility rather than narrowly scoped to known local/add-on cases. | More HTTP destinations can be contacted without transport security than the product likely needs. | Default deny cleartext. Permit loopback/private-network hosts through explicit runtime handling; require per-add-on opt-in and warnings for remote HTTP. |
| SEC-04 | Medium | Sensitive-data handling | Android | Confirmed | `android/.../downloads/DownloadStore.kt` | Download request headers are persisted as plaintext JSON in app-private storage. | Headers may contain bearer tokens, cookies, referers or proxy credentials. Backup exclusion reduces exposure but does not protect a compromised/debuggable device or diagnostic copy. | Persist only an allow-listed subset, redact secrets, or encrypt credential-bearing values with Android Keystore. Prefer re-resolving short-lived headers on resume. |
| SEC-05 | Medium | Architecture risk | Apple + Android | Confirmed design | `release workflows and edge-auth helpers` | An HMAC secret is provisioned into client apps with masking/obfuscation. | Any secret shipped to clients is recoverable and cannot be treated as a durable authorization boundary. | Use HMAC only for telemetry/abuse friction. Move privileged authorization to short-lived server-issued tokens, device attestation where appropriate, rate limiting, and server-side identity. |
| SEC-06 | Medium | Residual security issue | Apple | Confirmed historical behavior documented in code | `app/SourcesShared/SettingsBackup.swift` | Older backup behavior could include token/data-key material. Current filtering self-heals synced documents but cannot revoke or repair backup files users already exported. | Previously exported files may remain sensitive even after upgrading. | Document affected versions, rotate exposed credentials where feasible, detect/import old envelopes cautiously, and notify users to delete/recreate legacy exports. |
| STORE-02 | Medium | Bug / durability | Apple + Android | Confirmed | `DownloadStore load paths on both platforms` | A corrupt or undecodable download index fails open to an empty record list; no backup repair or user-visible recovery is attempted. | A single partial/corrupt write can make every download disappear from the UI while files remain on disk. | Keep index.json and index.prev with checksums, validate before rotation, repair from the previous copy, scan the download directory for recoverable records, and surface a diagnostic event instead of silently returning empty. |
| TEST-01 | Medium | Half-wired verification | Apple | Confirmed | `.harness/run-suites.sh` | The manual harness compiles only a small subset of the Apple test corpus and is not invoked by CI. | A large quantity of apparent test coverage is effectively documentation rather than an enforced quality gate. | Wire the harness into CI for its intended standalone contracts, and move the rest into real Xcode test targets. |
| AND-DL-09 | Low | Concurrency improvement | Android | Confirmed | `DownloadManager.kt — performTransferFileMutation` | A global transfer lock is held while an arbitrary file-I/O callback executes. | Slow disk operations serialize unrelated download control paths and raise ANR/deadlock risk if callbacks re-enter transfer state. | Use the lock only to claim a per-record mutation token, perform I/O outside it, then commit state with generation checks. |
| AND-DL-10 | Low | Lifecycle improvement | Android | Confirmed | `VortXApplication.kt — initDownloads` | Download initialization launches an ad-hoc CoroutineScope(Dispatchers.IO) with no retained Job or structured owner. | The work cannot be cancelled, joined or observed and can outlive intended startup sequencing. | Use an application-owned SupervisorJob/scope or WorkManager for durable reconciliation, and expose completion/health. |
| AND-PLY-05 | Low | Incorrectly inconsistent | Android | Confirmed | `ExoPlayerEngine.kt` | Resume admission differs by load route: some paths seek for any positive start position while the normal path requires more than five seconds. | The same title can resume differently based on routing/format rather than user history. | Use one resume-admission policy shared by Exo, mpv, adaptive and offline paths, including floor and tail guard. |
| DEAD-01 | Low | Dead/obsolete path | Apple | High confidence | `app/Sources/Player/HLSPlayerView.swift` | The file remains in the target, but AVPlayerEngine states that the bare HLSPlayerView path is no longer mounted; repository reference search finds no construction call. | Obsolete player code increases review surface and can be accidentally revived without current contracts. | Delete it after confirming no storyboard/reflection use, or move it under an explicit legacy target with a retirement issue. |
| DEAD-02 | Low | Dead/rollback path | Apple | High confidence | `app/Sources/Player/VortXRemuxResourceLoader.swift` | The progressive resource-loader remux path is described as a rollback/legacy implementation, has no construction reference, lacks seeking and contains a Phase-2 TODO. | It preserves a second incomplete transport architecture alongside the HLS server. | Remove it if rollback is no longer needed; otherwise isolate it behind a compile flag and add a real owner/test. |
| DEAD-03 | Low | Dead configuration | Apple | Confirmed | `app/SourcesShared/RemoteConfig.swift` | Remote-config timeout dials for detail settle and debrid resolution are validated and documented but have no call-site consumers. | Operators may believe these controls can change production behavior; stale defaults can become a regression when eventually wired. | Either wire them with baked-equivalence tests or remove them from the schema until a consumer exists. |
| DEAD-04 | Low | Dead/generated artifact | Apple | Confirmed | `app/.xcdd-buildlog-VortXTV.txt` | A generated Xcode build log is committed. | Repository noise, stale diagnostics and potential path/environment leakage. | Delete it and add the pattern to .gitignore. |
| DEAD-05 | Low | Orphaned artifact / reproducibility | Shared core | Confirmed public-tree observation | `core/Cargo.lock` | The public core directory contains Cargo.lock but no public Cargo.toml/source tree. | The lockfile cannot build anything in the public checkout and suggests an incomplete/stale split. | Remove it, or publish the matching manifest/source/submodule contract and document how the private engine is supplied. |
| DOC-01 | Low | Incorrect documentation | Android TV | Confirmed | `ui/tv/TvApp.kt, TvSettingsScreen.kt, README and related comments` | Several comments/readme sections describe older route or sign-in limitations that no longer match implemented screens. | Maintainers can duplicate work or preserve wrong assumptions during parity changes. | Make route/feature tables generated from capability declarations where possible; remove historical implementation notes from production source comments. |
| PAR-04 | Low | Feature parity | Android | Confirmed | `android/app/src/main/kotlin/com/vortx/android/catalog/SimilarClient.kt` | More Like This implements the TMDB leg but not Apple's add-on genre/catalog merge. | Recommendations are narrower and can diverge between platforms. | Port the merge/dedup/ranking policy into shared code and feed both platforms the same inputs. |
| SEC-07 | Low | Incorrect UX semantics | Android | Confirmed | `UpdateChecker.kt; UpdateUi.kt` | Documentation says the update prompt is once per launch, but choosing Later persists the build key and suppresses that build across later launches. | Users may miss the same important update indefinitely. | Store a timestamp/backoff or session-only dismissal, and reserve permanent suppression for an explicit Skip This Version action. |
| SEC-08 | Low | Concurrency bug risk | Android | High confidence | `UpdateChecker.kt` | Concurrent checks can access a plain mutable prompted-key set without synchronization. | Duplicate prompts or collection races are possible if startup/manual checks overlap. | Serialize checks with a Mutex/single-flight job and keep prompt state in StateFlow or a synchronized store. |
| REPRO-01 | Info | Scope / reproducibility | All | Confirmed | `project files, workflows and public core tree` | A fresh public checkout cannot reproduce every shipping target without private engine frameworks, generated artifacts and release credentials. | External contributors and automated auditors cannot independently compile the entire product. | Provide documented stubs or a public development mode, checksums/provenance for private binaries, and a manifest describing the exact missing inputs. |

## Apple ↔ Android feature parity matrix

Legend: **Parity** means equivalent product capability, not identical platform APIs. **Near parity** means both work but one route has important limitations. **Behind** means the feature is absent, hard-disabled or visibly incomplete.

| Area | Capability | Apple | Android | Assessment | Apple evidence | Android evidence | Action |
|---|---|---|---|---|---|---|---|
| Identity & sync | VortX account and encrypted cross-device sync | Implemented; v2 write migration still disabled | Implemented, including realtime manager | Near parity | VortXSyncManager.swift | sync/VortXSyncManager.kt | Finish Apple v2 ratchet migration |
| Identity & sync | Stremio account sign-in/import | Implemented | Implemented | Parity | CoreBridge/Auth surfaces | EngineStremioRepository/auth UI |  |
| Identity & sync | Profiles, PIN and Kids restrictions | Implemented | Implemented on phone and TV | Parity | Profiles.swift and profile UI | profile/* and Who's Watching screens |  |
| Identity & sync | Per-profile own Stremio account binding | Implemented account-switch outcomes | Partial; selection carries current session and ignores switch outcome | Android behind | Profiles.swift/account scope | WhosWatchingScreen.kt; TvWhosWatchingScreen.kt | P1 |
| Identity & sync | Settings backup/restore | Fuller export/import with secret filtering | Partial roster-oriented implementation | Android behind | SettingsBackup.swift | backup/SettingsBackup.kt | P1 |
| Add-ons | Install/remove/update/disable/reorder and store/pairing | Implemented | Implemented | Broad parity | CoreBridge/add-on views | CatalogRepository and add-on UI |  |
| Browsing | Home, Discover, Search, Library and Live | Implemented across Apple shells | Implemented on phone and TV | Parity | SourcesTV/SourcesiOS/SourcesShared | ui/screens and ui/tv |  |
| Browsing | Merge Discover and Search | Implemented | Implemented | Parity; Android comment is stale | Apple browse models | VortXApp.kt |  |
| Browsing | Home/Discover customization controls | Implemented | Several visible toggles lack consumers | Android behind | Apple settings + consumers | HomeDiscoverPreferences.kt | P1 |
| Browsing | Detail financials, spoiler-safe/blur and poster-label controls | Implemented | Settings exposed; consumers incomplete | Android behind | Apple detail/settings | HomeDiscoverPreferences.kt | P1 |
| Metadata | Trailers | Metadata-derived request path implemented | Partial; factory/model fields not ported | Android behind | Trailer resolver/models | model/TrailerRequest.kt | P1 |
| Metadata | More Like This | TMDB plus add-on/catalog merge | TMDB leg only | Android behind | Apple similar/recommendation code | catalog/SimilarClient.kt | P2 |
| Metadata | Ratings and person/title metadata | Implemented | Implemented | Broad parity | Ratings/person clients | ratings/catalog UI |  |
| External services | Trakt and SIMKL | Implemented | Implemented | Broad parity | TraktService.swift and SIMKL code | trakt/* and simkl/* |  |
| External services | Plex, Jellyfin and Emby | Implemented | Implemented | Broad parity | media-server clients | mediaserver/* |  |
| Live TV | IPTV playlists, guides and playback | Implemented | Implemented | Broad parity | IPTV shared/Apple UI | iptv/* |  |
| Sources | Debrid, direct HTTP, torrent/streaming server and Usenet/TorBox paths | Implemented | Implemented | Broad parity; route differences remain | DebridResolver/TorBox/stream server | debrid/*, torbox/*, engine/* |  |
| Sources | Community Source Index / Singularity | Implemented/feature-gated | Compiled but hard-disabled | Android behind | SourceIndexClient.swift | singularity/SourceIndexClient.kt | P2 or remove |
| Playback | libmpv engine | Implemented with native END_FILE reason handling | Implemented in full flavor; END_FILE reason lost | Android correctness gap | MPVMetalViewController.swift | mpv/MPVLib.kt; MpvPlayer.kt | P0 |
| Playback | Platform player route | AVPlayer full-chrome route | Media3/ExoPlayer fallback route | Near parity | AVPlayerEngine.swift | ExoPlayerEngine.kt | Capability differences must be explicit |
| Playback | Dolby Vision/HDR handling | Strong AVPlayer native-DV/remux path plus mpv | Media3/mpv device-dependent routes | Partial/device-dependent | PlayerEngineRouter/AVPlayerEngine | player router/config | Maintain device matrix |
| Playback | Audio/subtitle track selection and external subtitles | Implemented | Implemented; Exo extensionless URL gap | Near parity | AVPlayerEngine/MPV player | ExoPlayerEngine/MpvPlayer | P1 bug |
| Playback | Subtitle delay, audio delay and output policy | Full on mpv; AVPlayer has route-specific no-ops | Full on mpv; Exo has more no-ops | Route-specific parity | PlayerEngine capability code | PlayerEngine/ExoPlayerEngine | Expose capability model |
| Playback | Chapters | AVPlayer metadata and mpv support | mpv support; Exo chiefly ID3 | Android fallback behind | AVPlayerEngine | ExoPlayerEngine/MpvPlayer |  |
| Playback | Frame capture and community trickplay | Implemented on AVPlayer and mpv routes | Primarily mpv; direct-surface capture unverified, Exo limited | Android behind | AVPlayerEngine/MPV controller | MpvPlayer/ExoPlayerEngine | P1/P2 |
| Playback | Picture in Picture | Implemented | Implemented | Parity | AVPlayerEngine PiP | PlayerPip.kt |  |
| Playback | AirPlay / Google Cast | AirPlay/system route | Google Cast manager | Platform-equivalent | AVPlayer route | cast/CastManager.kt |  |
| Playback | Skip intro/credits/community skip and autoplay flow | Implemented | Implemented | Broad parity | Skip/community/player code | skip/* and PlayerScreen |  |
| Playback | Offline playback progress identity | PlaybackMeta preserves title identity | Known gap: local Playable can use stale session identity | Android materially behind | DownloadManager + player context | DownloadsScreen/TvDownloadsScreen | P0 |
| Downloads | Direct/debrid file downloads | Implemented | Implemented | Parity with durability issues | DownloadManager.swift | downloads/* | Fix stores on both |
| Downloads | Offline HLS | iPhone/iPad only; unavailable tvOS/macOS | Not implemented | Android behind; Apple platform-limited | AVAssetDownloadTask path | DownloadManager.kt | P1 |
| Downloads | Season/batch download | Implemented on iOS | Not implemented | Android behind | iOSBatchDownloadCoordinator.swift | No equivalent | P1/P2 |
| Downloads | Auto-delete watched downloads | Implemented and profile-aware | Preference only; behavior not wired | Android behind | DownloadManager.swift | DownloadManager.kt | P1 |
| Downloads | Queue, reorder and concurrency control | Implemented but has preflight/retry invariant bugs; HLS bypasses cap | Implemented through WorkManager/store | Near parity with Apple correctness gaps | DownloadManager.swift | downloads/* | P0/P1 |
| TV integration | Home-screen Continue Watching | Top Shelf | Android TV Watch Next/Play Next | Platform-equivalent | TopShelf snapshot code | tv/WatchNextPublisher.kt |  |
| Notifications | New episode alerts | Implemented | Implemented with WorkManager | Parity | NewEpisodeNotifications Apple path | notifications/NewEpisodeNotifications.kt |  |
| Navigation | Deep links into title/playback | Implemented | Implemented | Broad parity | Apple URL/deep-link handlers | deeplink/* and WatchNext intents |  |
| Updater | In-app update discovery/install | Implemented through Apple distribution paths | Implemented, but URL/digest trust needs hardening | Functionally present; Android risk | Apple update code/workflow | update/UpdateChecker.kt | P1 security |

## Fix specifications for the first engineering pass

### 1. Restore trustworthy Android terminal events

**Implementation target:** `MPVLib.EventObserver` must receive an object such as:

```kotlin
data class EndFileEvent(
    val reason: EndReason,
    val errorCode: Int?,
)

enum class EndReason { EOF, STOP, QUIT, ERROR, REDIRECT, UNKNOWN }
```

The JNI/upstream bridge should copy `mpv_event_end_file.reason` and `error`. `MpvPlayer` should feed a single terminal reducer. Only `EOF` may set `hasEnded=true`. `ERROR` sets `hasError=true`; `STOP` caused by replacement/teardown is non-terminal to the host; unknown fails closed as error, not watched.

**Acceptance tests:**

- Natural EOF marks ended once.
- HTTP disconnect after 30 seconds never marks ended or watched.
- Decoder failure never auto-advances.
- Manual close/source replacement never marks watched.
- Duplicate terminal callbacks are idempotent.

### 2. Make offline playback identity mandatory

Introduce a shared `PlaybackContext` separate from the transport URL. A local file must not enter `PlayerScreen` without:

- profile owner or active profile snapshot;
- content/meta id;
- exact video/episode id;
- type, season and episode;
- display title/poster;
- resume and watched identity;
- source provenance (`offline`, `debrid`, `torrent`, etc.).

The player/scrobble/watch-history owners should read this immutable context, not whichever engine metadata happens to be resident.

### 3. Fix Apple download scheduling around one owner

Replace recursive/direct starts with one scheduler:

```text
record mutation -> enqueue/requeue -> scheduler.fillAvailableSlots()
```

`startTask` should return `started`, `rejected(reason)`, or `deferred`. Rejections must not consume a slot. A self-heal retry should be requeued at priority, never started after `clearTask` has already drained the queue. Include HLS in either the same weighted cap or a clearly separate user-facing limit.

### 4. Reset player state per load

Both engines should use a terminal state reducer. At the start of every load create a fresh per-item state and preserve only intentional cross-item settings such as volume/speed. Never copy terminal flags forward.

### 5. Make release signing fail closed

- Require the production keystore, alias and passwords.
- Verify APK signature and certificate fingerprint.
- Reject the Android Debug subject/fingerprint.
- Generate signed provenance/checksum files.
- Publish only from a protected tag after required CI succeeds.
- Put debug-signed builds in a clearly separate internal channel/package id.

### 6. Convert tests from source inventory into gates

**Android required PR jobs:** compile full/play, JVM tests for both flavors, lint for both, instrumentation smoke tests, native-library verification, dependency/license/security checks.

**Apple required PR jobs:** XcodeGen validation, build every shipping target without release secrets, real Xcode test targets, standalone hostile-contract harnesses, Swift/static analysis and packaging smoke tests.

### 7. Make download indexes recoverable

Use a serialized store owner and a two-generation atomic format:

1. encode and validate the next document;
2. fsync/write `index.next`;
3. preserve `index.json` as `index.prev`;
4. atomically replace current;
5. retain checksum/schema metadata.

At launch, recover in order: current → previous → directory scan. Surface degradation in diagnostics and the UI.

### 8. Harden the Android updater

The signed appcast should include URL, expected length, SHA-256, build id and signing-certificate digest. The client should enforce HTTPS, host allow-list and redirect policy, verify bytes and signer, then hand the local verified APK to the installer.

### 9. Eliminate fake settings

Every user-visible setting should satisfy an automated contract:

```text
setting key -> UI owner -> runtime consumer -> default -> backup behavior -> test
```

A missing consumer should fail a wiring test or keep the row out of production.

### 10. Complete or remove dormant migrations

For Source Index, sync v2, vortx-core shadow ranking and YouTube V2, define one of:

- a rollout owner, metrics, kill-switch and target date; or
- deletion/isolation from shipping targets.

Shipping default-off code indefinitely creates a second architecture without buying user value.

## Suggested implementation order

### P0 — release and wrong-state protection

1. Block debug-signed releases and pin the release certificate.
2. Expose libmpv END_FILE reason and fix terminal-state handling.
3. Bind Android offline playback to an explicit PlaybackContext.
4. Reset ExoPlayer terminal state per load.
5. Fix Apple download queue preflight/retry scheduling.

### P1 — durability and enforced verification

1. Make download stores fail visibly and recover from a previous index.
2. Run Android tests/lint and Apple Xcode tests as required checks.
3. Make CodeQL/Semgrep fail closed and protect main.
4. Harden updater URL/artifact verification.
5. Wire or hide Android settings with no consumers.
6. Finish per-profile account switching.
7. Port Android HLS and auto-delete behavior.

### P2 — parity and simplification

1. Batch downloads, trailer derivation and richer Similar results on Android.
2. Source Index rollout decision.
3. Backup schema parity.
4. Remove obsolete HLS/remux player paths.
5. Retire the legacy WKWebView iOS shell.
6. Split oversized state/transport/UI files.

## Regression-test checklist

- Player terminal reducer: EOF/error/stop/replace/duplicate events.
- Error → next successful source on ExoPlayer.
- Repeated mute(true)/mute(false).
- Offline B after online A updates only B.
- Download queue head rejected while later entries start.
- Self-heal never exceeds max concurrency.
- Index write interruption recovers previous data.
- Extensionless HLS and subtitle URLs.
- Cross-origin redirect strips credentials.
- Profile switch swaps account/session before UI publication.
- Every production settings row has a runtime consumer.
- Release APK certificate equals the pinned fingerprint.
- Scanner failure makes CI red, never empty-green.

## Final assessment

VortX is not a thin or mostly-unimplemented Android port. Most of the major product architecture exists on both platforms. The problem is that several **small-looking seams own very large consequences**: terminal event classification, media identity, queue ownership, persistence acknowledgement, signing lineage and whether tests actually execute. Fixing those seams before adding more breadth will produce a larger reliability gain than another round of feature expansion.
