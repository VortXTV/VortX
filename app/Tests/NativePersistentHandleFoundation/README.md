# Persistent-handle foundation source units

This directory tests the complete production `VortxNativeRuntime.swift`,
`VortxNativeDeltaApplier.swift` and `VortxNativePublicationGate.swift` sources.
The feature is deliberately unwired and its artifact policy is false. These
fixtures do not authorize enabling it or replacing the existing session path.

The positive unit consists of those three production files, `Dependencies.swift`
and `FoundationTests.swift`. Dependencies contains exact complete production JSON
and account-scope declarations for this isolated unit; it is not a replacement
Session or native SDK. The test supplies a synthetic ABI, not an engine artifact.
Do not add another test entry point or compile this directory into the app.

Seven groups cover generation/legacy behavior, reservation busy rejection,
throw/lifetime release, reentry and the unlocked reservation gap, publication
metadata lifecycle, cross-gate identity and exact decoded-value comparison.
Expected output is the complete `expected-green.txt`. Both Swift 5 and strict
Swift 6 positive source-unit runs are retained by the audit coordinator.

Compile each file in `Negatives/` independently with the same four non-test
sources, never alongside the positive test entry point. Rejection must be for
the intended ownership/access constraint: N1 Copyable result, N2 escaping inout,
N3 asynchronous inout capture, N4 inaccessible initializer in a separate file.
An import, setup, output-shape or unrelated diagnostic is not a passing negative.
All four exact fragments have independently reviewed strict Swift 6 rejection
receipts. They intentionally cannot form a successful combined source target.

These are bounded source-unit results, not real Session/Facade/CoreBridge lease,
native transaction/durability, app/platform integration or performance acceptance.
The original delta-applier tests remain separate and unchanged. Use the project's
serialized low-priority test policy; no app/SDK build or live account is required.
