# Apple native delta applier

Status: source-reviewed and host source-unit verified, **unwired**. No
runtime, session, SDK, checkpoint, progress-coalescing or flush caller is changed.

`VortxNativeDeltaApplier` reconstructs a candidate from already-decoded v2
envelopes belonging to one exclusively owned handle. It checks exact UTF-8
session/account/profile identities, stored dictionary-key spellings, safe integer
revisions, complete base equality and the predecessor publication token. It is
not a hostile raw-JSON parser: decoding may already have lost duplicate keys.

Untouched histories, pending material and opaque siblings remain exact decoded
values. Independent retained archive/projection metadata need not have a current
profile or account-slot target; a canonical-only existing key match still refuses.
Actual watch patches require their incumbent paths and exact selected account
slot. An explicit authorized replacement replaces the whole named value; this
helper does not merge omitted data back into it.

Preparation does not publish. Completion brackets the owner's acceptance callback
with binding/token checks; that callback must finish scoped durable readback and
the exact native transaction commit. A callback return is not a durability proof.
Post-install failure requires uncertainty/reopen handling, not an old checkpoint
writeback or another drain. The owner must keep a single nonforked applier and
must not reenter it from the callback.

The separate `VortxNativeDeltaApplierTests.swift` entry point contains ten synthetic
decoded-value groups, including Unicode identity, retained metadata, cursor
ordering, completion refusal and full-value conservation. Its source-unit gate
uses complete actual JSON/error/scope declarations, not model stubs. It must not
be added to the existing session-test executable, which has its own entry point.

The focused host gate compiled each version separately with strict Swift 6,
complete concurrency checks, warnings as errors and one compiler job/thread.
The same final fixture reproduced the earlier Unicode-identity failure after
five groups and retained-metadata failure after nine groups; the current helper
passed all ten groups. These are synthetic decoded-value checks, not an app or
SDK build, a native-producer round trip or an installed-device result.

Activation still needs compatible SDK/provenance checks, replacement authority,
exclusive persistent-handle integration, native transaction and durable-reopen
evidence, unchanged progress/flush behavior, and platform/device verification.
Candidate encoding and outer validation still traverse the full snapshot;
encryption/checkpoint costs and measured performance are not improved by this
unwired helper alone.
