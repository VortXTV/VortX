# Issue 262: native account bootstrap

Base: `v0.5.4-rc.1`, build 273 (`c54e1cfe8`). This retains the release candidate's
checkpoint-first launch, deferred legacy conversion, and roster/settings performance fixes.

## Evidence

The October 15 attachments on [issue #262](https://github.com/VortXTV/VortX/issues/262)
repeatedly report `restore result=failed stage=legacy_preparation` with
`VortxNativeBootstrapArchive.Failure code=2` (`opaquePreference`). This happens before
native session installation, which also gates add-on mutations. It is different from the
original unsupported legacy-row error, whose per-item conversion fix remains in place.

The "new account" and "old account" exports share 393 of their 400 persistent diagnostic
rows and identical server tails. They are overlapping history, not independent clean
account reproductions. They do not expose the field that failed archive inspection.

## Confirmed failure and repair

Swift inspected native account-slot source-history SHA-256 fingerprints as possible
base64 documents. Some valid fingerprints decode to a leading JSON brace followed by
arbitrary bytes, so inspection rejected the entire account as an opaque preference.
Android already recognized this typed protocol location:

```text
/nativeSync/accountSlots/<profile>/slots/<slot>/sourceHistory/<source-sha256>
```

The fix recognizes exactly 64 lowercase hexadecimal characters at that location,
including in retained authenticated-source archives. It preserves the fingerprint
unchanged. Arbitrary fields and neighboring credential carriers still receive inspection.

The existing native carrier fixtures reproduce the failure without customer data.
All five own-account-slot documents failed before the fix. All 24 carrier documents
pass credential-free capture, archive encoding, validation, and nested archive validation
with the fix. The regression suite also checks malformed nonprotocol carriers and
credential removal from neighboring fields.

## Diagnostics and validation

Fresh account-document inspection now emits an `archive_inspection` breadcrumb before
a sanitizer policy rejection. It records a fixed reason and bounded schema path. Dynamic keys, preference names, IDs,
URLs, hashes, and values appear as `*`, for example:

```text
archive_inspection result=failed reason=opaque_preference field=/settings/payloadBase64/*
```

Run the Foundation-only regression suite from the repository root:

```bash
bash scripts/test-native-bootstrap-archive.sh
```

It requires Swift 6 and runs on macOS or Linux. The source-contract CI workflow and the
native bridge runner both include it.

The logs alone cannot prove which customer record triggered this error. Full Apple builds
and affected-device checks remain necessary: cold sign-in, account-data reconciliation,
profile synchronization, add-on installation followed by sign-out/sign-in, and Stremio
import. If a rejection remains, export fresh diagnostics immediately after that attempt
and use its `archive_inspection` breadcrumb, when present, to distinguish it from this
confirmed defect. Earlier retained-archive reads, later archive validation, and Foundation
parser errors still use the existing stage/domain/code diagnostics.

## 17 October follow-up

The new diagnostic export shows a profile-open attempt superseded during an active
restore, followed by a successful mount; it does not repeat the archive-inspection
failure described above. Waiting/automatic-open behavior, duplicate startup hydration,
missing-credential first import, parser cost and cross-platform audit findings are
tracked separately in [the recovery audit](issue-262-recovery-audit-20261017.md).
That document distinguishes checked source changes, safety holds and remaining work.
There is no new app build or affected-reporter acceptance from this source work.
