"""Bounded official directory indexes; no archives are fetched or executed."""
from html.parser import HTMLParser
import re
import urllib.parse
import urllib.request

SOURCES = {
    "ffmpeg": ("https://ffmpeg.org/releases/",),
    "gmp": ("https://gmplib.org/download/gmp/", "https://gmplib.org/download/gmp/archive/"),
    "nettle": ("https://ftp.gnu.org/gnu/nettle/",),
    "freetype": ("https://download.savannah.gnu.org/releases/freetype/",
                 "https://download.savannah.gnu.org/releases/freetype/freetype-old/"),
}
MAX_BYTES = 8 * 1024 * 1024
MAX_TAGS = 30000
MAX_LINKS = 12000
VERSION = re.compile(r"[0-9][0-9A-Za-z._+-]{0,99}")

class ArchiveCoverageError(ValueError):
    pass

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

class Listing(HTMLParser):
    def __init__(self, group):
        super().__init__(convert_charrefs=True)
        self.group = group
        self.tags = 0
        self.links = []
        self.in_h1 = False
        self.headings = []
        self.html_open = self.body_open = self.container_open = self.tbody_open = False
        self.html_closed = self.body_closed = self.container_closed = self.tbody_closed = False
        self.footer_open = self.footer_closed = self.bad_tail = False
        self.container = "pre" if group in {"ffmpeg", "gmp"} else "table"
    def handle_starttag(self, tag, attrs):
        self.tags += 1
        if self.tags > MAX_TAGS:
            raise ArchiveCoverageError("tag-bound")
        # These are static directory indexes, not documents to navigate or run.
        if tag in {"link", "base", "script", "form", "iframe", "object", "embed"}:
            raise ArchiveCoverageError("unsupported-navigation-or-active-content")
        if tag == "meta":
            if any(not isinstance(value, str) for _, value in attrs) or len(dict(attrs)) != len(attrs):
                raise ArchiveCoverageError("unsupported-meta")
            meta = {key: value.strip().lower() for key, value in attrs}
            if meta not in ({"http-equiv": "content-type", "content": "text/html; charset=utf-8"},
                            {"charset": "utf-8"},
                            {"name": "viewport", "content": "width=device-width"}):
                raise ArchiveCoverageError("unsupported-meta")
        if self.footer_closed: self.bad_tail = True
        if tag == "html":
            if self.html_open or self.html_closed: raise ArchiveCoverageError("html-structure")
            self.html_open = True
        elif tag == "body":
            if not self.html_open or self.body_open or self.body_closed: raise ArchiveCoverageError("body-structure")
            self.body_open = True
        elif tag == self.container:
            if not self.body_open or self.container_open or self.container_closed: raise ArchiveCoverageError("listing-structure")
            self.container_open = True
        elif tag == "tbody" and self.group == "freetype":
            if not self.container_open or self.tbody_open or self.tbody_closed: raise ArchiveCoverageError("tbody-structure")
            self.tbody_open = True
        elif tag == "i" and self.group == "freetype" and self.container_closed:
            if self.footer_open or self.footer_closed: raise ArchiveCoverageError("footer-structure")
            self.footer_open = True
        if tag == "h1":
            if not self.body_open or self.in_h1 or self.headings: raise ArchiveCoverageError("heading-structure")
            self.in_h1 = True
        if tag == "a":
            hrefs = [value for key, value in attrs if key == "href"]
            if len(hrefs) != 1 or not isinstance(hrefs[0], str):
                raise ArchiveCoverageError("malformed-link")
            # Retain every anchor. The reviewed pages have no anchors outside
            # their listing container; an unknown header/footer link can be a
            # continuation or history page and must not be silently ignored.
            self.links.append((hrefs[0], self.container_open))
            if len(self.links) > MAX_LINKS: raise ArchiveCoverageError("link-bound")
    def handle_endtag(self, tag):
        if tag == "h1": self.in_h1 = False
        elif tag == "tbody" and self.group == "freetype":
            if not self.tbody_open: raise ArchiveCoverageError("tbody-structure")
            self.tbody_open = False
            self.tbody_closed = True
        elif tag == self.container:
            if not self.container_open or self.tbody_open: raise ArchiveCoverageError("listing-structure")
            self.container_open = False
            self.container_closed = True
        elif tag == "i" and self.group == "freetype" and self.footer_open:
            self.footer_open = False
            self.footer_closed = True
        elif tag == "body":
            if not self.body_open or self.container_open: raise ArchiveCoverageError("body-structure")
            self.body_open = False
            self.body_closed = True
        elif tag == "html":
            if not self.html_open or self.body_open: raise ArchiveCoverageError("html-structure")
            self.html_open = False
            self.html_closed = True
    def handle_data(self, data):
        if self.in_h1: self.headings.append(data)
        if self.footer_closed and data.strip(): self.bad_tail = True

    def complete(self):
        if self.in_h1 or self.container_open or not self.container_closed or self.bad_tail: return False
        if self.group == "freetype":
            # Savannah's retained root and old-directory pages end after </i>,
            # without explicit </body></html>; their closed tbody/table and
            # terminal footer are required. A future shape must be reviewed.
            return self.tbody_closed and self.footer_closed and not self.footer_open
        return self.body_closed and self.html_closed and not self.body_open and not self.html_open

def archive_url(group, value):
    """Validate only direct archive children of fixed, known official directories."""
    if group not in SOURCES or not isinstance(value, str): return False
    parts = urllib.parse.urlsplit(value)
    if parts.scheme != "https" or parts.query or parts.fragment or parts.username or parts.password:
        return False
    for page in SOURCES[group]:
        base = urllib.parse.urlsplit(page)
        if parts.netloc != base.netloc or not parts.path.startswith(base.path): continue
        name = parts.path[len(base.path):]
        match = re.fullmatch(re.escape(group) + r"-(.+)\.tar\.(?:gz|bz2|xz|lz|zst)", name)
        if match and VERSION.fullmatch(match[1]): return True
    return False

def parse_listing(group, page, raw):
    if group not in SOURCES or page not in SOURCES[group] or len(raw) > MAX_BYTES:
        raise ArchiveCoverageError("invalid-page-or-bound")
    try: text = raw.decode("utf-8", "strict")
    except UnicodeDecodeError as error: raise ArchiveCoverageError("invalid-encoding") from error
    parser = Listing(group)
    parser.feed(text)
    parser.close()
    expected = urllib.parse.urlsplit(page).path.rstrip("/")
    if not parser.complete() or "".join(parser.headings).strip().rstrip("/") != "Index of " + expected:
        raise ArchiveCoverageError("unknown-listing")
    result = {}
    expected_child = SOURCES[group][1] if len(SOURCES[group]) == 2 and page == SOURCES[group][0] else None
    child_seen = expected_child is None
    for href, inside_listing in parser.links:
        if not inside_listing:
            raise ArchiveCoverageError("unexpected-outer-link")
        if href in ("../", "/", "./"): continue
        if href.startswith("?"):
            if re.fullmatch(r"\?C=[NMSD][;&]O=[AD]", href): continue
            raise ArchiveCoverageError("unknown-query-or-pagination")
        if not href or href.startswith("#") or re.search(r"(?:^|/)(?:next|page[0-9]*)\b|\.(?:html?|php)(?:[?#]|$)", href, re.I):
            raise ArchiveCoverageError("unknown-pagination")
        # Source entries are filenames; reject host, path, escaping and URL tricks for candidate archives.
        url = urllib.parse.urljoin(page, href)
        if expected_child and url == expected_child and href in ("archive/", "freetype-old/"):
            child_seen = True
            continue
        if href.endswith("/"):
            # Only this unrelated directory occurs in the retained root. All
            # other non-parent directories require explicit evidence/review.
            if group == "freetype" and page == SOURCES[group][0] and href == "ttfautohint-old/": continue
            if href == "/gnu/" and group == "nettle" and page == SOURCES[group][0]: continue
            raise ArchiveCoverageError("unknown-history-directory")
        filename = href.rsplit("/", 1)[-1]
        if not filename.startswith(group + "-"): continue
        if re.search(r"\.tar\.(?:gz|bz2|xz|lz|zst)\.(?:asc|sig|pq\.asc|md5|sha1|sha256|sha512)$", filename): continue
        if re.fullmatch(re.escape(group) + r"-[0-9][0-9A-Za-z._+-]*\.(?:changelog|release|ANNOUNCE)(?:\.[a-z]{2})?", filename): continue
        # Non-version bundles (e.g. ffmpeg-snapshot and freetype-doc) are not releases.
        if not re.match(re.escape(group) + r"-[0-9]", filename): continue
        if not archive_url(group, url) or href != filename:
            raise ArchiveCoverageError("unknown-or-unsafe-archive")
        version = re.fullmatch(re.escape(group) + r"-(.+)\.tar\.(?:gz|bz2|xz|lz|zst)", filename)[1]
        result.setdefault(version, set()).add(url)
    if not child_seen or not result: raise ArchiveCoverageError("missing-history-or-versions")
    return result

def read_page(page):
    if page not in {p for pages in SOURCES.values() for p in pages}:
        raise ArchiveCoverageError("non-allowlisted-page")
    request = urllib.request.Request(page, headers={"User-Agent":"VortX-dependency-health/1.0", "Accept":"text/html"})
    # No proxy, cookies, auth handlers or redirects. This is a metadata-only request.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=30) as response:
        if response.status != 200 or response.geturl() != page: raise ArchiveCoverageError("unexpected-response")
        if response.headers.get_all("Link", []) or response.headers.get_all("Content-Range", []):
            raise ArchiveCoverageError("unsupported-continuation-or-range")
        lengths = response.headers.get_all("Content-Length", [])
        transfer = response.headers.get_all("Transfer-Encoding", [])
        encoding = response.headers.get_all("Content-Encoding", [])
        if len(lengths) > 1 or len(transfer) > 1 or len(encoding) > 1 or (lengths and transfer):
            raise ArchiveCoverageError("ambiguous-framing")
        if encoding and encoding[0].strip().lower() != "identity": raise ArchiveCoverageError("encoded-response")
        if lengths:
            if not re.fullmatch(r"[0-9]+", lengths[0]) or int(lengths[0]) > MAX_BYTES:
                raise ArchiveCoverageError("content-length-bound")
        elif not transfer or transfer[0].strip().lower() != "chunked":
            raise ArchiveCoverageError("unverifiable-response-framing")
        raw = response.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES: raise ArchiveCoverageError("response-bound")
    if lengths and len(raw) != int(lengths[0]): raise ArchiveCoverageError("truncated-response")
    return raw

def releases(group, stable_key, reader=read_page):
    if group not in SOURCES: raise ArchiveCoverageError("unknown-group")
    all_versions = {}
    for page in SOURCES[group]:
        for version, urls in parse_listing(group, page, reader(page)).items():
            all_versions.setdefault(version, set()).update(urls)
    versions = sorted(all_versions)
    stable = [v for v in versions if stable_key(v) is not None]
    return {"versions": versions, "latest_stable": max(stable, key=stable_key) if stable else None,
            "source": SOURCES[group][0], "archive_urls": {v: sorted(all_versions[v]) for v in versions}}

def valid_metadata(group, value):
    if group not in SOURCES or not isinstance(value, dict) or value.get("source") != SOURCES[group][0]: return False
    versions, urls = value.get("versions"), value.get("archive_urls")
    if not isinstance(versions, list) or not versions or len(versions) > MAX_LINKS: return False
    if any(not isinstance(v, str) for v in versions) or versions != sorted(set(versions)): return False
    if not isinstance(urls, dict) or set(urls) != set(versions): return False
    for version in versions:
        if not isinstance(version, str) or not VERSION.fullmatch(version): return False
        links = urls[version]
        if not isinstance(links, list) or not links or len(links) > MAX_LINKS: return False
        if any(not isinstance(link, str) for link in links) or links != sorted(set(links)): return False
        for link in links:
            if not archive_url(group, link): return False
            name = urllib.parse.urlsplit(link).path.rsplit("/", 1)[-1]
            if not name.startswith(group + "-" + version + ".tar."): return False
    return value.get("latest_stable") is None or value.get("latest_stable") in versions
