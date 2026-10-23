# Curation defaults component tests

From a macOS checkout with Xcode command-line tools, Node.js and ripgrep available:

```sh
bash scripts/test-curation-defaults.sh
```

The runner resolves the repository from its own location or accepts the repository root as its
first argument. It uses the installed macOS SDK and its real XCTest framework/support library,
targeting macOS 14. No machine-specific directory, earlier build output, account or saved credential
is required. This is a focused component harness, not an application build.

## Source and coverage

The generator reads current production Feed, Model, signer, transport, common models and archive
dependencies from `app/SourcesShared`. It copies those files whole and records their hashes.
Complete JSON/error, lifecycle snapshot/transition/clock and host-field validator declarations
are extracted from larger actual source files with unique boundary guards. It does not duplicate
the implementation or replace current code with stored snapshots.

The production compile lane uses the original transport singleton initializer. For runtime only,
one exact constructor line becomes `AuthenticatedHTTPTransport(protocolClasses:
[DefaultsURLProtocol.self])`, using the existing injection initializer. All request, streaming,
redirect and cancellation algorithms remain actual production code. The catch-all URLProtocol
responds only with synthetic fixtures and cannot forward to a real network request.

| Test suite | Cases and coverage |
| --- | --- |
| `app/Tests/CurationDefaultsTests.swift` | 10 cases: complete envelope/public-base validation, duplicate and unsafe input, retained unknown fields, fixed-origin admission, cancelled joiner, noncooperating stop, late A→B→A results, freshness/retry/stale-age, clock rollback and authorization/not-found cache retirement |
| `app/Tests/CurationDefaultsClientTests.swift` | 7 cases: actual client request/signature shape, whole-envelope rejection, HTTP/transport mapping, streaming cap/3xx rejection, stale-before/during stamping, stale-after-response and caller cancellation |

`Main.swift` uses real Apple XCTest discovery and execution. It requires all original method names
exactly once, 10+7 discovered/executed cases, zero skips/failures and successful suite results.
It does not substitute assertion implementations or call test methods outside XCTest. A final
17-case marker is required by the wrapper.

App-global RemoteConfig, sign-in and MOAT surfaces are synthetic. Default starter loading traps;
model tests explicitly inject their fallback. The actual signer is compiled, but the executable
first requires that its bundle has no production signing key. Only empty-key fixture signature
shape is tested, not credential validity or server authentication.

## Bounds and retained evidence

The fixture/helper/generator manifest is statically pinned by the runner. Updates require explicit
review and pin changes; a run does not repin itself. All production inputs, generated outputs,
extracts and the transport transformation receive retained hashes, checked before and after stages.

All stages are serial at nice 15. Both compiles use Swift 6, complete strict concurrency, warnings
as errors, WMO, one compiler job and one compiler thread. Generation/compiler-version deadlines are
30 seconds, each compile 240 seconds and XCTest runtime 60 seconds. The pinned process-group
supervisor provides persisted interrupt requests, bounded TERM/KILL cleanup, direct-child reaping
and group-quiescence checks. The wrapper waits for cleanup before releasing its suite slot; an
uncertain receipt retains the slot for reconciliation. Do not delete an occupied slot without
checking its owner. The suite-local slot does not coordinate unrelated machine workloads.

Each invocation retains source hashes, toolchain identities, generated files, logs, statuses,
supervisor receipts and compiled artifacts under a fresh `app/build/curation-defaults-tests.*`
directory. Success requires normal exit 0, exact XCTest counts, source integrity and confirmed
cleanup. Crashes, timeouts, interrupts, assertion failures and incomplete discovery are not passes.
Retained run output and module caches must not be committed.

## Limits

This harness does not exercise real RemoteConfig/account/MOAT acquisition, production signing
credentials, starter/Discover loaders, profile persistence, native checkpoints, Home/Library
integration or rendering, physical devices, live HTTP/provider/backend, deployment or releases.
Compiling the full archive dependency is not a claim of exhaustive archive test coverage.
