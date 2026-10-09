#!/usr/bin/env python3
"""Retained baseline/candidate libmpv acceptance on one known synthetic loopback file."""
import argparse
import hashlib
import http.server
import json
from pathlib import Path
import queue
import re
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
MEDIA_SHA = "454a703555a26443f5645a1f52ea57ff178d914554410a96f5c75ed1bd95cc94"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def exercise(probe, mode, media, network, directory, baseline):
    armed, stalled, range_held, release = (threading.Event() for _ in range(4))
    records, handlers, lock = [], [], threading.Lock()
    started = time.monotonic()
    size = media.stat().st_size

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_GET(self):
            self.connection.settimeout(2)
            with lock:
                handlers.append(threading.current_thread())
            if self.path not in ("/synthetic.mkv", "/replacement.mkv"):
                self.send_error(404)
                return
            match = re.fullmatch(r"bytes=(\d+)-", self.headers.get("Range", "bytes=0-"))
            if not match or not 0 <= int(match[1]) < size:
                self.send_error(416)
                return
            offset = int(match[1])
            with lock:
                identifier = len(records) + 1
                hold = mode in ("rapid", "stop", "replace") and offset > 0 and not range_held.is_set()
                if hold:
                    range_held.set()
                record = {"id": identifier, "time": round(time.monotonic() - started, 3),
                          "replacement": self.path == "/replacement.mkv", "range": offset,
                          "status": None, "responseOffset": None, "heldBeforeHeaders": hold}
                records.append(record)
            try:
                if hold:
                    release.wait(20)
                    return
                self.send_response(206)
                self.send_header("Content-Length", str(size - offset))
                self.send_header("Content-Range", f"bytes {offset}-{size - 1}/{size}")
                self.send_header("Accept-Ranges", "bytes")
                self.end_headers()
                record.update(status=206, responseOffset=offset)
                with media.open("rb") as source:
                    source.seek(offset)
                    while not release.is_set():
                        if identifier == 1 and armed.is_set() and mode not in ("immediate", "cached"):
                            record["stalledAt"] = source.tell()
                            stalled.set()
                            release.wait(20)
                            return
                        chunk = source.read(8192)
                        if not chunk:
                            record["completed"] = True
                            return
                        self.wfile.write(chunk)
                        self.wfile.flush()
                        time.sleep(0.005)
            except OSError:
                record["clientClosed"] = True
            finally:
                self.close_connection = True

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    child = None
    lines = []
    try:
        child = subprocess.Popen([str(probe), f"http://127.0.0.1:{server.server_port}/synthetic.mkv",
                                  mode, *network], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, bufsize=1)
        incoming = queue.Queue()

        def consume():
            for line in child.stdout:
                incoming.put(line)

        reader = threading.Thread(target=consume, daemon=True)
        reader.start()
        deadline = time.monotonic() + 25
        while child.poll() is None or not incoming.empty():
            if time.monotonic() > deadline:
                raise TimeoutError("bounded native acceptance deadline")
            try:
                line = incoming.get(timeout=0.1)
            except queue.Empty:
                continue
            lines.append(line)
            print(line, end="", flush=True)
            if line.startswith("READY "):
                armed.set()
                if mode not in ("immediate", "cached") and not stalled.wait(3):
                    raise RuntimeError("old response did not reach the controlled stall")
                child.stdin.write("go\n")
                child.stdin.flush()
            if line.startswith("FIRST_SEEK"):
                if not range_held.wait(4):
                    raise RuntimeError("first seek did not reach controlled reopen")
                child.stdin.write("latest\n")
                child.stdin.flush()
        child.wait(timeout=2)
        reader.join(timeout=2)
        while not incoming.empty():
            lines.append(incoming.get_nowait())
    finally:
        if child and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=2)
        release.set()
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=2)
        for handler in handlers:
            handler.join(timeout=3)
        assert not any(handler.is_alive() for handler in handlers), "owned HTTP handler still running"
        result = child.returncode if child else None
        log = "".join(lines) + "REQUESTS " + json.dumps(records, sort_keys=True) + "\n"
        log += f"OWNED_SERVER_CLOSED=1 exit={result}\n"
        (directory / f"{mode}.log").write_text(log)
        print("REQUESTS", json.dumps(records, sort_keys=True), flush=True)
        print("OWNED_SERVER_CLOSED=1", "exit=" + str(result), flush=True)
    if baseline and mode == "stalled":
        assert result == 2 and "NOT_SETTLED" in log and "LANDED" not in log
        assert len(records) == 1 and records[0].get("stalledAt", 0) > 0
        assert re.search(r"NOT_SETTLED .*counter=(\d+) initial=\1(?:\s|$)", log)
        print("BASELINE_RED blocked old read prevents seek execution", flush=True)
    else:
        assert result == 0 and "DESTROY result=0" in log, mode
        required = "STOPPED" if mode == "stop" else "REPLACED" if mode == "replace" else "LANDED"
        assert required in log, mode
        if mode == "rapid":
            assert range_held.is_set() and "target=120.500" in log
        if mode == "cached":
            assert not any(r["range"] for r in records), records
        if mode == "stop":
            assert len(records) == 2 and records[1]["heldBeforeHeaders"], records
        if mode == "replace":
            assert any(r["replacement"] for r in records), records
            assert len([r for r in records if not r["replacement"]]) == 2, records
        print("PASS", mode, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--support", type=Path, required=True)
    parser.add_argument("--media", type=Path, required=True)
    parser.add_argument("--candidate-archive", type=Path)
    parser.add_argument("--attempt", type=int, required=True)
    args = parser.parse_args()
    assert args.attempt > 0 and digest(args.media) == MEDIA_SHA
    directory = ROOT / "app/build/mpv-http-seek-acceptance" / f"attempt-{args.attempt}"
    directory.mkdir(parents=True, exist_ok=False)
    controller = ROOT / "app/Sources/Player/MPVMetalViewController.swift"
    text = controller.read_text()
    network = []
    for key in ("network-timeout", "stream-lavf-o"):
        values = re.findall(r'mpv_set_option_string\(mpv,\s*"' + re.escape(key) + r'",\s*"([^"]+)"\)', text)
        assert len(values) == 1, (key, values)
        network.append(values[0])
    source = ROOT / "app/Tests/MPVHTTPSeekAcceptanceFixture.c"
    inputs = {str(p): digest(p) for p in (source, Path(__file__).resolve(), controller, args.media,
                                         ROOT / "scripts/mpv-http-seek-interrupt.patch")}
    framework_paths = []
    for name in ("Libmpv", "Libavcodec", "Libavdevice", "Libavfilter", "Libavformat", "Libavutil", "Libswresample", "Libswscale", "Libplacebo"):
        suffix = "" if name == "Libplacebo" else "-GPL"
        path = args.artifacts / f"{name}{suffix}.xcframework/macos-arm64_x86_64"
        inputs[str(path / f"{name}.framework/{name}")] = digest(path / f"{name}.framework/{name}")
        framework_paths += ["-F", str(path)]
    if args.candidate_archive:
        inputs[str(args.candidate_archive)] = digest(args.candidate_archive)
    (directory / "inputs.json").write_text(json.dumps(inputs, sort_keys=True, indent=2) + "\n")
    print("INPUTS", json.dumps(inputs, sort_keys=True), flush=True)
    frameworks = []
    for path in sorted(args.support.glob("*.framework")):
        if path.stem == "Libmpv" and args.candidate_archive:
            continue
        frameworks += ["-framework", path.stem]
    obj, probe = directory / "main.o", directory / "probe"
    commands = [["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-c", str(source),
                 "-I", str(args.artifacts / "Libmpv-GPL.xcframework/macos-arm64_x86_64/Libmpv.framework/Headers"),
                 "-o", str(obj)]]
    commands.append(["xcrun", "swiftc", str(obj), *([str(args.candidate_archive)] if args.candidate_archive else []),
                     *framework_paths, "-F", str(args.support), *frameworks, str(args.support / "libMoltenVK.a"),
                     *sum((["-framework", f] for f in ("AppKit", "AVFoundation", "CoreAudio", "AudioToolbox", "CoreVideo",
                           "CoreFoundation", "CoreMedia", "Metal", "VideoToolbox", "IOKit", "OpenGL",
                           "UniformTypeIdentifiers", "QuartzCore", "Security")), []),
                     "-lbz2", "-liconv", "-lexpat", "-lresolv", "-lxml2", "-lz", "-lc++", "-o", str(probe)])
    (directory / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    for command in commands:
        subprocess.run(command, check=True, timeout=90)
    print("PROBE", digest(probe), flush=True)
    modes = ("immediate", "stalled", "playing", "rapid", "cached", "stop", "replace") if args.candidate_archive else ("immediate", "stalled")
    for mode in modes:
        exercise(probe, mode, args.media, network, directory, not args.candidate_archive)


if __name__ == "__main__":
    main()
