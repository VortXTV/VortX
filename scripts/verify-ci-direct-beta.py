#!/usr/bin/env python3
"""Read-only hosted-CI beta preparation/verification. Never builds or publishes.

Only GET requests are issued. Beta 12 preflight needs only its original candidate runs.
prepare writes a new local nine-file upload directory;
verify-draft and verify-published independently authenticate both original CI artifacts.
The existing local Apple verifier supplies package/route inspection, NOT local provenance.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta
import functools
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

REPO = "VortXTV/VortX"
MARKER = "<!-- vortx-distribution: hosted-direct-beta -->"
PROVENANCE = "VortX-Hosted-Direct-Beta-Provenance.json"
SUMS = "SHA256SUMS.txt"
ENGINE = "a3169f338f3f05da4ad3adb39a1e557c3ddcac33"
NATIVE_BETA7_TAG = "v0.5.6-beta.7"
NATIVE_BETA7_ENGINE = "2ea2e0f27dd2e53b7b28228435ca35a70f92831f"
# Beta 11 follows the same reviewed native-only workflows and engine pin as beta 7, with the VortXAetherKit
# framework as a sixth Apple version pair. Both lanes are built at the candidate tag, on the release tag's
# exact commit; the protected release tag is pushed only after a full dry run of this checker passes against
# those builds, so a contract miss can no longer burn the release number (beta 9).
NATIVE_BETA11_TAG = "v0.5.6-beta.11"
NATIVE_BETA11_BUILD_TAG = "v0.5.6-beta.11-candidate.1"
NATIVE_BETA12_TAG = "v0.5.6-beta.12"
NATIVE_BETA12_BUILD_TAG = "v0.5.6-beta.12-candidate.3"
NATIVE_BETA12_BUILD = "283"
NATIVE_TAGS = (NATIVE_BETA7_TAG, NATIVE_BETA11_TAG, NATIVE_BETA12_TAG)
NATIVE_TARGETS = ("VortXiOSNative", "VortXMac", "VortXTV", "VortXTopShelf", "VortXTVLite")
NATIVE_TAG_TARGETS = {tag: NATIVE_TARGETS + (() if tag == NATIVE_BETA7_TAG else ("VortXAetherKit",)) for tag in NATIVE_TAGS}
HISTORICAL_BETA2_ENGINE = "af29b22e4c45740a1f5b6cb415b81f8430f55b9f"
STREMIO = "31c66611822043e089f5819ad232a5df93975873"
BUNDLETOOL_SHA = "a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
MAX_ARCHIVE = 5 * 1024**3
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
BETA12_TOOLS = (
    "scripts/verify-native-engine-abi.sh", "scripts/test-native-cutover-live-abi.sh",
    "scripts/test-native-oauth-intents.sh", "app/Tests/VortxNativeLiveABITests.swift",
    "scripts/run-protected-account-backup-abi.py", "scripts/test-account-backup-repair-live-abi.sh",
    "scripts/test-account-file-repair-service-live-abi.sh", "scripts/test-account-file-restore-live-abi.sh",
    "scripts/test-android-native-sync-host.sh", "android/native-sync-hosted.init.gradle",
    "scripts/verify-protected-apple-aether.py",
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


# Historical step contracts above are immutable: beta7 follows the reviewed native-only workflows.
NATIVE_BETA7_APPLE_STEPS = ("Preserve the workflow revision's native acceptance tool",) + tuple(
    "Promote the vortx-core engine workspace + verify it (fail closed)"
    if step == "Promote the vortx-core engine workspace + verify both engines (fail closed)" else step
    for step in APPLE_STEPS if step != "Fetch stremiox-core (private, pinned)")
NATIVE_BETA7_ANDROID_STEPS = (
    "Acquire reviewed Android mpv component from the checked-out release source",
    "Build exact host JNI for native sync release tests",
    "Require real native sync revision and account tests before packaging",
    "Retain native sync release JUnit and bounded provenance",
) + tuple(
    {"Promote the vortx-core workspace + record exact private source pins":
         "Promote the vortx-core workspace + record the exact private source pin",
     "Verify native BuildConfig and native-only engine in every Android artifact":
         "Verify native-only engine in every Android artifact"}.get(step, step)
    for step in ANDROID_STEPS if step != "Fetch stremiox-core (private, pinned)")
BETA12_LIVE_ABI = "Verify native account and episode ABI against the reviewed engine"
BETA12_APPLE_GATE = "Verify account backup repair, file service and restore against the packaged SDK"
BETA12_APPLE_EVIDENCE = "Retain account backup ABI evidence"
BETA12_ANDROID_GATE = "Require real native sync revision and account tests before packaging"
BETA12_ANDROID_EVIDENCE = "Retain native sync release JUnit and bounded provenance"
BETA12_AETHER_RESOLVE = "Resolve pinned Apple Aether release packages"
BETA12_AETHER_VERIFY = "Verify packaged Apple Aether linkage"
BETA12_AETHER_EVIDENCE = "Upload protected Apple Aether release evidence"
ANDROID_DRAFT_STEP = "Create or append to the draft release"
BETA12_AETHER_PACKAGES = {
    "aetherengine": {"version": "7.53.0", "revision": "4a82484b256deb70a2ae80d6923707d1fe54c6e7",
                     "location": "https://github.com/superuser404notfound/AetherEngine"},
    "libdovi": {"version": "2.1.0", "revision": "0d7cce1d6836a30d13a3a2326e50a153af53f014",
                "location": "https://github.com/superuser404notfound/LibDovi"},
}
BETA12_AETHER_APPS = {"tvos-simulator": ("tvos", "simulator"), "ios-simulator": ("ios", "simulator"),
    "tvos": ("tvos", ""), "tvos-lite": ("tvos", ""), "ios": ("ios", ""), "macos": ("macos", "")}
BETA12_AETHER_BINARIES = {"VortXAetherKit", "AetherLibavcodec", "AetherLibavfilter", "AetherLibavformat",
    "AetherLibavutil", "AetherLibdav1d", "AetherLibswresample", "AetherLibswscale", "AetherLibzimg", "AetherLibzvbi"}
BETA12_JNI_CLASSES = {
    "com.vortx.android.sync.VortXSyncManagerBackupRevisionTest": 14,
    "com.vortx.android.sync.NativeAccountSyncTest": 19,
    "com.vortx.android.integrations.NativeProspectiveProviderTest": 2,
    "com.vortx.android.engine.NativeRepositoryMutationJniTest": 18,
    "com.vortx.android.engine.NativeOwnerHistoryJniTest": 5,
    "com.vortx.android.engine.NativeOwnerHistoryCompatibilityTest": 25,
    "com.vortx.android.engine.NativeRawHostPreferencesTest": 22,
    "com.vortx.android.engine.DetachedAccountFileKernelJniTest": 1,
    "com.vortx.android.sync.AccountBackupRepairJniTest": 1,
}
BETA12_JNI_SUBSET = {
    name: count if name != "com.vortx.android.sync.NativeAccountSyncTest" else 13
    for name, count in BETA12_JNI_CLASSES.items()
    if name.rsplit(".", 1)[1] in ("VortXSyncManagerBackupRevisionTest", "NativeAccountSyncTest",
        "NativeRepositoryMutationJniTest", "NativeOwnerHistoryJniTest", "DetachedAccountFileKernelJniTest", "AccountBackupRepairJniTest")
}
BETA12_JNI_TOTAL = sum(BETA12_JNI_CLASSES.values())
BETA12_REAL_JNI = sum(BETA12_JNI_SUBSET.values())


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


def api(endpoint):
    # No caller-supplied host, method, token, URL, query, or gh command is accepted.
    return json.loads(subprocess.check_output(["gh", "api", "--method", "GET", "--", f"repos/{REPO}/{endpoint}"]))


def gh_metadata(arguments):
    # Local CLI metadata only: no endpoint, authentication request or shell.
    require(arguments in (("api", "--help"), ("--version",)), "unsupported CLI metadata command")
    process = subprocess.Popen(["gh", *arguments], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 10
    output = bytearray()
    try:
        with selectors.DefaultSelector() as monitor:
            monitor.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                require(remaining > 0 and monitor.select(remaining), "CLI metadata timed out")
                chunk = os.read(process.stdout.fileno(), min(4096, 65537 - len(output)))
                if not chunk:
                    break
                output.extend(chunk)
                require(len(output) <= 65536, "CLI metadata exceeds bound")
        require(process.wait(timeout=max(0.001, deadline - time.monotonic())) == 0,
                "CLI metadata command failed")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdout.close()
    require(output, "CLI metadata is empty")
    return bytes(output)


@functools.lru_cache(maxsize=1)
def gh_raw_options():
    # Probe once before any raw response. Never retry a failed raw download with
    # different flags, and do not change api()'s JSON metadata command.
    help_raw = gh_metadata(("api", "--help"))
    version_raw = gh_metadata(("--version",))
    help_text, version_text = (value.decode("utf-8") for value in (help_raw, version_raw))
    require(not re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", help_text + version_text),
            "CLI metadata contains control bytes")
    require(all(re.search(pattern, help_text, re.M) for pattern in
                (r"^USAGE\r?$", r"^  gh api <endpoint> \[flags\]\r?$", r"^FLAGS\r?$", r"^LEARN MORE\r?$")),
            "unrecognized API help metadata")
    advertised = re.findall(r"^[ \t]+--allow-escape-sequences[ \t]{2,}[^\r\n]+\r?$", help_text, re.M)
    require(help_text.count("--allow-escape-sequences") == len(advertised) <= 1,
            "malformed raw escape capability metadata")
    version_lines = version_text.splitlines()
    require(version_lines and re.fullmatch(r"gh version [0-9]+\.[0-9]+\.[0-9]+(?: [^\r\n]+)?", version_lines[0]),
            "unrecognized CLI version metadata")
    options = ("--allow-escape-sequences",) if advertised else ()
    receipt = {"schemaVersion": 1, "version": version_lines[0],
               "versionSha256": hashlib.sha256(version_raw).hexdigest(),
               "apiHelpSha256": hashlib.sha256(help_raw).hexdigest(), "apiHelpBytes": len(help_raw),
               "rawOptions": list(options)}
    print("GitHub raw transport capability: " + json.dumps(receipt, sort_keys=True), file=sys.stderr)
    return options


def api_download(endpoint, destination, limit, accept=None):
    # Both old and new CLIs keep exact raw bytes on this captured binary pipe.
    command = ["gh", "api", "--method", "GET", *gh_raw_options()]
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
            require(process.wait() == 0, f"GitHub raw read failed: {endpoint}")
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


def build_tag(tag):
    """The exact tag at which both original CI lanes were dispatched."""
    return {NATIVE_BETA11_TAG: NATIVE_BETA11_BUILD_TAG, NATIVE_BETA12_TAG: NATIVE_BETA12_BUILD_TAG}.get(tag, tag)


def expected_engine(tag):
    # Exact reviewed tag interpretation, never a caller-supplied/fallback engine pin.
    if tag in NATIVE_TAGS:
        return NATIVE_BETA7_ENGINE
    if tag == "v0.5.6-beta.2":
        return HISTORICAL_BETA2_ENGINE
    # beta.3 was tagged but never published; beta.4 is its corrected build and beta.5/beta.6 follow on the
    # same reviewed engine.
    require(tag in ("v0.5.6-beta.3", "v0.5.6-beta.4", "v0.5.6-beta.5", "v0.5.6-beta.6"), "no reviewed native engine pin for this beta tag")
    return ENGINE


def check_tag(tag, source):
    obj = api(f"git/ref/tags/{tag}")["object"]
    for _ in range(4):
        if obj["type"] == "commit":
            require(obj["sha"] == source, "release tag does not peel to original source")
            return
        require(obj["type"] == "tag", "tag has an unsupported object type")
        obj = api(f"git/tags/{sha(obj['sha'], 40)}")["object"]
    raise ValueError("tag nesting exceeds bound")


def release_identity(release, release_id, tag, draft, source):
    require(release.get("id") == release_id and release.get("tag_name") == tag and
            release.get("target_commitish") == source and
            release.get("draft") is draft and release.get("prerelease") is True and
            (release.get("published_at") is None if draft else
             isinstance(release.get("published_at"), str) and bool(release["published_at"])),
            "wrong release identity/state/source")
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


def source_contract(root, source, version, tag):
    require(subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip() == source,
            "verifier checkout is not the exact source commit")
    hashes = {}
    for relative in TOOLS + (BETA12_TOOLS if tag == NATIVE_BETA12_TAG else ()):
        recorded = subprocess.check_output(["git", "-C", str(root), "show", f"{source}:{relative}"])
        require((root / relative).read_bytes() == recorded, f"working file differs from source: {relative}")
        hashes[relative] = hashlib.sha256(recorded).hexdigest()
    build = source_versions((root / "app/project.yml").read_text(),
                            (root / "android/app/build.gradle.kts").read_text(), version, tag)
    return build, hashes


def source_versions(project, gradle, version, tag):
    expected_engine(tag)  # Unknown future tags cannot select a version/step policy.
    require(tag_version(tag) == version, "source version differs from the exact beta tag")
    versions = re.findall(r'^\s*MARKETING_VERSION:\s*"?([0-9.]+)"?\s*$', project, re.M)
    builds = re.findall(r'^\s*CURRENT_PROJECT_VERSION:\s*"?([0-9]+)"?\s*$', project, re.M)
    expected_pairs = 5 if tag == NATIVE_BETA7_TAG else 6
    require(len(versions) == len(builds) == expected_pairs and set(versions) == {version} and len(set(builds)) == 1,
            "Apple target version/build pairs must agree with the exact beta contract")
    if tag in NATIVE_TAGS:
        sections = project.split("\ntargets:\n")
        require(len(sections) == 2, "native beta requires the actual project target section")
        targets = sections[1].split("\nschemes:\n", 1)[0]
        blocks = re.findall(r'^  ([A-Za-z_][A-Za-z0-9_]*):\n(.*?)(?=^  [A-Za-z_][A-Za-z0-9_]*:\n|\Z)',
                            targets, re.M | re.S)
        for name in NATIVE_TAG_TARGETS[tag]:
            selected = [body for target, body in blocks if target == name]
            require(len(selected) == 1 and
                    re.findall(r'^\s*MARKETING_VERSION:\s*"?([0-9.]+)"?\s*$', selected[0], re.M) == [version] and
                    re.findall(r'^\s*CURRENT_PROJECT_VERSION:\s*"?([0-9]+)"?\s*$', selected[0], re.M) == [builds[0]],
                    "native beta target version/build differs: " + name)
    require(re.findall(r'versionName = "([^"]+)"', gradle) == [version] and
            re.findall(r'^\s*versionCode = ([0-9]+)\s*$', gradle, re.M) == [builds[0]],
            "Android source version/build differs from Apple/tag")
    positive(int(builds[0]))
    if tag == NATIVE_BETA12_TAG:
        require(builds[0] == NATIVE_BETA12_BUILD, "Beta 12 requires the exact cross-platform build number")
    return builds[0]


def job_contract(lane, tag):
    expected_engine(tag)
    required = LANES[lane][3]
    skipped = ("Refuse Android-only publication",) if lane == "android" else (
        "Validate immutable Beta 1 source recovery", "Build the content-addressed release feed artifact",
        "Upload the immutable feed handoff", "Constrain legacy comparison to artifact-only builds",
        "Constrain Full tvOS test mode to artifact-only builds", "Package Full tvOS test IPA",
    )
    if tag in NATIVE_TAGS:
        required = NATIVE_BETA7_APPLE_STEPS if lane == "apple" else NATIVE_BETA7_ANDROID_STEPS
        if lane == "apple":
            skipped = tuple("Reject removed legacy comparison builds"
                            if step == "Constrain legacy comparison to artifact-only builds" else step
                            for step in skipped) + (
                "Checkout the immutable recovered app source", "Verify immutable recovered source checkout")
    if tag == NATIVE_BETA12_TAG:
        if lane == "apple":
            required += (BETA12_APPLE_GATE, "Record account backup ABI gate outcome", BETA12_APPLE_EVIDENCE)
            required += (BETA12_AETHER_RESOLVE, BETA12_AETHER_VERIFY, BETA12_AETHER_EVIDENCE)
        else:
            required = tuple(name for name in required if name != ANDROID_DRAFT_STEP)
            skipped += (ANDROID_DRAFT_STEP,)
    return required, skipped


def successful_job(jobs, lane, run_id, attempt, source, tag):
    _, name, _, _, upload = LANES[lane]
    required, skipped = job_contract(lane, tag)
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
        stamp = stamp[1:] if stamp.startswith("\ufeff") else stamp
        require("\ufeff" not in stamp, "internal/repeated BOM in upload timestamp")
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


def step_time(value):
    require(isinstance(value, str) and "\ufeff" not in value, "invalid step timestamp")
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def require_step_order(steps, names):
    for before, after in zip(names, names[1:]):
        first, second = steps[before], steps[after]
        require(first["number"] < second["number"] and
                step_time(first["completed_at"]) <= step_time(second["started_at"]),
                "protected native gate did not precede packaging")


def unique_step_marker(log, step, prefix, pattern):
    start, end = step_time(step["started_at"]), step_time(step["completed_at"])
    require(end >= start, "negative protected native step duration")
    found = []
    with log.open(errors="strict") as lines:
        for line in lines:
            stamp, _, body = line.rstrip("\r\n").partition(" ")
            if body.startswith(prefix):
                require(start <= step_time(stamp.removeprefix("\ufeff")) < end + timedelta(seconds=1) and
                        re.fullmatch(pattern, body), "invalid protected native gate log marker")
                found.append(body)
    require(len(found) == 1, "missing or repeated protected native gate log marker")
    return found[0]


def beta12_gate_zip(name, names, run_id, repo_id, source, step, log, work):
    rows = api(f"actions/runs/{run_id}/artifacts?name={name}&per_page=100")
    require(rows.get("total_count") == 1 and len(rows["artifacts"]) == 1, "missing or ambiguous native gate artifact")
    artifact_id = positive(rows["artifacts"][0]["id"])
    artifact = api(f"actions/artifacts/{artifact_id}")
    run = artifact.get("workflow_run", {})
    require(artifact.get("id") == artifact_id and artifact.get("name") == name and artifact.get("expired") is False and
            run.get("id") == run_id and run.get("head_sha") == source and run.get("head_branch") == NATIVE_BETA12_BUILD_TAG and
            run.get("repository_id") == repo_id and run.get("head_repository_id") == repo_id and
            type(artifact.get("size_in_bytes")) is int and 0 < artifact["size_in_bytes"] <= 16 * 1024**2 and
            re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", "")), "native gate artifact has wrong original identity")
    with log.open(errors="strict") as lines:
        upload_proof(artifact, step, lines)
    path = work / f"beta12-gate-{artifact_id}.zip"
    api_download(f"actions/artifacts/{artifact_id}/zip", path, artifact["size_in_bytes"])
    require(path.stat().st_size == artifact["size_in_bytes"] and digest(path) == artifact["digest"][7:],
            "native gate ZIP does not match its original metadata")
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        require(len(entries) == len(names) and {row.filename for row in entries} == names and
                sum(row.file_size for row in entries) <= 16 * 1024**2 and
                all(0 < row.file_size <= 4 * 1024**2 and not row.flag_bits & 1 and
                    stat.S_IFMT(row.external_attr >> 16) in (0, stat.S_IFREG) for row in entries),
                "native gate ZIP inventory differs")
        # Read exact allowlisted entry names without writing raw receipts or XML to public output.
        contents = {row.filename: archive.read(row) for row in entries}
    return contents, {"artifactId": artifact_id, "artifactSha256": artifact["digest"][7:]}


def beta12_apple_gate(contents, pointer, source):
    gate, outcome, eligibility = (json.loads(contents[name]) for name in ("gate.json", "workflow-step.json", "eligibility.json"))
    identity = {"schemaVersion": 1, "sourceCommit": source, "workflowCommit": source,
                "runID": str(pointer["runId"]), "attempt": str(pointer["attempt"])}
    require(canonical(outcome) == canonical({**identity, "stepOutcome": "success"}), "Apple protected gate outcome differs")
    require(all(gate.get(key) == value for key, value in identity.items()) and
            gate.get("nativeSourceRevision") == expected_engine(NATIVE_BETA12_TAG) and gate.get("status") == "PASS" and
            gate.get("sdkUnchanged") is True and gate.get("sdkBefore") == gate.get("sdkAfter") and
            set(gate["sdkBefore"]) == {"headerSHA256", "librarySHA256"}, "Apple protected gate source/SDK differs")
    present = {f"app/SourcesShared/{name}.swift": True for name in (
        "VortxAccountBackupRepair", "VortxAccountFileRepairService", "VortxAccountFileRestore", "VortxAccountFileRestoreJournal")}
    require(canonical(eligibility) == canonical({"schemaVersion": 1, "sourceCommit": source, "featureFilesPresent": present,
            "restoreRequired": True, "required": True, "reason": "feature_gates_required"}), "Apple protected gate eligibility differs")
    fixtures = {"converter": ("ABI_COMPATIBILITY_PASS", 269, "backup-repair-abi"),
                "service": ("SERVICE_BOUNDARY_ABI_PASS", 35, "backup-repair-abi"),
                "restore": ("RESTORE_ADMISSION_JOURNAL_ABI_PASS", 63, "account-file-restore-abi")}
    require(set(gate["fixtures"]) == set(fixtures), "Apple protected gate fixture roster differs")
    for label, (status, minimum, binary) in fixtures.items():
        report = gate["fixtures"][label]
        require(report == json.loads(contents[label + ".json"]) and report.get("status") == "PASS" and
                type(report.get("entryExitCode")) is int and report["entryExitCode"] == 0 and report.get("receiptStatus") == status and
                type(report.get("passLines")) is int and report["passLines"] >= minimum and
                report.get("postRunInputsUnchanged") is True and
                all(type(report[phase].get("exitCode")) is int and report[phase]["exitCode"] == 0 and report[phase].get("timedOut") is False
                    for phase in ("compiler", "runtime")), "Apple protected gate fixture did not pass")
        sha(report["outputHashes"][binary])
    return {"coordinatorSha256": sha(gate["coordinatorSHA256"]),
            "sdkHeaderSha256": sha(gate["sdkBefore"]["headerSHA256"]),
            "sdkArchiveSha256": sha(gate["sdkBefore"]["librarySHA256"]),
            "assertionCounts": {label: gate["fixtures"][label]["passLines"] for label in fixtures}}


def beta12_android_gate(contents, source):
    reports = "reports/native-sync-host/"
    host, accepted = (json.loads(contents[reports + name]) for name in ("host-jni.json", "host-jni-accepted.json"))
    require(host.get("schema") == 1 and host.get("appSource") == source and
            host.get("engineSource") == expected_engine(NATIVE_BETA12_TAG) and host.get("features") == "jni,server,resource-host" and
            host.get("toolchain") == "nightly-2026-07-19" and host.get("hostTarget") == "x86_64-unknown-linux-gnu" and
            all(accepted.get(key) == value for key, value in host.items()), "Android host JNI identity differs")
    library, source_inputs = sha(host["librarySha256"]), sha(host["sourceInputsSha256"])
    require(accepted.get("postRuntimeLibrarySha256") == library and accepted.get("postRuntimeSourceInputsSha256") == source_inputs and
            canonical(accepted.get("testClasses")) == canonical(BETA12_JNI_CLASSES) and
            type(accepted.get("executed")) is int and accepted["executed"] == BETA12_JNI_TOTAL and
            type(accepted.get("realJniCases")) is int and accepted["realJniCases"] == BETA12_REAL_JNI and
            all(type(accepted.get(key)) is int and accepted[key] == 0
                for key in ("skipped", "failures", "errors")), "Android exact host JNI result differs")
    observed, xml_hashes = {}, {}
    names = accepted["realJniCaseNames"]
    require(set(names) == set(BETA12_JNI_CLASSES), "Android real JNI case classes differ")
    for class_name, count in BETA12_JNI_CLASSES.items():
        name = f"TEST-{class_name}.xml"
        raw = contents["test-results/testPlayDebugUnitTest/" + name]
        text = raw.decode("utf-8")
        require("\0" not in text and "<!DOCTYPE" not in text and "<!ENTITY" not in text, "unsupported JUnit XML declarations")
        suite = ET.fromstring(text)
        cases = {node.get("name") for node in suite.findall("testcase") if node.get("classname") == class_name and
                 node.get("status", "run") == "run" and node.get("name")}
        required = names[class_name]
        require(suite.tag == "testsuite" and suite.get("name") == class_name and suite.get("tests") == str(count) and
                len(cases) == len(suite.findall("testcase")) == count and
                all(suite.get(key) == "0" for key in ("skipped", "failures", "errors")) and suite.get("disabled", "0") == "0" and
                not any(node.tag in ("failure", "error", "skipped", "disabled") for node in suite.iter()) and
                isinstance(required, list) and len(set(required)) == len(required) == BETA12_JNI_SUBSET.get(class_name, 0) and
                set(required) <= cases, "Android JUnit exact roster or real JNI subset differs")
        observed[class_name] = len(required)
        xml_hashes[name] = hashlib.sha256(raw).hexdigest()
    require(accepted.get("junitXmlSha256") == xml_hashes, "Android original JUnit bytes differ")
    return {"hostLibrarySha256": library, "hostSourceInputsSha256": source_inputs, "executed": BETA12_JNI_TOTAL,
            "realJniCases": sum(observed.values()), "junitXmlSha256": xml_hashes}


def beta12_gate_proof(lane, pointer, source, repo_id, job, log, work):
    steps = {step["name"]: step for step in job["steps"]}
    run_id, attempt = pointer["runId"], pointer["attempt"]
    if lane == "apple":
        require_step_order(steps, ("Verify complete native engine ABI", BETA12_LIVE_ABI, BETA12_APPLE_GATE,
            BETA12_APPLE_EVIDENCE, "Capture exact native SDK and player inputs before app compilation", "Build tvOS (Full)"))
        unique_step_marker(log, steps[BETA12_LIVE_ABI], "app/Tests/VortxNativeLiveABITests.swift:",
                           r"app/Tests/VortxNativeLiveABITests\.swift: OK")
        runtime = {}
        for kind in ("library", "header"):
            prefix = "Verified unchanged " + kind + " "
            runtime[kind + "Sha256"] = unique_step_marker(log, steps[BETA12_LIVE_ABI], prefix,
                re.escape(prefix) + r"[0-9a-f]{64}").rsplit(" ", 1)[1]
        name = f"VortX-account-backup-abi-evidence-{run_id}-{attempt}"
        names = {"eligibility.json", "gate.json", "workflow-step.json", "converter.json", "service.json", "restore.json"}
        contents, artifact = beta12_gate_zip(name, names, run_id, repo_id, source, steps[BETA12_APPLE_EVIDENCE], log, work)
        return {**artifact, **beta12_apple_gate(contents, pointer, source), "fullLiveAbi": runtime}
    require_step_order(steps, ("Build exact host JNI for native sync release tests", BETA12_ANDROID_GATE,
        BETA12_ANDROID_EVIDENCE, "Build release APKs and Play bundle"))
    marker = (f"Verified exact JUnit XML: {BETA12_JNI_TOTAL} executed, {BETA12_REAL_JNI} real-JNI-required cases; "
              "zero skips/failures/errors")
    unique_step_marker(log, steps[BETA12_ANDROID_GATE], "Verified exact JUnit XML:", re.escape(marker))
    names = {f"test-results/testPlayDebugUnitTest/TEST-{key}.xml" for key in BETA12_JNI_CLASSES}
    names |= {"reports/native-sync-host/host-jni.json", "reports/native-sync-host/host-jni-accepted.json"}
    contents, artifact = beta12_gate_zip("VortX-Android-native-sync-host-tests", names, run_id, repo_id, source,
                                        steps[BETA12_ANDROID_EVIDENCE], log, work)
    return {**artifact, **beta12_android_gate(contents, source)}


def beta12_aether_gate(contents, pointer, source, app_handoff):
    identity = {"schemaVersion": 1, "sourceCommit": source, "workflowCommit": source,
                "ref": "refs/tags/" + NATIVE_BETA12_BUILD_TAG, "runId": pointer["runId"], "attempt": pointer["attempt"]}
    raw_resolution = contents["aether-resolved.json"]
    resolved = json.loads(raw_resolution)
    lock_sha = sha(resolved["packageResolvedSha256"])
    require(canonical(resolved) == canonical({**identity, "packageResolvedSha256": lock_sha,
                "packages": BETA12_AETHER_PACKAGES}), "Apple Aether resolution source or pins differ")
    resolution_sha = hashlib.sha256(raw_resolution).hexdigest()
    apps = {}
    for key, (platform, variant) in BETA12_AETHER_APPS.items():
        report = json.loads(contents[f"aether-{key}.json"])
        native = app_handoff / f"native-{key}.json"
        fields = {**identity, "key": key, "architecture": "arm64", "resolutionReceiptSha256": resolution_sha,
                  "packageResolvedSha256": lock_sha, "nativeAppReceiptSha256": digest(native),
                  "aetherLinkMapSha256": sha(report["aetherLinkMapSha256"])}
        require(set(report) == set(fields) | {"provider", "binaries"} and
                canonical({name: report[name] for name in fields}) == canonical(fields),
                "Apple Aether receipt does not bind its original native app")
        provider = report["provider"]
        require(set(provider) == {"platform", "variant", "libraryIdentifier", "upstreamSha256", "processedSha256", "arm64Sha256"} and
                provider["platform"] == platform and provider["variant"] == variant and
                re.fullmatch(r"[A-Za-z0-9_-]{1,100}", provider["libraryIdentifier"]), "Apple Aether provider slice differs")
        for field in ("upstreamSha256", "processedSha256", "arm64Sha256"):
            sha(provider[field])
        payload = read_json(native)["bundlePayload"]
        binaries = report["binaries"]
        require(set(binaries) == BETA12_AETHER_BINARIES, "Apple Aether framework roster differs")
        for name, binary in binaries.items():
            prefix = "Contents/Frameworks/" if key == "macos" else "Frameworks/"
            versioned = r"(?:Versions/[A-Za-z0-9_-]+/)?" if key == "macos" else ""
            require(set(binary) == {"path", "architectures", "rawSha256", "normalizedSha256"} and
                    re.fullmatch(re.escape(prefix + name + ".framework/") + versioned + re.escape(name), binary["path"]) and
                    binary["architectures"] in (["arm64"], ["arm64", "x86_64"]) and
                    (name != "VortXAetherKit" or binary["architectures"] == ["arm64"]) and
                    sha(binary["normalizedSha256"]) == payload[binary["path"]]["sha256"],
                    "Apple Aether framework path, architecture or normalized bytes differ")
            sha(binary["rawSha256"])
        apps[key] = {"nativeAppReceiptSha256": fields["nativeAppReceiptSha256"],
                     "aetherLinkMapSha256": fields["aetherLinkMapSha256"], "provider": provider, "binaries": binaries}
    return {"resolutionReceiptSha256": resolution_sha, "packageResolvedSha256": lock_sha,
            "packages": BETA12_AETHER_PACKAGES, "apps": apps}


def beta12_aether_proof(pointer, source, repo_id, job, log, work, app_handoff):
    steps = {step["name"]: step for step in job["steps"]}
    mac_sign = "Final-sign macOS before native app acceptance"
    require_step_order(steps, ("Generate the Xcode project", BETA12_AETHER_RESOLVE, "Build tvOS (Full)",
        mac_sign, "Verify exact native app selection and linked inputs", BETA12_AETHER_VERIFY, "Package the IPAs",
        BETA12_AETHER_EVIDENCE, "Upload the immutable app handoff"))
    signing_marker = "Protected Mac Aether link output sealed across final signing"
    unique_step_marker(log, steps[mac_sign], signing_marker, re.escape(signing_marker))
    names = {"aether-resolved.json"} | {f"aether-{key}.json" for key in BETA12_AETHER_APPS}
    contents, artifact = beta12_gate_zip("VortX-Apple-Aether-release-evidence", names, pointer["runId"],
        repo_id, source, steps[BETA12_AETHER_EVIDENCE], log, work)
    return {**artifact, **beta12_aether_gate(contents, pointer, source, app_handoff)}


def authenticate_build(lane, pointer, tag, source, names, work):
    require(set(pointer) == {"runId", "attempt", "artifactId"}, "build pointer has unknown/missing fields")
    run_id, attempt, artifact_id = (positive(pointer[key]) for key in ("runId", "attempt", "artifactId"))
    workflow, job_name, artifact_name, _, _ = LANES[lane]
    required, _ = job_contract(lane, tag)
    run = api(f"actions/runs/{run_id}")
    workflow_meta = api(f"actions/workflows/{workflow}")
    repository = run.get("repository", {})
    head_repository = run.get("head_repository", {})
    repo_id = positive(repository.get("id"))
    require(repository.get("full_name") == head_repository.get("full_name") == REPO and
            head_repository.get("id") == repo_id and run.get("id") == run_id and
            run.get("run_attempt") == attempt and run.get("event") == "workflow_dispatch" and
            run.get("head_sha") == source and run.get("head_branch") == build_tag(tag) and
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
    job, upload = successful_job(jobs, lane, run_id, attempt, source, tag)
    if lane == "apple":
        require(all(j.get("conclusion") == "skipped" for j in jobs if j.get("name") in
                    ("attach-release", "publish-existing-055")), "Apple write lane unexpectedly ran")
    artifact = api(f"actions/artifacts/{artifact_id}")
    workflow_run = artifact.get("workflow_run", {})
    require(artifact.get("id") == artifact_id and artifact.get("name") == artifact_name and
            artifact.get("expired") is False and type(artifact.get("size_in_bytes")) is int and
            0 < artifact["size_in_bytes"] <= MAX_ARCHIVE and
            re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", "")) and
            workflow_run.get("id") == run_id and workflow_run.get("head_sha") == source and
            workflow_run.get("head_branch") == build_tag(tag) and workflow_run.get("repository_id") == repo_id and
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
              "sourceCommit": source, "headBranch": build_tag(tag), "event": "workflow_dispatch",
              "repositoryId": repo_id, "jobId": job["id"], "jobName": job_name,
              "requiredSuccessfulSteps": list(required), "artifactName": artifact_name,
              "artifactSha256": artifact["digest"][7:], "artifactSize": artifact["size_in_bytes"],
              "artifactCreatedAt": artifact["created_at"]}
    if tag == NATIVE_BETA12_TAG:
        public["protectedNativeGate"] = beta12_gate_proof(lane, pointer, source, repo_id, job, log, work)
        if lane == "apple":
            public["protectedAetherGate"] = beta12_aether_proof(pointer, source, repo_id, job, log, work, output)
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
    expected = {"schemaVersion": 1, "event": "workflow_dispatch", "ref": f"refs/tags/{build_tag(tag)}",
                "sourceCommit": source, "workflowCommit": source, "runId": pointer["runId"],
                "attempt": pointer["attempt"], "inputs": APPLE_INPUTS}
    require(canonical(receipt) == canonical(expected), "original typed Apple dispatch inputs differ")


def inspect_apple(directory, pointer, tag, source, version, build, tools, helper, aether=None):
    engine = expected_engine(tag)
    workflow = read_json(directory / "native-workflow-provenance.json")
    require(workflow == {"schemaVersion": 1, "sourceCommit": source, "workflowCommit": source,
                        "verifierSha256": tools["scripts/verify-native-apple-package.py"], "tag": "",
                        "runId": pointer["runId"], "attempt": pointer["attempt"]},
            "original Apple workflow provenance differs; tag must remain empty")
    dispatch = read_json(directory / "native-ci-dispatch.json")
    validate_dispatch(dispatch, pointer, tag, source)
    inputs = read_json(directory / "native-build-inputs.json")
    require(inputs.get("schema") == 1 and inputs.get("engineSourceRevision") == engine and
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
        require(accepted["engineSourceRevision"] == engine and accepted["version"] == version and
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
        if aether is not None:
            with helper.open_app(package, spec[0]) as app:
                for binary in aether["apps"][key]["binaries"].values():
                    original = app / binary["path"]
                    require(original.is_file() and original.resolve() == app.resolve() / binary["path"] and
                            digest(original) == binary["rawSha256"], "packaged Apple Aether raw framework bytes differ")
        records.append((package, item))
    return records, {"originalWorkflow": workflow, "originalDispatch": dispatch,
                     "receiptSha256": {path.name: digest(path) for path in sorted(directory.glob("native-*.json"))}}


def validate_android_evidence(lines, pointer, tag, source, version, build):
    engine = expected_engine(tag)
    expected = [
        ("release tag", build_tag(tag)), ("release tag commit", source), ("source commit", source),
        ("native engine source commit", engine), ("native engine Cargo features", "jni,server,resource-host"),
        ("workflow run", f"https://github.com/{REPO}/actions/runs/{pointer['runId']}"),
        ("workflow run attempt", str(pointer["attempt"])),
        ("Android versionCode", build), ("Android versionName", version),
    ]
    if tag in NATIVE_TAGS:
        require(not any(line.startswith("legacy Stremio source commit") for line in lines),
                "native beta7 evidence must not record a legacy engine source")
    else:
        expected.append(("legacy Stremio source commit (not packaged)", STREMIO))
    for label, value in expected:
        require([line for line in lines if line.startswith(label + ": ")] == [f"{label}: {value}"],
                f"original Android evidence identity differs: {label}")


def inspect_android(directory, pointer, tag, source, version, build, root, bundletool):
    engine = expected_engine(tag)
    _, _, names = file_matrix(tag, version)
    files = {name: directory / name for name in sorted(names)}
    checksums(directory / "SHA256SUMS-android.txt", files)
    evidence = (directory / "SIGNING_PROVENANCE.txt").read_text()
    validate_android_evidence(evidence.splitlines(), pointer, tag, source, version, build)
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
        "engineSourceCommit": engine, "nativeFeatures": "jni,server,resource-host",
    }


def stable_snapshot(tag, helper):
    latest = api("releases/latest")
    require(latest.get("tag_name") != tag and latest.get("prerelease") is False and latest.get("draft") is False,
            "beta is Latest or stable Latest cannot be proved")
    return {"latest": {"id": positive(latest["id"]), "tag": latest["tag_name"]},
            "mainCommit": sha(api("git/ref/heads/main")["object"]["sha"], 40),
            "routes": helper.capture_public_routes(tag)}


def build_manifest(args, pointers, stable, helper, work, candidate_only=False):
    version = tag_version(args.tag)
    source = sha(args.source_commit, 40)
    build, tools = source_contract(args.repo_root, source, version, args.tag)
    if not candidate_only:
        check_tag(args.tag, source)
    else:
        require(args.tag == NATIVE_BETA12_TAG, "candidate-only verification is limited to Beta 12")
    if build_tag(args.tag) != args.tag:
        check_tag(build_tag(args.tag), source)
    apple_names, apple_matrix, android_names = file_matrix(args.tag, version)
    apple_dir, apple_run = authenticate_build("apple", pointers["apple"], args.tag, source, apple_matrix, work)
    android_dir, android_run = authenticate_build("android", pointers["android"], args.tag, source,
                                                android_names | {"SHA256SUMS-android.txt", "SIGNING_PROVENANCE.txt"}, work)
    apple, apple_evidence = inspect_apple(apple_dir, pointers["apple"], args.tag, source, version, build, tools,
                                         helper, aether=apple_run.get("protectedAetherGate"))
    android, android_evidence = inspect_android(android_dir, pointers["android"], args.tag, source, version,
                                               build, args.repo_root, args.bundletool)
    if args.tag == NATIVE_BETA12_TAG:
        proof = apple_run["protectedNativeGate"]
        native_inputs = read_json(apple_dir / "native-build-inputs.json")["inputs"]
        headers = {item["sha256"] for item in native_inputs if item.get("kind") == "header"}
        mac_archives = [item["sha256"] for item in native_inputs if item.get("kind") == "engine" and item.get("slice") == "macos-arm64"]
        require(headers == {proof["sdkHeaderSha256"]} == {proof["fullLiveAbi"]["headerSha256"]} and
                mac_archives == [proof["sdkArchiveSha256"]] and
                proof["coordinatorSha256"] == tools["scripts/run-protected-account-backup-abi.py"],
                "full live ABI or packaged-SDK proof does not bind the original Apple app inputs")
    records = sorted(apple + android, key=lambda pair: pair[1]["name"])
    manifest = {"schemaVersion": 1, "distribution": "hosted-direct-beta", "repository": REPO,
                "tag": args.tag, "sourceCommit": source,
                "version": version, "build": build, "sourceFileSha256": tools,
                "builds": {"apple": apple_run, "android": android_run},
                "evidence": {"apple": apple_evidence, "android": android_evidence},
                "artifacts": [item for _, item in records], "stableMustRemain": stable}
    if not candidate_only:
        manifest["releaseId"] = positive(args.release_id)
    return manifest, records


def candidate_receipt(manifest):
    return {"schemaVersion": 1, "mode": "beta12-candidate-preflight", "evidence": {
        key: value for key, value in manifest.items() if key != "releaseId"}}


def require_uncreated_beta12_tag():
    ref = "refs/tags/" + NATIVE_BETA12_TAG
    matches = api("git/matching-refs/tags/" + NATIVE_BETA12_TAG)
    require(isinstance(matches, list) and all(row["ref"].startswith(ref) and row["ref"] != ref for row in matches),
            "Beta 12 protected release tag already exists or its absence cannot be verified")


def original_pointers(args):
    return {lane: {"runId": positive(getattr(args, f"{lane}_run")),
                   "attempt": positive(getattr(args, f"{lane}_attempt")),
                   "artifactId": positive(getattr(args, f"{lane}_artifact"))} for lane in LANES}


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
    parser.add_argument("command", choices=("preflight", "prepare", "verify-draft", "verify-published"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--release-id", type=int)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--work-dir", required=True, type=Path)
    parser.add_argument("--bundletool", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--preflight-receipt", type=Path)
    parser.add_argument("--provenance-sha256")
    parser.add_argument("--event-file", type=Path)
    for lane in LANES:
        for field in ("run", "attempt", "artifact"):
            parser.add_argument(f"--{lane}-{field}", type=int)
    args = parser.parse_args()
    tag_version(args.tag)
    expected_engine(args.tag)
    sha(args.source_commit, 40)
    if args.command != "preflight":
        positive(args.release_id)
    # Authenticate checked-out helper bytes before importing their package/route inspection.
    source_contract(args.repo_root, args.source_commit, tag_version(args.tag), args.tag)
    specification = importlib.util.spec_from_file_location("direct_apple_content", args.repo_root / "scripts/verify-apple-direct-test-release.py")
    helper = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(helper)
    if args.command == "preflight":
        require(args.tag == NATIVE_BETA12_TAG and args.release_id is None and args.event_file is None and
                args.provenance_sha256 is None and args.preflight_receipt is None and args.output is not None and
                not args.output.exists(), "Beta 12 preflight requires a new local receipt and candidate-only inputs")
        require_uncreated_beta12_tag()
        stable = stable_snapshot(args.tag, helper)
        with tempfile.TemporaryDirectory(prefix="ci-direct-beta-preflight-", dir=args.work_dir) as temporary:
            manifest, _ = build_manifest(args, original_pointers(args), stable, helper, Path(temporary), candidate_only=True)
        require(stable_snapshot(args.tag, helper) == stable, "stable Latest/main/feeds/route snapshot changed")
        require_uncreated_beta12_tag()
        check_tag(build_tag(args.tag), args.source_commit)
        with args.output.open("xb") as receipt:
            receipt.write(canonical(candidate_receipt(manifest)))
        print(f"Verified both original Beta 12 candidate builds; no release writes. Receipt SHA-256: {digest(args.output)}")
        return
    require((args.preflight_receipt is not None) == (args.tag == NATIVE_BETA12_TAG and args.command == "prepare"),
            "only Beta 12 preparation requires its original preflight receipt")
    release = api(f"releases/{args.release_id}")
    release_identity(release, args.release_id, args.tag, args.command != "verify-published", args.source_commit)
    expected_provenance = args.provenance_sha256
    if args.event_file is not None:
        require(args.command == "verify-published" and expected_provenance is None,
                "event provenance binding applies only to published verification")
        event = read_json(args.event_file)
        require(event.get("action") == "published" and event.get("repository", {}).get("full_name") == REPO,
                "wrong release event identity")
        release_identity(event["release"], args.release_id, args.tag, False, args.source_commit)
        expected_provenance = provenance_binding(event["release"]["body"])
    if args.command != "prepare":
        sha(expected_provenance)
        require(provenance_binding(release["body"]) == expected_provenance,
                "current release body differs from the prepared/event provenance binding")
    with tempfile.TemporaryDirectory(prefix="ci-direct-beta-", dir=args.work_dir) as temporary:
        work = Path(temporary)
        if args.command == "prepare":
            require(args.output is not None and not args.output.exists(), "prepare requires a new output directory")
            if args.tag == NATIVE_BETA12_TAG:
                require(release.get("assets") == [], "Beta 12 requires an empty exact new draft")
            pointers = original_pointers(args)
            stable = stable_snapshot(args.tag, helper)
            manifest, records = build_manifest(args, pointers, stable, helper, work)
            if args.tag == NATIVE_BETA12_TAG:
                require(args.preflight_receipt.stat().st_size <= 1024**2 and
                        args.preflight_receipt.read_bytes() == canonical(candidate_receipt(manifest)),
                        "Beta 12 prepared source/builds/assets/routes differ from the root-held candidate proof")
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
        release_identity(current_release, args.release_id, args.tag, args.command != "verify-published", args.source_commit)
        if args.command == "prepare":
            if args.tag == NATIVE_BETA12_TAG:
                require(current_release.get("assets") == [], "Beta 12 draft changed during preparation")
            args.output.mkdir()
            for path, item in records:
                with path.open("rb") as source, (args.output / item["name"]).open("xb") as target:
                    shutil.copyfileobj(source, target)
            (args.output / SUMS).write_bytes(sums)
            (args.output / PROVENANCE).write_bytes(canonical(manifest))
            print(f"Prepared exactly nine local assets; no remote writes: {args.output}")
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
        release_identity(final_release, args.release_id, args.tag, args.command != "verify-published", args.source_commit)
        require(provenance_binding(final_release["body"]) == expected_provenance, "release provenance binding changed")
        require(release_assets(final_release, set(expected_hashes)) == current_assets, "release changed during byte checks")
        print(f"Verified {args.command}: original CI evidence, all nine asset bytes, unchanged stable routes")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError, zipfile.BadZipFile, ET.ParseError) as error:
        print(f"CI direct beta verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
