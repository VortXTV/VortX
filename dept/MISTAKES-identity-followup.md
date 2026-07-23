# VortX — identity-boundary FOLLOW-UP lane — Mistakes Ledger

Standing, append-only record for this lane only (`fix/identity-boundary-followup`,
`/Users/daksh/vortx-identity-followup`). Every mistake, hallucination, and CEO redirection or
correction gets recorded here — by any seat, including this secretary — so future agents working
this lane learn from it instead of repeating it, looping, or causing a regression.

**Rules for this document:**
- Append-only. Entries are never softened, edited to look better, or deleted after the fact. If a
  fact in an entry turns out wrong, add a correction note under it — do not rewrite history.
- Tag: `MIS-<yymmdd>-<nn>`, sequential per day, never reused.
- Each entry records: what happened, the root cause (not just the symptom), and the guardrail that
  prevents a repeat.
- Read this file (and the live log's Current-state block) before starting any work in this lane.

---

## Entries

### MIS-260722-01 — department head (manager) mistake, counts double
**What:** reported a build as passing on the strength of "exit code 0" when the command was
`xcodebuild ... 2>&1 | tail -30`. The exit code belonged to `tail`, not `xcodebuild`; the build had
actually FAILED with "'app/VortX.xcodeproj' does not exist."
**How caught:** the head grepped for the literal `** BUILD SUCCEEDED **` string as the CEO's
acceptance bar demands, got a count of 0, and re-read the output.
**Root cause:** a piped command's `$?` is the LAST element of the pipeline. Trusting it silently
inverts a failure into a pass.
**Lesson/guardrail:** never accept a pipeline's exit status as a build result. Either run the build
unpiped and check `$?`, or assert on the literal `** BUILD SUCCEEDED **` string. Note this is
exactly why the CEO worded the acceptance bar as "read the literal `** BUILD SUCCEEDED **`" rather
than "the build passes".

### MIS-260722-02 — adversarial verifier (Specialist seat) reached a wrong conclusion from a correct method
**What:** finding F-2 asserted `canImport(VortxEngine)` is false "in this repo" and that no
`*VortxEngine*` exists anywhere in the tree, concluding the VortxBridge changes had zero
type-check coverage.
**How caught:** the department head found `app/Vendor/` is gitignored wholesale (`.gitignore:31`)
and that the sibling worktree DOES contain `VortxEngine.xcframework`; after cloning it in, an
`#error` probe proved `canImport` is true (WHY-260722-03).
**Root cause:** the verifier's fixtures and reasoning were sound, but its environment was silently
incomplete — a fresh worktree lacks every gitignored build artifact, so "not found in the tree"
meant "not present in this checkout", not "not part of the project".
**Lesson/guardrail:** absence-of-evidence claims about a repo must state which checkout they were
made in and confirm the path is not gitignored before concluding a component does not exist.
Cross-reference FAIL-260722-01.

### MIS-260722-03 — the lane shipped a fresh over-assertion while fixing an over-assertion.
**What:** the round that fixed the F-1 collision replaced a false absolute doc claim with a NEW
false absolute doc claim ("can therefore never format the same token"), falsified by Unicode
canonical equivalence.
**How caught:** the independent re-verification agent tested the claim with a three-line fixture
instead of reading it.
**Root cause:** the fixer reasoned about the token's STRUCTURE (byte layout of the format string)
and wrote "never" about STRING EQUALITY, which in Swift is canonical equivalence, not byte
equality. The structural reasoning was correct; the claim generalized past it.
**Lesson/guardrail:** when writing an absolute claim about identifier equality, name the equality
relation being claimed ("byte for byte", "up to Swift String equality") — an unqualified "never"
invites exactly the one-fixture falsification this lane exists to prevent. Cross-reference
WHY-260722-05.
