#!/usr/bin/env python3
"""Compile selected vendor AVIO and test bounded, synthetic literal-loopback recovery."""
import argparse
import hashlib
import http.server
import json
from pathlib import Path
import subprocess
import threading

ROOT = Path(__file__).resolve().parents[1]
SIZE = 262144
BODY = bytes(i % 251 for i in range(SIZE))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def exercise(probe, mode, directory):
    release = threading.Event()
    records = []
    record_lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_GET(self):
            requested = self.headers.get("Range", "bytes=0-")
            if self.path != "/bytes" or not requested.startswith("bytes="):
                self.send_error(400)
                return
            try:
                offset = int(requested[6:].split("-", 1)[0])
            except ValueError:
                self.send_error(400)
                return
            if not 0 <= offset < SIZE:
                self.send_error(416)
                return
            valid_headers = (self.headers.get("User-Agent") == "fixture-source-A"
                             and self.headers.get("Referer") == "http://127.0.0.1/fixture-only"
                             and self.headers.get("X-Fixture") == 'comma,"quoted",\\slash')
            cookie_ok = offset == 0 or self.headers.get("Cookie") == "seed=synthetic"
            actual = 0 if offset and mode in ("ignored", "invalid") else offset
            status = 200 if offset and mode == "ignored" else 206
            with record_lock:
                records.append({"range": offset, "response": actual, "status": status,
                                "headersMatch": valid_headers, "cookieMatch": cookie_ok,
                                "cookiePresent": self.headers.get("Cookie") is not None,
                                "cookieLength": len(self.headers.get("Cookie", ""))})
            if not valid_headers or not cookie_ok:
                self.send_error(403)
                return
            if mode == "supersede" and offset == 131072:
                release.wait(6)  # Newer request remains available on a separate thread.
            try:
                self.send_response(status)
                self.send_header("Content-Length", str(SIZE - actual))
                self.send_header("Accept-Ranges", "bytes")
                if status == 206:
                    self.send_header("Content-Range", f"bytes {actual}-{SIZE - 1}/{SIZE}")
                # Host-only cookie: pinned HTTP matches explicit Domain against
                # Host including its nondefault port, which is a separate issue.
                self.send_header("Set-Cookie", "seed=synthetic; path=/")
                self.end_headers()
                if offset == 0:
                    self.wfile.write(BODY[:4096])
                    self.wfile.flush()
                    release.wait(8)
                else:
                    self.wfile.write(BODY[actual:])
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                self.close_connection = True

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        run = subprocess.run([str(probe), f"http://127.0.0.1:{server.server_port}/bytes", mode],
                             capture_output=True, text=True, timeout=12)
    finally:
        release.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
    output = run.stdout + run.stderr
    output += "REQUESTS " + json.dumps(records, sort_keys=True) + "\n"
    output += f"OWNED_SERVER_CLOSED=1 exit={run.returncode}\n"
    (directory / f"{mode}.log").write_text(output)
    print(output, end="", flush=True)
    assert run.returncode == 0, mode
    assert records and all(r["headersMatch"] and r["cookieMatch"] for r in records), mode
    ranges = [r["range"] for r in records]
    expected = [0] if mode == "stop" else [0, 131072, 196608] if mode == "supersede" else [0, 131072]
    assert ranges == expected, (mode, ranges)
    if mode in ("recover", "supersede"):
        assert "exactBytes=1 cleanError=1" in output
    else:
        assert "REJECTED status=-" in output and "admitted=0" in output
    print("PASS", mode, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--support", type=Path, required=True)
    parser.add_argument("--attempt", type=int, required=True)
    args = parser.parse_args()
    assert args.attempt > 0
    directory = ROOT / "app/build/mpv-http-seek-recovery" / f"attempt-{args.attempt}"
    directory.mkdir(parents=True, exist_ok=False)
    includes = directory / "include"
    includes.mkdir(exist_ok=True)
    source = ROOT / "app/Tests/MPVHTTPSeekRecoveryFixture.c"
    inputs = {str(source): digest(source), str(Path(__file__).resolve()): digest(Path(__file__).resolve())}
    paths = []
    for name in ("Libavformat", "Libavcodec", "Libavutil", "Libswresample", "Libswscale", "Libavfilter", "Libavdevice"):
        slice_path = args.artifacts / f"{name}-GPL.xcframework/macos-arm64_x86_64"
        framework = slice_path / f"{name}.framework"
        inputs[str(framework / name)] = digest(framework / name)
        link = includes / name.lower()
        target = (framework / "Headers").resolve()
        if link.is_symlink():
            assert link.resolve() == target, link
        elif link.exists():
            raise RuntimeError(f"Refusing existing non-symlink header path: {link}")
        else:
            link.symlink_to(target, target_is_directory=True)
        paths += ["-F", str(slice_path)]
    (directory / "inputs.json").write_text(json.dumps(inputs, sort_keys=True, indent=2) + "\n")
    print("INPUTS", json.dumps(inputs, sort_keys=True), flush=True)
    obj = directory / "main.o"
    probe = directory / "probe"
    commands = [["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(includes),
                 "-c", str(source), "-o", str(obj)]]
    frameworks = []
    for item in sorted(args.support.glob("*.framework")):
        frameworks += ["-framework", item.stem]
    commands.append(["xcrun", "swiftc", str(obj), *paths, "-F", str(args.support), *frameworks,
                     str(args.support / "libMoltenVK.a"),
                     *sum((["-framework", f] for f in ("AppKit", "AVFoundation", "CoreAudio", "AudioToolbox",
                           "CoreVideo", "CoreFoundation", "CoreMedia", "Metal", "VideoToolbox", "IOKit", "OpenGL",
                           "UniformTypeIdentifiers", "QuartzCore", "Security")), []),
                     "-lbz2", "-liconv", "-lexpat", "-lresolv", "-lxml2", "-lz", "-lc++", "-o", str(probe)])
    (directory / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    for command in commands:
        subprocess.run(command, check=True, timeout=90)
    print("PROBE", digest(probe), flush=True)
    for mode in ("recover", "ignored", "invalid", "stop", "supersede"):
        exercise(probe, mode, directory)


if __name__ == "__main__":
    main()
