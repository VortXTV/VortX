# Xperience export contract tests

From a macOS checkout with Xcode command-line tools, Node.js and ripgrep available:

```sh
bash scripts/test-xperience-export-contracts.sh
```

The script resolves the repository from its own location, or accepts the repository root as its
first argument. It uses the installed host macOS SDK and targets macOS 14. Nothing depends on a
particular home directory, prior build output, private account, saved credential or archived packet.

This is a component test harness, not a full application build. It copies current production files
directly from `app/SourcesShared`, records their hashes and checks for drift throughout the run.
It does not keep implementation snapshots or apply historical parser/controller/Keychain patches.
Only the complete JSON value, native error, failure-closed credential store, host-field validator
and synchronous prompt-delivery declarations are extracted from larger source files. Unique
declaration markers fail closed if those source boundaries change. The real signer, system
credential adapter, transport, strict parser, models, mapper and controller are current full sources.

## Source and test map

| Test file | Executed coverage |
| --- | --- |
| `app/Tests/XperienceExportConnectorTests.swift` | Official export URL admission/redaction, injected credential CAS/readback/repair, whole-envelope admission, mapper preservation/admission, synthetic HTTP and explicit controller link/reconnect/refresh flows |
| `app/Tests/XperienceMapperWireEqualityTests.swift` | Initial-link/refresh numeric wire variants, exact retained raw fields/tombstones, and explicit/nested/encoded/ambiguous credential rejection; invoked by the connector main |
| `app/Tests/XperienceLifecycleAmendmentTests.swift` | Original credential/native context loss during suspended work, cancellation and unchanged own acknowledgement |
| `app/Tests/XperienceCurationExportPromptLifecycleTests.swift` | Actual PromptState/dispatcher with same-profile loss, unchanged hints, successful/post-save-credential-failure receipts and dismissal |
| `test/xperience-export/fixtures/AppSurfaces.swift` | Synthetic ProfileStore, sign-in publisher and notification-name surface only |

The connector fixture runs once. Its URLProtocol shared-state fixture uses Swift 5 with warnings
as errors. The actual production component is separately typechecked with Swift 6, complete strict
concurrency and warnings as errors. Lifecycle and prompt executables also use Swift 6/complete/WAE.
The prompt executable reuses a generated copy of the lifecycle fixture with only its `@main`
attribute removed; helper methods/assertions remain unchanged and its earlier suite is not invoked
a second time. The prompt main invokes only its own `run()` explicitly. The full SwiftUI view is
not substituted into this non-rendering component harness.

Fixture and generator hashes live in `pinned-fixtures.sha256`, whose digest is hard-coded in the
runner. Updating an assertion, fixture, generator or supervisor requires an explicit reviewed pin
update, not an automatic in-run refresh. Production source hashes are captured once in the retained
run manifest and verified before/after stages; legitimate production changes are exercised as current
source rather than silently replaced with an old passing implementation.

## Bounded execution and receipts

All stages are serial at nice 15, WMO, one compiler job and one compiler thread. Generation and
compiler-version have 30-second deadlines; each compile has 240 seconds; connector runtime has
60 seconds and lifecycle/prompt runtimes have 30 seconds each. The pinned process-group supervisor
provides persisted interrupt requests, bounded TERM/KILL cleanup, direct-child reaping and group
quiescence checks. The wrapper waits for cleanup before releasing its suite slot. An uncertain
receipt retains the slot for reconciliation; do not remove it while a workload may remain alive.
The suite-local slot does not replace coordination with unrelated machine workloads.

Each invocation retains source/generated hashes, toolchain identities, logs, statuses, supervisor
receipts and executables under a fresh `app/build/xperience-export-contracts.*` directory. Success
requires normal exit 0, expected nonzero check-count markers, source integrity and confirmed cleanup.
A compiler error, thrown assertion, crash, timeout, interrupt or missing receipt is never a pass.
Do not commit retained run output or module caches.

## Limits

Tests use synthetic endpoints/keys, an injected in-memory credential backend, fake Store outcomes
and URLProtocol responses. They do not invoke runtime system Keychain operations, a real HTTP/DNS
request or installed app persistence. They do not exercise the actual Store/CoreBridge/facade,
native checkpoint or whole-account export budget. SwiftUI rendering, focus, sheet/full-screen
interaction, platform entitlements, physical devices, account delivery, signing and releases remain
separate gates. Passing this harness is not an application, native-durability or device certificate.
