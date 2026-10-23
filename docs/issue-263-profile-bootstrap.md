# Issue 263: literal add-on labels blocked profile preparation

Status: source repair and regression coverage; **not an affected-device acceptance claim**.
The published 0.5.5/build 274 packages are unchanged by this patch.

## Evidence and reproduced defect

The reporter's [0.5.4 follow-up and diagnostic attachment](https://github.com/VortXTV/VortX/issues/263#issuecomment-6221583821)
contain nine `legacy_preparation` failures with archive `opaquePreference` (code 2), each
preceded by `archive_inspection ... field=/*/*/*/*/*`. The exact attached file is 69,595 bytes,
SHA-256 `0d9b41f31647abe714e97be408d05c6c972b694ca3f4cdd9b54c92a6adb35c16`.
It was inspected without requesting or retaining the customer's account document.

The masked path does not disclose the customer's exact field or value. A real source path
matching its shape is `/vortx/addons/0/manifest/name` (or `description`). A synthetic valid
descriptor named `[4K] Community catalog` reproduces the same archive failure: the sanitizer
fails to parse the display text as JSON, then mistakes its initial `[` for a damaged container.
Because fresh account inspection runs before session installation, this prevents the whole
profile restore and downstream add-on operations. Waiting longer does not repair that rejection.

## Repair and safeguards

- Recognize a complete add-on descriptor by its HTTP(S) transport URL and nonempty manifest
  `id`, `name` and `version` strings. Only its direct manifest `name`/`description` strings get
  display-text context. Content recognition follows the same descriptor through legacy
  projection, native registers, independent-source envelopes and retained archives.
- After the existing structured inspection, permit a short, balanced literal `[label]` or
  `{label}`, with no quoting, key/value syntax, escapes or nested delimiters. Preserve its text
  exactly. A prefix that itself parses as JSON is not a literal-label exception: malformed
  `[true] {"token":...}` and similar trailing-data containers still fail.
- Do not carry display context into other fields, arrays, objects or decoded containers.
  Encoded credential inspection, malformed backup rejection, opaque binary rejection,
  typed fingerprint handling and recursion limits remain in force. No unknown data is dropped.
- Diagnostic breadcrumbs now retain additional fixed schema words and a fixed carrier category
  (`plain_text_prefix`, `base64_prefix`, `opaque_data`, `backup_envelope`, `settings_envelope`,
  or `depth_limit`). IDs, URLs, display text, dynamic keys and values remain masked or absent.

## Verification

The regression fails against the prior production source and passes after the fix. Run:

```bash
bash scripts/test-native-bootstrap-archive.sh
bash scripts/test-apple-legacy-bootstrap.sh
bash scripts/test-native-website-addon-edits.sh
bash scripts/test-native-own-account-producer.sh
```

The archive suite covers 63 complete capture/encode/validate/retained-source journeys across
the actual descriptor carrier shapes, plus malformed credential structures, encoded containers,
non-display fields, context leakage, diagnostic privacy and existing credential boundaries.
The adapter suite exercises actual legacy projection with both profiles and library retention;
website and independent-source suites cover their actual production validation/retention paths.
These are standalone host/control fixtures with synthetic data and inert transport/storage, not
an app build, real-account operation or physical-device test. The C-ABI-only lanes of these
runners require an explicitly supplied engine library and are not implied by the host checks.

Keep #262 and #263 open until an affected-device check establishes profile opening, add-on
persistence, reopen and cross-device synchronization. If this account still fails, the improved
redacted breadcrumb distinguishes the remaining field/category without exposing its contents.
