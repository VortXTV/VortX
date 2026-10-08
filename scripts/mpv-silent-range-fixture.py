#!/usr/bin/env python3
"""Local-only HTTP Range fixture for MPVSilentSeekFixture.c; never uses provider media."""
import argparse
import http.server
import pathlib
import re
import subprocess
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", required=True, type=pathlib.Path)
    parser.add_argument("--media", required=True, type=pathlib.Path)
    parser.add_argument("--mode", choices=["range", "bounded206", "ignored-range"], default="range")
    parser.add_argument("--scenario", choices=["playing", "paused", "overlap-paused"], default="playing")
    args = parser.parse_args()
    media = args.media.read_bytes()
    source = pathlib.Path("app/Sources/Player/MPVMetalViewController.swift").read_text()
    options = re.search(r'"(reconnect=1,reconnect_streamed=1,[^"\n]+)"', source).group(1)
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path != "/synthetic.mkv":
                self.send_error(404)
                return
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
            start = int(match[1]) if match else 0
            end = int(match[2]) if match and match[2] else len(media) - 1
            end = min(end, len(media) - 1)
            if start > end:
                self.send_error(416)
                return
            if args.mode == "bounded206":
                end = min(end, start + 128 * 1024 - 1)
            ignored = args.mode == "ignored-range" and start > 0
            requests.append((start, end, ignored))
            print(f"HTTP range={start}-{end} ignored={ignored}", flush=True)
            if ignored:
                start, end = 0, len(media) - 1
            self.send_response(206 if match and not ignored else 200)
            self.send_header("Content-Type", "video/x-matroska")
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Accept-Ranges", "bytes")
            if match and not ignored:
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(media)}")
            self.end_headers()
            try:
                for offset in range(start, end + 1, 8192):
                    self.wfile.write(media[offset:min(offset + 8192, end + 1)])
                    self.wfile.flush()
                    # Keep a real cold mid-file seek rather than letting the entire synthetic
                    # file finish downloading before the first rendered clock tick.
                    time.sleep(0.025)
            except (BrokenPipeError, ConnectionResetError):
                pass

    class Server(http.server.ThreadingHTTPServer):
        def handle_error(self, *_):
            # mpv intentionally cancels old Range sockets on seek/stop.
            pass

    server = Server(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        url = f"http://127.0.0.1:{server.server_port}/synthetic.mkv"
        expected = "expect-stalled" if args.mode == "ignored-range" else "expect-settled"
        result = subprocess.run([str(args.probe.resolve()), url, options, expected, args.scenario], timeout=50)
    finally:
        server.shutdown()
        server.server_close()
    print(f"fixture mode={args.mode} scenario={args.scenario} requests={len(requests)} coldRange={any(r[0] > 0 for r in requests)} exit={result.returncode}")
    return result.returncode if any(r[0] > 0 for r in requests) else 1


if __name__ == "__main__":
    raise SystemExit(main())
