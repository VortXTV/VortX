# Apple sync, artwork and Usenet follow-up — 11 September 2026

Implementation batch on top of the current playback fixes; not a new public release.

## Included

- QR add-on pairing retains the relay-issued session authority through claim and acknowledgement.
- Same-title metadata updates publish late poster, background, logo, episode inventory, thumbnails and trailer changes. Large-image decode permits remain held until the load finishes.
- Trakt Continue Watching understands Trakt's scheme-less artwork URLs, uses the local library artwork fallback and joins exact cached title aliases without joining unrelated same-name titles.
- Saved NNTP servers support priority, enable/disable, editing and removal. Legacy single-server settings migrate. The resolver preserves add-on server order, then tries the ordered saved-server route, then the existing TorBox cloud fallback when configured. Server credentials remain in owner-scoped secure storage.
- Direct Newznab/NZBGeek settings and searches feed the normal Apple source lists. Queries use the selected episode, participate in source settlement and are fenced to account, profile and configuration. Empty completed searches do not repeatedly restart. HTTPS API keys and NZB links are excluded from diagnostics and settings backups.
- Explicit add-on prequel/sequel links are navigable on Apple detail pages. Known TMDB movie collections also expose dated release neighbors. This is not a claim of complete anime relationship coverage or narrative-order inference.
- Owner library progress merges position, duration, episode and timestamp as one observation. Warm-device recovery adds missing account titles without inventing new install intent. Continue Watching cards and resume selection honor newer peer progress while preserving active playback and explicit local rewinds.
- Owner watched/unwatched actions have account-scoped causal receipts; overlay profiles merge per-episode mark/unmark clocks. Episode badges consume the merged state. Whole-season actions write the history carrier once, and whole-title actions correctly supersede older episode actions. Durable overlay watched history is separate from the short CW rail (currently bounded to 1,800 title rows).

## Website deployed separately

`vortx-site` commit `fa56f7d` is deployed to the `vortx` Cloudflare Pages production project at vortx.tv.

- One-time Stremio import uses the official Stremio API directly. Passwords are passed exactly, not retained; cancellation and account changes invalidate old attempts. Credential errors, network failures and malformed collections are distinguished.
- App-owned and website-owned add-ons share ordering controls without transferring ownership. URL changes retain their slot and use explicit removal/re-add receipts. Mutations are serialized and refreshed from the encrypted account document.
- The manifest-fetch proxy remains the separately deployed VortX API. Its source was not available in the canonical inventory; this batch does not claim to repair an unidentified server-side proxy defect.

## Verification and limits

Focused executable checks cover pairing authority, real model artwork publication, title relations, Trakt artwork/alias folding, NNTP configuration, Newznab request/parser/storage boundaries, owner/overlay watch merges, add-on ordering and catalog resolution. The website has 40 passing tests and a successful production build. Issue #164's 77 wiring checks pass; its stale single-line function-signature anchor was updated after checking the actual session guards.

Real embedded NNTP protocol fixtures cover raw/archive playback, byte ranges, forward/backward seeks, pause/reopen, cancellation and two-provider failover. These use synthetic loopback articles, not live provider accounts. They do not establish real-network sustained throughput or Dolby Vision stability.

Final platform build receipts and any private test IPA are retained outside Git in the workspace recovery directory. iOS and macOS checks are unsigned Debug builds; macOS verification is Apple silicon, not Intel. tvOS is an unsigned Release build for sideload testing, not a signed public release.

## Remaining verification and subsequent work

1. Test the updated Apple build on both ends of a TV/phone/Mac account: install, remove, reorder, change URL, watched/unwatched and resume, including offline changes and relaunch. An older installed binary does not acquire these fixes from the website deployment.
2. Exercise real NZBGeek/Newznab searches and the configured NNTP providers on Apple TV. Confirm sustained playback and automatic episode selection; keep DV/pause/seek hardware testing separate from passing protocol fixtures.
3. Confirm the reported anime title now receives its actual artwork. The publication bug is repaired; absent or HTTP-404 upstream images remain a separate failure mode.
4. Inspect the manifest proxy implementation/deployment if website URL installation still fails, without falsely reporting an account save as a device installation receipt.
5. Broader Android playback/audio/remote/back-navigation and Apple UI parity, iPhone hero/source formatting, macOS design work, and unsupported relationship-provider coverage remain separate work. They are not included or represented as complete in this Apple batch.
6. No stale draft release or previously built IPA should be published. A public beta still requires current source/artifact, signing, release-feed and deployment verification.
