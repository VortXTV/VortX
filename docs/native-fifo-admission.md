# Native read admission and save ordering

`VortxNativeFIFOAdmission` records ownership of the existing Facade `native_state`
task chain. It does not create a second scheduler, a background import or a new
checkpoint writer.

An asynchronous provider read starts with the original account/profile/registry
bindings and source authority. Capture is allowed only while the save queue is
quiet. The same read capability must survive the provider work and be consumed
once when its actual task is installed under the Facade lock.

| Capability phase | Permitted use |
| --- | --- |
| Reading at the original quiet generation | Read, or admit one task |
| Admitted but waiting | No read, replay or commit |
| Its own member running | Original source and acknowledged identity checks still apply |
| Finished, cancelled, closed or uncertain | Permanently rejected |

Every admitted ordinary mutation and progress flush retires earlier unconsumed
reads, even if that mutation later fails. A duplicate progress tick dropped by the
existing deduplication policy is not an admission and does not retire a read.
Later queued intents do not invalidate the member already running; an actual
acknowledged profile/account/registry change does. Tasks retain their existing
predecessor ordering and settle membership only after ACK publication and
completion return.

The original source lock precedes the Facade lock. `queueAuthority` checks the
same capability without reacquiring the source lock, for composition that already
checks the original source separately. It is not source authentication on its own.
Do not recursively enter `read.withActive` from an operation already enclosed by
it or wrap the Session's nonrecursive lease into the original source authority.

`dispatchCapturedNativeActions` is an ordinary current-action adapter to the
existing Session. It is **not** a historical import API. Never translate watched
history into current-time `mark_watched` or `report_progress` actions through it.
Typed owner-history, exact raw checkpoint/export, complete-account budgeting,
peer handling and SDK activation have separate gates; this queue primitive does
not enable them.

## Focused verification

On macOS, run one source-unit lane at a time:

```sh
bash scripts/test-native-migration-phase-a.sh fifo
bash scripts/test-native-migration-phase-a.sh session
```

The FIFO lane uses the complete production primitive, authority/error/JSON owners
and genuine XCTest discovery. The Session lane compiles the real Facade/Session;
its kernel, transport and checkpoint collaborators are synthetic. Neither lane
proves the native C ABI, system credentials, physical-device behavior or a release.
Both retain compiler/runtime/source receipts under ignored `app/build` output.
The shared explicit native fixture inputs include the primitive so the normal
live-ABI and existing complete-Facade harnesses keep their actual source closure.
