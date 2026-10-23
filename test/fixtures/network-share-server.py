"""Local fixture for the network share tests: a tiny WebDAV + folder-listing server.

Serves two shares from in-memory trees, never the real filesystem:
  /dav/   answers PROPFIND (Depth 1) with a multistatus body; GET is refused
  /web/   answers GET with an nginx-style listing; PROPFIND is refused (405)
Both need Basic auth me:pw. /dav/away/ redirects to another host; /web/hop/ redirects inside the share.
The bound port is printed on the first stdout line.
"""
import base64
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote

TREE = {
    "/dav/": ["Films/", "Arrival (2016).mkv", "poster.jpg"],
    "/dav/Films/": ["Dune Part Two.mkv"],
    "/web/": ["Shows/", "The Matrix (1999).mp4", "notes.txt"],
    "/web/Shows/": ["S01E01.mkv"],
}
AUTH = "Basic " + base64.b64encode(b"me:pw").decode()
# Video files for the playback probe. /dav/ refuses HEAD (405) so the client falls back to a ranged GET.
FILES = {"/web/The Matrix (1999).mp4", "/dav/Arrival (2016).mkv"}
REDIRECTS = {"/web/moved.mkv": "/web/The%20Matrix%20(1999).mp4", "/web/go-away.mkv": "http://elsewhere.invalid/x.mkv"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def authorized(self):
        if self.headers.get("Authorization") == AUTH:
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="fixture"')
        self.end_headers()
        return False

    def path_only(self):
        return unquote(self.path.split("?")[0])

    def redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.end_headers()

    def do_PROPFIND(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        path = self.path_only()
        if path == "/dav/away/":
            return self.redirect("http://elsewhere.invalid/dav/")
        if not path.startswith("/dav/"):
            self.send_response(405)
            self.end_headers()
            return
        if not self.authorized():
            return
        if path not in TREE:
            self.send_response(404)
            self.end_headers()
            return
        parts = [f"<D:response><D:href>{quote(path)}</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>"]
        for name in TREE[path]:
            folder = name.endswith("/")
            kind = "<D:collection/>" if folder else ""
            size = "" if folder else "<D:getcontentlength>1234</D:getcontentlength>"
            parts.append(f"<D:response><D:href>{quote(path + name)}</D:href><D:propstat><D:prop><D:resourcetype>{kind}</D:resourcetype>{size}</D:prop></D:propstat></D:response>")
        body = ('<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">' + "".join(parts) + "</D:multistatus>").encode()
        self.send_response(207)
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_file(self, head):
        path = self.path_only()
        if path in REDIRECTS:
            self.redirect(REDIRECTS[path])
            return True
        if path not in FILES:
            return False
        if not self.authorized():
            return True
        if head and path.startswith("/dav/"):
            self.send_response(405)
            self.end_headers()
            return True
        body = b"0123456789"
        ranged = self.headers.get("Range") == "bytes=0-0"
        self.send_response(206 if ranged else 200)
        self.send_header("Content-Length", "1" if ranged else str(len(body)))
        self.end_headers()
        if not head:
            self.wfile.write(body[:1] if ranged else body)
        return True

    def do_HEAD(self):
        if not self.serve_file(head=True):
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        if self.serve_file(head=False):
            return
        path = self.path_only()
        if path == "/web/hop/":
            return self.redirect("/web/Shows/")
        if not path.startswith("/web/"):
            self.send_response(405)
            self.end_headers()
            return
        if not self.authorized():
            return
        if path not in TREE:
            self.send_response(404)
            self.end_headers()
            return
        links = "".join(f'<a href="{quote(name)}">{name}</a>\n' for name in TREE[path])
        body = f"<html><body><h1>Index of {path}</h1><pre><a href=\"../\">../</a>\n{links}</pre></body></html>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
