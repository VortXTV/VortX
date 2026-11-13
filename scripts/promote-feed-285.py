#!/usr/bin/env python3
"""Protected one-time operation for the already published Build 285."""

import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener
import zipfile

from importlib import import_module

guard = import_module("guard-feed-285")
OPS_TAG = "v0.5.6-ops-feed285-20261113"
STAGE_SHA = "72f6ab52f038e07658e5f3d57d43dc758726fee540dfb7ee45723fa87efa6117"
TARGET_RECEIPT = "4148a63443cfde8491cba7b72d22665ce48b9657e2fe029e3810d4d038110cd2"
TARGET = "v0.5.6-beta.13:285:f1880ad0551005ecd7ff55228513595ac18810a8c72118ea491a2cb99e4aea43"
OLD_RECEIPT = "fc66e74df174687e359b2420cc3c801907d4ebda94d3f07bb040bf7ae433937a"
OLD_APP_SOURCE = "35761135a71867d23a9c4ee83cbdb31fe65747bd"
BODY_SHA = "f6f611bdefc595f070ce89e78f10947a442bc858b344c5df7d7b3dc5ff1b56d4"
ANDROID_ARCHIVE = "ff6ecb5edfd87ca5cc0975b181a434af4af77978a8b52f286a8407df6f104596"
SOURCE_PATH = "altstore/source.json"
RAW_MAIN = f"https://raw.githubusercontent.com/{guard.REPO}/main/{SOURCE_PATH}"
RECEIPT_URL = "https://vortx.tv/__release/receipt"
BOT_IDENTITY = {"name": "Mamaclapper", "email": "50227842+mamaclapper@users.noreply.github.com"}
MAX_BYTES = 2 * 1024 * 1024
RAW_WAIT = 330
EDGE_WAIT = 150

require = guard.require
sha256 = guard.sha256


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def canonical(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def github(path, method="GET", body=None, output=None, timeout=30):
    args = ["gh", "api", "--method", method, "--", f"repos/{guard.REPO}/{path}"]
    if body is not None:
        args[4:4] = ["--input", "-"]
    env = {key: value for key, value in os.environ.items() if key not in {"RELEASE_FEED_RECEIPT_SECRET", "GH_DEBUG"}}
    result = subprocess.run(args, input=canonical(body) if body is not None else None,
                            stdout=output if output is not None else subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=timeout, env=env)
    require(result.returncode == 0, f"GitHub {method} failed for {path.split('?')[0]}")
    return guard.load(result.stdout) if output is None else None


def read_http(url, data=None, signature=None, *, follow=False):
    headers = {"Accept-Encoding": "identity", "User-Agent": "curl/8.5.0", "Cache-Control": "no-cache"}
    if signature is not None:
        headers.update({"Content-Type": "application/json", "X-VortX-Receipt": f"sha256={signature}"})
    opener = build_opener() if follow else build_opener(NoRedirect())
    with opener.open(Request(url, data=data, headers=headers), timeout=15) as response:
        raw = response.read(MAX_BYTES + 1)
        require(response.status == 200 and len(raw) <= MAX_BYTES, "HTTP response invalid or oversized")
        return raw, response.headers


def receipt(secret, body, retry=False):
    signature = hmac.new(secret, body, hashlib.sha256).hexdigest()
    for attempt in range(3 if retry else 1):
        try:
            data, _ = read_http(RECEIPT_URL, body, signature)
            return guard.load(data)
        except HTTPError as error:
            if error.code not in (500, 502, 503, 504) or not retry or attempt == 2:
                raise ValueError(f"authenticated feed {guard.load(body)['action']} failed: HTTP {error.code}") from None
        except (URLError, TimeoutError):
            if not retry or attempt == 2:
                raise ValueError(f"authenticated feed {guard.load(body)['action']} transport failed") from None
        time.sleep(3)


def active(secret):
    return receipt(secret, b'{"action":"read-active-receipt"}', retry=True).get("active")


def check_active(record, generation, release_id, receipt_sha, source_sha, appcast_sha, *, exact_payload=None):
    require(isinstance(record, dict) and isinstance(record.get("manifest"), dict), "durable active receipt unavailable")
    manifest = record["manifest"]
    expected_build = 285 if exact_payload is not None else 274
    expected_tag = guard.TAG if exact_payload is not None else "v0.5.5"
    expected_source = guard.SOURCE if exact_payload is not None else OLD_APP_SOURCE
    digest = record.get("receiptSha256")
    require(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest) is not None and
            (receipt_sha is None or digest == receipt_sha) and
            manifest.get("generation") == generation and str(manifest.get("releaseId")) == str(release_id) and
            manifest.get("tag") == expected_tag and str(manifest.get("build")) == str(expected_build) and
            manifest.get("sourceCommit") == expected_source and
            manifest.get("sourceSha256") == source_sha and manifest.get("appcastSha256") == appcast_sha and
            sha256(record["sourceText"].encode()) == source_sha and sha256(record["appcastText"].encode()) == appcast_sha,
            "durable active receipt identity or bytes differ")
    if exact_payload is not None:
        require(record.get("manifest") == exact_payload["manifest"] and
                all(record.get(stored) == exact_payload[wire] for stored, wire in
                    (("sourceText", "source"), ("appcastText", "appcast"), ("checksumText", "checksum"))),
                "durable Build 285 receipt differs from reviewed stage")
    return digest


def current_main():
    ref = github("git/ref/heads/main")
    require(ref["ref"] == "refs/heads/main" and ref["object"]["type"] == "commit", "main ref differs")
    return ref


def main_source(head):
    content = github(f"contents/{SOURCE_PATH}?ref={head}")
    require(content.get("type") == "file" and content.get("path") == SOURCE_PATH and
            content.get("encoding") == "base64", "main install-source content identity differs")
    return base64.b64decode("".join(content["content"].split()), validate=True)


def source_commit(head, body, message):
    require(current_main()["object"]["sha"] == head, "main moved before install-source compare-and-swap")
    base_tree = github(f"git/commits/{head}")["tree"]["sha"]
    blob = github("git/blobs", "POST", {"content": base64.b64encode(body).decode(), "encoding": "base64"})["sha"]
    tree = github("git/trees", "POST", {"base_tree": base_tree, "tree": [
        {"path": SOURCE_PATH, "mode": "100644", "type": "blob", "sha": blob}
    ]})["sha"]
    commit = github("git/commits", "POST", {"message": message, "tree": tree, "parents": [head],
                                        "author": BOT_IDENTITY, "committer": BOT_IDENTITY})["sha"]
    require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None and current_main()["object"]["sha"] == head,
            "new main commit invalid or main moved")
    return commit


def advance_main(commit):
    result = github("git/refs/heads/main", "PATCH", {"sha": commit, "force": False})
    require(result["object"]["sha"] == commit, "main did not accept the exact install-source commit")


def wait_raw(expected):
    def check():
        raw, _ = read_http(RAW_MAIN)
        require(raw == expected, "anonymous raw main install source did not converge to exact bytes")
    wait_readback(check, RAW_WAIT)


def wait_readback(check, timeout):
    deadline = time.monotonic() + timeout
    while True:
        try:
            check()
            return
        except (URLError, TimeoutError, ValueError):
            if time.monotonic() >= deadline:
                raise
        time.sleep(5)


def verify_routes(generation, expected, *, queries):
    for name, digest in expected.items():
        for query in ("", "?feed-verify=" + generation) if queries else ("",):
            raw, headers = read_http(f"https://vortx.tv/{name}{query}")
            require(sha256(raw) == digest and headers.get_all("x-vortx-feed-generation") == [generation] and
                    headers.get_all("x-vortx-feed-state") == ["active"],
                    f"{name} did not return exact active bytes and generation")


def check_release(packages, directory=None):
    responses = {"latest.json": github("releases/latest"), "release.json": github(f"releases/{guard.RELEASE}")}
    for name, record in responses.items():
        _, body = guard.release_identity(record)
        require(sha256(body.encode()) == BODY_SHA, "public release body drifted since review")
        guard.verified_assets(record, packages)
        if directory is not None:
            (directory / name).write_bytes(canonical(record))


def take_evidence(directory):
    for prefix, tag, obj in (("", guard.TAG, guard.TAG_OBJECT),
                             ("candidate-", guard.CANDIDATE, guard.CANDIDATE_OBJECT)):
        (directory / f"{prefix}tag-ref.json").write_bytes(canonical(github(f"git/ref/tags/{tag}")))
        (directory / f"{prefix}tag-object.json").write_bytes(canonical(github(f"git/tags/{obj}")))
    main = current_main()
    (directory / "main-ref.json").write_bytes(canonical(main))
    old_main = main_source(main["object"]["sha"])
    (directory / "main-source.json").write_bytes(old_main)
    for name in guard.EXPECTED_ROUTES:
        raw, headers = read_http(f"https://vortx.tv/{name}")
        (directory / name).write_bytes(raw)
        (directory / (name + ".headers")).write_text(
            "".join(f"{key}: {headers.get(key)}\n" for key in ("x-vortx-feed-generation", "x-vortx-feed-state")),
            encoding="ascii")
    for name in (guard.PROVENANCE_NAME, "SHA256SUMS.txt"):
        body, _ = read_http(f"https://github.com/{guard.REPO}/releases/download/{guard.TAG}/{name}", follow=True)
        (directory / name).write_bytes(body)
    return old_main


def hosted_receipts(directory):
    prior = github("actions/runs/43102337340")
    require((prior["id"], prior["event"], prior["head_branch"], prior["head_sha"], prior["run_attempt"],
             prior["status"], prior["conclusion"], prior["workflow_id"]) ==
            (43102337340, "release", guard.TAG, guard.SOURCE, 1, "completed", "success", 293211344),
            "read-only published asset verification identity differs")
    jobs = github("actions/runs/43102337340/attempts/1/jobs")["jobs"]
    expected = [row for row in jobs if row["id"] == 130796722876]
    require(len(expected) == 1 and expected[0]["name"] == "verify-hosted-direct-beta" and
            expected[0]["status"] == "completed" and expected[0]["conclusion"] == "success" and
            any(step["name"] == "Verify original CI handoffs and all public beta bytes without feed writes" and
                step["conclusion"] == "success" for step in expected[0]["steps"]),
            "read-only original public package verification is missing")
    artifact = github("actions/artifacts/13863521461")
    run = artifact["workflow_run"]
    require((artifact["id"], artifact["name"], artifact["size_in_bytes"], artifact["digest"], artifact["expired"]) ==
            (13863521461, "VortX-Android-release", 201681040, "sha256:" + ANDROID_ARCHIVE, False) and
            (run["id"], run["head_sha"], run["head_branch"], run["repository_id"], run["head_repository_id"]) ==
            (43032604411, guard.SOURCE, guard.CANDIDATE, 1261501126, 1261501126),
            "original Android hosted artifact identity differs")
    archive = directory / "original-android.zip"
    with archive.open("wb") as stream:
        github("actions/artifacts/13863521461/zip", output=stream, timeout=120)
    with archive.open("rb") as stream:
        require(archive.stat().st_size == 201681040 and hashlib.file_digest(stream, "sha256").hexdigest() == ANDROID_ARCHIVE,
                "original Android artifact ZIP bytes differ")
    with zipfile.ZipFile(archive) as original:
        for name in ("SHA256SUMS-android.txt", "SIGNING_PROVENANCE.txt"):
            entries = [item for item in original.infolist() if item.filename == name]
            require(len(entries) == 1 and 0 < entries[0].file_size <= 1024 * 1024,
                    f"original Android evidence roster differs for {name}")
            (directory / name).write_bytes(original.read(entries[0]))


def run_context():
    expected = {"GITHUB_REPOSITORY": guard.REPO, "GITHUB_REPOSITORY_ID": "1261501126",
                "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_ACTOR": "mamaclapper",
                "GITHUB_ACTOR_ID": "50227842", "GITHUB_RUN_ATTEMPT": "1",
                "GITHUB_REF": f"refs/tags/{OPS_TAG}",
                "GITHUB_WORKFLOW_REF": f"{guard.REPO}/.github/workflows/recover-release-feed.yml@refs/tags/{OPS_TAG}",
                "RELEASE_ID": str(guard.RELEASE), "RELEASE_TAG": guard.TAG, "GENERATION": TARGET,
                "EXPECTED_ACTIVE_GENERATION": guard.OLD_GENERATION, "SOURCE_COMMIT": guard.SOURCE}
    require(all(os.environ.get(key) == value for key, value in expected.items()), "workflow dispatch identity differs")
    run = github(f"actions/runs/{int(os.environ['GITHUB_RUN_ID'])}")
    require(run["workflow_id"] == 345603253 and run["head_sha"] == os.environ["GITHUB_SHA"] and
            run["head_branch"] == OPS_TAG and run["path"].split("@", 1)[0] == ".github/workflows/recover-release-feed.yml" and
            run["run_attempt"] == 1 and run["event"] == "workflow_dispatch",
            "workflow ID, run or operations tag differs")
    commit = github(f"commits/{os.environ['GITHUB_SHA']}")
    require([parent["sha"] for parent in commit["parents"]] == [guard.MAIN] and
            {row["filename"] for row in commit["files"]} ==
            {".github/workflows/recover-release-feed.yml", "scripts/guard-feed-285.py",
             "scripts/promote-feed-285.py", "scripts/feed-285-stage.json"},
            "operations commit parent or file scope differs")
    return os.environ.pop("RELEASE_FEED_RECEIPT_SECRET").encode()


def promote(secret, stage_path):
    stage_bytes = stage_path.read_bytes()
    require(sha256(stage_bytes) == STAGE_SHA, "unsigned stage request bytes differ from reviewed SHA-256")
    stage = guard.load(stage_bytes)
    manifest = stage["manifest"]
    require(manifest["generation"] == TARGET and manifest["sourceCommit"] == guard.SOURCE and
            manifest["releaseId"] == str(guard.RELEASE) and stage["action"] == "stage",
            "unsigned stage request identity differs")
    semantic = canonical({key: stage[key] for key in ("action", "manifest", "source", "appcast", "checksum")})
    require(sha256(semantic) == TARGET_RECEIPT, "stage semantic receipt digest differs")
    new_source = stage["source"].encode()
    target_routes = {"appcast.json": manifest["appcastSha256"], "altstore.json": manifest["sourceSha256"],
                     "vortx-altstore.json": manifest["sourceSha256"]}

    with tempfile.TemporaryDirectory(prefix="vortx-feed285-", dir=os.environ["RUNNER_TEMP"]) as scratch:
        directory = Path(scratch)
        old_source = take_evidence(directory)
        provenance = guard.load((directory / guard.PROVENANCE_NAME).read_bytes())
        packages = provenance["artifacts"]
        check_release(packages, directory)
        hosted_receipts(directory)
        guard.verify(directory, directory, Path.cwd())
        old_public_source, _ = read_http(RAW_MAIN)
        require(old_public_source == old_source, "initial anonymous raw main source bytes differ")
        verify_routes(guard.OLD_GENERATION, guard.EXPECTED_ROUTES, queries=True)
        old_digest = check_active(active(secret), guard.OLD_GENERATION, 415681390, OLD_RECEIPT,
                                  guard.OLD_SOURCE, guard.OLD_APPCAST)
        print(f"Authenticated predecessor: {guard.OLD_GENERATION}, receipt {old_digest}", flush=True)
        response = receipt(secret, stage_bytes, retry=True)
        require(response.get("staged") is True and response.get("generation") == TARGET and
                str(response.get("releaseId")) == str(guard.RELEASE) and
                response.get("receiptSha256") == TARGET_RECEIPT, "stage did not accept exact receipt")
        print(f"Staged immutable generation {TARGET}, receipt {TARGET_RECEIPT}", flush=True)
        check_release(packages)
        check_active(active(secret), guard.OLD_GENERATION, 415681390, old_digest, guard.OLD_SOURCE, guard.OLD_APPCAST)
        verify_routes(guard.OLD_GENERATION, guard.EXPECTED_ROUTES, queries=False)

        written = source_commit(guard.MAIN, new_source, "chore(release): repair Build 285 install feed")
        edge_attempted = False
        try:
            advance_main(written)
            require(main_source(written) == new_source, "committed install source differs")
            wait_raw(new_source)
            require(current_main()["object"]["sha"] == written, "main moved before feed promotion")
            check_release(packages)
            edge_attempted = True
            response = receipt(secret, canonical({"action": "promote", "operationId": f"promote:{guard.RELEASE}:{TARGET}",
                                                  "releaseId": str(guard.RELEASE), "generation": TARGET,
                                                  "expectedActiveGeneration": guard.OLD_GENERATION}), retry=True)
            require(response.get("promoted") is True and response.get("generation") == TARGET and
                    response.get("receiptSha256") == TARGET_RECEIPT and
                    (response.get("previousGeneration") == guard.OLD_GENERATION or
                     (response.get("idempotent") is True and response.get("previousGeneration") == TARGET)),
                    "promotion did not accept exact receipt")
            check_active(active(secret), TARGET, guard.RELEASE, TARGET_RECEIPT,
                         manifest["sourceSha256"], manifest["appcastSha256"], exact_payload=stage)
            wait_readback(lambda: verify_routes(TARGET, target_routes, queries=True), EDGE_WAIT)
            final_raw, _ = read_http(RAW_MAIN)
            require(final_raw == new_source and current_main()["object"]["sha"] == written,
                    "canonical raw main source or committed head drifted after promotion")
            check_release(packages)
            print(f"Verified existing Latest Build 285 on all three routes and main commit {written}.", flush=True)
        except Exception:
            failures = []
            durable_restored = not edge_attempted
            if edge_attempted:
                try:
                    observed = active(secret)
                    if observed["manifest"]["generation"] == TARGET:
                        check_active(observed, TARGET, guard.RELEASE, TARGET_RECEIPT,
                                     manifest["sourceSha256"], manifest["appcastSha256"], exact_payload=stage)
                        try:
                            response = receipt(secret, canonical({"action": "rollback", "expectedCurrentGeneration": TARGET,
                                                                  "restoreGeneration": guard.OLD_GENERATION}))
                            require(response.get("rolledBack") is True and
                                    response.get("generation") == guard.OLD_GENERATION, "edge rollback acknowledgement differs")
                        except ValueError:
                            # A lost response is safe only if the next read proves the exact old receipt.
                            pass
                    check_active(active(secret), guard.OLD_GENERATION, 415681390, old_digest,
                                 guard.OLD_SOURCE, guard.OLD_APPCAST)
                    durable_restored = True
                except Exception:
                    failures.append("durable feed")
            if durable_restored:
                try:
                    head = current_main()["object"]["sha"]
                    current_source = main_source(head)
                    if current_source == new_source:
                        require(head == written or github(f"compare/{written}...{head}")["status"] == "ahead",
                                "current main does not descend from our exact write")
                        restore = source_commit(head, old_source, "chore(release): restore previous install feed")
                        advance_main(restore)
                    else:
                        require(current_source == old_source, "unrelated main source change prevents compensation")
                    wait_raw(old_source)
                except Exception:
                    failures.append("raw main install source")
                if edge_attempted:
                    try:
                        wait_readback(lambda: verify_routes(guard.OLD_GENERATION, guard.EXPECTED_ROUTES, queries=True), EDGE_WAIT)
                    except Exception:
                        failures.append("public feed")
            else:
                print("Preserved main install source because the old durable feed could not be established.", file=sys.stderr)
            if failures:
                print(f"::error::Compensation incomplete for {', '.join(failures)}. Inspect exact state before retry.", file=sys.stderr)
            else:
                print("Verified previous feed and main source after compensation.", flush=True)
            raise


if __name__ == "__main__":
    try:
        secret = run_context()
        require(bool(secret), "protected feed secret is unavailable")
        promote(secret, Path(__file__).with_name("feed-285-stage.json"))
    except (KeyError, OSError, TypeError, ValueError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"::error::Build 285 feed operation stopped ({type(error).__name__}): {error}", file=sys.stderr)
        sys.exit(1)
