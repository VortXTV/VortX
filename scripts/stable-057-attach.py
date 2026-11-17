#!/usr/bin/env python3
"""Draft-only attachment from the exact original Apple 0.5.7 Build 302 archive."""

import argparse
from datetime import timedelta
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import zipfile
from urllib.parse import quote

REPO = "VortXTV/VortX"
REPO_ID = 1261501126
TAG = "v0.5.7"
BUILD = 302
SOURCE = "c56213a20fe064b0ac1ac0cc8e607c2ef449fea1"
TAG_OBJECT = "3ab4a5810b2882617a0fb6f39bf5ed5fd34a0d32"
RELEASE = 447897160
RELEASE_NAME = "VortX 0.5.7: Account Recovery, Offline Playback and Better Browsing (Build 302)"
BODY_SHA = "fc3141219531deacd99bc404918dc4ac575fa1e37746a955bfac709e8b826d1d"
DRAFT_SNAPSHOT_SHA = "61d151ab451a157879fc60e8edc69f29e5d32559dff1351e28ab7b55dea8be00"
ATTACH_SHA_BASE = "616c52d0e531461d7de03ee919fb1c7f94ba488f"
APPLE_RUN = 43995790455
APPLE_JOB = 133747413522
FAILED_ATTACH_JOB = 133815991705
APPLE_ARCHIVE = 14299280966
APPLE_ARCHIVE_SIZE = 285870712
APPLE_ARCHIVE_SHA = "16a3f2b111f5e285c303731c33d001cd671a63213db0e975801e48013f7db5ce"
APPLE_PROOF_RUN = 44016713556
APPLE_PROOF_JOB = 133816285391
APPLE_PROOF_ARCHIVE = 14298833051
APPLE_PROOF_SIZE = 33755
APPLE_PROOF_SHA = "1a0b9b3a26c5d3da15222a77d39508eaf2dae9a3d76a2fb300761a35a8fdbc02"
APPLE_PROOF_JSON_SHA = "d688bc01379e8c54380436d1434eb0a0db3d080df72dad9c5f3391474d737d98"
PROOF_REF = "beta-stable-057-hosted-verify-20261117"
PROOF_SOURCE = "c2fbd8e32941a1c646e1048d8b6dc5a35ea18968"
TRANSPORT_PATH = "scripts/verify-ci-direct-beta.py"
TRANSPORT_SHA = "344b29ca070214e7228bf500cbd14a72ea3fcbeae4ee8f25c3b2cccd32a3bc6a"
OPS_TAG = "v0.5.7-ops-attach-20261117"
OPS_WORKFLOW = ".github/workflows/recover-release-feed.yml"
OPS_WORKFLOW_ID = 345603253
OPS_SCRIPT = "stable-057-attach.py"
OPS_PLAN = "stable-057-attach-plan.json"
OPS_TRANSPORT = "stable-057-attach-ci.py"
SUMS = "SHA256SUMS-ci.txt"
APPLE_PACKAGES = {f"VortX-{platform}-{TAG}-ci.{suffix}" for platform, suffix in
                  (("iOS", "ipa"), ("tvOS", "ipa"), ("tvOS-lite", "ipa"), ("macOS", "dmg"))}
APPLE_ASSETS = APPLE_PACKAGES | {SUMS}
ANDROID_ASSETS = {"VortX-0.5.7-full-mpv-universal.apk", "VortX-0.5.7-play-media3-universal.apk",
                  "VortX-0.5.7-play-media3.aab", "SHA256SUMS-android.txt", "SIGNING_PROVENANCE.txt"}
APPLE_NATIVES = {"native-build-inputs.json", "native-workflow-provenance.json",
                 *(f"native-{key}.json" for key in ("ios", "tvos", "tvos-lite", "macos", "ios-simulator", "tvos-simulator")),
                 *(f"native-package-{key}.json" for key in ("ios", "tvos", "tvos-lite", "macos"))}
PROOF_NAMES = {SUMS, "apple-original.json", *(f"apple-feed/{name}" for name in (SUMS, "appcast.json", "source.json", "manifest.json"))}
FAILURE_STEP = "Download and authenticate immutable handoff archives"
FAILURE_TEXT = "the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway"
EXPECTED_ATTACH_STEPS = (
    ("Set up job", "success"),
    ("Validate immutable handoff provenance before coordinator resume", "success"),
    (FAILURE_STEP, "failure"),
    ("Bind the draft release, tag commit, and monotonic source before any write", "skipped"),
    ("Attach only exact draft assets and create the authenticated staged receipt", "skipped"),
    ("Atomically activate the staged feed, prove routes, then publish last", "skipped"),
    ("Complete job", "success"),
)
METADATA_FIELDS = ("id", "name", "state", "size", "digest", "browser_download_url")
MAX_JSON = 2 * 1024**2


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(obj):
    return (json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()


def unique_keys(pairs):
    obj = {}
    for key, value in pairs:
        require(key not in obj, "duplicate JSON key in evidence")
        obj[key] = value
    return obj


def load(raw):
    return json.loads(raw, object_pairs_hook=unique_keys)


def bound_bytes(path, size):
    with path.open("rb") as stream:
        raw = stream.read(size + 1)
    require(0 < len(raw) <= size, f"{path.name} is empty or exceeds its bound")
    return raw


def apply_transport(path):
    require(sha(bound_bytes(path, MAX_JSON)) == TRANSPORT_SHA, "frozen raw transport source differs")
    spec = importlib.util.spec_from_file_location("reviewed_stable_ci_verifier", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def inspect_proof(zip_path):
    raw = bound_bytes(zip_path, APPLE_PROOF_SIZE)
    require(len(raw) == APPLE_PROOF_SIZE and sha(raw) == APPLE_PROOF_SHA, "reviewed Apple proof ZIP differs")
    with zipfile.ZipFile(zip_path) as archive:
        items = archive.infolist()
        require(len(items) == len(PROOF_NAMES) and {item.filename for item in items} == PROOF_NAMES and
                all(0 < item.file_size <= MAX_JSON and (item.external_attr >> 16) & 0o170000 in (0, stat.S_IFREG)
                    and not item.flag_bits & 1 and not item.is_dir() for item in items),
                "reviewed Apple proof member roster differs")
        proof_raw = archive.read("apple-original.json")
        require(sha(proof_raw) == APPLE_PROOF_JSON_SHA, "reviewed Apple proof JSON differs")
        proof = load(proof_raw)
        require(proof["releaseId"] == RELEASE and proof["sourceCommit"] == SOURCE and proof["tagObject"] == TAG_OBJECT and
                proof["frozenVerifierHashes"][TRANSPORT_PATH] == TRANSPORT_SHA and proof["files"].keys() == APPLE_ASSETS,
                "reviewed Apple proof identity differs")
        require(proof["apple"] == {"artifactId": APPLE_ARCHIVE, "artifactName": "VortX-tvOS-ci",
                "artifactSha256": APPLE_ARCHIVE_SHA, "artifactSize": APPLE_ARCHIVE_SIZE, "attempt": 1,
                "headBranch": TAG, "jobId": APPLE_JOB, "runId": APPLE_RUN, "sourceCommit": SOURCE},
                "reviewed original Apple archive pointer differs")
        require(archive.read(SUMS) == archive.read(f"apple-feed/{SUMS}") and
                sha(archive.read(SUMS)) == proof["files"][SUMS]["sha256"], "reviewed Apple checksums differ")
    return proof["files"]


def draft_identity(draft):
    require(draft["id"] == RELEASE and draft["tag_name"] == TAG and draft["target_commitish"] == SOURCE and
            draft["draft"] is True and draft["prerelease"] is False and draft["published_at"] is None and
            draft["name"] == RELEASE_NAME and sha(draft["body"].encode()) == BODY_SHA,
            "stable draft identity, notes or publication flags differ")


def project_assets(ci, draft):
    assets = draft["assets"]
    by_name = {row["name"]: {field: row[field] for field in METADATA_FIELDS} for row in assets}
    require(len(by_name) == len(assets) and len({row["id"] for row in assets}) == len(assets),
            "draft assets repeat identity")
    for name, row in by_name.items():
        require(type(row["id"]) is int and row["id"] > 0 and row["state"] == "uploaded" and
                type(row["size"]) is int and 0 < row["size"] <= 2 * 1024**3 and
                re.fullmatch(r"sha256:[0-9a-f]{64}", row["digest"]) is not None, "draft asset metadata differs")
        ci.validate_asset_url("verify-draft", draft, TAG, name, row["browser_download_url"])
    return by_name


def render(repo, proof, draft, out):
    out.mkdir()
    (out / ".github/workflows").mkdir(parents=True)
    (out / "scripts").mkdir()
    transport = subprocess.check_output(["git", "-C", str(repo), "show", f"{SOURCE}:{TRANSPORT_PATH}"])
    transport_path = out / "scripts" / OPS_TRANSPORT
    transport_path.write_bytes(transport)
    ci = apply_transport(transport_path)
    draft_raw = bound_bytes(draft, MAX_JSON)
    require(sha(draft_raw) == DRAFT_SNAPSHOT_SHA, "reviewed Android-only draft snapshot differs")
    draft_state = load(draft_raw)
    draft_identity(draft_state)
    android = project_assets(ci, draft_state)
    require(android.keys() == ANDROID_ASSETS, "reviewed Android-only draft roster differs")
    plan = canonical({"schemaVersion": 1, "releaseId": RELEASE, "sourceCommit": SOURCE, "tag": TAG, "build": BUILD,
                      "android": android, "apple": inspect_proof(proof)})
    (out / "scripts" / OPS_PLAN).write_bytes(plan)
    (out / "scripts" / OPS_SCRIPT).write_bytes(Path(__file__).read_bytes())
    template = Path(__file__).with_name("recover-release-feed.template.yml").read_text()
    require(template.count("@PLAN_SHA256@") == 2, "workflow plan placeholders differ")
    (out / OPS_WORKFLOW).write_text(template.replace("@PLAN_SHA256@", sha(plan)))
    print(f"Plan SHA-256 {sha(plan)}")


def tag_is_frozen(ci):
    ref = ci.api(f"git/ref/tags/{TAG}")
    annotated = ci.api(f"git/tags/{TAG_OBJECT}")
    require(ref["ref"] == f"refs/tags/{TAG}" and
            ref["object"]["type"] == "tag" and ref["object"]["sha"] == TAG_OBJECT and
            annotated["sha"] == TAG_OBJECT and annotated["tag"] == TAG and
            annotated["object"]["type"] == "commit" and annotated["object"]["sha"] == SOURCE,
            "annotated stable tag differs")


def exact_run(run, identifier, workflow, route, branch, source, conclusion):
    require(run["id"] == identifier and run["run_attempt"] == 1 and run["workflow_id"] == workflow and
            run["event"] == "workflow_dispatch" and run["head_branch"] == branch and run["head_sha"] == source and
            run["path"].split("@", 1)[0] == route and run["repository"]["id"] == REPO_ID and
            run["head_repository"]["id"] == REPO_ID and run["status"] == "completed" and
            run["conclusion"] == conclusion, "reviewed original workflow or attempt differs")


def exact_jobs(ci, identifier):
    page = ci.api(f"actions/runs/{identifier}/attempts/1/jobs?per_page=100")
    jobs = page["jobs"]
    require(page["total_count"] == len(jobs) and len({job["name"] for job in jobs}) == len(jobs),
            "original job roster was truncated or repeated")
    return {job["name"]: job for job in jobs}


def exact_job(job, run, identifier, source, conclusion):
    require(job["id"] == identifier and job["run_id"] == run and job["run_attempt"] == 1 and
            job["head_sha"] == source and job["status"] == "completed" and job["conclusion"] == conclusion,
            "reviewed original job identity or conclusion differs")


def successful_step(job, name):
    found = [step for step in job["steps"] if step["name"] == name]
    require(len(found) == 1 and found[0]["status"] == "completed" and found[0]["conclusion"] == "success",
            f"expected successful original step missing: {name}")
    return found[0]


def prove_failed_step(ci, job, log):
    steps = job["steps"]
    require([step["number"] for step in steps] == list(range(1, len(EXPECTED_ATTACH_STEPS) + 1)) and
            all(step["status"] == "completed" for step in steps) and
            tuple((step["name"], step["conclusion"]) for step in steps) == EXPECTED_ATTACH_STEPS,
            "old attach did not fail before every release/feed write")
    start = ci.step_time(steps[2]["started_at"])
    end = ci.step_time(steps[2]["completed_at"]) + timedelta(seconds=1)
    matches = []
    with log.open(encoding="utf-8") as lines:
        for line in lines:
            stamp, _, message = line.rstrip("\r\n").partition(" ")
            if message == FAILURE_TEXT:
                matches.append(stamp.removeprefix("\ufeff"))
    require(len(matches) == 1 and start <= ci.step_time(matches[0]) < end,
            "old attach failure does not match captured GitHub CLI refusal")


def artifact_record(ci, artifact_id, name, size, digest, run, branch, source):
    artifact = ci.api(f"actions/artifacts/{artifact_id}")
    origin = artifact["workflow_run"]
    require(artifact["id"] == artifact_id and artifact["name"] == name and not artifact["expired"] and
            artifact["size_in_bytes"] == size and artifact["digest"] == f"sha256:{digest}" and
            origin["id"] == run and origin["head_branch"] == branch and origin["head_sha"] == source and
            origin["repository_id"] == REPO_ID and origin["head_repository_id"] == REPO_ID,
            "original artifact metadata differs")
    return artifact


def verify_original(ci, plan, work):
    apple_workflow = (APPLE_RUN, 293211344, ".github/workflows/release-tvos.yml", TAG, SOURCE, "failure")
    exact_run(ci.api(f"actions/runs/{APPLE_RUN}"), *apple_workflow)
    exact_run(ci.api(f"actions/runs/{APPLE_RUN}/attempts/1"), *apple_workflow)
    jobs = exact_jobs(ci, APPLE_RUN)
    require([job["id"] for job in jobs.values() if job["conclusion"] == "failure"] == [FAILED_ATTACH_JOB] and
            all(job["conclusion"] == "skipped" for name, job in jobs.items() if name not in {"build-tvos", "attach-release"}),
            "old workflow did not have one isolated pre-write attachment failure")
    build_job = jobs["build-tvos"]
    attach_job = jobs["attach-release"]
    exact_job(build_job, APPLE_RUN, APPLE_JOB, SOURCE, "success")
    exact_job(attach_job, APPLE_RUN, FAILED_ATTACH_JOB, SOURCE, "failure")
    failure_log = work / "failed-attach.log"
    ci.api_download(f"actions/jobs/{FAILED_ATTACH_JOB}/logs", failure_log, 16 * 1024**2)
    prove_failed_step(ci, attach_job, failure_log)

    proof_workflow = (APPLE_PROOF_RUN, 343149688, ".github/workflows/release-packaging-validation.yml",
                      PROOF_REF, PROOF_SOURCE, "success")
    exact_run(ci.api(f"actions/runs/{APPLE_PROOF_RUN}"), *proof_workflow)
    proof_job = exact_jobs(ci, APPLE_PROOF_RUN)["verify"]
    exact_job(proof_job, APPLE_PROOF_RUN, APPLE_PROOF_JOB, PROOF_SOURCE, "success")
    successful_step(proof_job, "Reauthenticate package bytes with the reviewed verifier")
    proof_upload = successful_step(proof_job, "Upload bounded stable verification receipts")
    proof_meta = artifact_record(ci, APPLE_PROOF_ARCHIVE, "VortX-0.5.7-302-verified-apple-original",
                                 APPLE_PROOF_SIZE, APPLE_PROOF_SHA, APPLE_PROOF_RUN, PROOF_REF, PROOF_SOURCE)
    proof_log = work / "original-proof.log"
    ci.api_download(f"actions/jobs/{APPLE_PROOF_JOB}/logs", proof_log, 32 * 1024**2)
    with proof_log.open(encoding="utf-8") as lines:
        ci.upload_proof(proof_meta, proof_upload, lines)
    proof_zip = work / "reviewed-proof.zip"
    ci.api_download(f"actions/artifacts/{APPLE_PROOF_ARCHIVE}/zip", proof_zip, APPLE_PROOF_SIZE)
    require(inspect_proof(proof_zip) == plan["apple"], "original Apple package receipts differ from the reviewed plan")
    artifact = artifact_record(ci, APPLE_ARCHIVE, "VortX-tvOS-ci", APPLE_ARCHIVE_SIZE, APPLE_ARCHIVE_SHA,
                               APPLE_RUN, TAG, SOURCE)
    build_log = work / "original-build.log"
    ci.api_download(f"actions/jobs/{APPLE_JOB}/logs", build_log, 512 * 1024**2)
    upload_step = successful_step(build_job, "Upload the immutable app handoff")
    with build_log.open(encoding="utf-8") as lines:
        ci.upload_proof(artifact, upload_step, lines)
    archive = work / "original-apple.zip"
    ci.api_download(f"actions/artifacts/{APPLE_ARCHIVE}/zip", archive, APPLE_ARCHIVE_SIZE)
    extracted = work / "original-apple"
    ci.extract_exact(archive, artifact, APPLE_ASSETS | APPLE_NATIVES, extracted)
    for name, expected in plan["apple"].items():
        check_file(ci, extracted / name, expected)
    sums = {}
    for line in (extracted / SUMS).read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (?:out/)?([A-Za-z0-9.-]+)", line)
        require(match is not None and match[2] not in sums, "Apple checksum evidence is invalid")
        sums[match[2]] = match[1]
    require(sums == {name: plan["apple"][name]["sha256"] for name in APPLE_PACKAGES},
            "original Apple checksums do not bind the four packages")
    return extracted


def check_file(ci, path, expected):
    require(path.stat().st_size == expected["size"] and ci.digest(path) == expected["sha256"],
            f"Apple file differs from the reviewed original: {path.name}")


def read_draft(ci, plan):
    draft = ci.api(f"releases/{RELEASE}")
    draft_identity(draft)
    assets = project_assets(ci, draft)
    require(ANDROID_ASSETS <= assets.keys() <= (ANDROID_ASSETS | APPLE_ASSETS) and
            all(assets[name] == prior for name, prior in plan["android"].items()),
            "immutable Android draft baseline or current asset roster differs")
    for name in assets.keys() & APPLE_ASSETS:
        expected = plan["apple"][name]
        require(assets[name]["size"] == expected["size"] and assets[name]["digest"] == f"sha256:{expected['sha256']}",
                f"existing Apple draft asset differs: {name}")
    return assets


def upload_missing(token, path):
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
               "Content-Type": "application/octet-stream", "Content-Length": str(path.stat().st_size),
               "User-Agent": "VortX-stable-057-protected-attach"}
    endpoint = f"/repos/{REPO}/releases/{RELEASE}/assets?name={quote(path.name, safe='')}"
    connection = http.client.HTTPSConnection("uploads.github.com", timeout=120)
    try:
        with path.open("rb") as stream:
            connection.request("POST", endpoint, body=stream, headers=headers)
            response = connection.getresponse()
            raw = response.read(MAX_JSON + 1)
            require(response.status == 201 and 0 < len(raw) <= MAX_JSON,
                    f"GitHub did not acknowledge Apple draft upload: {path.name} HTTP {response.status}")
            return load(raw)
    finally:
        connection.close()


def attach(ci, plan, extracted, work, token):
    assets = read_draft(ci, plan)
    for name in sorted(APPLE_ASSETS):
        tag_is_frozen(ci)
        assets = read_draft(ci, plan)
        if name in assets:
            continue
        try:
            created = upload_missing(token, extracted / name)
        except (ValueError, OSError, http.client.HTTPException):
            # An ambiguous request is reconciled through authenticated exact metadata.
            # A mismatched or missing asset is never clobbered or retried blindly.
            assets = read_draft(ci, plan)
            require(name in assets, f"GitHub upload remains unconfirmed: {name}")
        else:
            assets = read_draft(ci, plan)
            require(name in assets and assets[name]["id"] == created["id"],
                    f"authenticated Apple upload readback differs: {name}")
    require(assets.keys() == ANDROID_ASSETS | APPLE_ASSETS, "exact ten-asset draft is incomplete")
    authenticated = work / "authenticated"
    authenticated.mkdir()
    for name in sorted(APPLE_ASSETS):
        target = authenticated / name
        ci.api_download(f"releases/assets/{assets[name]['id']}", target,
                        plan["apple"][name]["size"], "application/octet-stream")
        check_file(ci, target, plan["apple"][name])
    require(read_draft(ci, plan) == assets, "draft assets moved during authenticated byte proof")
    tag_is_frozen(ci)
    return assets


def context(ci, plan_raw):
    expected = {"GITHUB_REPOSITORY": REPO, "GITHUB_REPOSITORY_ID": str(REPO_ID),
                "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_ACTOR": "mamaclapper",
                "GITHUB_ACTOR_ID": "50227842", "GITHUB_TRIGGERING_ACTOR": "mamaclapper", "GITHUB_RUN_ATTEMPT": "1",
                "GITHUB_REF": f"refs/tags/{OPS_TAG}", "GITHUB_WORKFLOW_REF": f"{REPO}/{OPS_WORKFLOW}@refs/tags/{OPS_TAG}",
                "REVIEWED_PLAN_SHA256": sha(plan_raw), "DISPATCH_PLAN_SHA256": sha(plan_raw)}
    require(all(os.environ.get(key) == value for key, value in expected.items()), "protected attachment context differs")
    source = os.environ["GITHUB_SHA"]
    run_id = int(os.environ["GITHUB_RUN_ID"])
    require(re.fullmatch(r"[0-9a-f]{40}", source) and source == os.environ["GITHUB_WORKFLOW_SHA"] and
            subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() == source and
            not subprocess.check_output(["git", "status", "--porcelain"], text=True),
            "attachment checkout differs")
    run = ci.api(f"actions/runs/{run_id}")
    require(run["id"] == run_id and run["workflow_id"] == OPS_WORKFLOW_ID and run["run_attempt"] == 1 and
            run["head_sha"] == source and run["head_branch"] == OPS_TAG and run["path"].split("@", 1)[0] == OPS_WORKFLOW and
            run["repository"]["id"] == REPO_ID and run["head_repository"]["id"] == REPO_ID and
            run["event"] == "workflow_dispatch", "protected attachment workflow differs")
    ref = ci.api(f"git/ref/tags/{OPS_TAG}")
    require(ref["ref"] == f"refs/tags/{OPS_TAG}" and ref["object"]["type"] == "tag", "attachment tag is not annotated")
    annotated = ci.api(f"git/tags/{ci.sha(ref['object']['sha'], 40)}")
    require(annotated["sha"] == ref["object"]["sha"] and annotated["tag"] == OPS_TAG and
            annotated["object"]["type"] == "commit" and annotated["object"]["sha"] == source,
            "annotated attachment tag differs from reviewed source")
    commit = ci.api(f"commits/{source}")
    require([parent["sha"] for parent in commit["parents"]] == [ATTACH_SHA_BASE] and
            {row["filename"] for row in commit["files"]} == {OPS_WORKFLOW, *(f"scripts/{name}" for name in
                (OPS_SCRIPT, OPS_PLAN, OPS_TRANSPORT))}, "attachment operations parent or file scope differs")
    return {"runId": run_id, "attempt": 1, "sourceCommit": source, "ref": OPS_TAG, "workflowId": OPS_WORKFLOW_ID}


def run():
    scripts = Path(__file__).parent
    ci = apply_transport(scripts / OPS_TRANSPORT)
    plan_raw = bound_bytes(scripts / OPS_PLAN, MAX_JSON)
    plan = load(plan_raw)
    require(plan.keys() == {"schemaVersion", "releaseId", "sourceCommit", "tag", "build", "android", "apple"} and
            type(plan["schemaVersion"]) is int and plan["schemaVersion"] == 1 and
            plan["releaseId"] == RELEASE and plan["sourceCommit"] == SOURCE and plan["tag"] == TAG and plan["build"] == BUILD and
            plan["android"].keys() == ANDROID_ASSETS and plan["apple"].keys() == APPLE_ASSETS, "attachment plan differs")
    recovery = context(ci, plan_raw)
    tag_is_frozen(ci)
    read_draft(ci, plan)
    token = os.environ["GH_TOKEN"]
    require(bool(token), "GitHub job token unavailable")
    runner_temp = Path(os.environ["RUNNER_TEMP"])
    with tempfile.TemporaryDirectory(prefix="stable-057-attach-", dir=runner_temp) as directory:
        work = Path(directory)
        files = verify_original(ci, plan, work)
        assets = attach(ci, plan, files, work, token)
    result = {"schemaVersion": 1, "releaseId": RELEASE, "sourceCommit": SOURCE, "tag": TAG, "build": BUILD,
              "tagObject": TAG_OBJECT, "draft": True, "prerelease": False, "draftBodySha256": BODY_SHA,
              "originalAppleRunId": APPLE_RUN, "originalAppleArtifactId": APPLE_ARCHIVE,
              "originalAppleAttempt": 1, "originalAppleJobId": APPLE_JOB,
              "originalAppleArtifactSize": APPLE_ARCHIVE_SIZE, "originalAppleArtifactSha256": APPLE_ARCHIVE_SHA,
              "reviewedAppleProof": {"runId": APPLE_PROOF_RUN, "artifactId": APPLE_PROOF_ARCHIVE, "artifactSha256": APPLE_PROOF_SHA},
              "recovery": recovery,
              "assets": {name: {"id": asset["id"], "size": asset["size"], "sha256": asset["digest"][7:]}
                         for name, asset in assets.items()}}
    (runner_temp / "attachment.json").write_bytes(canonical(result))
    print(f"Verified all ten draft asset identities and downloaded five exact Apple assets on draft {RELEASE}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    renderer = actions.add_parser("render")
    renderer.add_argument("--repo", type=Path, required=True)
    renderer.add_argument("--apple-proof", type=Path, required=True)
    renderer.add_argument("--android-draft", type=Path, required=True)
    renderer.add_argument("--out", type=Path, required=True)
    actions.add_parser("attach")
    args = parser.parse_args()
    if args.action == "render":
        render(args.repo, args.apple_proof, args.android_draft, args.out)
    else:
        run()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"::error::Stable Apple attachment stopped ({type(error).__name__}): {error}", file=sys.stderr)
        sys.exit(1)
