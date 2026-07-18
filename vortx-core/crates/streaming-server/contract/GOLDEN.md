# The streaming-server HTTP contract (GOLDEN, captured 2026-07-18)

This is the contract the VortX app + libmpv depend on, captured two ways:

1. **App call sites** (the authority on what MUST work), from `/Users/daksh/vortx/app`:
   `SourcesShared/StremioServer.swift`, `SourcesShared/TorrentTrackers.swift`,
   `Sources/NodeServer.swift` (port file), `Sources/PlayerScreen.swift` +
   `SourcesTV/TVPlayerView.swift` (stats polling, `/remove`),
   `SourcesTV/OpenLinkView.swift` (magnet create + `files` parsing).
2. **The real server.js v4.21.0** (`/Users/daksh/vortx/app/Resources/server.js`,
   sha-pinned by `scripts/fetch-server-deps.sh`) run under node v26.3.0 with
   `HOME`/`APP_PATH` sandboxed, every endpoint curled and recorded. Field names
   below are byte-exact from those live responses. The `/proxy` behaviour was
   additionally read out of the server.js source (module at ~line 71010) because
   node 26 breaks its http-agent (see Deviations).

Every field name in this file is BYTE-EXACT. Do not rename, re-case, or "fix" them.

## 0. Bind + port file

- Bind `127.0.0.1:11470` (host `0.0.0.0` when LAN sharing is on). server.js
  silently drifts to 11471-11474 on EADDRINUSE; the Rust server instead binds
  the configured port DETERMINISTICALLY (bounded retry, then hard exit).
- On successful bind, write the bare port number (`11470`) to a
  `stremio-server.port` file. iOS/tvOS `NodeServer.discoveredPort` reads that
  exact filename from the caches dir and validates the range `11470...11474`.

## 1. GET /settings  (the app's online-readiness signal)

`StremioServer.respondsAsServer` requires: HTTP **200** + a JSON object with a
top-level **`values`** object. Anything else = the app latches "Offline".

Captured top-level keys: `options`, `values`, `baseUrl`.

Captured `values` (v4.21.0 defaults; names byte-exact):

```json
{
  "serverVersion": "4.21.0",
  "appPath": "<APP_PATH>",
  "cacheRoot": "<APP_PATH>",
  "cacheSize": 2147483648,
  "btMaxConnections": 55,
  "btHandshakeTimeout": 20000,
  "btRequestTimeout": 4000,
  "btDownloadSpeedSoftLimit": 2621440,
  "btDownloadSpeedHardLimit": 3670016,
  "btMinPeersForStable": 5,
  "remoteHttps": "",
  "localAddonEnabled": false,
  "transcodeHorsepower": 0.75,
  "transcodeMaxBitRate": 0,
  "transcodeConcurrency": 1,
  "transcodeTrackConcurrency": 1,
  "transcodeHardwareAccel": true,
  "transcodeProfile": null,
  "allTranscodeProfiles": ["videotoolbox"],
  "transcodeMaxWidth": 1920,
  "proxyStreamsEnabled": false
}
```

`baseUrl`: `"http://<lanIP>:<port>"` (falls back to the loopback base).

## 2. POST /settings  (merge; the jetsam-cap path)

- Body: any JSON object; server.js merges it into `values`
  (`saveSettings -> userSettings.extend`). The app posts
  `{"cacheSize": <bytes>, "btMaxConnections": 24}` and RETRIES until it sees
  HTTP **200** (`applyServerConfig`); a dropped 200 means the 2 GB default cache
  stays and tvOS jetsam-kills the app under torrent load.
- Captured response: `200`, `content-type: application/json`, body
  `{"success":true}`. A following GET /settings reflects the merged values.

## 3. POST /{infoHash}/create  (idempotent; blocks until metadata)

Request body (from `StremioServer.prepare` / `primeTorrent` / `OpenLinkView`):

```json
{
  "torrent": { "infoHash": "<40-hex lowercase>" },
  "peerSearch": { "sources": ["dht:<hash>", "tracker:<url>", ...], "min": 40, "max": 150 }
}
```

- `sources` entries are `"dht:<hash>"` or `"tracker:<udp|http|https url>"`. The
  app injects HTTP/HTTPS trackers (TorrentTrackers) because UDP/DHT are dead in
  the tvOS sandbox; the server must additionally inject its own HTTP/HTTPS
  default trackers so a bare create can still reach a swarm.
- Idempotent: a second create on a live engine returns its current status and
  ignores the new peerSearch ("the first create's sources are the ones that stick").
- BLOCKS until torrent metadata is in (the app allows 75 s), then returns **200**
  with the full engine-status JSON, identical in shape to stats.json below,
  with `files` populated. `OpenLinkView.resolveMagnet` decodes
  `files: [{name, length}]` from THIS response to pick the fileIdx.

Captured response top-level keys (byte-exact, same set as stats.json):

`infoHash, name, peers, unchoked, queued, unique, connectionTries, swarmPaused,
swarmConnections, swarmSize, selections, wires, files, downloaded, uploaded,
downloadSpeed, uploadSpeed, sources, peerSearchRunning, opts`

`files[]` items: `{ "path": "Sintel/Sintel.mp4", "name": "Sintel.mp4",
"length": 129241752, "offset": 7884 }` (keys byte-exact: `path, name, length, offset`).

## 4. GET /{infoHash}/{fileIdx}  (the playback endpoint)

- `infoHash` is LOWERCASED by the app; `fileIdx` defaults to 0 when absent.
- Auto-creates the engine when it is not running (Continue-Watching resume hits
  this without a prior create; optional `?tr=` query trackers are honored).
- **BLOCKS until the first requested bytes are downloaded**, then streams.
- Range-capable. Captured headers:
  - `Range: bytes=0-1023` -> **206 Partial Content**,
    `Content-Range: bytes 0-1023/129241752`, `Content-Length: 1024`,
    `Accept-Ranges: bytes`, `Content-Type: video/mp4`,
    `Cache-Control: max-age=0, no-cache`.
  - No Range -> **200** with the full `Content-Length`.
  - HEAD -> 200 + the same headers, no body.
  - (server.js also emits `transferMode.dlna.org` / `contentFeatures.dlna.org`;
    libmpv does not need them. Optional.)

## 5. GET /{infoHash}/stats.json  (player warm-up polling)

Captured top-level keys, byte-exact (same set/order as the create response):

```
infoHash        string  40-hex
name            string
peers           int     <- app reads (fallback for swarmConnections)
unchoked        int
queued          int
unique          int
connectionTries int     <- app logs
swarmPaused     bool
swarmConnections int    <- app reads FIRST for the "N connected" line
swarmSize       int
selections      array
wires           array   (per-peer objects; app never reads: may be [])
files           array   of {path, name, length, offset}
downloaded      number  <- app reads: > 3_000_000 = warm, retryLoad
uploaded        number
downloadSpeed   number  BYTES/SEC <- app reads (shows MB/s at > 10_000)
uploadSpeed     number
sources         array   of {numFound, numFoundUniq, numRequests, url, lastStarted}
peerSearchRunning bool  <- app logs
opts            object  (echo of the create opts; app never reads)
```

The app's decoders (`TorrentStats`) read EXACTLY: `peers`, `swarmConnections`,
`connectionTries`, `peerSearchRunning`, `downloaded`, `downloadSpeed`. Those six
are the hard contract; the rest are shape-parity.

- **Unknown/removed hash: 200, `content-type: application/json`, body `null`**
  (captured; NOT a 404). The app's decode of `null` fails soft and it keeps polling.

## 6. GET /{infoHash}/remove  (engine teardown; a GET, not DELETE)

- Captured: **200**, `content-type: application/json`, body `{}`.
- Destroys the engine (peers/sockets) but the on-disk cache MAY remain; a
  follow-up file GET auto-creates and reuses cached pieces (captured: instant 206).

## 7. /proxy  (header forwarder + HLS rewriter)

Route shape (from `StremioServer.proxiedURL` + server.js source):

```
/proxy/d={originEnc}&h={Name:Value enc}&h={...}/{path}?{query}
```

- The FIRST path segment after `/proxy/` is a querystring: `d` = destination
  origin (single), `h` = request header (repeated), `r` = response header
  override (repeated). Values percent-encoded (the app encodes `&=+/?:`).
- Each `h=` is split on its FIRST colon into Name:Value (a value may contain `:`).
- Upstream request: forward this whitelist from the client request:
  `accept, accept-encoding, accept-language, connection, transfer-encoding,
  range, if-range, user-agent`, plus `host: <dest host>`, then apply the `h=`
  headers on top. Redirects followed manually up to 5, re-applying `h=` each hop.
  (server.js fetches with `rejectUnauthorized: false`; see deviation 6.)
- Response: forward this whitelist upstream->client:
  `accept-ranges, content-type, content-length, content-range, connection,
  transfer-encoding, last-modified, etag, server, date`, then apply `r=` overrides.
- Playlist detection: dest path extension `.m3u`/`.m3u8` OR content-type
  containing `mpegurl` (case-insensitive). For playlists: DROP content-length,
  set `accept-ranges: none`, chunked transfer, and rewrite the body line-by-line:
  - relative URI lines: UNCHANGED (they resolve against the proxy URL itself,
    which keeps segments flowing through the proxy - captured live).
  - root-relative (`/x`): `urlJoin(virtualRoot, line)` where
    `virtualRoot = /proxy/<the exact original opts segment>`.
  - absolute, SAME origin as `d`: `urlJoin(virtualRoot, pathname) + search`.
  - absolute, DIFFERENT origin: `/proxy/d=<newOrigin enc>&h=<same h's>` + path + search.
  - comment/tag lines: only the `URI="..."` attribute value is rewritten, same rules.
- Never proxy loopback destinations (`127.0.0.1`/`localhost`/`::1`/`0.0.0.0`).
  (The app also refuses client-side; the server enforces it too.)

## Out of scope (deliberately NOT implemented)

- `/yt/{id}` trailers: the app uses `trailer.vortx.tv` on every build.
- No DELETE routes; teardown is the GET `/remove` above.
- HLS transcode (`/hlsv2`), casting/DLNA discovery, `/local-addon`,
  `/subtitles`, `/opensubHash`, stats WebSocket: no VortX call sites.
  Torrent playback is the only job of this server (direct/debrid/HLS play
  client-side).

## Known deviations from server.js (all deliberate)

1. Port: deterministic bind (retry then exit) instead of the silent 11471-11474
   drift that used to strand sessions.
2. server.js under node 26 rejects `http:` proxy destinations (its https-agent
   breaks: `ERR_INVALID_PROTOCOL`, captured). The Rust proxy handles http AND
   https destinations, which matches the production node-18 behaviour.
3. server.js's different-origin HLS rewrite doubles a non-default port
   (`url.parse().host` already includes the port, then it appends `:port`
   again). The Rust rewriter emits the port once. Bug not reproduced.
4. `connection` / `transfer-encoding` are hop-by-hop and managed by the HTTP
   stack (hyper), not blindly copied. `accept-encoding` is not forwarded, so
   upstream bodies pass through identity, byte-transparent (server.js's
   node-fetch decompressed gzip while leaking the compressed content-length).
5. `wires` is `[]` and aggregate counters not tracked by rqbit
   (`unchoked`, `connectionTries`, `unique`, `swarmSize`) are best-effort
   approximations from rqbit's peer stats. The app only trusts the six fields
   listed in section 5, all of which are real.
6. The proxy VERIFIES upstream TLS by default (server.js ships
   `rejectUnauthorized: false`, which invites MITM). A CDN with a broken chain
   can be accommodated with the opt-in `VORTX_PROXY_INSECURE_TLS=1` env, which
   restores server.js parity for that deployment only.
