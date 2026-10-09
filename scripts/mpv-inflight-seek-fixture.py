#!/usr/bin/env python3
"""Bounded, literal-loopback-only transport mechanism test. Never accepts a provider URL."""
import argparse
import http.server
import json
import pathlib
import queue
import re
import subprocess
import threading
import time


def validate(mode, lines):
    """Assert the observed mechanism, not just native command acceptance or process exit."""
    native = "".join(lines)
    events = [json.loads(line) for line in lines if line.startswith("{")]
    command = re.search(r"COMMAND target=104\.146 status=0 .*initialCounter=(\d+)", native)
    result = re.search(r"RESULT sought=1 sawSeek=1 landed=(\d) passed12s=(\d) ended=(\d)", native)
    clean = any(e["kind"] == "cleanup" and e.get("childExited") and e.get("ownedListenerClosed") for e in events)
    if not command or not result or not clean or "DESTROY complete" not in native:
        return False
    initial = int(command[1])
    after = [e for e in events if e["kind"] == "request" and e["afterArm"] and e["requestedStart"] > 0]
    landing = re.search(r"LANDING elapsed=([0-9.]+) position=([0-9.]+) counterDelta=([0-9]+) pausePreserved=1", native)
    deadline = re.search(r"event=original-12s-deadline .*seeking=1 eof=0 pause=1 counterValid=1 counter=(\d+)", native)
    if mode in ("immediate", "redirect", "stalled"):
        if not landing or abs(float(landing[2]) - 104.146) > 0.5 or int(landing[3]) < 1 or not after:
            return False
        if any(e["status"] != 206 or e["requestedStart"] != e["responseStart"] for e in after):
            return False
        if mode == "stalled":
            release = next((e for e in events if e["kind"] == "seek-released" and e["oldResponseStalled"]), None)
            return bool(release and deadline and int(deadline[1]) == initial and float(landing[1]) > 12
                        and min(e["elapsed"] for e in after) - release["elapsed"] > 12)
        return (float(landing[1]) < 12 and result[2] == "0"
                and (mode != "redirect" or any(e["kind"] == "redirect" and e["status"] == 302 for e in events)))
    expected_status = 200 if mode == "ignored" else 206
    return bool(not landing and result[1] == "0" and deadline and int(deadline[1]) > initial
                and any(e["status"] == expected_status and e["responseStart"] != e["requestedStart"] for e in after))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", type=pathlib.Path)
    parser.add_argument("--media", type=pathlib.Path)
    parser.add_argument("--validate-receipt", type=pathlib.Path)
    parser.add_argument("--mode", required=True, choices=["immediate", "stalled", "ignored", "invalid", "redirect"])
    args = parser.parse_args()
    if args.validate_receipt:
        passed = validate(args.mode, args.validate_receipt.read_text().splitlines(keepends=True))
        print(f"receipt mechanism assertion mode={args.mode} passed={passed}")
        return 0 if passed else 1
    if args.probe is None or args.media is None:
        parser.error("--probe and --media are required for a native run")
    # Compile and exercise unchanged production network timeout/options, not a faster test policy.
    source = pathlib.Path("app/Sources/Player/MPVMetalViewController.swift").read_text()
    network_timeout = re.search(r'"network-timeout", "([0-9.]+)"', source)[1]
    options = re.search(r'"(reconnect=1,reconnect_streamed=1,[^"\n]+)"', source)[1]
    media = args.media.read_bytes()
    armed, stalled, cleanup = threading.Event(), threading.Event(), threading.Event()
    claim_lock = threading.Lock()
    requests = []
    output = []
    origin = time.monotonic()

    def receipt(kind, **fields):
        line = json.dumps({"kind": kind, "elapsed": round(time.monotonic() - origin, 3), **fields})
        output.append(line + "\n")
        print(line, flush=True)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == "/redirect":
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/synthetic.mkv")
                self.send_header("Content-Length", "0")
                self.end_headers()
                receipt("redirect", status=302, requestedRange=self.headers.get("Range"))
                return
            if self.path != "/synthetic.mkv":
                self.send_error(404)
                return
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
            requested_start = int(match[1]) if match else 0
            end = min(int(match[2]) if match and match[2] else len(media) - 1, len(media) - 1)
            if requested_start > end:
                self.send_error(416)
                return
            invalid = armed.is_set() and requested_start > 0 and args.mode in ("ignored", "invalid")
            start = 0 if invalid else requested_start
            status = 200 if invalid and args.mode == "ignored" else (206 if match else 200)
            content_range = f"bytes {start}-{end}/{len(media)}" if status == 206 else None
            request = {"requestedStart": requested_start, "responseStart": start, "responseEnd": end,
                       "contentRange": content_range, "status": status, "afterArm": armed.is_set()}
            requests.append(request)
            receipt("request", **request)
            self.send_response(status)
            self.send_header("Content-Type", "video/x-matroska")
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Accept-Ranges", "bytes")
            if content_range:
                self.send_header("Content-Range", content_range)
            self.end_headers()
            try:
                for offset in range(start, end + 1, 8192):
                    hold = False
                    if args.mode == "stalled" and armed.is_set():
                        with claim_lock:
                            if not stalled.is_set():
                                stalled.set()
                                hold = True
                    if hold:
                        receipt("old-response-stalled", requestedStart=requested_start, blockedAt=offset,
                                newRangeConnectionsAvailable=True)
                        cleanup.wait(65)
                        return
                    if cleanup.is_set():
                        return
                    self.wfile.write(media[offset:min(offset + 8192, end + 1)])
                    self.wfile.flush()
                    time.sleep(0.025)
                receipt("response-complete", requestedStart=requested_start, responseEnd=end)
            except (BrokenPipeError, ConnectionResetError):
                receipt("response-canceled", requestedStart=requested_start)

    class Server(http.server.ThreadingHTTPServer):
        daemon_threads = True

        def handle_error(self, *_):
            pass  # mpv cancels exactly these owned sockets on seek/stop.

    server = Server(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    probe = None
    failure = None
    try:
        path = "redirect" if args.mode == "redirect" else "synthetic.mkv"
        url = f"http://127.0.0.1:{server.server_port}/{path}"
        probe = subprocess.Popen([str(args.probe.resolve()), url, network_timeout, options,
                                  "negative-control" if args.mode in ("ignored", "invalid") else "expect-landing"],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, bufsize=1)
        lines = queue.Queue()

        def drain():
            for line in probe.stdout:
                lines.put(line)
            lines.put(None)

        threading.Thread(target=drain, daemon=True).start()
        while time.monotonic() - origin < 65:
            try:
                line = lines.get(timeout=0.2)
            except queue.Empty:
                continue
            if line is None:
                break
            output.append(line)
            print(line, end="", flush=True)
            if line.startswith("READY"):
                armed.set()
                if args.mode == "stalled" and not stalled.wait(3):
                    raise RuntimeError("could not stall the existing response")
                # Let the demuxer consume already-buffered data and block on that old response.
                time.sleep(0.5)
                receipt("seek-released", oldResponseStalled=stalled.is_set())
                probe.stdin.write("seek\n")
                probe.stdin.flush()
        else:
            raise TimeoutError("bounded fixture wall timeout")
        result = probe.wait(timeout=3)
        receipt("result", mode=args.mode, exit=result, coldRangeAfterArm=any(r["afterArm"] and r["requestedStart"] > 0 for r in requests))
    except (RuntimeError, TimeoutError, subprocess.TimeoutExpired) as error:
        failure = str(error)
        receipt("failure", reason=failure)
        result = 1
    finally:
        if probe is not None and probe.poll() is None:
            probe.terminate()
            try:
                probe.wait(timeout=3)
            except subprocess.TimeoutExpired:
                probe.kill()
                probe.wait(timeout=3)
        cleanup.set()
        server.shutdown()
        server.server_close()
        receipt("cleanup", childExited=probe is None or probe.poll() is not None, ownedListenerClosed=True)
    passed = not failure and result == 0 and validate(args.mode, output)
    print(f"receipt mechanism assertion mode={args.mode} passed={passed}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
