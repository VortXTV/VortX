"""Synthetic loopback control server. Never fetches an NZB, provider, or media URL."""
import http.server
import json
import subprocess
import sys
import threading
import time

lock = threading.Lock()
creates = []
cancels = []
active = set()
retired = set()
capabilities = {
    "version": 1, "raw": True, "multipartYenc": True, "checksumsRequired": True,
    "archives": ["rar4-store", "rar5-store", "7z-copy"],
    "operationCancellation": True, "operationIdFormat": "uuid",
    "selection": {"fileIdx": True, "fileMustInclude": True, "episode": True,
                  "fileIdxOrder": "nzb-media-or-archive-entry-order", "regexSyntax": "bare-or-js-ims"},
}


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, status, value=None):
        body = json.dumps(value).encode() if value is not None else b""
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path == "/nzb/capabilities":
            self.reply(200, capabilities)
        elif self.path == "/__snapshot":
            with lock:
                snapshot = {"creates": creates[:], "cancels": cancels[:], "active": list(active)}
            self.reply(200, snapshot)
        else:
            self.reply(404)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path.startswith("/nzb/operations/") and self.path.endswith("/cancel"):
            operation = self.path.split("/")[3]
            with lock:
                cancels.append(operation)
                retired.add(operation)
                active.discard(operation)
            self.reply(204)
            return
        if self.path != "/nzb/create":
            self.reply(404)
            return
        value = json.loads(body)
        operation = value.get("operationId", "legacy-" + str(time.monotonic_ns()))
        with lock:
            creates.append(value)
        scenario = value["nzbUrls"][0].split("/")[-1]
        if scenario == "pending":
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                with lock:
                    if operation in retired:
                        break
                time.sleep(0.01)
        with lock:
            cancelled = operation in retired
            if not cancelled and scenario not in ("failure", "mismatch", "malformed"):
                active.add(operation)
        if cancelled:
            self.reply(410, {"error": "operation_cancelled"})
        elif scenario == "failure":
            self.reply(503, {"error": "resource_limit"})
        elif scenario == "mismatch":
            self.reply(422, {"error": "selection_unmatched"})
        elif scenario == "malformed":
            self.reply(200, {"missing": "key"})
        else:
            self.reply(200, {"key": "key-" + operation})

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
worker = threading.Thread(target=server.serve_forever, daemon=True)
worker.start()
try:
    result = subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}"], timeout=45)
    sys.exit(result.returncode)
finally:
    server.shutdown()
    server.server_close()
    worker.join()
