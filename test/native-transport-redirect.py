"""Credential-free HTTP fixture: a real 307 must never forward the NZB control POST."""
import http.server
import json
import subprocess
import sys
import threading

requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(("GET", self.path))
        body = json.dumps({"version": 1, "raw": True, "multipartYenc": True,
                           "checksumsRequired": True,
                           "archives": ["rar4-store", "rar5-store", "7z-copy"]}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        requests.append(("POST", self.path))
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.send_response(307)
        self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/credential-sink")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    subprocess.run([sys.argv[1], "--redirect-fixture", f"http://127.0.0.1:{server.server_port}"],
                   check=True, timeout=15)
    assert requests == [("GET", "/nzb/capabilities"), ("POST", "/nzb/create")], requests
finally:
    server.shutdown()
    server.server_close()
    thread.join()
