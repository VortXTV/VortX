# Watch Party async regressions

Run from the repository root on macOS with Python 3.9 or later, a Swift 6 toolchain and the macOS SDK installed:

```sh
python3 scripts/test-watch-party-regressions.py
```

The runner builds separate standalone Session and panel-model executables from the production sources in `app/SourcesShared`. The model and account-auth helpers are extracted from their production owner files; the tests do not redeclare them. Generated sources, compiler caches and executables belong under `app/_build/watch-party-regressions`.

Unique raw source-region fences delimit the genuine auth and model prefixes. Each run retains their whole-source and byte-range hashes in `sources.json`, compiler/test logs and a `result.json` with source conservation and actual step results. The runner uses strict Swift 6, complete concurrency checks, warnings as errors and one compiler job. The two builds run sequentially with one owned module cache; a file lock rejects a concurrent invocation. Keep the accompanying build-directory `.gitignore` so generated output stays local.

The suite contains 12 Session regression groups and 4 actual panel-model regression groups. Session coverage includes lease-proof replacement and member-refresh races, retired/unknown nonces, generation and socket ownership, reservation/publication outcome correlation, metadata callbacks, startup admission, and ordered own-echo handling. Model coverage includes readiness coalescing behind a slow outbound, snapshot capture after a newer local seek, cancellation before replay task entry, and draining the latest queued seek without an old own echo rewinding local playback.

`ControlledTransport.swift` supplies queued synthetic HTTP replies, stable socket objects, and a manual clock with controlled asynchronous sleep handles. Selected canceled HTTP, receive and timer work can be retained and completed late. This preserves the historical stale receive/timer regression: old work must not mutate or close a fresh connection. Other pending continuations are released during cleanup. Bounded task yields and process timeouts make scheduling failures observable without elapsed wall-clock sleeps.

`PlaybackFacades.swift` supplies only the native/playback type shapes needed by these isolated sources. Authentication capture uses a real isolated credential registry with synthetic account-session values. HTTP response and transport types, wire encryption, admission, Session and panel-model behavior come from production sources. Generated invite keys and encrypted outbound controls stay in memory and are never printed.

These tests validate the controlled asynchronous schedules and their assertions. They do not launch a GUI, contact a network service, use a real account or Keychain, run a native player, build the full app, or establish device/release correctness.
