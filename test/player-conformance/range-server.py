#!/usr/bin/env python3
"""
range-server.py - serve ONE file over HTTP with real Range (206) support.

Why this exists instead of `python3 -m http.server`: the stdlib one-liner server
answers every GET with 200 and the whole body, ignoring `Range`. The plain-remux
read path issues ranged reads, so a non-range server makes the remux look broken
in a way that is indistinguishable from a player bug. This server answers
`Range: bytes=a-b` with `206 Partial Content` + a correct `Content-Range`, and
`416` with `Content-Range: bytes */<size>` for an unsatisfiable range.

It also binds 0.0.0.0 on an EPHEMERAL port and writes the chosen port to a file,
because the fixture must be reachable from the simulator at the Mac's LAN
address (a loopback URL is demoted to libmpv at three separate layers).

Finally it PACES delivery at a byte rate. That is load-bearing, not a nicety: an
unpaced LAN server hands the simulator ~90 MiB in well under a second, so the
remux closes every segment of the file BEFORE AVPlayer issues its first
/media.m3u8 request. The session degenerates into an instant ENDLIST VOD and the
startup gate that contract point 1 governs is never exercised at all - the gate
would read a first playlist of "all N segments" and score it GREEN while the
beta's real premature-open defect (it opens at 2 closed segments) sat untouched.
A paced source reproduces the real debrid/direct condition where the producer and
the player race.

    usage: range-server.py <file> <portfile> [bind-address] [bytes-per-second]
           bytes-per-second 0 (or omitted) = unpaced.
"""

import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

if len(sys.argv) < 3:
    sys.stderr.write(__doc__)
    sys.exit(2)

PATH = os.path.abspath(sys.argv[1])
PORTFILE = sys.argv[2]
BIND = sys.argv[3] if len(sys.argv) > 3 else "0.0.0.0"
RATE = int(sys.argv[4]) if len(sys.argv) > 4 else 0

NAME = "/" + os.path.basename(PATH)
SIZE = os.path.getsize(PATH)
# Small blocks so the pacing sleep is fine-grained rather than bursty.
CHUNK = 64 * 1024


class RangeHandler(BaseHTTPRequestHandler):
    # HTTP/1.1 so keep-alive + Content-Length framing behave like a real CDN.
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[fixture-server] %s\n" % (fmt % args))

    def _parse_range(self):
        """None = no range header; 'unsat' = 416; (start, end) inclusive otherwise."""
        header = self.headers.get("Range")
        if not header:
            return None
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", header.strip())
        if not match:
            return None
        raw_start, raw_end = match.group(1), match.group(2)
        if raw_start == "" and raw_end == "":
            return None
        if raw_start == "":
            count = int(raw_end)
            if count == 0:
                return "unsat"
            return (max(0, SIZE - count), SIZE - 1)
        start = int(raw_start)
        if start >= SIZE:
            return "unsat"
        end = int(raw_end) if raw_end else SIZE - 1
        end = min(end, SIZE - 1)
        if end < start:
            return "unsat"
        return (start, end)

    def _serve(self, with_body):
        if self.path.split("?")[0] != NAME:
            self.send_error(404, "only %s is served" % NAME)
            return
        rng = self._parse_range()
        if rng == "unsat":
            self.send_response(416)
            self.send_header("Content-Range", "bytes */%d" % SIZE)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if rng:
            start, end = rng
            length = end - start + 1
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, SIZE))
        else:
            start, length = 0, SIZE
            self.send_response(200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "video/x-matroska")
        self.send_header("Content-Length", str(length))
        self.end_headers()
        if not with_body:
            return
        try:
            with open(PATH, "rb") as handle:
                handle.seek(start)
                remaining = length
                began = time.monotonic()
                sent = 0
                while remaining > 0:
                    block = handle.read(min(CHUNK, remaining))
                    if not block:
                        break
                    self.wfile.write(block)
                    remaining -= len(block)
                    sent += len(block)
                    if RATE > 0:
                        due = began + sent / RATE
                        slack = due - time.monotonic()
                        if slack > 0:
                            time.sleep(slack)
        except (BrokenPipeError, ConnectionResetError):
            # A player that seeks or stops mid-segment closes the socket. Normal.
            pass

    def do_GET(self):
        self._serve(True)

    def do_HEAD(self):
        self._serve(False)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


server = Server((BIND, 0), RangeHandler)
with open(PORTFILE, "w") as portfile:
    portfile.write(str(server.server_address[1]))
sys.stderr.write("[fixture-server] %s (%d B) on %s:%d\n"
                 % (NAME, SIZE, BIND, server.server_address[1]))
sys.stderr.flush()
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
