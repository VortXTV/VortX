#!/usr/bin/env python3
"""Acquire one reviewed public component; never build, install, publish or select a version."""
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import time
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from xml.parsers import expat
import zipfile

MAX_BYTES = 512 * 1024 * 1024
ABIS = {"arm64-v8a", "armeabi-v7a", "x86_64"}
LIBS = {"libmpv.so", "libplayer.so", "libc++_shared.so", "libavcodec.so",
        "libavformat.so", "libavutil.so", "libavfilter.so", "libavdevice.so",
        "libswresample.so", "libswscale.so"}
ASSET = re.compile(r"https://github\.com/VortXTV/VortX/releases/download/"
                   r"vendor-[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.aar")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def selection(path):
    fields = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        require(separator and key in {"url", "sha256"} and key not in fields,
                "Invalid component descriptor key")
        fields[key] = value.strip()
    require(set(fields) == {"url", "sha256"}, "Component descriptor requires both keys")
    url, checksum = fields["url"], fields["sha256"]
    if not url and not checksum:
        return None
    require(ASSET.fullmatch(url) and re.fullmatch(r"[0-9a-f]{64}", checksum),
            "Component selection requires one exact same-repository vendor AAR URL and SHA-256")
    return url, checksum


class ReleaseRedirects(HTTPRedirectHandler):
    max_redirections = 5

    def redirect_request(self, request, fp, code, message, headers, new_url):
        target = urlsplit(new_url)
        require(target.scheme == "https" and target.hostname in {
            "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"
        } and target.port in (None, 443) and not target.username and not target.password
                and not target.fragment, "Unapproved component download redirect")
        return super().redirect_request(request, fp, code, message, headers, new_url)


def manifest_identity(raw):
    """Read only manifest identity; forbid DTDs/entities before expansion, in any encoding."""
    require(len(raw) <= 65536, "Oversized AAR manifest")
    parser = expat.ParserCreate(namespace_separator="}")
    depth, elements, root, uses = 0, 0, None, []

    def reject_declaration(*unused):
        raise ValueError("Unsupported AAR manifest declarations")

    def start(name, attributes):
        nonlocal depth, elements, root
        depth += 1
        elements += 1
        require(depth <= 32 and elements <= 4096, "AAR manifest exceeds structure bound")
        if depth == 1:
            root = (name, attributes)
        elif depth == 2 and name == "uses-sdk":
            uses.append(attributes)

    def end(name):
        nonlocal depth
        depth -= 1

    parser.StartDoctypeDeclHandler = reject_declaration
    parser.EntityDeclHandler = reject_declaration
    parser.ExternalEntityRefHandler = reject_declaration
    parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_NEVER)
    parser.StartElementHandler, parser.EndElementHandler = start, end
    try:
        parser.Parse(raw, True)
    except expat.ExpatError as error:
        raise ValueError("Invalid AAR manifest XML") from error
    return root, uses


def verify_aar(path, checksum):
    require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= MAX_BYTES,
            "Missing, linked or oversized component AAR")
    require(sha256(path) == checksum, "Component AAR digest mismatch; refusing replacement")
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) <= 20000 and len(names) == len(set(names)), "Invalid AAR membership")
        require(all(not name.startswith("/") and "\\" not in name and
                    all(part not in ("", ".", "..") for part in name.rstrip("/").split("/"))
                    for name in names), "Unsafe AAR entry name")
        require(sum(item.file_size for item in archive.infolist()) <= 1024 * 1024 * 1024,
                "Oversized uncompressed AAR")
        require("classes.jar" in names and "AndroidManifest.xml" in names, "Not a complete AAR")
        require(archive.getinfo("AndroidManifest.xml").file_size <= 65536, "Oversized AAR manifest")
        manifest = archive.read("AndroidManifest.xml")
        root, uses = manifest_identity(manifest)
        require(root[0] == "manifest" and root[1].get("package") == "dev.jdtech.mpv"
                and len(uses) == 1
                and uses[0].get("http://schemas.android.com/apk/res/android}minSdkVersion") == "26",
                "Component AAR must retain the real minSdk 26 manifest")
        libraries = [name for name in names if name.startswith("jni/") and name.endswith(".so")]
        require(all(len(name.split("/")) == 3 for name in libraries), "Invalid native AAR layout")
        require({name.split("/")[1] for name in libraries} == ABIS, "Component ABI set differs")
        for abi in ABIS:
            present = {name.split("/")[-1] for name in libraries if name.startswith(f"jni/{abi}/")}
            require(LIBS <= present and all(archive.getinfo(f"jni/{abi}/{lib}").file_size > 0
                                          for lib in LIBS), "Incomplete component native payload")


def acquire(root):
    selected = selection(root / "android/mpv-component.properties")
    if selected is None:
        print("Android mpv component: unchanged Maven baseline (no download)")
        return
    url, checksum = selected
    cache = root / "android/.gradle/vortx-mpv-components" / checksum
    # Refuse a redirected local cache; do not alter or replace existing files.
    require(cache.resolve() == cache.absolute(), "Linked component cache path")
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / "libmpv.aar"
    if not target.exists() and not target.is_symlink():
        descriptor, temporary_name = tempfile.mkstemp(prefix="download-", suffix=".partial", dir=cache)
        temporary = Path(temporary_name)
        try:
            started, total = time.monotonic(), 0
            request = Request(url, headers={"User-Agent": "VortX-component-acquisition"})
            with os.fdopen(descriptor, "wb") as output:
                # No credentials, retry, TLS bypass or arbitrary initial URL. Standard CA validation.
                with build_opener(ReleaseRedirects()).open(request, timeout=30) as response:
                    require(response.status == 200, "Unexpected component download status")
                    while True:
                        require(time.monotonic() - started < 120, "Component download deadline")
                        # A single buffered read returns available bytes, allowing the wall-clock
                        # budget to be checked even if a server dribbles a response slowly.
                        block = response.read1(64 * 1024)
                        if not block:
                            break
                        total += len(block)
                        require(total <= MAX_BYTES, "Component download exceeds limit")
                        output.write(block)
            verify_aar(temporary, checksum)
            try:
                os.link(temporary, target)  # atomic create only; never replace a competing cache entry
            except FileExistsError:
                pass
        finally:
            temporary.unlink(missing_ok=True)  # only this invocation's uniquely created temporary file
    verify_aar(target, checksum)  # verify cached bytes as well; a bad cache never falls back/redownloads
    print(json.dumps({"componentURL": url, "sha256": checksum, "bytes": target.stat().st_size,
                      "minSdk": 26, "abis": sorted(ABIS), "runtimeSecurityTested": False}))


if __name__ == "__main__":
    try:
        acquire(Path(__file__).resolve().parents[1])
    except ValueError as error:
        raise SystemExit(str(error)) from None
    except Exception as error:
        # Redirect URLs can contain temporary signed query values: do not echo transport traces.
        raise SystemExit("Component acquisition failed (" + type(error).__name__ + ")") from None
