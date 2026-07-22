# DEBUG headless playback hook (plain-remux lane)

Starts a plain-remux playback session on the tvOS app with no human, so the
conformance battery's live points can run under `xcrun simctl` alone. Implemented
in `app/SourcesTV/DebugPlaybackHook.swift` + two `#if DEBUG` call sites in
`app/SourcesTV/VortXTVApp.swift`. Zero player sources touched.

**Debug builds only.** The entire feature (the hook file body, both call sites,
and the `debug-play` deep-link host) compiles under `#if DEBUG` and is provably
absent from a Release binary. Release ignores the env var, and the deep link
falls through to the normal router, which drops it as "not ours".

## Triggers

Cold start (deterministic, installs nothing):

```bash
# simctl passes env to the app via SIMCTL_CHILD_-prefixed vars in the CALLING
# environment (there is no --setenv flag; see `xcrun simctl help launch`).
SIMCTL_CHILD_VORTX_DEBUG_PLAY_URL="http://<host>:<port>/fixture.mkv" \
SIMCTL_CHILD_VORTX_DEBUG_PLAY_TITLE="Conformance Run" \
xcrun simctl launch --terminate-running-process "$UDID" com.stremiox.tv
```

Warm re-trigger (app already running, no relaunch):

```bash
xcrun simctl openurl "$UDID" \
  "vortx://debug-play?url=http%3A%2F%2F<host>%3A<port>%2Ffixture.mkv"
```

`VORTX_DEBUG_PLAY_TITLE` is optional (display only). The deep link takes exactly
one query parameter, `url`, percent-encoded. A warm re-trigger cleanly replaces
any still-mounted previous session (fresh request id, full player rebuild).

## Input requirements (rejected loudly otherwise)

- `http` or `https` scheme only.
- **Non-loopback host.** `localhost`, `::1`, and anything `127.*` are rejected:
  the router, the engine gate, and the remux candidacy all veto loopback, which
  would silently land the stream on libmpv. The simulator shares the Mac's
  loopback, so serve the fixture from the Mac's LAN IP or a real hostname.
- **Matroska evidence in the URL**, matching the plain-remux candidacy: a real
  `.mkv` path extension, or a boundary-matched `.mkv` token or `matroska` token
  in the filename/query. Without it the stream would not take the remux lane.
- Stream URL at most 2048 chars; whole deep link at most 4096.

## What the hook pins (before the player mounts)

`UserDefaults.standard`, prior values logged, not reverted afterwards:

| Key | Pinned to | Why |
|-----|-----------|-----|
| `stremiox.playerEngine` | `avfoundation` | Router rule 2, the only path a non-DV MKV takes to AVFoundation |
| `stremiox.dvRemuxHLS` | `true` | Local-HLS delivery stays on even if a RemoteConfig kill-switch was fetched |
| `stremiox.plainRemux` | `true` | Plain-remux lane stays on, same determinism reason |

## Readiness markers (machine-readable, stable)

Written to the app container's `Library/Caches/diagnostics.log` under category
`debughook`, i.e. lines of the form `<timestamp> [debughook] <marker>`:

```
debug-play accept trigger=<env|deeplink> token=<id:xxxxxx> engineOverride=avfoundation dvRemuxHLS=true plainRemux=true startFromZero=true
debug-play reject trigger=<env|deeplink> reason=<reason> token=<id:xxxxxx|->
```

Wait predicate for the harness: grep for `"] debug-play accept "` (success) or
`"] debug-play reject "` (fail fast). Reject `reason` vocabulary (fixed strings,
never input fragments): `deeplink-too-long`, `missing-url-param`, `url-too-long`,
`unparseable-url`, `scheme-not-http`, `loopback-host`, `no-mkv-evidence`.

The `token` is the process-salted redaction token of the URL's last path
component, the SAME token the player's `route file=<token> ...` line carries, so
accept -> route -> mount correlate in one grep within a run. Raw URLs are never
written (the diagnostics log is always on).

Each accept is preceded by three pin lines:

```
debug-play pin key=<key> prior=<prior|<unset>> new=<value>
```

Playback-start markers after accept are the pre-existing ones the trace already
reads: `route ... isDV=false ... -> engine=avfoundation` (category `dv`),
`plain-remux mount (local HLS) host=... -> 127.0.0.1:<port>` (category
`avplayer`), then the `hls req` / `hls resp` request log.

## Sequencing note

Accept fires at validation time; the playback request is assigned ~1.5 s later
(the same shell-settle delay `-tv-playertest` uses). Session start should be
awaited on the `route`/`plain-remux mount` lines, not on the accept marker
alone.
