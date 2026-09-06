# Diagnostic 14: shared Apple NNTP archive reader

Diagnostic: 13,696 lines; all lines covered by three bounded read-only audits, with the
NNTP/server tail and consequential source evidence checked by the implementation owner.
The user also reports the failure when using the Mac as the engine. No live provider
credentials or private media were used for reproduction.

## Evidence and limits

- The first local NZB passes initialization, then `/7zip/stream` repeatedly reports that
  header offset 6,108,794,201 is outside the available archive volumes. This does not by
  itself establish whether those volumes are incomplete or have incorrectly inferred sizes.
- The second local NZB identifies a stored/COPY MKV in an 81-volume archive. Playback
  never reaches a first frame; initial and mid-file ranges recur and the Node heartbeat
  records delays up to 6.383 seconds. App and Node timestamps differ by one timezone hour.
- These failures are after local NNTP creation, not proof that the saved server cannot
  authenticate. TorBox cloud download creation is not proof of local streaming success.
- A 150 MiB HTTP volume range is **not** evidence of a 150 MiB NNTP article. A hypothesis
  based on that conflation was rejected. Similarly, `grabSegments` always queues after
  `subscribe` via the comma operator; stale subscriptions alone do not prove re-fetch
  suppression. No scheduler rewrite was made on those unsupported assumptions.

## Reproduced defects repaired

The tracked post-checksum patch targets the shared generated server's 7z reader/router
and its own HTTP volume adapter, without changing RAR/ZIP readers or provider credentials.

1. Inclusive chunk endpoints disagreed with advertised inner-file length.
2. A selected COPY subfile ignored its offset within the shared folder, reading another
   file's bytes instead. Actual old-parser fixture output reproduces this corruption.
3. Chunk construction assumed equal prior volume sizes and deducted whole volumes rather
   than the actual bytes consumed from the first one.
4. Header reads requested one extra byte and could not span volume boundaries.
5. The HTTP volume adapter expanded `bytes=0-0` to `bytes=0-`, fetching the entire remainder.
6. Composite cancellation assumed a child HTTP request already existed; a pending async
   open and future volumes could outlive the consumer. Child errors and short/overlong
   bodies now terminate the owned stream.
7. The 7z HTTP route now handles inclusive/suffix ranges, unsatisfiable requests, and HEAD
   consistently with the actual file bytes and safely destroys its composite reader.

## Verification

`node test/server-usenet-archive.test.js` loads the actual vendored modules in memory,
reproduces the old byte-length/subfile/zero-endpoint defects, applies the exact tracked
production patch, and checks:

- Whole-file and single-byte/cross-volume seek equality for unequal split sizes.
- Header splits, including the signature header, and COPY-folder subfile selection.
- Actual localhost HTTP full/ranged/suffix/HEAD replies and content lengths.
- Malformed/truncated/oversized header bounds, short/overlong body rejection.
- Cancellation while a child is still opening; no subsequent volume starts.
- Missing/ambiguous patch anchors, idempotency, and complete bundle syntax validity.

The fetch pipeline verifies the pinned vendor checksum first, runs the failing-control
and repaired-parser tests, applies the tracked patch, and syntax-checks the generated
artifact. Independent TypeScript review and the adapter/body-accounting re-review passed.

This is not a physical TV/Mac playback receipt. It does not prove that these repairs alone
resolve every diagnostic failure. Still to verify: actual provider-backed NNTP playback,
long pause/reseek/reopen behavior, the first archive's volume-size provenance, and the
source-specific CPU stalls. Separate DV mux failure, TorBox DNS failures/backoff, and
immediate failures of some direct add-on links in earlier log sessions remain distinct
findings; this archive patch does not claim to fix them. No release was cut for this change.
