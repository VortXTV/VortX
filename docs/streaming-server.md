# Streaming server: inbound peers + playhead-first piece selection

> Engine design note for VortX's own streaming server (ROADMAP 1.0, "a built-in torrent
> engine so torrents work without debrid"). VortX's engine is a pure, I/O-free kernel: the
> host (Swift/Kotlin/TS) owns bytes, the clock, and all network and parallelism; the kernel
> only plans and decides. So this streaming server is a HOST capability that the kernel PLANS
> for, mirroring the `Fetch` host boundary in `vortx-core/crates/source/src/transport.rs`.
>
> Reference implementation studied (source read, not just the README):
> `github.com/andrewhack/stremio-libtorrent-server`, an open, clean-room reimplementation of
> Stremio's closed streaming server, written in Python 3.11 + FastAPI over libtorrent 2.0,
> packaged as one Docker image alongside the web player, speaking the exact Stremio server
> protocol (`/:infoHash/:idx`, `/:infoHash/stats.json`, `/removeAll`, etc.) so an unmodified
> client direct-plays through it.

## Why this exists

VortX resolves playback debrid-first: direct URL, then debrid-cached, then debrid-uncached,
then raw torrent (`vortx-core/crates/debrid/src/resolve.rs`, ranks 0..3). The last branch,
`ResolveMethod::Torrent`, needs a streaming server to actually serve bytes. The closed Stremio
server we currently bundle has two structural defects. The reference repo fixes both, and they
are visible in its code, not just claimed in marketing.

## Defect 1: outbound-only, the stock server never LISTENS for inbound peers

A large fraction of swarm peers are themselves behind NAT and cannot accept inbound
connections. They are reachable only if someone dials them, or if they dial you. A purely
outbound client can reach only the connectable half of a swarm, so on thin or sparse swarms the
download starves for no good reason. On a healthy torrent you never notice; on a thin one you
are throttled to nothing.

The fix is one session setting plus discovery and NAT toggles. libtorrent equivalents, with the
reference values:

| Setting | Value | Effect |
|---|---|---|
| `listen_interfaces` | `0.0.0.0:<port>` | Bind an inbound listener so NATed peers can connect TO us. This is the core win. |
| `enable_upnp` / `enable_natpmp` | `true` | Auto-map the router port so the inbound listener is reachable from the WAN. |
| `enable_dht` / `enable_lsd` | `true` | Trackerless plus local peer discovery, to find more peers. |
| `connections_limit` | 400 | Peer ceiling. |
| `connection_speed` | 500 | Ramp new peer connections quickly. |
| `request_queue_time` / `max_out_request_queue` / `max_allowed_in_request_queue` | `1` / `1500` / `2000` | Deep request pipelines for sustained throughput. |
| `suggest_mode` | `suggest_read_cache` | Suggest pieces from our read cache to peers. |
| `mixed_mode_algorithm` | `prefer_tcp` | Stability over uTP under contention. |
| `announce_to_all_trackers` / `announce_to_all_tiers` | `true` | Maximize swarm formation (mirrors VortX's TCP/TLS-tracker reliability work, 0.2.41 to 0.2.44). |

Default BitTorrent port 6881 (TCP and UDP). The acceptance check is concrete, not a vibe:
`ss -tlnp` must show `0.0.0.0:6881 LISTEN`, and during playback `ss -tan` must show at least one
inbound `ESTAB` (a peer that connected TO us).

## Defect 2: downloads to complete the file, not to feed the playhead

The stock server behaves like a generic torrent client (download to complete the file) and hides
the levers. A media server should download the bytes about to be watched FIRST. The reference
does this in two layers.

1. **Kill background completion.** Set EVERY piece to priority 0 once, at add time
   (`Handle.ensure_low_baseline()` calls `prioritize_pieces([0] * num_pieces)`). Nothing
   downloads except what the read head needs.

2. **Sliding deadline window around the read head, NOT `sequential_download`.** Notably the
   shipped engine deliberately does not set libtorrent's `sequential_download` flag (the design
   plan did; the production code dropped it because it is too rigid for seeks). Instead the file
   server (`stream/fileserver.py::wait_and_read`) maintains a window of pieces ahead of the
   current read offset, each raised to top priority (7) and given a `set_piece_deadline`. The
   deadline is GRADED by distance: the head piece gets 0 ms (most urgent), each further piece
   gets +50 ms, so libtorrent fetches in playback order without a hard in-order lock.

   Two subtleties worth stealing:
   - The window is a BYTE BUDGET (about 50 MiB), not a fixed piece count. On torrents with large
     pieces it stays a tight region (roughly 4 to 12 pieces) instead of fanning out over a
     gigabyte, so a seek genuinely rushes the first piece at the target.
   - On a SEEK, drop the previous window's not-yet-downloaded pieces back to priority 0 and reset
     their deadlines (`Handle.refocus()`), so all bandwidth re-concentrates on the new region
     instead of splitting across two windows.
   - The same `set_piece_deadline` mechanism rushes a trailing MP4 `moov` atom (end-of-file
     metadata) for an instant start, with no whole-file download and no special first-or-last
     piece hack.

## HTTP byte-serving with range requests

- Parse `Range`: support `bytes=A-B`, `bytes=A-` (open end), `bytes=-N` (suffix), and no header
  (whole file); clamp the end to file size; return an inclusive `(start, end)`.
- Map a byte offset to a global piece via `(file_offset + pos) / piece_length`; block per chunk
  until `have_piece`, then read the region straight off disk (verified pieces are written to
  `save_path/<file_path>`).
- NEVER read past the last verified byte of the current piece. The next piece may be sparse or
  zero on disk and would emit corrupt frames. Read in about 256 KiB chunks.
- Respond `206` with `Content-Range`, `Accept-Ranges: bytes`, `Content-Length`; support `HEAD`;
  lazily create the torrent session on the first `/:infoHash/:idx` hit.
- Cache budget is LRU-evicted and must exceed the largest file (18 GiB default in the reference),
  with a short grace (about 5 minutes) for recently-served torrents.

## How VortX implements this better: engine-integrated, not a bolt-on

VortX keeps the kernel pure and pushes the libtorrent dependency to the host, so the streaming
policy is deterministic and unit-tested with zero I/O, and the same plan runs identically on
every platform. This is the existing kernel/host split, applied to streaming.

1. **New pure crate `vortx-core/crates/streaming`.** A `StreamingPlan` planner: given a
   `vortx_protocol::Stream` (`crates/protocol/src/resource.rs:192`, which already carries
   `info_hash`, `file_idx`, and `behavior_hints`) routed from `ResolveMethod::Torrent`, emit
   (a) the libtorrent SESSION CONFIG (the table above) as plain data, and (b) the
   PIECE-PRIORITY PLAN for a given read offset (a port of the reference `wait_and_read` window
   math: byte-budget window, distance-graded deadlines, a refocus diff on seek). Pure,
   deterministic, fully tested. Sibling of `vortx-nzb` (engine plans retrieval, host moves bytes).

2. **Host boundary trait `TorrentHost`** (sibling of `Fetch` in `crates/source/src/transport.rs`):
   the host owns the libtorrent or rqbit session, the disk, the sockets, and the clock; the engine
   stamps priorities, deadlines, and the byte budget. The kernel never opens a socket, exactly
   like the fan-out `Fetch` boundary today.

3. **Wire `ResolveMethod::Torrent`** in `crates/engine/src/resolve.rs` to return a `StreamingPlan`
   the host executes, preserving the command/query FFI split (commands mutate, queries decide).

4. **Debrid-cached first, playhead-first P2P as the fallback.** Reuse the existing resolve order:
   most playback is instant via direct or debrid; the playhead-first server is the path that makes
   raw torrents viable when no debrid is configured. Reuse the `crates/source/src/exit.rs` policy
   style for a "playback may start" gate (enough head-window pieces verified) instead of waiting
   for completion.

5. **Expose the levers** the stock server hid: inbound port and UPnP toggle, connection limit,
   readahead or window byte budget, and cache size. These are already partly modeled by the app's
   `ServerConfigView.swift`; surface the new ones there and in the dashboard.

## Open questions and risks

- **Pure-Rust vs libtorrent FFI on the host.** `rqbit` or `cratetorrent` (pure Rust) avoid a C++
  dependency and ease the iOS/tvOS static-link story, but must be verified to support a
  `set_piece_deadline` equivalent (per-piece urgency), UPnP/NAT-PMP, and an inbound listener.
  libtorrent has all of these proven. Decide per host platform: Mac and desktop can afford
  libtorrent; mobile may prefer pure Rust.
- **iOS/tvOS background and memory.** VortX already had a streaming-server-killed-by-jetsam class
  of bug (RSS climbed until the OS killed the server). The byte-budget window (not whole-file)
  plus a device-scaled cache cap directly address this. Keep the readahead source-sized (the
  0.2.41 to 0.2.44 lesson) and never background-complete.
- **Inbound port on mobile.** UPnP/NAT-PMP may be unavailable on cellular or CGNAT; the listener
  still helps on LAN and Wi-Fi, and DHT still discovers peers. Treat inbound as best-effort,
  never required.

## Engine integration points (file map)

- `vortx-core/crates/debrid/src/resolve.rs:27,153`: `ResolveMethod::Torrent` (the hook; rank 3,
  last resort after direct, debrid-cached, debrid-uncached).
- `vortx-core/crates/source/src/transport.rs:53`: `trait Fetch` (the template for `TorrentHost`).
- `vortx-core/crates/engine/src/resolve.rs`: where the streaming plan gets returned to the host.
- `vortx-core/crates/protocol/src/resource.rs:192`: `Stream` (`info_hash`, `file_idx`,
  `behavior_hints`), the inputs a streaming server needs.
- `vortx-core/crates/source/src/exit.rs`: early-exit policy style for a "may start playback" gate.
- `vortx-core/crates/nzb`: the analogous "engine plans retrieval, host moves bytes" precedent.
- `vortx-core/Cargo.toml`: workspace members (add `crates/streaming`).

## Reference repo files (for the implementer)

- `src/stremiosrv/torrent/engine.py`: session config (inbound listen, UPnP/NAT-PMP/DHT,
  tunables), `ensure_low_baseline`, `boost_piece`, `refocus`, `set_piece_deadline`, lazy add.
- `src/stremiosrv/stream/fileserver.py::wait_and_read`: the byte-budget sliding deadline window
  plus the safe per-piece disk read.
- `src/stremiosrv/torrent/picker.py`: pure `pieces_for_range` / `priority_plan`.
- `src/stremiosrv/stream/ranges.py::parse_range`: HTTP Range parsing.
- `src/stremiosrv/config.py`: env surface (port 6881, 18 GiB cache, 128 MiB readahead, 400 conns).

## Ordered build plan

1. Scaffold the pure crate. Add `crates/streaming` to `vortx-core/Cargo.toml` members; create
   `crates/streaming/Cargo.toml` (deps: `vortx-protocol`, `serde`, `thiserror`; dev-dep
   `proptest`) modeled on `crates/nzb/Cargo.toml`.
2. Implement `StreamingPlan` (pure). In `crates/streaming/src/`: `session.rs` (the session-config
   table as a serde struct with VortX defaults), `picker.rs` (port the `wait_and_read` window
   math: `pieces_for_range`, byte-budget-to-piece window, distance-graded deadlines, the refocus
   diff), `plan.rs` (entry from a `Stream`). Unit plus proptest, zero I/O.
3. Define the `TorrentHost` host trait in `crates/streaming/src/host.rs`, sibling of `Fetch`:
   add a torrent, set piece priorities and deadlines from a `StreamingPlan`, report `have_piece`
   and the read head. Engine stamps, host executes.
4. Wire resolve. In `crates/engine/src/resolve.rs`, route `ResolveMethod::Torrent` to return a
   `StreamingPlan`; add a `ResolveRequest`/`ResolveResponse` variant so the FFI command/query
   split holds.
5. Add a "playback may start" gate mirroring `crates/source/src/exit.rs`: start once enough
   head-window pieces are verified, rather than on completion.
6. Host implementation (platform phase, outside the kernel). Implement `TorrentHost` over
   libtorrent (Mac/desktop) and evaluate `rqbit`/`cratetorrent` for mobile; verify per-piece
   deadline equivalents, UPnP/NAT-PMP, and an inbound `0.0.0.0:<port>` listener (run the `ss`
   acceptance checks). Replace the `app/SourcesShared/MacNodeServer.swift` and `StremioServer.swift`
   consumers.
7. Surface the levers. Extend `app/SourcesShared/ServerConfigView.swift` (and the web dashboard)
   with the inbound-port and UPnP toggle, the window byte budget, the connection limit, and the
   cache size.
