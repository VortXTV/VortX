#!/usr/bin/env python3
"""Render and run one protected combined-feed promotion for VortX stable 0.5.7."""

import argparse
import base64
import hashlib
import hmac
import io
import json
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
import re
import subprocess
import sys
import time
import zipfile
from functools import lru_cache
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

REPO = "VortXTV/VortX"
TAG = "v0.5.7"
VERSION = "0.5.7"
BUILD = 302
SOURCE = "c56213a20fe064b0ac1ac0cc8e607c2ef449fea1"
TAG_OBJECT = "3ab4a5810b2882617a0fb6f39bf5ed5fd34a0d32"
RELEASE_ID = 447897160
REPO_ID = 1261501126
OPS_TAG = "v0.5.7-ops-combined-feed-20261117"
OPS_WORKFLOW = ".github/workflows/recover-release-feed.yml"
OPS_WORKFLOW_ID = 345603253
ATTACH_TAG = "v0.5.7-ops-attach-20261117"
ATTACH_ARTIFACT = "VortX-Stable-057-Apple-Attachment-Receipt"
ATTACH_STEP = "Attach and authenticate the five original Apple draft assets"
ORIGINAL_ATTACH_ID = 133815991705
ORIGINAL_ATTACH_FAILURE = "Download and authenticate immutable handoff archives"
SOURCE_PATH = "altstore/source.json"
RAW_MAIN = f"https://raw.githubusercontent.com/{REPO}/main/{SOURCE_PATH}"
RECEIPT_URL = "https://vortx.tv/__release/receipt"
OPS_SCRIPT = "stable-057-feed.py"
OPS_PLAN = "stable-057-plan.json"
OPS_STAGE = "stable-057-stage.json"
SUMS = "SHA256SUMS.txt"
PROVENANCE = "VortX-CI-Provenance.json"
SIGNER = "FC22B87ECD9E4FA26930A1C3E227D8F7D918C646B216032B5DA820EF1AC218CA"
BOT_IDENTITY = {"name": "Mamaclapper", "email": "50227842+mamaclapper@users.noreply.github.com"}
MAX_BYTES = 2 * 1024 * 1024
MAX_PLAN_BYTES = 1024 * 1024
MAX_STAGE_BYTES = 1024 * 1024
MAX_PACKAGE_BYTES = 1024 * 1024 * 1024
PUBLIC_VERIFY_WAIT = 360
RAW_WAIT = 330
EDGE_WAIT = 150
PACKAGES = {
    "ios": f"VortX-iOS-{TAG}-ci.ipa",
    "tvos": f"VortX-tvOS-{TAG}-ci.ipa",
    "tvosLite": f"VortX-tvOS-lite-{TAG}-ci.ipa",
    "mac": f"VortX-macOS-{TAG}-ci.dmg",
    "androidFull": f"VortX-{VERSION}-full-mpv-universal.apk",
    "androidPlay": f"VortX-{VERSION}-play-media3-universal.apk",
    "androidBundle": f"VortX-{VERSION}-play-media3.aab",
}
REQUIRED_ASSETS = set(PACKAGES.values()) | {SUMS, PROVENANCE}
APPLE_SUMS = "SHA256SUMS-ci.txt"
ANDROID_SUMS = "SHA256SUMS-android.txt"
ANDROID_SIGNING = "SIGNING_PROVENANCE.txt"
REQUIRED_ASSETS |= {APPLE_SUMS, ANDROID_SUMS, ANDROID_SIGNING}
OLD = {
    "id": 446921868,
    "tag": "v0.5.6-beta.15",
    "build": 301,
    "source": "44c1fe53ed4012561f5326baba6e2d5951af18d4",
    "publishedAt": "2026-11-16T11:23:52Z",
    "bodySha256": "9d75515f418b071e44625aaa7570ff4b7faa5a32016e057e45a4c548489e6570",
    "generation": "v0.5.6-beta.15:301:9b5d98edbb135958738be10ca7bf3619fa3e7592c9b81953448ae7c839e15310",
    "receipt": "e99054d99153d31171c734197509ce3462b8f795e23b8fa9d3c7dd0ca5b248e9",
    "sourceSha256": "c585793974a95b8f21386f7dc23ae3366b65cff9bdea6f1eb645083c16849141",
    "appcastSha256": "322a5302ce1748e2bf9bbb014dd06f2b1a30b09b90eb6ee897f02fdea20136c8",
    "checksumSha256": "c22153a3d4e0f57e46db2c2b68413b25342f94e464f45ea97f7f9759d33b2d86",
}
BUILD_LANES = {
    "apple": (43995790455, 293211344, ".github/workflows/release-tvos.yml", "build-tvos", "VortX-tvOS-ci"),
    "android": (43995790267, 342394030, ".github/workflows/android-release.yml", "release-android", "VortX-Android-release"),
}
BINDINGS_KEYS = {"schemaVersion", "releaseId", "releaseName", "releaseBodySha256",
                 "sourceCommit", "tagObject", "mainHead", "assets", "attachment"}
PLAN_KEYS = BINDINGS_KEYS | {"stageSha256", "receiptSha256", "generation"}
STAGE_KEYS = {"schemaVersion", "action", "manifest", "source", "appcast", "checksum"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(raw):
    return hashlib.sha256(raw).hexdigest()


def hex_value(value, length):
    return isinstance(value, str) and re.fullmatch(f"[0-9a-f]{{{length}}}", value) is not None


def positive_int(value):
    return type(value) is int and 0 < value < 2**53


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "JSON contains a duplicate key")
        result[key] = value
    return result


def reject_nonfinite(_value):
    raise ValueError("JSON contains a non-finite number")


def load(raw):
    return json.loads(raw, object_pairs_hook=unique_keys, parse_constant=reject_nonfinite)


def canonical(obj):
    return json.dumps(obj, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")).encode()


def file_bytes(path, limit):
    with path.open("rb") as stream:
        raw = stream.read(limit + 1)
    require(0 < len(raw) <= limit, f"{path.name} is empty or oversized")
    return raw


def asset_url(name):
    return f"https://github.com/{REPO}/releases/download/{TAG}/{name}"


def checksum_records(raw):
    records = {}
    for line in raw.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9.-]+)", line)
        require(match is not None and match[2] not in records, "checksum file has malformed or duplicate entries")
        records[match[2]] = match[1]
    return records


def bind_stage_asset(entry, name, record):
    expected = {"name": name, "checksumName": name, "url": asset_url(name),
                "size": record["size"], "sha256": record["sha256"], "state": "uploaded", "assetId": record["id"]}
    require(entry == expected, f"stage asset metadata differs for {name}")


def validate_bindings(plan, *, rendered):
    require(isinstance(plan, dict) and plan.keys() == (PLAN_KEYS if rendered else BINDINGS_KEYS) and
            type(plan["schemaVersion"]) is int and plan["schemaVersion"] == 1, "operation plan schema differs")
    require(plan["sourceCommit"] == SOURCE and plan["tagObject"] == TAG_OBJECT and
            hex_value(plan["mainHead"], 40) and hex_value(plan["releaseBodySha256"], 64),
            "source, tag, main or release-body pin differs")
    require(plan["releaseId"] == RELEASE_ID and
            isinstance(plan["releaseName"], str) and 0 < len(plan["releaseName"]) <= 200,
            "stable draft release identity differs")
    assets = plan["assets"]
    require(isinstance(assets, dict) and assets.keys() == REQUIRED_ASSETS, "published 12-asset roster differs")
    for name, item in assets.items():
        maximum = MAX_PACKAGE_BYTES if name in PACKAGES.values() else MAX_BYTES
        require(isinstance(item, dict) and item.keys() == {"id", "size", "sha256"} and
                positive_int(item["id"]) and positive_int(item["size"]) and item["size"] <= maximum and
                hex_value(item["sha256"], 64), "invalid published asset record")
    require(len({item["id"] for item in assets.values()}) == len(assets), "published asset IDs must be distinct")
    attachment = plan["attachment"]
    require(isinstance(attachment, dict) and attachment.keys() == {"runId", "jobId", "coordinatorCommit",
                "tagObject", "artifactId", "artifactSize", "artifactSha256"} and
            all(positive_int(attachment[key]) for key in ("runId", "jobId", "artifactId", "artifactSize")) and
            attachment["artifactSize"] <= MAX_PLAN_BYTES and
            all(hex_value(attachment[key], 40) for key in ("coordinatorCommit", "tagObject")) and
            hex_value(attachment["artifactSha256"], 64), "approved Apple attachment proof differs")


def verify_stage(plan, raw):
    require(0 < len(raw) <= MAX_STAGE_BYTES, "stage exceeds the Worker body limit or is empty")
    stage = load(raw)
    require(isinstance(stage, dict) and stage.keys() == STAGE_KEYS and stage["schemaVersion"] == 2 and
            stage["action"] == "stage" and all(isinstance(stage[key], str) for key in ("source", "appcast", "checksum")),
            "stage payload schema differs")
    manifest = stage["manifest"]
    require(isinstance(manifest, dict) and manifest.keys() == {"schemaVersion", "tag", "version", "build",
            "sourceCommit", "name", "notes", "prerelease", "releaseId", "generation", "sourceSha256", "appcastSha256",
            "checksumSha256", "feedSha256", "assets", "checksumAsset", "android"} and manifest["schemaVersion"] == 2 and
            manifest["tag"] == TAG and manifest["version"] == VERSION and manifest["build"] == BUILD and
            manifest["sourceCommit"] == plan["sourceCommit"] and manifest["releaseId"] == str(plan["releaseId"]) and
            manifest["prerelease"] is False and manifest["name"] == plan["releaseName"] and
            isinstance(manifest["notes"], str) and 0 < len(manifest["notes"]) <= 20000 and
            "vortx-distribution:" not in manifest["notes"] and "vortx-channel:" not in manifest["notes"],
            "stage is not the exact Build 302 stable release")
    for wire, field in (("source", "sourceSha256"), ("appcast", "appcastSha256"), ("checksum", "checksumSha256")):
        require(sha256(stage[wire].encode()) == manifest[field], f"stage {wire} bytes differ")
    feed_digest = sha256("\n".join(stage[key] for key in ("source", "appcast", "checksum")).encode())
    require(manifest["feedSha256"] == feed_digest and manifest["generation"] == f"{TAG}:{BUILD}:{feed_digest}",
            "stage generation differs from exact source, appcast and checksum bytes")
    require(manifest["assets"].keys() == PACKAGES.keys(), "stage must carry all seven release packages")
    for key, name in PACKAGES.items():
        bind_stage_asset(manifest["assets"][key], name, plan["assets"][name])
    bind_stage_asset(manifest["checksumAsset"], SUMS, plan["assets"][SUMS])
    require(len(stage["checksum"].encode()) == plan["assets"][SUMS]["size"] and
            manifest["checksumSha256"] == plan["assets"][SUMS]["sha256"] and
            checksum_records(stage["checksum"]) == {name: plan["assets"][name]["sha256"] for name in PACKAGES.values()},
            "combined checksums do not bind exactly the seven packages")
    verify_feed_entries(stage, manifest)
    receipt_sha = sha256(canonical({key: stage[key] for key in STAGE_KEYS - {"schemaVersion"}}))
    return stage, {"stageSha256": sha256(raw), "receiptSha256": receipt_sha, "generation": manifest["generation"]}


def verify_feed_entries(stage, manifest):
    appcast = load(stage["appcast"])
    require(len(stage["appcast"].encode()) <= 512 * 1024 and appcast["schemaVersion"] == 2 and
            appcast["_generatedFromTag"] == TAG and appcast["_generatedFromCommit"] == manifest["sourceCommit"],
            "appcast metadata differs from the stable release")
    common = {"tag": TAG, "version": VERSION, "build": BUILD, "name": manifest["name"],
              "notes": manifest["notes"], "prerelease": False}
    for platform, kind in (("ios", "ipa"), ("tvos", "ipa"), ("mac", "dmg")):
        asset = manifest["assets"][platform]
        expected = common | {"url": asset["url"], "ipa": asset["url"], "size": asset["size"],
                             "sha256": asset["sha256"], "artifactType": kind,
                             "altstore": "https://vortx.tv/altstore.json" if platform == "ios" else None}
        require(all(appcast[platform].get(key) == value for key, value in expected.items()),
                f"appcast entry differs for {platform}")
    android = {}
    for flavor, engine, key in (("full", "mpv", "androidFull"), ("play", "media3", "androidPlay")):
        asset = manifest["assets"][key]
        android[flavor] = common | {"versionCode": BUILD, "flavor": flavor, "engine": engine,
                                   "applicationId": "com.vortx.android", "artifactType": "apk", "signed": True,
                                   "url": asset["url"], "size": asset["size"], "sha256": asset["sha256"], "signer": SIGNER}
    require(manifest["android"] == android and appcast["android"] == android,
            "stage and appcast must contain both exact signed Build 302 Android variants")
    apps = load(stage["source"])["apps"]
    for bundle, key, minimum in (("com.stremiox.app.native", "ios", "16.0"), ("com.stremiox.tv", "tvos", "18.0")):
        rows = [app for app in apps if app["bundleIdentifier"] == bundle]
        require(len(rows) == 1 and rows[0]["versions"], f"AltStore has an invalid roster for {bundle}")
        versions = rows[0]["versions"]
        asset = manifest["assets"][key]
        head = versions[0]
        require(str(head["buildVersion"]) == str(BUILD) and head["version"] == VERSION and
                head["minOSVersion"] == minimum and head["downloadURL"] == asset["url"] and
                head["size"] == asset["size"] and head["sha256"] == asset["sha256"],
                f"AltStore head differs for {bundle}")
        require(len(versions) > 1 and str(versions[1]["buildVersion"]) == str(OLD["build"]) and
                len({str(row["buildVersion"]) for row in versions}) == len(versions),
                f"AltStore omits the prior verified build or repeats a version for {bundle}")


def render(bindings_path, stage_path, output):
    plan = load(file_bytes(bindings_path, MAX_PLAN_BYTES))
    validate_bindings(plan, rendered=False)
    stage_raw = file_bytes(stage_path, MAX_STAGE_BYTES)
    _, stage_pins = verify_stage(plan, stage_raw)
    plan_raw = canonical(plan | stage_pins) + b"\n"
    template = Path(__file__).with_name("recover-release-feed.template.yml").read_text()
    require(template.count("@PLAN_SHA256@") == 2, "workflow plan placeholders differ")
    workflow = template.replace("@PLAN_SHA256@", sha256(plan_raw))
    output.mkdir()
    (output / ".github/workflows").mkdir(parents=True)
    (output / "scripts").mkdir()
    (output / OPS_WORKFLOW).write_text(workflow)
    (output / "scripts" / OPS_SCRIPT).write_bytes(Path(__file__).read_bytes())
    (output / "scripts" / OPS_PLAN).write_bytes(plan_raw)
    (output / "scripts" / OPS_STAGE).write_bytes(stage_raw)
    print(f"Plan SHA-256 {sha256(plan_raw)}")
    print(f"Target generation {stage_pins['generation']}")


class ReleaseDownloads(HTTPRedirectHandler):
    """GitHub may redirect public release assets to these HTTPS download hosts."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urlsplit(newurl)
        require(parsed.scheme == "https" and parsed.netloc in {
            "release-assets.githubusercontent.com", "objects.githubusercontent.com",
        }, "unexpected public release download redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


@lru_cache(maxsize=1)
def github_raw_options():
    result = subprocess.run(["gh", "api", "--help"], capture_output=True, check=True, timeout=10)
    if b"--allow-escape-sequences" in result.stdout:
        return ["--allow-escape-sequences"]
    return []


def github(path, method="GET", body=None, *, octet_stream=False):
    args = ["gh", "api", "--method", method]
    if body is not None:
        args.extend(["--input", "-"])
    if octet_stream:
        args.extend(github_raw_options())
        if path.startswith("releases/assets/"):
            args.extend(["--header", "Accept: application/octet-stream"])
    args.extend(["--", f"repos/{REPO}/{path}"])
    env = {key: value for key, value in os.environ.items() if key not in {"RELEASE_FEED_RECEIPT_SECRET", "GH_DEBUG"}}
    result = subprocess.run(args, input=None if body is None else canonical(body),
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30, env=env)
    require(result.returncode == 0, f"GitHub {method} failed for {path.split('?')[0]}")
    return result.stdout if octet_stream else load(result.stdout)


def read_http(url, *, data=None, signature=None):
    headers = {"Accept-Encoding": "identity", "User-Agent": "curl/8.5.0", "Cache-Control": "no-cache"}
    if signature is not None:
        headers.update({"Content-Type": "application/json", "X-VortX-Receipt": f"sha256={signature}"})
    opener = build_opener(NoRedirect())
    with opener.open(Request(url, data=data, headers=headers), timeout=15) as response:
        raw = response.read(MAX_BYTES + 1)
        require(response.status == 200 and 0 < len(raw) <= MAX_BYTES, "HTTP response invalid or oversized")
        return raw, response.headers


def receipt(secret, payload, *, retry=False):
    body = payload if isinstance(payload, bytes) else canonical(payload)
    action = load(body)["action"]
    signature = hmac.new(secret, body, hashlib.sha256).hexdigest()
    attempts = 3 if retry else 1
    for idx in range(attempts):
        try:
            raw, _ = read_http(RECEIPT_URL, data=body, signature=signature)
            return load(raw)
        except HTTPError as error:
            if error.code not in (500, 502, 503, 504) or idx == attempts - 1:
                raise ValueError(f"authenticated feed {action} failed: HTTP {error.code}") from None
        except (URLError, TimeoutError):
            if idx == attempts - 1:
                raise ValueError(f"authenticated feed {action} transport failed") from None
        time.sleep(3)


def wait_readback(check, timeout):
    deadline = time.monotonic() + timeout
    while True:
        try:
            return check()
        except (URLError, TimeoutError, ValueError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(5)


def verify_tag():
    ref = github(f"git/ref/tags/{TAG}")
    obj = github(f"git/tags/{TAG_OBJECT}")
    require(ref["ref"] == f"refs/tags/{TAG}" and ref["object"]["type"] == "tag" and
            ref["object"]["sha"] == TAG_OBJECT and obj["sha"] == TAG_OBJECT and obj["tag"] == TAG and
            obj["object"]["type"] == "commit" and obj["object"]["sha"] == SOURCE,
            "annotated stable tag differs from reviewed source")


def release_assets(record, plan, *, draft, published_at=None):
    require(record["id"] == RELEASE_ID and record["tag_name"] == TAG and record["target_commitish"] == SOURCE and
            record["draft"] is draft and record["prerelease"] is False and
            (published_at is None or record["published_at"] == published_at) and
            record["name"] == plan["releaseName"], "stable release identity or publication time differs")
    body = record["body"]
    marker = f"<!-- vortx-ci-provenance-sha256: {plan['assets'][PROVENANCE]['sha256']} -->"
    require(sha256(body.encode()) == plan["releaseBodySha256"] and body.splitlines().count(marker) == 1 and
            "vortx-channel:" not in body and "vortx-distribution:" not in body,
            "published release notes, stable channel or provenance binding differs")
    assets = record["assets"]
    indexed = {row["name"]: row for row in assets}
    require(len(indexed) == len(assets) and indexed.keys() == plan["assets"].keys(),
            "public stable release contains missing, duplicate or unexpected asset names")
    html = record.get("html_url")
    temporary = None
    if draft and isinstance(html, str):
        temporary = re.fullmatch(rf"https://github\.com/{re.escape(REPO)}/releases/tag/(untagged-[0-9a-f]{{20}})", html)
    for name, item in plan["assets"].items():
        row = indexed[name]
        url = row["browser_download_url"]
        valid_url = url == asset_url(name) or (
            temporary is not None and url == f"https://github.com/{REPO}/releases/download/{temporary[1]}/{name}"
        )
        require(row["id"] == item["id"] and row["size"] == item["size"] and
                row["digest"] == f"sha256:{item['sha256']}" and row["state"] == "uploaded" and
                valid_url, f"public stable release asset differs: {name}")


def verify_previous_latest(record):
    require(record["id"] == OLD["id"] and record["tag_name"] == OLD["tag"] and
            record["target_commitish"] == OLD["source"] and record["draft"] is False and
            record["prerelease"] is False and record["published_at"] == OLD["publishedAt"] and
            sha256(record["body"].encode()) == OLD["bodySha256"], "expected Build 301 GitHub Latest identity differs")


def verify_latest(plan, stamp, *, anonymous=False):
    if anonymous:
        raw, _ = read_http(f"https://api.github.com/repos/{REPO}/releases/latest")
        release_assets(load(raw), plan, draft=False, published_at=stamp)
    else:
        release_assets(github(f"releases/{RELEASE_ID}"), plan, draft=False, published_at=stamp)
        release_assets(github("releases/latest"), plan, draft=False, published_at=stamp)


def verify_run(build, settings):
    run_id, workflow_id, route, job_name, artifact_name = settings
    require(build["runId"] == run_id and build["attempt"] == 1 and
            build["sourceCommit"] == SOURCE and build["headBranch"] == TAG and
            build["artifactName"] == artifact_name and positive_int(build["artifactId"]) and
            positive_int(build["artifactSize"]) and hex_value(build["artifactSha256"], 64),
            f"approved provenance differs for {job_name}")
    is_apple = job_name == "build-tvos"
    run = github(f"actions/runs/{run_id}")
    require(run["id"] == run_id and run["run_attempt"] == 1 and run["workflow_id"] == workflow_id and
            run["head_sha"] == SOURCE and run["head_branch"] == TAG and run["path"].split("@")[0] == route and
            run["status"] == "completed" and run["conclusion"] == ("failure" if is_apple else "success") and
            run["event"] == "workflow_dispatch" and
            run["repository"]["id"] == REPO_ID and run["head_repository"]["id"] == REPO_ID,
            f"original GitHub build run differs for {job_name}")
    jobs = github(f"actions/runs/{run_id}/attempts/1/jobs")["jobs"]
    matches = [job for job in jobs if job["name"] == job_name and job["status"] == "completed" and
               job["conclusion"] == "success"]
    require(len(matches) == 1 and ("jobId" not in build or matches[0]["id"] == build["jobId"]),
            f"original successful build job differs for {job_name}")
    if is_apple:
        verify_original_attachment_failure(jobs)
    artifact = github(f"actions/artifacts/{build['artifactId']}")
    origin = artifact["workflow_run"]
    require(artifact["id"] == build["artifactId"] and artifact["name"] == artifact_name and artifact["expired"] is False and
            artifact["digest"] == f"sha256:{build['artifactSha256']}" and artifact["size_in_bytes"] == build["artifactSize"] and
            origin["id"] == run_id and origin["head_sha"] == SOURCE and origin["head_branch"] == TAG and
            origin["repository_id"] == REPO_ID and origin["head_repository_id"] == REPO_ID,
            f"immutable hosted artifact metadata differs for {job_name}")


def verify_original_attachment_failure(jobs):
    failures = [job for job in jobs if job["conclusion"] == "failure"]
    require(len(failures) == 1 and failures[0]["name"] == "attach-release" and
            failures[0]["id"] == ORIGINAL_ATTACH_ID and failures[0]["status"] == "completed" and
            failures[0]["run_attempt"] == 1, "Apple original failure is outside the reviewed pre-write attachment")
    steps = failures[0]["steps"]
    expected_skipped = ["Bind the draft release, tag commit, and monotonic source before any write",
                        "Attach only exact draft assets and create the authenticated staged receipt",
                        "Atomically activate the staged feed, prove routes, then publish last"]
    require(all(step["status"] == "completed" for step in steps) and
            [step["name"] for step in steps if step["conclusion"] == "failure"] == [ORIGINAL_ATTACH_FAILURE] and
            [step["name"] for step in steps if step["conclusion"] == "skipped"] == expected_skipped,
            "Apple original attachment failed after the reviewed pre-write boundary")


def verify_recovered_attachment(plan, original_apple):
    recovery = plan["attachment"]
    commit, tag_object = (recovery[key] for key in ("coordinatorCommit", "tagObject"))
    ref = github(f"git/ref/tags/{ATTACH_TAG}")
    tag = github(f"git/tags/{tag_object}")
    require(ref["ref"] == f"refs/tags/{ATTACH_TAG}" and ref["object"]["type"] == "tag" and
            ref["object"]["sha"] == tag_object and tag["tag"] == ATTACH_TAG and tag["sha"] == tag_object and
            tag["object"]["type"] == "commit" and tag["object"]["sha"] == commit,
            "approved Apple attachment tag differs")
    run_id = recovery["runId"]
    run = github(f"actions/runs/{run_id}")
    require(run["id"] == run_id and run["run_attempt"] == 1 and run["workflow_id"] == OPS_WORKFLOW_ID and
            run["head_sha"] == commit and run["head_branch"] == ATTACH_TAG and
            run["path"].split("@")[0] == OPS_WORKFLOW and run["status"] == "completed" and
            run["conclusion"] == "success" and run["event"] == "workflow_dispatch" and
            run["repository"]["id"] == REPO_ID and run["head_repository"]["id"] == REPO_ID and
            run["actor"]["login"] == "mamaclapper", "approved Apple attachment run differs")
    jobs = github(f"actions/runs/{run_id}/attempts/1/jobs")["jobs"]
    require(len(jobs) == 1 and jobs[0]["id"] == recovery["jobId"] and jobs[0]["name"] == "attach" and
            jobs[0]["status"] == "completed" and jobs[0]["conclusion"] == "success" and
            [step["conclusion"] for step in jobs[0]["steps"] if step["name"] == ATTACH_STEP] == ["success"],
            "approved Apple attachment job did not finish")
    artifact_id = recovery["artifactId"]
    artifact = github(f"actions/artifacts/{artifact_id}")
    origin = artifact["workflow_run"]
    require(artifact["id"] == artifact_id and artifact["name"] == ATTACH_ARTIFACT and not artifact["expired"] and
            artifact["digest"] == f"sha256:{recovery['artifactSha256']}" and
            artifact["size_in_bytes"] == recovery["artifactSize"] and origin["id"] == run_id and
            origin["head_sha"] == commit and origin["head_branch"] == ATTACH_TAG and
            origin["repository_id"] == REPO_ID and origin["head_repository_id"] == REPO_ID,
            "approved Apple attachment artifact differs")
    raw = github(f"actions/artifacts/{artifact_id}/zip", octet_stream=True)
    require(len(raw) == recovery["artifactSize"] and sha256(raw) == recovery["artifactSha256"],
            "approved Apple attachment artifact bytes differ")
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        members = archive.infolist()
        require(len(members) == 1 and members[0].filename == "attachment.json" and
                0 < members[0].file_size <= MAX_PLAN_BYTES, "attachment artifact members differ")
        proof = load(archive.read(members[0]))
    original_assets = {name: item for name, item in plan["assets"].items() if name not in {SUMS, PROVENANCE}}
    expected_recovery = {"runId": run_id, "attempt": 1, "sourceCommit": commit,
                         "ref": ATTACH_TAG, "workflowId": OPS_WORKFLOW_ID}
    require(type(proof["schemaVersion"]) is int and proof["schemaVersion"] == 1 and
            proof["releaseId"] == RELEASE_ID and proof["sourceCommit"] == SOURCE and proof["tag"] == TAG and
            proof["tagObject"] == TAG_OBJECT and proof["build"] == BUILD and proof["draft"] is True and
            proof["prerelease"] is False and proof["recovery"] == expected_recovery and
            proof["originalAppleRunId"] == original_apple["runId"] and
            proof["originalAppleArtifactId"] == original_apple["artifactId"] and
            proof["originalAppleArtifactSize"] == original_apple["artifactSize"] and
            proof["originalAppleArtifactSha256"] == original_apple["artifactSha256"] and proof["assets"] == original_assets,
            "attachment proof did not bind all ten exact original draft assets")


def verify_draft_evidence(plan, stage):
    def asset(name):
        item = plan["assets"][name]
        raw = github(f"releases/assets/{item['id']}", octet_stream=True)
        require(len(raw) == item["size"] and sha256(raw) == item["sha256"], f"release evidence bytes differ for {name}")
        return raw

    require(asset(SUMS) == stage["checksum"].encode(), "combined checksum asset differs from stage")
    provenance = load(asset(PROVENANCE))
    require(type(provenance.get("schemaVersion")) is int and provenance["schemaVersion"] == 1 and
            provenance["repository"] == REPO and provenance["releaseId"] == RELEASE_ID and
            provenance["sourceCommit"] == SOURCE and provenance["tag"] == TAG and
            provenance["version"] == VERSION and str(provenance["build"]) == str(BUILD),
            "published provenance release identity differs")
    rows = provenance["artifacts"]
    expected = {name: (plan["assets"][name]["size"], plan["assets"][name]["sha256"]) for name in PACKAGES.values()}
    require(len(rows) == len(expected) and {row["name"]: (row["size"], row["sha256"]) for row in rows} == expected,
            "published provenance does not bind exactly the seven verified packages")

    for checksum_file, keys in ((APPLE_SUMS, ("ios", "tvos", "tvosLite", "mac")),
                                (ANDROID_SUMS, ("androidFull", "androidPlay", "androidBundle"))):
        # Original CI emits either a basename or an out/ basename. The exact public
        # evidence bytes are independently pinned above, and all names must be accounted for.
        original = asset(checksum_file).decode("ascii").replace("  out/", "  ").replace("  dist/", "  ")
        pinned = {PACKAGES[key]: expected[PACKAGES[key]][1] for key in keys}
        reviewed_original = {name.replace(f"-{TAG}-ci.", "-ci."): digest for name, digest in pinned.items()}
        actual = checksum_records(original)
        require(actual == pinned or (checksum_file == APPLE_SUMS and actual == reviewed_original),
                f"{checksum_file} does not bind its exact CI package set")
    signing = asset(ANDROID_SIGNING).decode("utf-8")
    lines = signing.splitlines()
    require(lines.count(f"Android versionCode: {BUILD}") == 1 and lines.count(f"Android versionName: {VERSION}") == 1,
            "published CI Android version receipt differs")
    fingerprint = ":".join(SIGNER[i:i + 2] for i in range(0, len(SIGNER), 2))
    for key, kind in (("androidFull", "APK"), ("androidPlay", "APK"), ("androidBundle", "AAB")):
        sections = re.split(r"(?m)^verified (?:APK|AAB): ", signing)
        marker = f"verified {kind}: {PACKAGES[key]}"
        matches = [section for section in sections[1:] if section.startswith(f"{PACKAGES[key]}\n")]
        require(lines.count(marker) == 1 and len(matches) == 1 and
                [line.strip() for line in matches[0].splitlines()].count(f"signer SHA-256: {fingerprint}") == 1,
                f"published production signature evidence differs for {PACKAGES[key]}")
    for lane, settings in BUILD_LANES.items():
        verify_run(provenance["builds"][lane], settings)
    verify_recovered_attachment(plan, provenance["builds"]["apple"])



def stamp_time(value):
    require(isinstance(value, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value) is not None,
            "missing or invalid GitHub publication timestamp")
    return datetime.fromisoformat(value)


def published_identity(plan, started):
    record = github(f"releases/{RELEASE_ID}")
    release_assets(record, plan, draft=False)
    stamp = record["published_at"]
    published = stamp_time(stamp)
    require(started - timedelta(seconds=15) <= published <= min(datetime.now(timezone.utc) + timedelta(seconds=15),
                                                                started + timedelta(minutes=3)),
            "GitHub publication timestamp is outside this operation")
    return stamp


def mark_latest(plan, stamp):
    latest = github("releases/latest")
    if latest["id"] == RELEASE_ID:
        release_assets(latest, plan, draft=False, published_at=stamp)
        return
    verify_previous_latest(latest)
    try:
        record = github(f"releases/{RELEASE_ID}", "PATCH", {"tag_name": TAG, "make_latest": "true"})
        release_assets(record, plan, draft=False, published_at=stamp)
    except (OSError, subprocess.SubprocessError, ValueError):
        # A read proves whether a failed/ambiguous request actually changed Latest.
        pass
    wait_readback(lambda: verify_latest(plan, stamp), 90)


def publish(plan, started):
    record = github(f"releases/{RELEASE_ID}")
    release_assets(record, plan, draft=True)
    require(record["published_at"] is None, "stable draft has an existing publication timestamp")
    verify_previous_latest(github("releases/latest"))
    verify_tag()
    try:
        updated = github(f"releases/{RELEASE_ID}", "PATCH", {
            "tag_name": TAG, "target_commitish": SOURCE, "draft": False, "prerelease": False, "make_latest": "false",
        })
        release_assets(updated, plan, draft=False)
    except (OSError, subprocess.SubprocessError, ValueError):
        # Always bind the actual state independently before treating the draft as published.
        pass
    return wait_readback(lambda: published_identity(plan, started), 90)


def verified_public_asset(plan, name, deadline):
    item = plan["assets"][name]
    headers = {"Accept-Encoding": "identity", "User-Agent": "curl/8.5.0", "Cache-Control": "no-cache"}
    retry_until = min(deadline, time.monotonic() + 60)
    while True:
        try:
            with build_opener(ReleaseDownloads()).open(Request(asset_url(name), headers=headers), timeout=15) as response:
                require(response.status == 200, f"anonymous package response differs for {name}")
                digest = hashlib.sha256()
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    require(total <= item["size"] and time.monotonic() <= deadline,
                            f"anonymous package exceeded exact size or verification deadline: {name}")
                    digest.update(chunk)
            require(total == item["size"] and digest.hexdigest() == item["sha256"],
                    f"anonymous package bytes differ: {name}")
            return
        except HTTPError as error:
            if error.code not in {404, 500, 502, 503, 504} or time.monotonic() >= retry_until:
                raise ValueError(f"anonymous download of {name} failed: HTTP {error.code}") from None
        except (URLError, TimeoutError):
            if time.monotonic() >= retry_until:
                raise ValueError(f"anonymous download of {name} did not complete") from None
        time.sleep(3)


def verify_published_release(plan, stamp):
    release_assets(github(f"releases/{RELEASE_ID}"), plan, draft=False, published_at=stamp)
    raw, _ = read_http(f"https://api.github.com/repos/{REPO}/releases/tags/{TAG}")
    release_assets(load(raw), plan, draft=False, published_at=stamp)


def verify_published_bytes(plan, stamp):
    wait_readback(lambda: verify_published_release(plan, stamp), 90)
    verify_previous_latest(github("releases/latest"))
    deadline = time.monotonic() + PUBLIC_VERIFY_WAIT
    with ThreadPoolExecutor(max_workers=3) as pool:
        pending = [pool.submit(verified_public_asset, plan, name, deadline) for name in plan["assets"]]
        for result in pending:
            result.result()
    verify_published_release(plan, stamp)
    verify_tag()


def restore_unproved_publication(plan, started):
    # Compensate only during publication and Latest verification. Unrelated changes to
    # either release identity or the Latest pointer remain with their owner.
    verify_tag()
    record = github(f"releases/{RELEASE_ID}")
    latest = github("releases/latest")
    if record["draft"] is False:
        stamp = published_identity(plan, started)
        if latest["id"] == RELEASE_ID:
            release_assets(latest, plan, draft=False, published_at=stamp)
            verify_previous_latest(github(f"releases/{OLD['id']}"))
            try:
                old = github(f"releases/{OLD['id']}", "PATCH", {"tag_name": OLD["tag"], "make_latest": "true"})
                verify_previous_latest(old)
            except (OSError, subprocess.SubprocessError, ValueError):
                pass
            wait_readback(lambda: verify_previous_latest(github("releases/latest")), 90)
        else:
            verify_previous_latest(latest)
        release_assets(github(f"releases/{RELEASE_ID}"), plan, draft=False, published_at=stamp)
        try:
            github(f"releases/{RELEASE_ID}", "PATCH", {
                "tag_name": TAG, "target_commitish": SOURCE, "draft": True, "prerelease": False, "make_latest": "false",
            })
        except (OSError, subprocess.SubprocessError, ValueError):
            pass
    wait_readback(lambda: release_assets(github(f"releases/{RELEASE_ID}"), plan, draft=True), 90)
    verify_previous_latest(github("releases/latest"))


def current_main():
    ref = github("git/ref/heads/main")
    require(ref["ref"] == "refs/heads/main" and ref["object"]["type"] == "commit" and
            hex_value(ref["object"]["sha"], 40), "main ref identity differs")
    return ref["object"]["sha"]


def main_source(head):
    content = github(f"contents/{SOURCE_PATH}?ref={head}")
    require(content["type"] == "file" and content["path"] == SOURCE_PATH and content["encoding"] == "base64" and
            positive_int(content["size"]) and content["size"] <= MAX_BYTES, "main install-source identity differs")
    raw = base64.b64decode("".join(content["content"].split()), validate=True)
    require(len(raw) == content["size"], "main install-source size differs")
    return raw


def source_commit(head, body, message):
    require(current_main() == head, "main moved before install-source compare-and-swap")
    base = github(f"git/commits/{head}")["tree"]["sha"]
    blob = github("git/blobs", "POST", {"content": base64.b64encode(body).decode(), "encoding": "base64"})["sha"]
    tree = github("git/trees", "POST", {"base_tree": base, "tree": [
        {"path": SOURCE_PATH, "mode": "100644", "type": "blob", "sha": blob},
    ]})["sha"]
    commit = github("git/commits", "POST", {"message": message, "tree": tree, "parents": [head],
                                        "author": BOT_IDENTITY, "committer": BOT_IDENTITY})["sha"]
    require(hex_value(commit, 40) and current_main() == head,
            "install-source commit invalid or main moved")
    compare = github(f"compare/{head}...{commit}")
    require(compare["status"] == "ahead" and compare["ahead_by"] == 1 and compare["behind_by"] == 0 and
            [row["filename"] for row in compare["files"]] == [SOURCE_PATH] and
            main_source(commit) == body, "generated commit differs outside the install source")
    return commit


def advance_main(commit):
    ref = github("git/refs/heads/main", "PATCH", {"sha": commit, "force": False})
    require(ref["object"]["sha"] == commit, "main did not accept the exact install-source commit")


def wait_raw(expected):
    def check():
        raw, _ = read_http(RAW_MAIN)
        require(raw == expected, "anonymous raw main install source differs")
    wait_readback(check, RAW_WAIT)


def verify_history(old, new):
    # Preserve the same source and app metadata, with the stable entry prepended to
    # the existing eight-row history window in each of the two relevant bundles.
    prior = load(old)
    target = load(new)
    for bundle in ("com.stremiox.app.native", "com.stremiox.tv"):
        before = next(app for app in prior["apps"] if app["bundleIdentifier"] == bundle)
        after = next(app for app in target["apps"] if app["bundleIdentifier"] == bundle)
        expected = [after["versions"][0], *before["versions"]][:8]
        require(after["versions"] == expected, f"install-source history differs for {bundle}")
        after["versions"] = before["versions"]
    require(prior == target, "install-source changed outside the two release histories")


def read_active(secret):
    return receipt(secret, {"action": "read-active-receipt"}, retry=True)


def verify_active(response, expected, *, stage=None):
    active = response.get("active")
    require(isinstance(active, dict) and response.get("inheritedAndroidState") == "active",
            "active receipt unavailable or missing its own complete Android feed")
    manifest = active["manifest"]
    require(manifest["generation"] == expected["generation"] and str(manifest["releaseId"]) == str(expected["id"]) and
            manifest["tag"] == expected["tag"] and manifest["build"] == expected["build"] and
            manifest["sourceCommit"] == expected["source"] and manifest["prerelease"] is False and
            active["receiptSha256"] == expected["receipt"], "durable active receipt identity differs")
    for key, raw_key in (("sourceSha256", "sourceText"), ("appcastSha256", "appcastText"),
                         ("checksumSha256", "checksumText")):
        require(manifest[key] == expected[key] and sha256(active[raw_key].encode()) == expected[key],
                f"durable active receipt {raw_key} differs")
    require(manifest["android"].keys() == {"full", "play"}, "durable active receipt does not cover both Android variants")
    if stage is not None:
        require(manifest == stage["manifest"] and all(active[raw] == stage[wire] for raw, wire in (
            ("sourceText", "source"), ("appcastText", "appcast"), ("checksumText", "checksum"),
        )), "durable stable receipt differs from the reviewed stage payload")


def verify_routes(expected, *, queries=True):
    generation = expected["generation"]
    paths = ("appcast.json", "altstore.json", "vortx-altstore.json")
    for path in paths:
        digest = expected["appcastSha256" if path == "appcast.json" else "sourceSha256"]
        for query in ("", "?feed-verify=" + generation) if queries else ("",):
            raw, headers = read_http(f"https://vortx.tv/{path}{query}")
            require(sha256(raw) == digest and headers.get_all("x-vortx-feed-generation") == [generation] and
                    headers.get_all("x-vortx-feed-state") == ["active"] and
                    headers.get_all("content-type") == ["application/json; charset=utf-8"] and
                    headers.get_all("cache-control") == ["public, max-age=120, s-maxage=120, must-revalidate"],
                    f"{path} did not return exact active bytes and generation")


def target_identity(plan, stage):
    manifest = stage["manifest"]
    return {"id": RELEASE_ID, "tag": TAG, "build": BUILD, "source": SOURCE,
            "generation": plan["generation"], "receipt": plan["receiptSha256"],
            **{field: manifest[field] for field in ("sourceSha256", "appcastSha256", "checksumSha256")}}


def compensated_main(written, old_source, new_source):
    head = current_main()
    raw = main_source(head)
    if raw == new_source:
        if head != written:
            compare = github(f"compare/{written}...{head}")
            require(compare["status"] == "ahead" and compare["merge_base_commit"]["sha"] == written,
                    "current main does not descend from the exact promotion commit")
        restored = source_commit(head, old_source, "chore(release): restore verified Build 301 install feed")
        try:
            advance_main(restored)
        except (ValueError, OSError, subprocess.SubprocessError):
            # The API may have lost the acknowledgement after writing. Read back the exact branch.
            require(current_main() == restored, "restoration commit could not be established")
        require(main_source(current_main()) == old_source, "restored GitHub source differs")
    else:
        require(raw == old_source, "unrelated main source change prevents compensation")
    wait_raw(old_source)


def compensate(secret, edge_attempted, written, old_source, new_source, target, stage):
    failures = []
    try:
        seen = read_active(secret)
        if edge_attempted and seen.get("active", {}).get("manifest", {}).get("generation") == target["generation"]:
            verify_active(seen, target, stage=stage)
            try:
                receipt(secret, {"action": "rollback", "expectedCurrentGeneration": target["generation"],
                                 "restoreGeneration": OLD["generation"]})
            except (URLError, TimeoutError, ValueError):
                # Accept an ambiguous response only after the independently authenticated predecessor read.
                pass
        verify_active(read_active(secret), OLD)
    except Exception:
        failures.append("durable feed")
    if failures:
        print("::error::Preserved main because the exact predecessor durable feed could not be established.",
              file=sys.stderr)
        return failures
    try:
        compensated_main(written, old_source, new_source)
    except Exception:
        failures.append("main source")
    try:
        wait_readback(lambda: verify_routes(OLD), EDGE_WAIT)
    except Exception:
        failures.append("public feed")
    return failures


def finalize(plan, stage, stage_raw, secret):
    old_head = plan["mainHead"]
    old_source = main_source(old_head)
    new_source = stage["source"].encode()
    require(sha256(old_source) == OLD["sourceSha256"] and current_main() == old_head,
            "expected main predecessor differs")
    verify_history(old_source, new_source)
    verify_tag()
    draft = github(f"releases/{RELEASE_ID}")
    release_assets(draft, plan, draft=True)
    require(draft["published_at"] is None, "stable draft has an existing publication timestamp")
    verify_previous_latest(github("releases/latest"))
    verify_draft_evidence(plan, stage)
    wait_raw(old_source)
    verify_active(read_active(secret), OLD)
    verify_routes(OLD)
    print(f"Verified draft {RELEASE_ID}, all package identities, and the Build 301 predecessor.", flush=True)

    started = datetime.now(timezone.utc)
    try:
        stamp = publish(plan, started)
        verify_published_bytes(plan, stamp)
        print(f"Verified all twelve anonymous stable release assets at publication {stamp}.", flush=True)
        mark_latest(plan, stamp)
        verify_latest(plan, stamp)
        wait_readback(lambda: verify_latest(plan, stamp, anonymous=True), 90)
    except Exception:
        try:
            restore_unproved_publication(plan, started)
        except Exception:
            print("::error::Could not establish restoration of the exact draft and Build 301 GitHub Latest.",
                  file=sys.stderr)
        else:
            print("Verified exact stable draft and Build 301 GitHub Latest after compensation.", flush=True)
        raise
    # A public release with independently verified exact package bytes is retained if the feed operation fails.
    return promote(plan, stage, stage_raw, secret, stamp, old_source, new_source)


def promote(plan, stage, stage_raw, secret, stamp, old_source, new_source):
    target = target_identity(plan, stage)
    old_head = plan["mainHead"]
    require(current_main() == old_head and main_source(old_head) == old_source,
            "expected main predecessor changed after stable publication")
    verify_active(read_active(secret), OLD)
    verify_latest(plan, stamp)
    staged = receipt(secret, stage_raw, retry=True)
    require(staged.get("staged") is True and staged.get("generation") == target["generation"] and
            str(staged.get("releaseId")) == str(RELEASE_ID) and staged.get("receiptSha256") == target["receipt"],
            "stage acknowledgement does not bind the exact combined feed")
    verify_active(read_active(secret), OLD)
    verify_routes(OLD, queries=False)
    verify_latest(plan, stamp)
    written = source_commit(old_head, new_source, "chore(release): publish stable 0.5.7 update feeds")
    edge_attempted = False
    try:
        advance_main(written)
        wait_raw(new_source)
        require(current_main() == written and main_source(written) == new_source,
                "canonical source moved before feed promotion")
        verify_tag()
        verify_latest(plan, stamp)
        verify_active(read_active(secret), OLD)
        edge_attempted = True
        promoted = receipt(secret, {"action": "promote", "operationId": f"promote:{RELEASE_ID}:{target['generation']}",
                                    "releaseId": str(RELEASE_ID), "generation": target["generation"],
                                    "expectedActiveGeneration": OLD["generation"]}, retry=True)
        require(promoted.get("promoted") is True and promoted.get("generation") == target["generation"] and
                promoted.get("receiptSha256") == target["receipt"] and
                (promoted.get("previousGeneration") == OLD["generation"] or
                 (promoted.get("idempotent") is True and promoted.get("previousGeneration") == target["generation"])),
                "promotion acknowledgement does not bind the exact combined feed and predecessor")
        verify_active(read_active(secret), target, stage=stage)
        wait_readback(lambda: verify_routes(target), EDGE_WAIT)
        raw, _ = read_http(RAW_MAIN)
        require(raw == new_source and current_main() == written,
                "canonical raw source moved after promotion")
        verify_latest(plan, stamp)
        verify_latest(plan, stamp, anonymous=True)
        verify_tag()
    except Exception:
        failures = compensate(secret, edge_attempted, written, old_source, new_source, target, stage)
        if failures:
            print(f"::error::Compensation incomplete for {', '.join(failures)}. Inspect state before retry.",
                  file=sys.stderr)
        else:
            print("Verified exact Build 301 feed and main-source bytes after compensation.", flush=True)
        raise
    return {"schemaVersion": 1, "tag": TAG, "version": VERSION, "build": BUILD, "releaseId": RELEASE_ID,
            "sourceCommit": SOURCE, "publishedAt": stamp, "mainCommit": written, "previousGeneration": OLD["generation"],
            "generation": target["generation"], "receiptSha256": target["receipt"],
            "sourceSha256": target["sourceSha256"], "appcastSha256": target["appcastSha256"],
            "checksumSha256": target["checksumSha256"], "publishedAssets": plan["assets"]}


def run_context(plan_raw, plan):
    pinned = sha256(plan_raw)
    env_expected = {
        "GITHUB_REPOSITORY": REPO, "GITHUB_REPOSITORY_ID": str(REPO_ID),
        "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_ACTOR": "mamaclapper",
        "GITHUB_ACTOR_ID": "50227842", "GITHUB_TRIGGERING_ACTOR": "mamaclapper",
        "GITHUB_RUN_ATTEMPT": "1", "GITHUB_REF": f"refs/tags/{OPS_TAG}",
        "GITHUB_WORKFLOW_REF": f"{REPO}/{OPS_WORKFLOW}@refs/tags/{OPS_TAG}",
        "REVIEWED_PLAN_SHA256": pinned, "DISPATCH_PLAN_SHA256": pinned,
    }
    require(all(os.environ.get(key) == value for key, value in env_expected.items()), "operation dispatch context differs")
    source = os.environ["GITHUB_SHA"]
    run_id = int(os.environ["GITHUB_RUN_ID"])
    require(positive_int(run_id) and hex_value(source, 40) and os.environ["GITHUB_WORKFLOW_SHA"] == source and
            subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() == source and
            not subprocess.check_output(["git", "status", "--porcelain"], text=True),
            "checked-out operation source differs")
    run = github(f"actions/runs/{run_id}")
    require(run["id"] == run_id and run["workflow_id"] == OPS_WORKFLOW_ID and run["head_sha"] == source and
            run["head_branch"] == OPS_TAG and run["path"].split("@")[0] == OPS_WORKFLOW and
            run["run_attempt"] == 1 and run["event"] == "workflow_dispatch", "original operation workflow identity differs")
    ref = github(f"git/ref/tags/{OPS_TAG}")
    require(ref["ref"] == f"refs/tags/{OPS_TAG}" and ref["object"]["type"] == "tag" and
            hex_value(ref["object"]["sha"], 40), "operation tag is not annotated")
    obj = github(f"git/tags/{ref['object']['sha']}")
    require(obj["sha"] == ref["object"]["sha"] and obj["tag"] == OPS_TAG and
            obj["object"]["type"] == "commit" and obj["object"]["sha"] == source,
            "annotated operation tag no longer resolves to the reviewed workflow")
    commit = github(f"commits/{source}")
    require([parent["sha"] for parent in commit["parents"]] == [plan["mainHead"]] and
            {row["filename"] for row in commit["files"]} ==
            {OPS_WORKFLOW, f"scripts/{OPS_SCRIPT}", f"scripts/{OPS_PLAN}", f"scripts/{OPS_STAGE}"},
            "protected operation commit has an unexpected parent or file scope")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_subparsers(dest="mode", required=True)
    render_command = mode.add_parser("render")
    render_command.add_argument("--bindings", type=Path, required=True)
    render_command.add_argument("--stage", type=Path, required=True)
    render_command.add_argument("--out", type=Path, required=True)
    mode.add_parser("finalize")
    args = parser.parse_args()
    if args.mode == "render":
        render(args.bindings, args.stage, args.out)
        return
    paths = Path(__file__).parent
    plan_raw = file_bytes(paths / OPS_PLAN, MAX_PLAN_BYTES)
    plan = load(plan_raw)
    validate_bindings(plan, rendered=True)
    stage_raw = file_bytes(paths / OPS_STAGE, MAX_STAGE_BYTES)
    stage, stage_pins = verify_stage(plan, stage_raw)
    require(all(plan[key] == value for key, value in stage_pins.items()), "plan does not bind the reviewed stage bytes")
    run_context(plan_raw, plan)
    secret = os.environ.pop("RELEASE_FEED_RECEIPT_SECRET").encode()
    require(bool(secret), "protected feed secret unavailable")
    result = finalize(plan, stage, stage_raw, secret)
    output = Path(os.environ["RUNNER_TEMP"]) / "stable-057-feed-result.json"
    output.write_bytes(canonical(result) + b"\n")
    print(f"Verified stable {TAG} on GitHub Latest and all feed routes at {result['generation']}.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, TypeError, ValueError, subprocess.SubprocessError) as error:
        print(f"::error::Stable feed operation stopped ({type(error).__name__}): {error}", file=sys.stderr)
        sys.exit(1)
