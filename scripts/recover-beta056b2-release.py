#!/usr/bin/env python3
"""Read-only release recovery for the original v0.5.6-beta.2 CI artifacts.

Only GET requests are issued. prepare writes a new local nine-file upload directory;
verify-draft and verify-published independently authenticate both original CI artifacts.
The existing local Apple verifier supplies package/route inspection, NOT local provenance.
The sole receipt exception admits absent optional text inputs as well as empty strings.
Original receipt bytes remain immutable. The original tag's published-event verifier
still rejects that serialization shape; recovery verification does not make it green.
The caller must supply an independently reviewed verifier hash and its public source
commit. This hash is a review anchor, not self-issued release authorization.
"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timedelta
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

REPO = "VortXTV/VortX"
MARKER = "<!-- vortx-distribution: hosted-direct-beta -->"
PROVENANCE = "VortX-Hosted-Direct-Beta-Provenance.json"
SUMS = "SHA256SUMS.txt"
ENGINE = "af29b22e4c45740a1f5b6cb415b81f8430f55b9f"
STREMIO = "31c66611822043e089f5819ad232a5df93975873"
BUNDLETOOL_SHA = "a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
MAX_ARCHIVE = 5 * 1024**3
RECOVERY_TAG = "v0.5.6-beta.2"
RECOVERY_SOURCE = "96e6ca683fc60ce983d9426da186ed8d0c7bdedb"
RECOVERY_TAG_OBJECT = "f93bb281b27cb60e86ca7d5f3dc9fd239afc1618"
RECOVERY_RELEASE = 416691309
RECOVERY_VERSION = "0.5.6"
RECOVERY_BUILD = "276"
RECOVERY_PATH = "scripts/recover-beta056b2-release.py"
ORIGINAL_VERIFIER_SHA = "10a2fa9c5f243616ad0fe0735e369421272cb76718d6def27fb96f5cf7d894aa"
DISPATCH_SIZE = 421
DISPATCH_SHA = "ad2039da0759f1921efd7c508d7702ced556233fc8513d6fb08ac111981cbe42"
MAX_RECOVERY_SOURCE = 256 * 1024
RECOVERY_POINTERS = {
    "apple": {"runId": 39163405443, "attempt": 1, "artifactId": 12152826504},
    "android": {"runId": 39163407259, "attempt": 1, "artifactId": 12150540496},
}
RECOVERY_ARTIFACTS = {
    "apple": {"size": 216906795, "sha256": "6a619e2982396ee5ee5d8c3da444cda4f41c5a9ac3128bd8924b305c1c329ce8"},
    "android": {"size": 185302478, "sha256": "d98e5d428e05764528d3c6ffc2030ba0290ed78ea1c24e0770172b0a3267659e"},
}
RECOVERY_STABLE = {"latest": {"id": 415681390, "tag": "v0.5.5"},
                   "mainCommit": "bcc7ed2dfcca91e900cebe25f6921d4294e23868"}
RECOVERY_BOOLEAN_INPUTS = {
    "native_only": True, "publish_existing_055": False, "tvos_test_only": False,
    "publish_release": False, "apple_only": False,
}
RECOVERY_OPTIONAL_TEXT_INPUTS = (
    "release_tag", "recovery_source_commit", "resume_handoff", "mpvkit_artifacts_url",
    "mpvkit_artifacts_sha256", "release_id", "altstore_note",
)
APPLE_INPUTS = {
    "native_only": True, "release_tag": "", "publish_release": False,
    "publish_existing_055": False, "tvos_test_only": False,
    "recovery_source_commit": "", "resume_handoff": "",
    "mpvkit_artifacts_url": "", "mpvkit_artifacts_sha256": "",
    "apple_only": False, "release_id": "", "altstore_note": "",
}
TOOLS = (
    "scripts/verify-ci-direct-beta.py", "scripts/verify-apple-direct-test-release.py",
    "scripts/verify-native-apple-package.py", "scripts/verify-android-release-signing.sh",
    "scripts/verify-android-release-version.sh", ".github/workflows/release-tvos.yml",
    ".github/workflows/android-release.yml", "app/project.yml", "android/app/build.gradle.kts",
)
APPLE_STEPS = (
    "Select the authenticated native source revision",
    "Bind native acceptance tooling to workflow and source provenance",
    "Record artifact-only dispatch inputs for hosted beta verification",
    "Preflight the engine token (fail closed)",
    "Fetch stremiox-core (private, pinned)", "Fetch vortx-core (private monorepo, pinned)",
    "Promote the vortx-core engine workspace + verify both engines (fail closed)",
    "Select the newest Xcode on the runner", "Show toolchain",
    "Install XcodeGen (pinned release artifact, sha256-verified)",
    "Rust nightly with rust-src (tvOS is a tier 3 target)",
    "Verify complete native engine ABI", "Build native macOS streaming server from the same pin",
    "Verify Apple engine artifacts (fail closed)",
    "Verify native account and episode ABI against the reviewed engine",
    "Fetch the MPVKit-DVFEL artifacts (pinned, sha256-verified)", "Generate the Xcode project",
    "Capture exact native SDK and player inputs before app compilation",
    "Check shared server settings at the iOS 16 deployment target",
    "Smoke-test tvOS launch in a simulator (fail closed)",
    "Build tvOS (Full)", "Build tvOS (Lite)", "Build iOS",
    "Gate iOS-simulator link + dSYM (fail closed)", "Build macOS",
    "Final-sign macOS before native app acceptance", "Verify exact native app selection and linked inputs",
    "Verify tvOS device artifact metadata (fail closed)", "Audit bundle symlinks (fail closed)",
    "Package the IPAs", "Upload the immutable app handoff",
)
ANDROID_STEPS = (
    "Bind the build to the requested release tag (fail closed)",
    "Preflight the engine token (fail closed)", "Preflight release signing inputs (fail closed)",
    "Fetch stremiox-core (private, pinned)", "Fetch vortx-core (private monorepo, pinned)",
    "Promote the vortx-core workspace + record exact private source pins",
    "Build release APKs and Play bundle",
    "Verify native BuildConfig and native-only engine in every Android artifact",
    "Verify pinned production signer on every Android artifact",
    "Verify Play APK remains GPL-native-library free", "Stage verified release assets and provenance",
    "Upload the immutable Android handoff", "Create or append to the draft release",
)
LANES = {
    "apple": ("release-tvos.yml", "build-tvos", "VortX-tvOS-ci", APPLE_STEPS,
              "Upload the immutable app handoff"),
    "android": ("android-release.yml", "release-android", "VortX-Android-release", ANDROID_STEPS,
                "Upload the immutable Android handoff"),
}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def positive(value):
    require(type(value) is int and 0 < value < 2**63, "expected positive immutable numeric ID")
    return value


def sha(value, length=64):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{%d}" % length, value), "invalid digest")
    return value


def stream_digest(stream):
    result = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024**2), b""):
        result.update(chunk)
    return result.hexdigest()


def digest(path):
    with path.open("rb") as stream:
        return stream_digest(stream)


def canonical(value):
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=True) + "\n").encode()


def read_json(path):
    require(path.stat().st_size <= 32 * 1024**2, "JSON receipt exceeds bound")
    return json.loads(path.read_bytes())


def recovery_identity(tag, source, release_id, version=None, build=None):
    require(tag == RECOVERY_TAG and source == RECOVERY_SOURCE and
            type(release_id) is int and release_id == RECOVERY_RELEASE,
            "recovery is restricted to the original beta.2 tag/source/release")
    require(version is None or version == RECOVERY_VERSION, "recovery version differs")
    require(build is None or build == RECOVERY_BUILD, "recovery build differs")


def recovery_pointer(lane, pointer):
    require(lane in RECOVERY_POINTERS and isinstance(pointer, dict) and
            set(pointer) == {"runId", "attempt", "artifactId"} and
            all(type(pointer[key]) is int for key in pointer) and
            pointer == RECOVERY_POINTERS[lane], "recovery original run/attempt/artifact pointer differs")


def recovery_artifact(lane, artifact):
    expected = RECOVERY_ARTIFACTS[lane]
    require(type(artifact.get("size_in_bytes")) is int and
            artifact["size_in_bytes"] == expected["size"] and
            artifact.get("digest") == "sha256:" + expected["sha256"],
            "recovery original artifact size/digest differs")


def authenticate_recovery_source(args):
    # This gate executes before any checked-out helper import or package inspection.
    expected_sha = sha(args.recovery_verifier_sha256)
    commit = sha(args.recovery_source_commit, 40)
    own_path = Path(__file__).resolve()
    require(0 < own_path.stat().st_size <= MAX_RECOVERY_SOURCE, "recovery verifier size exceeds bound")
    own_bytes = own_path.read_bytes()
    require(hashlib.sha256(own_bytes).hexdigest() == expected_sha,
            "recovery verifier differs from the root-held independent review hash")
    url = f"https://api.github.com/repos/{REPO}/contents/{RECOVERY_PATH}?ref={commit}"
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"}, method="GET")
    # Public read with no token/header inherited from gh or the environment.
    with urllib.request.urlopen(request, timeout=90) as response:
        raw = response.read(2 * MAX_RECOVERY_SOURCE + 1)
    require(len(raw) <= 2 * MAX_RECOVERY_SOURCE, "public recovery source response exceeds bound")
    public = json.loads(raw)
    require(isinstance(public, dict) and public.get("type") == "file" and
            public.get("encoding") == "base64" and public.get("path") == RECOVERY_PATH and
            type(public.get("size")) is int and public["size"] == len(own_bytes) and
            0 < public["size"] <= MAX_RECOVERY_SOURCE and isinstance(public.get("content"), str),
            "public recovery source metadata differs")
    encoded = public["content"].replace("\n", "")
    require(len(encoded) <= 4 * ((MAX_RECOVERY_SOURCE + 2) // 3), "public recovery source encoding exceeds bound")
    decoded = base64.b64decode(encoded, validate=True)
    require(decoded == own_bytes and hashlib.sha256(decoded).hexdigest() == expected_sha,
            "public recovery source bytes differ from the independently reviewed verifier")
    return {"schemaVersion": 1, "kind": "beta056b2-dispatch-serialization-recovery",
            "sourceCommit": commit, "path": RECOVERY_PATH, "verifierSha256": expected_sha,
            "originalVerifier": {"sourceCommit": RECOVERY_SOURCE,
                                 "path": "scripts/verify-ci-direct-beta.py", "sha256": ORIGINAL_VERIFIER_SHA},
            "exception": {"code": "omitted-empty-optional-dispatch-text-inputs",
                          "reason": "The original dispatch receipt omits seven optional empty text inputs; five required typed booleans and all other identity and artifact gates remain exact.",
                          "originalPublishedEventVerifier": "expected-to-fail-original-typed-input-shape"}}


def api(endpoint):
    # No caller-supplied host, method, token, URL, query, or gh command is accepted.
    return json.loads(subprocess.check_output(["gh", "api", "--method", "GET", "--", f"repos/{REPO}/{endpoint}"]))


def api_download(endpoint, destination, limit, accept=None):
    command = ["gh", "api", "--method", "GET"]
    if accept:
        command += ["-H", f"Accept: {accept}"]
    command += ["--", f"repos/{REPO}/{endpoint}"]
    with destination.open("xb") as target:
        process = subprocess.Popen(command, stdout=subprocess.PIPE)
        try:
            count = 0
            while chunk := process.stdout.read(1024**2):
                count += len(chunk)
                require(count <= limit, "download exceeds declared bound")
                target.write(chunk)
            require(process.wait() == 0, "GitHub read failed")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()


def public_download(tag, name, destination, size, expected_sha):
    # Deliberately no GH_TOKEN or Authorization header on public tag downloads.
    url = f"https://github.com/{REPO}/releases/download/{tag}/{name}"
    with urllib.request.urlopen(url, timeout=90) as source, destination.open("xb") as target:
        count = 0
        while chunk := source.read(1024**2):
            count += len(chunk)
            require(count <= size, "public response is larger than the authenticated asset")
            target.write(chunk)
    require(count == size and digest(destination) == expected_sha, "public tag download bytes differ")


def tag_version(tag):
    match = re.fullmatch(r"v([0-9]+\.[0-9]+\.[0-9]+)-beta\.([1-9][0-9]*)", tag)
    require(match is not None, "only strict beta.N tags are eligible")
    return match[1]


def check_tag(tag, source):
    recovery_identity(tag, source, RECOVERY_RELEASE)
    obj = api(f"git/ref/tags/{tag}")["object"]
    require(obj.get("type") == "tag" and obj.get("sha") == RECOVERY_TAG_OBJECT,
            "original beta.2 annotated tag object differs")
    for _ in range(4):
        if obj["type"] == "commit":
            require(obj["sha"] == source, "release tag does not peel to original source")
            return
        require(obj["type"] == "tag", "tag has an unsupported object type")
        obj = api(f"git/tags/{sha(obj['sha'], 40)}")["object"]
    raise ValueError("tag nesting exceeds bound")


def release_identity(release, release_id, tag, draft):
    require(release.get("id") == release_id and release.get("tag_name") == tag and
            release.get("draft") is draft and release.get("prerelease") is True and
            (draft or isinstance(release.get("published_at"), str)), "wrong release identity/state")
    body = release.get("body") or ""
    require(body.splitlines().count(MARKER) == 1 and body.count("vortx-distribution:") == 1 and
            "vortx-channel: latest-beta" not in body and "vortx-platforms: apple" not in body,
            "release requires the unique hosted direct beta marker, without another channel/platform override")


def provenance_binding(body):
    lines = [line for line in body.splitlines() if "vortx-ci-provenance-sha256:" in line]
    require(len(lines) == 1, "release body needs one exact prepared-provenance digest line")
    match = re.fullmatch(r"<!-- vortx-ci-provenance-sha256: ([0-9a-f]{64}) -->", lines[0])
    require(match is not None, "malformed prepared-provenance digest line")
    return match[1]


def source_contract(root, source, version):
    require(subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip() == source,
            "verifier checkout is not the exact source commit")
    hashes = {}
    for relative in TOOLS:
        recorded = subprocess.check_output(["git", "-C", str(root), "show", f"{source}:{relative}"])
        require((root / relative).read_bytes() == recorded, f"working file differs from source: {relative}")
        hashes[relative] = hashlib.sha256(recorded).hexdigest()
    project = (root / "app/project.yml").read_text()
    versions = re.findall(r'^\s*MARKETING_VERSION:\s*"?([0-9.]+)"?\s*$', project, re.M)
    builds = re.findall(r'^\s*CURRENT_PROJECT_VERSION:\s*"?([0-9]+)"?\s*$', project, re.M)
    require(len(versions) == len(builds) == 6 and set(versions) == {version} and len(set(builds)) == 1,
            "six Apple target version/build pairs must agree with the beta tag")
    gradle = (root / "android/app/build.gradle.kts").read_text()
    require(re.findall(r'versionName = "([^"]+)"', gradle) == [version] and
            re.findall(r'^\s*versionCode = ([0-9]+)\s*$', gradle, re.M) == [builds[0]],
            "Android source version/build differs from Apple/tag")
    positive(int(builds[0]))
    return builds[0], hashes


def successful_job(jobs, lane, run_id, attempt, source):
    _, name, _, required, upload = LANES[lane]
    found = [job for job in jobs if job.get("name") == name]
    require(len(found) == 1, "expected one exact original build job")
    job = found[0]
    require(job.get("run_id") == run_id and job.get("run_attempt") == attempt and
            job.get("head_sha") == source and job.get("status") == "completed" and
            job.get("conclusion") == "success", "build job was not successful at the requested attempt")
    steps = job["steps"]
    for name in required:
        selected = [step for step in steps if step.get("name") == name]
        require(len(selected) == 1 and selected[0].get("status") == "completed" and
                selected[0].get("conclusion") == "success", f"required step did not succeed: {name}")
    skipped = ("Refuse Android-only publication",) if lane == "android" else (
        "Validate immutable Beta 1 source recovery", "Build the content-addressed release feed artifact",
        "Upload the immutable feed handoff", "Constrain legacy comparison to artifact-only builds",
        "Constrain Full tvOS test mode to artifact-only builds", "Package Full tvOS test IPA",
    )
    for name in skipped:
        selected = [step for step in steps if step.get("name") == name]
        require(len(selected) == 1 and selected[0].get("conclusion") == "skipped",
                f"forbidden publication/recovery/comparison step was not skipped: {name}")
    return job, next(step for step in steps if step["name"] == upload)


def upload_proof(artifact, step, lines):
    parse = lambda value: datetime.fromisoformat(value.replace("Z", "+00:00"))
    start, end = parse(step["started_at"]), parse(step["completed_at"])
    boundary = end + timedelta(seconds=1)
    require(end >= start and start <= parse(artifact["created_at"]) <= boundary,
            "artifact creation is outside the original upload step")
    expected = [
        f"SHA256 digest of uploaded artifact is {artifact['digest'][7:]}",
        f"Artifact {artifact['name']} successfully finalized. Artifact ID {artifact['id']}",
        f"Artifact {artifact['name']} has been successfully uploaded! Final size is {artifact['size_in_bytes']} bytes. Artifact ID is {artifact['id']}",
    ]
    matches = [[] for _ in expected]
    for line in lines:
        stamp, separator, body = line.rstrip("\r\n").partition(" ")
        if separator and body in expected:
            when = parse(stamp)
            require(start <= when < boundary, "upload proof falls outside its step")
            matches[expected.index(body)].append(when)
    require(all(len(items) == 1 for items in matches), "missing/duplicate exact upload ID/name/size/digest log proof")
    require(matches[0][0] <= matches[1][0] <= matches[2][0], "upload proof order differs")


def extract_exact(path, artifact, names, output):
    # Same opened, nonsymlink regular file for hash and ZIP; extract flat regular files only.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        require(stat.S_ISREG(metadata.st_mode) and metadata.st_size == artifact["size_in_bytes"], "artifact ZIP size/type differs")
        require(stream_digest(stream) == artifact["digest"][7:], "artifact ZIP digest differs")
        stream.seek(0)
        with zipfile.ZipFile(stream) as archive:
            entries = archive.infolist()
            require(len(entries) == len(names) and {entry.filename for entry in entries} == names,
                    "artifact has missing, duplicate, or extra files")
            require(sum(entry.file_size for entry in entries) <= MAX_ARCHIVE, "unpacked artifact exceeds bound")
            for entry in entries:
                mode = entry.external_attr >> 16
                require(re.fullmatch(r"[A-Za-z0-9._-]{1,200}", entry.filename) and not entry.is_dir() and
                        not entry.flag_bits & 1 and stat.S_IFMT(mode) in (0, stat.S_IFREG) and
                        0 < entry.file_size <= 2 * 1024**3, "unsafe artifact ZIP entry")
            output.mkdir()
            for entry in entries:
                with archive.open(entry) as source, (output / entry.filename).open("xb") as target:
                    shutil.copyfileobj(source, target)


def authenticate_build(lane, pointer, tag, source, names, work):
    recovery_identity(tag, source, RECOVERY_RELEASE)
    recovery_pointer(lane, pointer)
    require(set(pointer) == {"runId", "attempt", "artifactId"}, "build pointer has unknown/missing fields")
    run_id, attempt, artifact_id = (positive(pointer[key]) for key in ("runId", "attempt", "artifactId"))
    workflow, job_name, artifact_name, required, _ = LANES[lane]
    run = api(f"actions/runs/{run_id}")
    workflow_meta = api(f"actions/workflows/{workflow}")
    repository = run.get("repository", {})
    head_repository = run.get("head_repository", {})
    repo_id = positive(repository.get("id"))
    require(repository.get("full_name") == head_repository.get("full_name") == REPO and
            head_repository.get("id") == repo_id and run.get("id") == run_id and
            run.get("run_attempt") == attempt and run.get("event") == "workflow_dispatch" and
            run.get("head_sha") == source and run.get("head_branch") == tag and
            run.get("path") == workflow_meta.get("path") == f".github/workflows/{workflow}" and
            run.get("workflow_id") == workflow_meta.get("id") and
            run.get("status") == "completed" and run.get("conclusion") == "success",
            "workflow/run/repository/ref/source/latest-attempt identity differs")
    jobs = []
    for page in range(1, 11):
        payload = api(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}")
        jobs.extend(payload["jobs"])
        if len(jobs) >= payload["total_count"]:
            break
    require(len(jobs) == payload["total_count"], "job pagination incomplete")
    job, upload = successful_job(jobs, lane, run_id, attempt, source)
    if lane == "apple":
        require(all(j.get("conclusion") == "skipped" for j in jobs if j.get("name") in
                    ("attach-release", "publish-existing-055")), "Apple write lane unexpectedly ran")
    artifact = api(f"actions/artifacts/{artifact_id}")
    recovery_artifact(lane, artifact)
    workflow_run = artifact.get("workflow_run", {})
    require(artifact.get("id") == artifact_id and artifact.get("name") == artifact_name and
            artifact.get("expired") is False and type(artifact.get("size_in_bytes")) is int and
            0 < artifact["size_in_bytes"] <= MAX_ARCHIVE and
            re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", "")) and
            workflow_run.get("id") == run_id and workflow_run.get("head_sha") == source and
            workflow_run.get("head_branch") == tag and workflow_run.get("repository_id") == repo_id and
            workflow_run.get("head_repository_id") == repo_id, "artifact metadata is not the original run's output")
    log = work / f"{lane}.log"
    api_download(f"actions/jobs/{positive(job['id'])}/logs", log, 512 * 1024**2)
    with log.open(errors="strict") as lines:
        upload_proof(artifact, upload, lines)
    archive = work / f"{lane}.zip"
    api_download(f"actions/artifacts/{artifact_id}/zip", archive, artifact["size_in_bytes"])
    output = work / lane
    extract_exact(archive, artifact, names, output)
    public = {**pointer, "workflow": f".github/workflows/{workflow}", "workflowId": workflow_meta["id"],
              "sourceCommit": source, "headBranch": tag, "event": "workflow_dispatch",
              "repositoryId": repo_id, "jobId": job["id"], "jobName": job_name,
              "requiredSuccessfulSteps": list(required), "artifactName": artifact_name,
              "artifactSha256": artifact["digest"][7:], "artifactSize": artifact["size_in_bytes"],
              "artifactCreatedAt": artifact["created_at"]}
    return output, public


def checksums(path, files, prefix=""):
    expected = {prefix + name: digest(file) for name, file in files.items()}
    observed = {}
    for line in path.read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._/-]+)", line)
        require(match is not None and match[2] not in observed, "malformed or duplicate checksum entry")
        observed[match[2]] = match[1]
    require(observed == expected, "checksum matrix/content differs")


def file_matrix(tag, version):
    apple = {key: f"VortX-{slug}-ci.{extension}" for key, slug, extension in (
        ("ios", "iOS", "ipa"), ("tvos", "tvOS", "ipa"), ("tvos-lite", "tvOS-lite", "ipa"),
        ("macos", "macOS", "dmg"))}
    receipts = {"native-build-inputs.json", "native-workflow-provenance.json", "native-ci-dispatch.json",
                "native-ios-simulator.json", "native-tvos-simulator.json"}
    for key in apple:
        receipts |= {f"native-{key}.json", f"native-package-{key}.json"}
    android = {f"VortX-{version}-full-mpv-universal.apk", f"VortX-{version}-play-media3-universal.apk",
               f"VortX-{version}-play-media3.aab"}
    return apple, set(apple.values()) | receipts | {"SHA256SUMS-ci.txt"}, android


def validate_dispatch(receipt, pointer, tag, source):
    recovery_identity(tag, source, RECOVERY_RELEASE)
    recovery_pointer("apple", pointer)
    expected = {"schemaVersion": 1, "event": "workflow_dispatch", "ref": f"refs/tags/{tag}",
                "sourceCommit": source, "workflowCommit": source, "runId": pointer["runId"],
                "attempt": pointer["attempt"]}
    require(isinstance(receipt, dict) and set(receipt) == set(expected) | {"inputs"},
            "original Apple dispatch metadata keys differ")
    require(canonical({key: receipt[key] for key in expected}) == canonical(expected),
            "original Apple dispatch metadata differs")
    inputs = receipt["inputs"]
    require(isinstance(inputs, dict) and
            set(inputs) <= set(RECOVERY_BOOLEAN_INPUTS) | set(RECOVERY_OPTIONAL_TEXT_INPUTS) and
            set(RECOVERY_BOOLEAN_INPUTS) <= set(inputs), "original Apple dispatch input keys differ")
    require(all(type(inputs[key]) is bool and inputs[key] is value
                for key, value in RECOVERY_BOOLEAN_INPUTS.items()),
            "original typed Apple dispatch booleans differ")
    require(all(type(inputs[key]) is str and inputs[key] == ""
                for key in RECOVERY_OPTIONAL_TEXT_INPUTS if key in inputs),
            "original Apple dispatch optional text must be absent or exactly empty")


def inspect_apple(directory, pointer, tag, source, version, build, tools, helper):
    workflow = read_json(directory / "native-workflow-provenance.json")
    require(workflow == {"schemaVersion": 1, "sourceCommit": source, "workflowCommit": source,
                        "verifierSha256": tools["scripts/verify-native-apple-package.py"], "tag": "",
                        "runId": pointer["runId"], "attempt": pointer["attempt"]},
            "original Apple workflow provenance differs; tag must remain empty")
    dispatch_path = directory / "native-ci-dispatch.json"
    require(dispatch_path.stat().st_size == DISPATCH_SIZE, "original beta.2 raw dispatch receipt size/digest differs")
    dispatch_raw = dispatch_path.read_bytes()
    require(len(dispatch_raw) == DISPATCH_SIZE and hashlib.sha256(dispatch_raw).hexdigest() == DISPATCH_SHA,
            "original beta.2 raw dispatch receipt size/digest differs")
    dispatch = json.loads(dispatch_raw)
    validate_dispatch(dispatch, pointer, tag, source)
    inputs = read_json(directory / "native-build-inputs.json")
    require(inputs.get("schema") == 1 and inputs.get("engineSourceRevision") == ENGINE and
            inputs.get("features") == helper.EXPECTED_NATIVE_FEATURES, "native SDK input identity differs")
    index = {}
    for row in inputs["inputs"]:
        key = (row.get("kind"), row.get("slice"), row.get("target"))
        require(key not in index, "duplicate native SDK input")
        index[key] = sha(row["sha256"])
    native = helper.NATIVE
    expected_keys = {("engine", value, None) for value in native.ENGINE_SLICES.values()}
    expected_keys |= {("header", value, None) for value in native.ENGINE_SLICES.values()}
    expected_keys |= {("mpv", value, target) for value in native.MPV_SLICES.values() for target in native.MPV_TARGETS}
    expected_keys |= {("mpv-manifest", None, None), ("mac-server", None, None)}
    require(set(index) == expected_keys and len({index[key] for key in index if key[0] == "header"}) == 1,
            "native SDK/player input matrix or copied headers differ")
    apple, _, _ = file_matrix(tag, version)
    checksums(directory / "SHA256SUMS-ci.txt", {name: directory / name for name in apple.values()}, "out/")
    records = []
    for key in (*apple, "ios-simulator", "tvos-simulator"):
        platform = {"tvos-lite": "tvos", "ios-simulator": "ios-sim", "tvos-simulator": "tvos-sim"}.get(key, key)
        raw = read_json(directory / f"native-{key}.json")
        accepted = helper._portable_receipt(raw, platform)
        require(accepted["engineSourceRevision"] == ENGINE and accepted["version"] == version and
                accepted["build"] == build, "accepted native app revision/version/build differs")
        for name, value in accepted["loadedArchives"].items():
            if name == "libvortx_ffi.a":
                input_key = ("engine", native.ENGINE_SLICES[platform], None)
            else:
                targets = [target for target, binary in native.MPV_TARGETS.items() if binary == name]
                require(len(targets) == 1, "unrecognized linked archive")
                input_key = ("mpv", native.MPV_SLICES[platform], targets[0])
            require(index.get(input_key) == value, "accepted linker input hash differs from captured SDK")
        if key not in apple:
            continue  # Simulator payloads were checked by authenticated CI; not release packages.
        package = directory / apple[key]
        package_receipt = read_json(directory / f"native-package-{key}.json")
        expected_package = {field: raw[field] for field in
                            ("engineSourceRevision", "platform", "bundleIdentifier", "version", "build")}
        expected_package.update(schema=1, artifact=package.name, artifactSha256=digest(package))
        require(package_receipt == expected_package, "CI package receipt differs from original archive")
        spec = helper.ARTIFACTS[key]
        require(accepted["bundleIdentifier"] == spec[3], "native bundle identifier differs")
        item = {"name": package.name.replace("-ci.", f"-{tag}-ci."), "sha256": digest(package),
                "size": package.stat().st_size, "platform": key, "version": version, "build": build,
                "bundleIdentifier": spec[3], "signature": spec[5], "notarization": spec[6]}
        helper.inspect_artifact(package, {**item, "acceptedAppReceipt": accepted}, key)
        records.append((package, item))
    return records, {"originalWorkflow": workflow, "originalDispatch": dispatch,
                     "originalDispatchRaw": dispatch_raw.decode("utf-8"), "originalDispatchSha256": DISPATCH_SHA,
                     "receiptSha256": {path.name: digest(path) for path in sorted(directory.glob("native-*.json"))}}


def inspect_android(directory, pointer, tag, source, version, build, root, bundletool):
    _, _, names = file_matrix(tag, version)
    files = {name: directory / name for name in sorted(names)}
    checksums(directory / "SHA256SUMS-android.txt", files)
    evidence = (directory / "SIGNING_PROVENANCE.txt").read_text()
    lines = evidence.splitlines()
    for label, value in (
        ("release tag", tag), ("release tag commit", source), ("source commit", source),
        ("native engine source commit", ENGINE), ("native engine Cargo features", "jni,server,resource-host"),
        ("legacy Stremio source commit (not packaged)", STREMIO),
        ("workflow run", f"https://github.com/{REPO}/actions/runs/{pointer['runId']}"),
        ("workflow run attempt", str(pointer["attempt"])),
        ("Android versionCode", build), ("Android versionName", version),
    ):
        require([line for line in lines if line.startswith(label + ": ")] == [f"{label}: {value}"],
                f"original Android evidence identity differs: {label}")
    require(digest(bundletool) == BUNDLETOOL_SHA, "bundletool content is not the pinned verifier")
    environment = dict(os.environ, BUNDLETOOL_JAR=str(bundletool))
    paths = [str(files[name]) for name in sorted(files)]
    subprocess.run(["bash", str(root / "scripts/verify-android-release-signing.sh"), "verify", *paths],
                   check=True, env=environment)
    subprocess.run(["bash", str(root / "scripts/verify-android-release-version.sh"), build, version, *paths],
                   check=True, env=environment)
    for name, path in files.items():
        with zipfile.ZipFile(path) as archive:
            require(archive.testzip() is None, "Android package CRC differs")
            entries = archive.namelist()
            require(len(entries) == len(set(entries)), "duplicate Android archive entries")
            prefix = "base/" if name.endswith(".aab") else ""
            native_libraries = {entry for entry in entries if entry.endswith("/libvortx_ffi.so")}
            require(native_libraries == {f"{prefix}lib/{abi}/libvortx_ffi.so" for abi in
                                        ("arm64-v8a", "armeabi-v7a", "x86_64")}, "native Android ABI matrix differs")
            require(not any("libstremiox" in entry or "libnode" in entry for entry in entries),
                    "legacy engine payload in native Android package")
            if "-play-" in name:
                require(not any(re.search(r"/lib(mpv|player|avcodec|avformat|avutil)\.so$", entry) for entry in entries),
                        "GPL native payload in Play package")
    return [(path, {"name": name, "sha256": digest(path), "size": path.stat().st_size,
                    "platform": "android", "version": version, "build": build,
                    "signature": "pinned-production-signer"}) for name, path in files.items()], {
        "signingAndVersionEvidenceSha256": digest(directory / "SIGNING_PROVENANCE.txt"),
        "checksumEvidenceSha256": digest(directory / "SHA256SUMS-android.txt"),
        "engineSourceCommit": ENGINE, "nativeFeatures": "jni,server,resource-host",
    }


def stable_snapshot(tag, helper):
    latest = api("releases/latest")
    require(latest.get("tag_name") != tag and latest.get("prerelease") is False and latest.get("draft") is False,
            "beta is Latest or stable Latest cannot be proved")
    snapshot = {"latest": {"id": positive(latest["id"]), "tag": latest["tag_name"]},
                "mainCommit": sha(api("git/ref/heads/main")["object"]["sha"], 40),
                "routes": helper.capture_public_routes(tag)}
    require(snapshot["latest"] == RECOVERY_STABLE["latest"] and
            snapshot["mainCommit"] == RECOVERY_STABLE["mainCommit"], "recovery stable Latest/main pins differ")
    return snapshot


def build_manifest(args, pointers, stable, helper, work):
    version = tag_version(args.tag)
    source = sha(args.source_commit, 40)
    recovery_identity(args.tag, source, args.release_id, version)
    require(set(pointers) == set(RECOVERY_POINTERS), "recovery lane matrix differs")
    for lane, pointer in pointers.items():
        recovery_pointer(lane, pointer)
    build, tools = source_contract(args.repo_root, source, version)
    recovery_identity(args.tag, source, args.release_id, version, build)
    require(tools["scripts/verify-ci-direct-beta.py"] == ORIGINAL_VERIFIER_SHA,
            "original tag verifier differs from the frozen recovery base")
    check_tag(args.tag, source)
    apple_names, apple_matrix, android_names = file_matrix(args.tag, version)
    apple_dir, apple_run = authenticate_build("apple", pointers["apple"], args.tag, source, apple_matrix, work)
    android_dir, android_run = authenticate_build("android", pointers["android"], args.tag, source,
                                                android_names | {"SHA256SUMS-android.txt", "SIGNING_PROVENANCE.txt"}, work)
    apple, apple_evidence = inspect_apple(apple_dir, pointers["apple"], args.tag, source, version, build, tools, helper)
    android, android_evidence = inspect_android(android_dir, pointers["android"], args.tag, source, version,
                                               build, args.repo_root, args.bundletool)
    records = sorted(apple + android, key=lambda pair: pair[1]["name"])
    manifest = {"schemaVersion": 1, "distribution": "hosted-direct-beta", "repository": REPO,
                "releaseId": positive(args.release_id), "tag": args.tag, "sourceCommit": source,
                "version": version, "build": build, "sourceFileSha256": tools,
                "builds": {"apple": apple_run, "android": android_run},
                "evidence": {"apple": apple_evidence, "android": android_evidence},
                "artifacts": [item for _, item in records], "stableMustRemain": stable}
    manifest["verificationRecovery"] = {
        **args.verification_recovery,
        "originalDispatchReceipt": {"json": apple_evidence["originalDispatch"],
                                    "rawJson": apple_evidence["originalDispatchRaw"],
                                    "sha256": apple_evidence["originalDispatchSha256"], "size": DISPATCH_SIZE},
    }
    return manifest, records


def release_assets(release, expected):
    assets = release.get("assets")
    require(isinstance(assets, list) and len(assets) == len(expected), "release has missing/extra assets")
    by_name = {asset.get("name"): asset for asset in assets}
    require(set(by_name) == expected, "release asset names differ or repeat")
    for asset in assets:
        positive(asset.get("id"))
        require(asset.get("state") == "uploaded" and type(asset.get("size")) is int and
                0 < asset["size"] <= 2 * 1024**3 and
                re.fullmatch(r"sha256:[0-9a-f]{64}", asset.get("digest", "")), "release asset metadata is incomplete")
    # Download counts and other mutable counters are not asset identity. Recheck only these
    # exact content/ID/URL fields before and after downloading; never reject our own reads.
    fields = ("id", "name", "state", "size", "digest", "browser_download_url")
    return {name: {field: asset[field] for field in fields} for name, asset in by_name.items()}


def validate_asset_url(command, release, tag, name, url):
    require(command in ("verify-draft", "verify-published"), "unsupported asset URL verification mode")
    canonical_url = f"https://github.com/{REPO}/releases/download/{tag}/{name}"
    allowed = url == canonical_url
    if command == "verify-draft":
        require(release.get("draft") is True, "temporary asset URL requires an authenticated draft")
        html = release.get("html_url")
        match = re.fullmatch(rf"https://github\.com/{re.escape(REPO)}/releases/tag/(untagged-[0-9a-f]{{20}})",
                             html) if isinstance(html, str) else None
        if match is not None:
            allowed = allowed or url == f"https://github.com/{REPO}/releases/download/{match[1]}/{name}"
    require(allowed, "release asset URL differs from its exact tag or authenticated draft URL")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "verify-draft", "verify-published"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--recovery-verifier-sha256", required=True)
    parser.add_argument("--recovery-source-commit", required=True)
    parser.add_argument("--release-id", required=True, type=int)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--work-dir", required=True, type=Path)
    parser.add_argument("--bundletool", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--provenance-sha256")
    parser.add_argument("--event-file", type=Path)
    for lane in LANES:
        for field in ("run", "attempt", "artifact"):
            parser.add_argument(f"--{lane}-{field}", type=int)
    args = parser.parse_args()
    tag_version(args.tag)
    sha(args.source_commit, 40)
    positive(args.release_id)
    recovery_identity(args.tag, args.source_commit, args.release_id, tag_version(args.tag))
    for lane in LANES:
        supplied = [getattr(args, f"{lane}_{field}") for field in ("run", "attempt", "artifact")]
        if args.command == "prepare" or any(value is not None for value in supplied):
            recovery_pointer(lane, dict(zip(("runId", "attempt", "artifactId"), supplied)))
    args.verification_recovery = authenticate_recovery_source(args)
    # Authenticate checked-out helper bytes before importing their package/route inspection.
    source_build, source_tools = source_contract(args.repo_root, args.source_commit, tag_version(args.tag))
    recovery_identity(args.tag, args.source_commit, args.release_id, tag_version(args.tag), source_build)
    require(source_tools["scripts/verify-ci-direct-beta.py"] == ORIGINAL_VERIFIER_SHA,
            "original tag verifier differs from the frozen recovery base")
    specification = importlib.util.spec_from_file_location("direct_apple_content", args.repo_root / "scripts/verify-apple-direct-test-release.py")
    helper = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(helper)
    release = api(f"releases/{args.release_id}")
    release_identity(release, args.release_id, args.tag, args.command != "verify-published")
    expected_provenance = args.provenance_sha256
    if args.event_file is not None:
        require(args.command == "verify-published" and expected_provenance is None,
                "event provenance binding applies only to published verification")
        event = read_json(args.event_file)
        require(event.get("action") == "published" and event.get("repository", {}).get("full_name") == REPO,
                "wrong release event identity")
        release_identity(event["release"], args.release_id, args.tag, False)
        expected_provenance = provenance_binding(event["release"]["body"])
    if args.command != "prepare":
        sha(expected_provenance)
        require(provenance_binding(release["body"]) == expected_provenance,
                "current release body differs from the prepared/event provenance binding")
    with tempfile.TemporaryDirectory(prefix="ci-direct-beta-", dir=args.work_dir) as temporary:
        work = Path(temporary)
        if args.command == "prepare":
            require(args.output is not None and not args.output.exists(), "prepare requires a new output directory")
            pointers = {lane: {"runId": positive(getattr(args, f"{lane}_run")),
                               "attempt": positive(getattr(args, f"{lane}_attempt")),
                               "artifactId": positive(getattr(args, f"{lane}_artifact"))} for lane in LANES}
            stable = stable_snapshot(args.tag, helper)
            manifest, records = build_manifest(args, pointers, stable, helper, work)
        else:
            version = tag_version(args.tag)
            apple, _, android = file_matrix(args.tag, version)
            final_names = {name.replace("-ci.", f"-{args.tag}-ci.") for name in apple.values()} | android | {SUMS, PROVENANCE}
            assets = release_assets(release, final_names)
            provenance_file = work / PROVENANCE
            record = assets[PROVENANCE]
            require(record["size"] <= 1024**2, "public provenance is unexpectedly large")
            api_download(f"releases/assets/{record['id']}", provenance_file, record["size"], "application/octet-stream")
            require(provenance_file.stat().st_size == record["size"] and digest(provenance_file) == record["digest"][7:],
                    "provenance release metadata differs")
            require(digest(provenance_file) == expected_provenance,
                    "provenance differs from the root-held preparation digest or published event")
            recorded = read_json(provenance_file)
            pointers = {lane: {key: recorded["builds"][lane][key] for key in ("runId", "attempt", "artifactId")} for lane in LANES}
            stable = recorded["stableMustRemain"]
            manifest, records = build_manifest(args, pointers, stable, helper, work)
            require(recorded == manifest and provenance_file.read_bytes() == canonical(manifest),
                    "public provenance differs from reauthenticated CI evidence")
        sums = "".join(f"{item['sha256']}  {item['name']}\n" for _, item in records).encode()
        require(stable_snapshot(args.tag, helper) == stable, "stable Latest/main/feeds/route snapshot changed")
        check_tag(args.tag, args.source_commit)
        current_release = api(f"releases/{args.release_id}")
        release_identity(current_release, args.release_id, args.tag, args.command != "verify-published")
        if args.command == "prepare":
            args.output.mkdir()
            for path, item in records:
                with path.open("rb") as source, (args.output / item["name"]).open("xb") as target:
                    shutil.copyfileobj(source, target)
            (args.output / SUMS).write_bytes(sums)
            (args.output / PROVENANCE).write_bytes(canonical(manifest))
            print(f"Recovery prepared exactly nine local assets; no remote writes: {args.output}")
            print(f"Prepared provenance SHA-256: {digest(args.output / PROVENANCE)}")
            return
        expected_bytes = {SUMS: sums, PROVENANCE: canonical(manifest)}
        expected_hashes = {item["name"]: (item["size"], item["sha256"]) for _, item in records}
        expected_hashes.update({name: (len(value), hashlib.sha256(value).hexdigest()) for name, value in expected_bytes.items()})
        current_assets = release_assets(current_release, set(expected_hashes))
        require(current_assets == assets, "release assets changed during verification")
        for name, (size, expected_sha) in expected_hashes.items():
            asset = current_assets[name]
            require(asset["size"] == size and asset["digest"] == f"sha256:{expected_sha}",
                    "release asset metadata differs from original CI bytes")
            validate_asset_url(args.command, current_release, args.tag, name, asset.get("browser_download_url"))
            destination = work / ("verified-" + name)
            if args.command == "verify-published":
                public_download(args.tag, name, destination, size, expected_sha)
            else:
                api_download(f"releases/assets/{asset['id']}", destination, size, "application/octet-stream")
                require(destination.stat().st_size == size and digest(destination) == expected_sha, "draft bytes differ")
        require(stable_snapshot(args.tag, helper) == stable, "stable routes changed during downloads")
        check_tag(args.tag, args.source_commit)
        final_release = api(f"releases/{args.release_id}")
        release_identity(final_release, args.release_id, args.tag, args.command != "verify-published")
        require(provenance_binding(final_release["body"]) == expected_provenance, "release provenance binding changed")
        require(release_assets(final_release, set(expected_hashes)) == current_assets, "release changed during byte checks")
        print(f"Recovery verified {args.command}: original CI evidence, all nine asset bytes, unchanged stable routes")
        print("Original tag published-event verifier remains incompatible with the sparse dispatch receipt.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"CI direct beta verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
