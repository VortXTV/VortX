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

## Diagnostic 15 follow-up: wire framing and bounded delivery

All 19,002 diagnostic lines are accounted for: lines 1–13,398 exactly match the
previously read diagnostic prefix; the remaining lines were read in disjoint ranges.
The first new attempt is a plain NNTP MKV, not an archive. Neither it nor the later
patched-7z attempt reaches a first frame; Easynews++ HTTP does. The 7z request for
`bytes=0-31` proves the previous archive patch was installed. NNTP heartbeat delays
reach 9.191 seconds and RSS reaches 1,187 MB. Packet contents are not in this log,
so protocol fixtures establish the defects below, not the exact packet split on TV.

The additional tracked `patch-server-nntp.js` repair addresses:

- A split NNTP article terminator leaves the old worker permanently BUSY. Status
  lines also incorrectly assumed TCP packet boundaries. A byte-stream parser now
  handles both; disconnect, cancellation and bounded response timeout settle work.
- Idle connection retirement permanently poisoned a reusable grabber. Cancellation
  now drains before its close callback, and an explicit new read can reopen it.
- An early stalled article allowed later articles to accumulate without reaching
  HTTP backpressure. A connection-sized ordered window, capped at 16 pieces, bounds
  this read-ahead and advances without rescanning every earlier completed slot.
- HTTP backpressure had an inverted comparison. Response ownership also now follows
  the outgoing response lifecycle, and NZB ranged replies correctly return 206.
- Needle auto-parsed `application/xml` NZBs before the actual NZB parser received
  them. Fetching the raw response preserves valid XML.
- GROUP rejection must not prevent ARTICLE by message-ID; this retains existing
  provider compatibility under RFC 3977 section 6.2.1.
- Reentrant result delivery passed the primary server's missing-article error into
  a newly subscribed backup-server request before that server responded. Snapshotting
  and detaching the old subscriber bucket before callbacks preserves the new request.
  Both a failing-control test and real two-server raw/archive byte-equality tests
  verify this additional fix. The patch can also update the existing wire-v1 bundle
  idempotently, without replacing any native app binary.
- TV-only CI exposed a cancellation race: a late backup result could deliver into
  an already-finished HTTP response whose buffer had been cleared, crashing the
  engine with `Buffer.concat` receiving null. Response retirement now fences both
  cleanup paths; stopped grabbers reject backup success/failure and halt an ordered
  callback drain immediately. A deterministic regression reproduced two deliveries
  after cancellation before the fix and zero afterwards (including failed backup).

`node test/server-nntp.test.js` exercises the actual vendored worker, NZB parser,
scheduler, yEnc decoder, raw-file HTTP route, and split-7z route against local
synthetic TCP/HTTP servers. It reproduces the unpatched hang and verifies fragmented
status/body/end markers, disconnect/timeout/cancel recovery, exact complete/ranged
bytes, backward/forward seeks, HEAD, idle same-key reopen, and a stalled-first-piece
window. Backbone recovery is tested while paused, then all 100 ordered pieces drain
after resume. Real primary/backup servers additionally recover missing middle articles
without corrupting raw or archived bytes. `VORTX_NNTP_MEDIA_TEST=1` generates synthetic Matroska video
and audio with FFmpeg and decodes both raw and split-archive NNTP HTTP streams.

Separately, failed-before-first-frame playback now returns to the attempted episode
instead of the last watched episode. Close-scoped attempted identity is distinct
from a genuine first-frame receipt: it never writes watched/progress/scrobble state.
Both detail surfaces are wired, and all 16 standalone Swift policy checks pass.

Independent Swift and JavaScript review passed. This is a local-test build change,
not a public release. Physical Apple TV playback with the user's provider/title
still requires the new IPA test; no synthetic result is represented as that receipt.
