# VortX — identity-boundary FOLLOW-UP lane — Live Log

Worktree: `/Users/daksh/vortx-identity-followup`
Branch: `fix/identity-boundary-followup`
Parent lane: `fix/identity-boundary-correction` (worktree `/Users/daksh/vortx-identity-fix`, tip `4a6c9cf`)

Tagging convention: `WHY-<yymmdd>-<nn>` for decisions, `FAIL-<yymmdd>-<nn>` for failures (status
`open` -> `root-caused` -> `fixed`, updated in place, never re-numbered), `MIS-<yymmdd>-<nn>` for
mistakes (logged in `MISTAKES-identity-followup.md`, cross-referenced here by tag only), and real
git short SHAs for actual code changes. This file's own maintenance events (doc creation, etc.)
are logged plainly, dated, untagged, since they are neither a decision, a failure, nor a code diff.

---

## Current state

*(Overwritten in place as work proceeds — this is the single source of truth for "where things
stand right now." History lives only in the Chronological record below.)*

- **Status: COMMITTED.** All three sites (SITE-1, SITE-2, SITE-3) are complete and verified. The
  work is committed as `a71467c` on branch `fix/identity-boundary-followup` in
  `/Users/daksh/vortx-identity-followup` (parent `f421a49`). **Not pushed** — the branch has no
  upstream configured (`git rev-parse --abbrev-ref @{u}` errors "no upstream configured") and no
  remote-tracking branch contains `a71467c` (`git branch -r --contains a71467c` is empty) — per CEO
  instruction.
- **`dept/` is untracked by design, not an oversight.** `git log --all -- dept/` is empty: `dept/`
  has never been tracked anywhere in this repo's history, so it is lane scaffolding rather than
  repo content, and was deliberately excluded from the commit to keep the review diff clean for an
  adversarial reviewer. It is not gitignored (`git check-ignore` finds no rule for it), so it can
  still be added later if the CEO wants it tracked.
- **Diff size:** the commit itself (`f421a49..a71467c`) is 11 files changed, 746 insertions(+), 178
  deletions(-), all under `app/`. The full lane review diff for an adversarial reviewer is
  `4a6c9cf...a71467c` — 13 files, 761 insertions(+)/180 deletions(-), the +2 files being
  `CHANGELOG.md` and `app/SourcesShared/WhatsNew.swift`, both docs-only, picked up from the `beta`
  merge at `f421a49` (see WHY-260722-01 for why this is the correct base, not a beta-relative
  diff).
- **Acceptance bars — all met, each personally verified by the department head against real
  artifacts (not agent reports):**
  * Forging the media-server identity is a compile error — verified by two independent adversarial
    agents writing their own fixtures across 8+ construction routes (SE-0189 direct init, nested
    storage assignment, synthesized memberwise init, direct fileprivate init, cross-file Decodable
    synthesis, hand-written `init(from:)`, `RawRepresentable`, and a second file literally named
    `SourceIndexIdentity.swift`), plus a mutation proof that re-opens every forge when the seal is
    widened.
  * The 4 view call sites pass typed values — and the parameters now have NO defaults, so omitting
    them fails to compile.
  * App builds — final CLEAN build of both targets: VortXiOSNative and VortXTV each produced a
    literal `** BUILD SUCCEEDED **` with real (unpiped) exit code 0, zero errors, and no new
    warnings in any changed file.
  * Existing identity suites pass — the department head re-ran all four personally: lifecycle
    EXIT_1=0, caller gate EXIT_2=0, TorBox boundary EXIT_3=0, torrent contract EXIT_4=0, all
    reporting ALL PASS including the caller gate's MUTANT red-checks.
- **Known residuals, explicitly accepted (not defects):** `unsafeBitCast`/unsafe pointer writes can
  forge any sealed Swift value type including the parent lane's `PublicationTarget`
  (memory-safety opt-out, out of threat model); token injectivity holds up to Swift String
  equality i.e. Unicode canonical equivalence, which is the comparison every consumer uses and is
  not exploitable (verified: `MediaServerSource`'s own `fetchKey` and cache fold identically); the
  seal governs token SHAPES, not who may claim to be a page.

---

## Chronological record

### 2026-07-22 — Secretary docs created (untagged, administrative)
Created `dept/LOG-identity-followup.md` and `dept/MISTAKES-identity-followup.md` in this
worktree. Verified every seeded fact below directly against the repo (see citations); nothing in
this log is taken on trust from the dispatch prompt alone except where explicitly marked. No
production files were read for edits and none were modified — this session is doc-only, per the
secretary's standing scope.

### f421a49 — Lane created: `fix/identity-boundary-followup` branched from `4a6c9cf`, `beta` merged in
Verified via `git log --oneline --graph`:
```
*   f421a49 Merge branch 'beta' into fix/identity-boundary-followup
|\
| * 89c246e docs(release): beta 7 changelog and the missing debrid what's new entry
| * 71bb047 docs: correct Android TV scope in changelog to match shipped code
* | 4a6c9cf fix(apple): make identity forging a compile error and type the main merge gate
* | 9a017a1 fix(apple): seal auxiliary source identity pipeline
* | 7bc86c3 fix(apple): fence auxiliary sources by typed identity
|/
* 8992132 feat(tvos): multi-track audio and embedded subtitles on the dolby vision lane
```
`4a6c9cf` is the parent lane's tip (branch `fix/identity-boundary-correction`, worktree
`/Users/daksh/vortx-identity-fix`, confirmed via `git -C /Users/daksh/vortx-identity-fix branch
--show-current`). The two commits merged in from `beta` (`89c246e`, `71bb047`) are confirmed
docs-only via `git show --stat`:
- `71bb047` — `CHANGELOG.md` only (2 lines changed).
- `89c246e` — `CHANGELOG.md` + `app/SourcesShared/WhatsNew.swift` (13 lines added, both release
  copy).

No app source file changed by the merge itself — the merge is a pure ancestry/prerequisite move,
not a functional one.

### WHY-260722-01 — Base off the parent lane, then merge `beta`, to satisfy both "off beta" and the typed-identity prerequisite
The CEO asked for a worktree "off beta." Verified this is **not** literally satisfiable in a pure
sense: `git merge-base 4a6c9cf origin/beta` = `8992132`, and `git merge-base --is-ancestor 4a6c9cf
origin/beta` returns false — `4a6c9cf` is **not** an ancestor of `beta`. The typed identity types
this follow-up lane depends on (`SourceIndexIdentity.PublicationTarget` / `TargetResolution` /
`MergeAuthorization`, confirmed present at `app/SourcesShared/SourceIndexIdentity.swift:132`,
`:195`, `:162`) exist only on the parent lane (introduced across `7bc86c3` / `9a017a1` / `4a6c9cf`
on `fix/identity-boundary-correction`), so a pure-`beta` base cannot compile the follow-up code at
all.
**Resolution:** branch from `4a6c9cf` (parent lane tip, carries the prerequisites) and merge `beta`
into it (`f421a49`, 2 docs-only commits). This satisfies both constraints simultaneously — the
branch *contains* `beta`, and the prerequisites are present so the lane's fixes actually compile.

### SITE-1 — `SourceListModel.setContext(...)`'s `auxiliaryContentID` parameter is a raw `String?` witness
Verified full signature at `app/SourcesShared/SourceListModel.swift:168-169`:
```swift
func setContext(metaId: String, streamId: String?, continuity: String?, pin: ResolvedPin?,
                auxiliaryContentID: String? = nil, mediaServerTargetID: String? = nil) {
```
The field's own doc comment (`SourceListModel.swift:69-75`) states plainly: *"The page's WITNESS
token for the TorBox + Singularity merges. This is the one identifier the view layer still hands
over as a raw `String?` ... It is never formatted into output, a key, a request, or a log line."*
It is inert by construction — `SourceIndexIdentity.mergeAuthorization` (called at
`SourceListModel.swift:244-247`) is what actually gates the merge, comparing this raw witness
against each auxiliary source's SEALED `publishedTarget`.
**4 view call sites, verified by grep on `auxiliaryContentID:`:**
- `app/SourcesiOS/iOSDetailView.swift:2408`
- `app/SourcesiOS/iOSDetailView.swift:2420`
- `app/SourcesiOS/iOSDetailView.swift:4226`
- `app/SourcesTV/DetailView.swift:2011`
(Matches the 3-in-iOS / 1-in-tvOS split stated in the dispatch exactly.)

### SITE-2 — media-server merge lane merges on a raw page token, not a typed value
Verified at `app/SourcesShared/SourceListModel.swift:253-254`:
```swift
let mediaTarget = ctx.mediaServerTargetID
let mediaServerGroups = mediaTarget != nil && mediaServers.publishedContentID == mediaTarget
    ? mediaServers.groups : []
```
Both sides of this `==` are raw `String?`. The code's own comment at
`SourceListModel.swift:275-277` names this explicitly as the remaining gap: *"The TorBox and
Singularity merges REQUIRE the typed authorizations snapshotted above; the media-server lane still
compares its own raw page token."* `mediaServers.publishedContentID` is set in
`app/SourcesShared/MediaServerSource.swift:48` from a `target` string built at
`MediaServerSource.swift:40-43` (either the raw imdb id, or `"\(idKey):\(season):\(episode)"`).
Confirmed the non-IMDb fallback tokens the dispatch describes exist and are real, at:
- `app/SourcesiOS/iOSDetailView.swift:2170` — `sourceContentID ?? "meta:\(id)"`
- `app/SourcesiOS/iOSDetailView.swift:4265` — `episodeContentID ?? "meta:\(meta.id)|video:\(shownVideo.id)"`
- `app/SourcesTV/DetailView.swift:2491` — `"meta:\(libraryID)|video:\(videoID)"`
These are deliberately non-IMDb (title/year- or library-id–keyed fallback pages), which is exactly
why they cannot ride `PublicationTarget` (an IMDb/tmdb-rooted sealed type) as-is — a real
structural reason this site is harder than SITE-1, not just unaddressed.

### SITE-3 — `VortxShadowRanking.observe(metaId:)` takes a raw `metaId`, lowest severity
Verified at `app/SourcesShared/VortxBridge.swift:142-143`:
```swift
static func observe(groups: [CoreStreamSourceGroup], continuity: String?, pin: ResolvedPin?,
                    cachedHashes: Set<String>, prefs: SourcePreferences.Snapshot, metaId: String) {
```
Called from `app/SourcesShared/SourceListModel.swift:336-338` with `metaId: ctx.metaId` (the raw
`Context.metaId` field, `SourceListModel.swift:67`). Severity confirmed lowest of the three:
- Sink is `os.Logger` only (`VortxBridge.swift:130`, `.error("shadow[\(metaId, privacy:
  .public)]...")` at `VortxBridge.swift:182`) — **not** the exportable diagnostics file
  (`SourceIndexDiag`, defined separately in `SourceIndexIdentity.swift`); no cross-reference
  between the two found.
- Flag-gated OFF by default: `VortxShadowFlag.isOn` (`VortxBridge.swift:22-24`) reads
  `UserDefaults.standard.bool(forKey:)`, which defaults to `false` when unset — confirmed no
  code path sets this key to `true` by default. The guard at `VortxBridge.swift:144`
  (`guard VortxShadowFlag.isOn else { return }`) short-circuits before `metaId` is ever used when
  the flag is off.

### Identity suites and their literal compile commands
Read verbatim from each file's header comment (quoted exactly, not paraphrased):

**`app/Tests/SourceIndexSourceListLifecycleTests.swift`**
```
xcrun swiftc -strict-concurrency=complete -warnings-as-errors -o /tmp/source-list-lifecycle-test \
  app/SourcesShared/SourceIndexContract.swift \
  app/SourcesShared/SourceIndexIdentity.swift \
  app/SourcesShared/SourceListModel.swift \
  app/Tests/SourceIndexSourceListLifecycleTests.swift && /tmp/source-list-lifecycle-test
```

**`app/Tests/IdentityCallerGateTests.swift`**
```
xcrun swiftc -warnings-as-errors -o /tmp/identity-caller-gate \
  app/Tests/IdentityCallerGateTests.swift \
  && /tmp/identity-caller-gate
```

**`app/Tests/TorBoxIdentityBoundaryTests.swift`**
```
xcrun swiftc -D SOURCE_INDEX_IDENTITY_TESTING -warnings-as-errors -o /tmp/torbox-identity-boundary \
  app/SourcesShared/SourceIndexContract.swift \
  app/SourcesShared/SourceIndexIdentity.swift \
  app/SourcesShared/TorBoxSearchSource.swift \
  app/Tests/TorBoxIdentityBoundaryTests.swift && /tmp/torbox-identity-boundary
```

**`app/Tests/SourceIndexTorrentContractTests.swift`**
```
xcrun swiftc -D SOURCE_INDEX_IDENTITY_TESTING -o /tmp/source-index-contract-test \
  app/SourcesShared/SourceIndexContract.swift \
  app/SourcesShared/SourceIndexIdentity.swift \
  app/SourcesShared/MoatToken.swift \
  app/SourcesShared/SourceIndexClient.swift \
  app/SourcesShared/TorBoxSearchSource.swift \
  app/Tests/SourceIndexTorrentContractTests.swift && /tmp/source-index-contract-test
```

None of these four commands have been run in this session (secretary scope is docs-only). Running
them and recording pass/fail is production-lane work for the next dispatch.

### Acceptance bar (seeded, CEO-set — not yet attempted)
- Forging the media-server identity must become a **compile error** (closes SITE-2).
- All 4 view call sites (SITE-1) pass a **typed** value, not raw `String?`.
- The app **builds** — literal `** BUILD SUCCEEDED **` in the build log is the bar, not "looks
  fine."
- The four identity suites above **still pass** after the fix.
- **Do not push** this branch.

### WHY-260722-02 — media-server identity got its own sealed type rather than widening PublicationTarget
Media-server lookup legitimately serves IMDb-less pages (title/year matching), so its page token
is deliberately broader than PublicationTarget's canonical-IMDb contract. Widening
PublicationTarget would break the one invariant every other consumer depends on. Instead a new
sealed `SourceIndexIdentity.MediaServerTarget` reuses the *sealing pattern* (nested `private struct
Storage` behind one `private let`, get-only computed view, explicit `fileprivate init` suppressing
the memberwise init) but not the type. Construction only via factories in
`SourceIndexIdentity.swift`: one deriving the token from an already-sealed `PublicationTarget`, one
taking the raw parts so the identity file formats the `meta:<id>` / `meta:<id>|video:<id>` shape
itself. A sealed `MediaServerMergeAuthorization` now gates `MediaServerSource.merge`. The
string-witness factory `mergeAuthorization(published:pageContentID:)` was REPLACED (not kept
alongside) by a sealed-to-sealed `mergeAuthorization(published:page:)`, because leaving a public
raw-string route would defeat the lane.

### FAIL-260722-01 — status: fixed. A fresh worktree of this repo is not build-ready
Symptom: `xcodegen generate` failed in `/Users/daksh/vortx-identity-followup` with "Target
VortXMac/VortXTV has a missing source directory .../app/Resources/server.js" and
node-darwin-arm64; after that was resolved, `xcodebuild` failed with "There is no XCFramework
found at .../app/Vendor/{NodeMobile,StremioXCore,VortxEngine}.xcframework".
Root cause: those paths are gitignored build artifacts, not tracked source — `.gitignore:31`
ignores `app/Vendor/` wholesale, `:34` `server.js`, `:38` `node-darwin-arm64`, `:60`
`app/Resources/fonts/`. A worktree created with `git worktree add` therefore starts without them.
Fix: APFS-cloned (`cp -Rc`) `app/Resources/{server.js,node-darwin-arm64,fonts}` and the whole
`app/Vendor/` directory from the sibling worktree `/Users/daksh/vortx-identity-fix`, then re-ran
`xcodegen` and `xcodebuild` successfully.
Guardrail for future lanes: after `git worktree add` on this repo, copy those four paths before
attempting any Xcode build; a "missing source directory" or "no XCFramework found" error means
missing artifacts, NOT a code defect.

### WHY-260722-03 — proved `canImport(VortxEngine)` is true rather than assuming it
An adversarial verifier reported (finding F-2) that the `#if canImport(VortxEngine)` block in
`VortxBridge.swift` had zero type-check coverage, concluding the engine is absent from the repo.
That conclusion came from grepping a worktree that was missing the gitignored `app/Vendor/` (see
FAIL-260722-01). After cloning `Vendor/` in, the department head injected
`#error("PROBE: ENGINE IS IMPORTABLE IN THIS TARGET")` inside the `#if` and rebuilt: the build
failed with exactly that error at `VortxBridge.swift:2:8`, proving the branch is compiled in
VortXiOSNative. The probe was then reverted and the restored file confirmed byte-identical to its
pre-probe state. F-2 is therefore closed by compilation, not by argument. Method note: this is the
same doctrine the lane's own test suite follows — a guard that cannot be shown to fail is not
verified.

### Adversarial findings (round 1) — dispositions
- **F-1 HIGH**, `app/SourcesShared/SourceIndexIdentity.swift` — the IMDb-less fallback token
  encoding is NOT injective: the `|video:` separator is caller-injectable, so
  `mediaServerTarget(metaID: "kitsu:42|video:kitsu:42:7")` and
  `mediaServerTarget(metaID: "kitsu:42", videoID: "kitsu:42:7")` produce the byte-identical token
  and the merge gate authorizes a cross-page merge. Confirmed end-to-end against the real
  `SourceListModel`. Pre-existing in shape (the old inline formatting collided identically) but the
  lane took ownership of the format and asserted in shipping doc that it cannot happen.
  DISPOSITION: fix round, reject `|` in both parts to make the encoding injective by construction.
- **F-2 MEDIUM**, `VortxBridge.swift` — CLOSED by the department head, see WHY-260722-03. No
  action.
- **F-3 MEDIUM**, `SourceIndexIdentity.swift` — production doc comment makes an absolute claim ("a
  pre-baked token string cannot be smuggled in: every token in existence was formatted or derived
  by the factories below") falsified by both F-1 and F-6; this is the same class of over-assertion
  commit `4a6c9cf` was written to punish. DISPOSITION: fix round, qualify the claim.
- **F-4 MEDIUM**, `app/Tests/SourceIndexSourceListLifecycleTests.swift` — two inherited "CAPTURED
  COMPILER OUTPUT (literal)" header lines do not reproduce (claims 13:14/14:14/15:14/16:14 and
  6:24/6:14; actual 5:14/6:14/7:14/8:14 and 5:24/5:14 plus two omitted errors). Inherited from
  `4a6c9cf`. DISPOSITION: fix round, re-capture real output.
- **F-5 LOW-MEDIUM**, `SourceListModel.swift` — `.absent` <-> `.mismatch` is now an identity change
  (previously a no-op), blanking engine rows too for up to one 250 ms coalescer window.
  DISPOSITION: fix round, have `OutputIdentity` carry the derived content id rather than the
  resolution enum.
- **F-6 LOW**, `SourceIndexIdentity.swift` — `unsafeBitCast` / `withUnsafeMutableBytes` forge the
  sealed value. Out of scope: forges any sealed Swift value type including the parent lane's
  accepted `PublicationTarget`; an explicit memory-safety opt-out, not a construction route.
  DISPOSITION: no code change, doc qualification only (folded into F-3).
- **F-7 LOW**, `SourceListModel.swift` vs `MediaServerSource.swift` — asymmetric defaulting:
  `refresh(publicationTarget:)` fails loud with no default, `setContext` keeps defaults so a future
  view silently gets a dead merge lane. DISPOSITION: fix round, remove the defaults.
- **F-8 LOW**, `SourceListModel.swift` — `validatedTarget` in the rebuild signature path builds an
  `NSRegularExpression` per call, drifting from the stated "cheap reads" / "O(1)-ish" invariant.
  Negligible real cost. DISPOSITION: fix round, correct the comments only, no caching.
- **F-9 LOW**, `VortxBridge.swift` — `let meta = metaToken` is now a dead alias. DISPOSITION: fix
  round, remove.
- **F-10 LOW**, `TorBoxSearchSource.swift` + `SourceIndexClient.swift` — orphaned
  `publishedContentID` derived views with no production consumers. DISPOSITION: fix round, remove
  and update the four test references.
- **F-11 LOW**, implementer report only — imprecise line-range citations. No code impact.

### FAIL-260722-02 — status: fixed. tvOS build failed on infrastructure, not code.
Symptom: VortXTV build exit 65 while VortXiOSNative passed on the same tree. Errors were
`accessing build database ".../XCBuildData/build.db": disk I/O error`, `unable to read PCH file
...VortXTV-primary-Bridging-header.pch: 'No such file or directory'`, and `cannot open constant
extraction protocol list input file`.
Diagnosis: all three are BUILD-SYSTEM failures, not compiler diagnostics — none names a source
file and line, which is how a Swift type error presents. Disk had 297 GB free, so not capacity.
Root cause: corrupted incremental build database in DerivedData.
Fix: moved the project's DerivedData aside and ran a clean build; both targets then produced
literal `** BUILD SUCCEEDED **`.
Guardrail: distinguish build-system errors from compiler diagnostics before assigning anyone to
chase a code bug. A compiler error cites file:line; a build-database or PCH error does not.

### WHY-260722-04 — the injectivity fix: reject the separator rather than escape it.
Adversarial finding F-1 showed the fallback token encoding was not injective:
`mediaServerTarget(metaID: "kitsu:42|video:kitsu:42:7")` and `mediaServerTarget(metaID: "kitsu:42",
videoID: "kitsu:42:7")` formatted the byte-identical token, and `mediaServerMergeAuthorization`
then authorized a cross-page merge (confirmed end-to-end against the real `SourceListModel`). The
distinction that had been missed: SEALING controls WHO can build a token; INJECTIVITY controls
whether two DIFFERENT pages can build the SAME one. The lane had fixed only the first while
asserting both.
Decision: reject `|` in every fallback part via one shared gate (`mediaServerFallbackPart`, which
also applies the 128-byte cap so a future third part cannot apply one and forget the other),
rather than escaping. Reasons: injectivity becomes a property of construction rather than
convention (a one-part token contains no `|`, a two-part token exactly one, so `meta:A` can never
equal `meta:A'|video:B'`); rejecting is how this file already resolves ambiguity (`contentKey`
rejects a partial coordinate pair instead of widening it); and a `|` in a real meta/video id is
pathological, so failing closed costs at most the media lane on one degenerate page while failing
open costs a cross-page merge of the user's own files.
Independently re-verified: 60+ crafted adversarial inputs plus a 67,340-statement structural brute
force found 0 collisions — and the same search finds 36 collisions when the `|` rejection alone is
removed, proving the search has teeth and that line is load-bearing.

### WHY-260722-05 — doc claims were rewritten to be literally true, twice.
Two rounds of over-assertion were caught and corrected, in a lane whose parent commit (`4a6c9cf`)
exists precisely because a comment asserted something false. First: "a pre-baked token string
cannot be smuggled in: every token in existence was formatted or derived by the factories below" —
falsified by both the F-1 collision and `unsafeBitCast`. Second, introduced by the fix itself: "Two
different (metaID, videoID) statements can therefore never format the same token" — falsified by
Unicode canonical equivalence, since Swift String equality is canonical, not byte-wise, so
"caf\u{00E9}" (5 UTF-8 bytes) and "cafe\u{0301}" (6 bytes) produce tokens that compare equal and
authorize each other. Both now state exactly what holds and what does not. A supporting exhaustive
scan of all Unicode scalars confirmed no scalar other than U+007C canonically decomposes to
anything containing `|` (non-trivial, because canonical decomposition CAN reach ASCII, e.g. U+1FEF
decomposes to a backtick), so the structural argument survives normalization.

### Adversarial round 2 (post-fix re-verification) — outcome.
FIX-1 through FIX-8 all VERIFIED by an independent agent producing its own evidence; REGRESSED:
none. The stale-episode fence and the absent<->mismatch no-op were confirmed simultaneously by
execution (23/23 checks on an independent driver over the real `SourceListModel`), including the
harder E2 -> mismatch -> E3 path. Four residual LOW/INFO findings (F-A unicode doc claim, F-B
unpinned half of FIX-3, F-C invented provenance in the test header, F-D/F-E scope edges) were all
closed in a final polish round; F-B's pin was proven to go RED when the line it guards is
reverted.

### a71467c — the lane, committed
Subject line: `fix(apple): type the last three raw identifier sites on the merge path`. Closes
SITE-1, SITE-2, and SITE-3 (see their entries above) — all three raw-identifier sites on the merge
path named at lane creation are now typed. Stats verified directly: `git diff --shortstat f421a49
a71467c` and `git show --stat a71467c` both report 11 files changed, 746 insertions(+), 178
deletions(-), all under `app/`; parent confirmed as `f421a49` via `git rev-parse HEAD^`.
**Not pushed**, per CEO instruction — verified `git rev-parse --abbrev-ref @{u}` has no upstream to
report, and `git branch -r --contains a71467c` returns nothing across every configured remote
(`origin`, `jbecker`, `origami`, `stremiox-core-private`, `vortx-core-private`).
**The review diff for an adversarial reviewer is `4a6c9cf...a71467c`, not a diff against `beta`.**
`beta` lacks the typed identity types this lane depends on entirely — the prerequisite types
(`PublicationTarget` / `TargetResolution` / `MergeAuthorization`) exist only on the parent lane's
tip `4a6c9cf` (see WHY-260722-01), so a beta-relative diff would show those types materializing
from nothing instead of the actual follow-up work. `4a6c9cf...a71467c` is 13 files,
761 insertions(+)/180 deletions(-) (verified via `git diff --shortstat`), the +2 files over the
single-commit stat being `CHANGELOG.md` and `app/SourcesShared/WhatsNew.swift` — both docs-only,
carried in by the `beta` merge at `f421a49`.
**Build prerequisite for any reviewer:** a fresh worktree of this repo is not build-ready as
cloned. Copy the gitignored build artifacts — `app/Vendor/` plus
`app/Resources/{server.js,node-darwin-arm64,fonts}` — in before attempting any Xcode build, or
`xcodegen`/`xcodebuild` will fail on a missing source directory / missing XCFramework that reads
like a code defect but is not one (see FAIL-260722-01; re-confirmed here via `git check-ignore -v`
on all four paths).
**The commit body carries its own reasoning, not just a diff.** It documents the
sealing-vs-injectivity distinction in its own words (sealing decides who may build a token;
injectivity decides whether two different pages may build the same one) and cross-references the
two doc-over-assertion corrections this lane made and caught in itself (see WHY-260722-05: the
pre-fix absolute claim falsified by the F-1 collision, and the fresh absolute claim the fix itself
introduced, falsified by Unicode canonical equivalence) — so a reviewer reading `git show a71467c`
directly gets the reasoning without needing these docs.
