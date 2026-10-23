# Player property-handle repair — 18 October 2026

## Source change

The native event drain already admits one handle whose destruction is serialized
behind that drain. FILE_LOADED path lookup and enhancement-layer inspection now
receive that admitted handle instead of rereading the controller's shared optional
property. Track count/type/dependency/id lookups use that same handle.

Delayed readahead work borrows a handle when the work starts, not when it is
scheduled. That admission supplies its bitrate/drop/stall reads and cache setters.
The generic scalar/string helpers bind their optional handle once before a native
call, preserving the previous fallback, status, integer-width and free behavior.
Stop ordering, callbacks, EOF recovery, completion thresholds and UI are unchanged.

A raw pointer is not an owner. This is not a universal synchronization repair for
every caller of the shared handle, nor evidence that this caused the reported EOF.

## Retained regression inputs

- `app/Tests/PlayerPropertyHandleSourceUnit.swift` is the fake-ABI fixture template.
- `scripts/player-property-source-unit.cjs` exports pure `prepare` and `accept`
  functions. They extract selected complete production methods, fill the template,
  check routing/preservation contracts and detect four structural regressions.

These files are byte-identical to the inputs used in the retained verification.
The module performs no filesystem/process operations; it is not an application
entrypoint or a compiler runner. It deliberately does not introduce a second
unsupervised compiler path. A separate reviewed, serial source-unit harness supplies
the exact controller text/fixture, compiles the generated Swift 5 unit and passes
the observed normal process result to `accept`. `prepare` returns the generated
unit, adapter text and extraction hashes. The `red` and `green` expectations are
explicit; a compilation failure, signal or timeout is not a behavioral RED.

The fixture is a template, not a normal app-target source file. Its deterministic
stored-work collaborator does not emulate real native threads or destruction.
The extractor fails closed on its known declaration/brace shape and method count;
it is not a general Swift parser.

## Observed source-unit results

| Phase | Compiler | Binary | Observed result |
| --- | --- | --- | --- |
| Original source | Normal 0 | Normal 1 | 29 behavior checks with exactly 13 expected failures; six source contracts with four routing failures |
| Repaired source | Normal 0 | Normal 0 | 29 behavior checks, six source contracts and four detected structural mutations: 39 passing checks |

Both phases used the same fixture, extraction/assertion module, tool policy and
one low-priority compile/test slot. Source, captured inputs, commands, executable,
results and selected tool-tree fences were retained. Compiler logs contain denied
xcrun temporary-cache writes; the compiler still completed normally and no sandbox
policy was relaxed. Logs are combined stdout/stderr, not proof of empty stderr.

The checks cover nil transitions, borrowed-handle routing, ramp execution-time
admission, preserved zero/raw/error/NaN and native-width behavior, and string/free
semantics. They do not prove a full controller SDK/actor build, actual libmpv
lifetime/concurrency/queue behavior, device playback or measured responsiveness.
No app/SDK/package build, playback, installation, account write or release was
performed. Physical EOF and performance acceptance remain separate.
