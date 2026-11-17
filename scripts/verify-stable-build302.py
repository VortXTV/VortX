#!/usr/bin/env python3
"""Verify the seven 0.5.7/302 draft packages against frozen original CI evidence.

GitHub access is authenticated GET only. Combined receipts are written locally
after both original runs, all package payloads and every draft asset have passed.
"""
from __future__ import annotations

import argparse
import base64
from dataclasses import dataclass
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path("/Users/daksh/VortXTV/VortX")
WORK_AREA = Path(__file__).resolve().parent
REPO = "VortXTV/VortX"
REPO_ID = 1261501126
TAG = "v0.5.7"
TAG_OBJECT = "3ab4a5810b2882617a0fb6f39bf5ed5fd34a0d32"
VERSION = "0.5.7"
BUILD = "302"
SOURCE = "c56213a20fe064b0ac1ac0cc8e607c2ef449fea1"
ENGINE = "2ea2e0f27dd2e53b7b28228435ca35a70f92831f"
DRAFT = 447897160
ATTEMPT = 1
APPLE_PACKAGES = {
    "ios": f"VortX-iOS-{TAG}-ci.ipa",
    "tvos": f"VortX-tvOS-{TAG}-ci.ipa",
    "tvos-lite": f"VortX-tvOS-lite-{TAG}-ci.ipa",
    "macos": f"VortX-macOS-{TAG}-ci.dmg",
}
ANDROID_PACKAGES = (
    f"VortX-{VERSION}-full-mpv-universal.apk",
    f"VortX-{VERSION}-play-media3-universal.apk",
    f"VortX-{VERSION}-play-media3.aab",
)
ANDROID_ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64")
APPLE_CHECKSUM = "SHA256SUMS-ci.txt"
ANDROID_CHECKSUM = "SHA256SUMS-android.txt"
ANDROID_SIGNING = "SIGNING_PROVENANCE.txt"
COMBINED_CHECKSUM = "SHA256SUMS.txt"
COMBINED_PROVENANCE = "VortX-CI-Provenance.json"
APPLE_FEED_MEMBERS = {"manifest.json", "source.json", "appcast.json", APPLE_CHECKSUM}
HOSTED_WORKFLOW = ".github/workflows/release-packaging-validation.yml"
HOSTED_WORKFLOW_ID = 343149688
HOSTED_SOURCE_PATH = "scripts/verify-stable-build302.py"
HOSTED_REF = "beta-stable-057-hosted-verify-20261117"
HOSTED_UPLOAD = "Upload bounded stable verification receipts"
HOSTED_VERIFY = "Reauthenticate package bytes with the reviewed verifier"
HOSTED_ARTIFACT = "VortX-0.5.7-302-verified-ci-originals"
APPLE_SIMULATORS = ("ios-simulator", "tvos-simulator")
APPLE_RECEIPTS = {
    "native-build-inputs.json", "native-workflow-provenance.json",
    *(f"native-{key}.json" for key in (*APPLE_PACKAGES, *APPLE_SIMULATORS)),
    *(f"native-package-{key}.json" for key in APPLE_PACKAGES),
}
APPLE_DRAFT_STEP = "Attach only exact draft assets and create the authenticated staged receipt"
APPLE_STAGE_STEP = "Atomically activate the staged feed, prove routes, then publish last"
TOOLS = (
    ".github/workflows/release-tvos.yml", ".github/workflows/android-release.yml",
    "app/project.yml", "android/app/build.gradle.kts", "scripts/verify-ci-direct-beta.py",
    "scripts/verify-native-apple-package.py", "scripts/verify-apple-direct-test-release.py",
    "scripts/verify-protected-apple-aether.py", "scripts/verify-android-release-signing.sh",
    "scripts/verify-android-release-version.sh",
)


@dataclass(frozen=True)
class Lane:
    run_id: int
    workflow_id: int
    workflow: str
    job: str
    archive: str
    upload: str
    members: frozenset[str]


APPLE = Lane(43995790455, 293211344, TOOLS[0], "build-tvos", "VortX-tvOS-ci",
             "Upload the immutable app handoff",
             frozenset(set(APPLE_PACKAGES.values()) | APPLE_RECEIPTS | {APPLE_CHECKSUM}))
ANDROID = Lane(43995790267, 342394030, TOOLS[1], "release-android", "VortX-Android-release",
               "Upload the immutable Android handoff",
               frozenset(ANDROID_PACKAGES) | {ANDROID_CHECKSUM, ANDROID_SIGNING})


def require(condition, message):
    if not condition:
        raise ValueError(message)


def source_bytes(path):
    return subprocess.check_output(
        ["git", "-C", str(ROOT), "show", f"{SOURCE}:{path}"], timeout=10)


def source_contract():
    checkout = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"],
                                       timeout=10, text=True).strip()
    require(checkout == SOURCE, "checkout is not the frozen 0.5.7 source")
    hashes = {}
    for path in TOOLS:
        file = ROOT / path
        raw = source_bytes(path)
        require(not file.is_symlink() and file.read_bytes() == raw,
                f"live verifier input differs from frozen source: {path}")
        hashes[path] = hashlib.sha256(raw).hexdigest()
    validate_source_versions(source_bytes(TOOLS[2]).decode(), source_bytes(TOOLS[3]).decode())
    require(ENGINE.encode() in source_bytes(TOOLS[0]) and ENGINE.encode() in source_bytes(TOOLS[1]),
            "protected workflow engine pins differ")
    return hashes


def validate_source_versions(project, gradle):
    versions = re.findall(r'^\s*MARKETING_VERSION:\s*"([0-9.]+)"\s*$', project, re.M)
    builds = re.findall(r'^\s*CURRENT_PROJECT_VERSION:\s*"([0-9]+)"\s*$', project, re.M)
    require(versions == [VERSION] * 6 and builds == [BUILD] * 6,
            "Apple target version or build matrix differs")
    require(re.findall(r'^\s*versionName = "([^"]+)"\s*$', gradle, re.M) == [VERSION] and
            re.findall(r'^\s*versionCode = ([0-9]+)\s*$', gradle, re.M) == [BUILD],
            "Android source version or build differs")


def load_tool(path, name):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_tag(ci):
    ref = ci.api(f"git/ref/tags/{TAG}")
    require(ref["ref"] == f"refs/tags/{TAG}" and ref["object"]["type"] == "tag" and
            ref["object"]["sha"] == TAG_OBJECT, "the frozen annotated release tag differs")
    obj = ci.api(f"git/tags/{TAG_OBJECT}")
    require(obj["sha"] == TAG_OBJECT and obj["tag"] == TAG and
            obj["object"]["type"] == "commit" and obj["object"]["sha"] == SOURCE,
            "the frozen release tag no longer peels directly to the source commit")


def check_release(release):
    require(release.get("id") == DRAFT and release.get("tag_name") == TAG and
            release.get("target_commitish") == SOURCE and release.get("draft") is True and
            release.get("prerelease") is False and release.get("published_at") is None,
            "the exact stable draft identity or state differs")
    name = release.get("name")
    body = release.get("body")
    require(isinstance(name, str) and "Build 302" in name and isinstance(body, str) and
            "vortx-channel: latest-beta" not in body and "vortx-platforms: apple" not in body,
            "the stable draft title or notes channel differs")


def required_steps(ci, lane):
    if lane == APPLE:
        base = [name for name in ci.NATIVE_BETA7_APPLE_STEPS
                if name != "Record artifact-only dispatch inputs for hosted beta verification"]
        return (*base, "Select the authenticated native source revision", "Verify protected stable 0.5.7 dispatch",
                "Verify protected Apple legacy archive recovery", ci.BETA15_APPLE_UPDATE,
                ci.BETA15_APPLE_TRAILER, ci.BETA15_APPLE_SHORT_HISTORY, ci.BETA12_APPLE_GATE,
                "Record account backup ABI gate outcome", ci.BETA12_APPLE_EVIDENCE,
                ci.BETA12_AETHER_RESOLVE, ci.BETA12_AETHER_VERIFY, ci.BETA12_AETHER_EVIDENCE,
                "Build the content-addressed release feed artifact", "Upload the immutable feed handoff")
    return (*ci.NATIVE_BETA7_ANDROID_STEPS, ci.BETA13_ANDROID_BACKUP_CAS, ci.BETA14_ANDROID_REGRESSIONS)


def check_run(run, lane, *, original_only=False):
    success = run.get("status") == "completed" and run.get("conclusion") == "success"
    awaiting_coordinator = (original_only and lane == APPLE and
                           run.get("status") in ("in_progress", "waiting", "pending") and
                           run.get("conclusion") is None)
    require(run.get("id") == lane.run_id and run.get("run_attempt") == ATTEMPT and
            run.get("workflow_id") == lane.workflow_id and run.get("head_sha") == SOURCE and
            run.get("head_branch") == TAG and run.get("path", "").split("@")[0] == lane.workflow and
            run.get("event") == "workflow_dispatch" and (success or awaiting_coordinator) and
            all(run.get(field, {}).get("id") == REPO_ID and run[field].get("full_name") == REPO
                for field in ("repository", "head_repository")),
            f"{lane.job}: original successful run/source/ref/workflow identity differs")


def check_job(ci, jobs, lane, name, *, auxiliary=False):
    matches = [job for job in jobs if job.get("name") == name]
    require(len(matches) == 1, f"{name}: expected exactly one original job")
    job = matches[0]
    require(job.get("run_id") == lane.run_id and job.get("run_attempt") == ATTEMPT and
            job.get("head_sha") == SOURCE and job.get("status") == "completed" and
            job.get("conclusion") == "success", f"{name}: original job identity or result differs")
    steps = {step["name"]: step for step in job["steps"]}
    require(len(steps) == len(job["steps"]), f"{name}: duplicate workflow step names")
    if auxiliary:
        required = ("Validate immutable handoff provenance before coordinator resume",
                    "Download and authenticate immutable handoff archives",
                    "Bind the draft release, tag commit, and monotonic source before any write", APPLE_DRAFT_STEP)
        skipped = (APPLE_STAGE_STEP,)
    else:
        required = required_steps(ci, lane)
        skipped = ("Validate immutable Beta 1 source recovery", "Checkout the immutable recovered app source",
                   "Verify immutable recovered source checkout", "Reject removed legacy comparison builds",
                   "Record artifact-only dispatch inputs for hosted beta verification",
                   "Constrain Full tvOS test mode to artifact-only builds", "Package Full tvOS test IPA"
                   ) if lane == APPLE else ("Refuse Android-only publication",)
    for step in required:
        require(steps.get(step, {}).get("status") == "completed" and
                steps[step].get("conclusion") == "success", f"{name}: required step did not succeed: {step}")
    for step in skipped:
        require(steps.get(step, {}).get("conclusion") == "skipped", f"{name}: forbidden step ran: {step}")
    return job, steps


def artifact_candidates(ci, lane, name):
    page = ci.api(f"actions/runs/{lane.run_id}/artifacts?name={name}&per_page=100")
    require(page.get("total_count") == 1 and len(page.get("artifacts", [])) == 1,
            f"{name}: ambiguous or missing original artifact")
    return ci.positive(page["artifacts"][0]["id"])


def check_artifact(ci, artifact, lane, name, artifact_id, size_bound):
    origin = artifact.get("workflow_run", {})
    require(artifact.get("id") == artifact_id and artifact.get("name") == name and
            artifact.get("expired") is False and
            0 < ci.positive(artifact["size_in_bytes"]) <= size_bound and
            re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", "")) and
            origin.get("id") == lane.run_id and origin.get("head_sha") == SOURCE and
            origin.get("head_branch") == TAG and origin.get("repository_id") == REPO_ID and
            origin.get("head_repository_id") == REPO_ID,
            f"{name}: artifact metadata differs from the original workflow")


def original_logs(ci, job, output):
    ci.api_download(f"actions/jobs/{ci.positive(job['id'])}/logs", output, 512 * 1024**2)


def extract_original_archive(ci, artifact, members, work, directory, cache):
    # The caller refreshes and verifies the GitHub artifact and upload-step proof.
    # extract_exact reopens and rehashes the full ZIP even when it came from the cache.
    cache.mkdir(mode=0o700, exist_ok=True)
    require(not cache.is_symlink() and cache.is_dir(), "unsafe original ZIP cache directory")
    artifact_id = artifact["id"]
    digest = ci.sha(artifact["digest"][7:])
    retained = cache / f"{artifact_id}-{digest}.zip"
    if retained.exists() or retained.is_symlink():
        ci.extract_exact(retained, artifact, members, directory)
        return
    fresh = work / f"original-{artifact_id}.zip"
    ci.api_download(f"actions/artifacts/{artifact_id}/zip", fresh, artifact["size_in_bytes"])
    ci.extract_exact(fresh, artifact, members, directory)
    try:
        os.link(fresh, retained, follow_symlinks=False)
    except FileExistsError:
        # Another successful reader can populate the same identity concurrently.
        # Leave its exact bytes to be reauthenticated on every subsequent read.
        pass


def download_lane(ci, lane, work, label, *, original_only=False, reviewed_archive=None):
    check_run(ci.api(f"actions/runs/{lane.run_id}"), lane, original_only=original_only)
    workflow = ci.api(f"actions/workflows/{lane.workflow_id}")
    require(workflow.get("id") == lane.workflow_id and workflow.get("path") == lane.workflow,
            f"{lane.job}: registered workflow differs")
    page = ci.api(f"actions/runs/{lane.run_id}/attempts/{ATTEMPT}/jobs?per_page=100")
    require(page.get("total_count") == len(page.get("jobs", [])), "original job list was truncated")
    jobs = page["jobs"]
    job, steps = check_job(ci, jobs, lane, lane.job)
    log = work / f"{label}-build.log"
    original_logs(ci, job, log)
    if lane == APPLE and not original_only:
        attach, attach_steps = check_job(ci, jobs, lane, "attach-release", auxiliary=True)
        attach_log = work / "apple-attach.log"
        original_logs(ci, attach, attach_log)
        marker = f"draft release {DRAFT} has all verified Apple assets; feed staging follows combined verification"
        ci.unique_step_marker(attach_log, attach_steps[APPLE_DRAFT_STEP], marker, re.escape(marker))
    identifier = artifact_candidates(ci, lane, lane.archive)
    artifact = ci.api(f"actions/artifacts/{identifier}")
    check_artifact(ci, artifact, lane, lane.archive, identifier, ci.MAX_ARCHIVE)
    if reviewed_archive is not None:
        expected_id, expected_size, expected_digest = reviewed_archive
        require((str(identifier), str(artifact["size_in_bytes"]), artifact["digest"][7:]) ==
                (expected_id, expected_size, expected_digest),
                f"{lane.archive}: artifact differs from the reviewed dispatch pointer")
    with log.open(errors="strict") as lines:
        ci.upload_proof(artifact, steps[lane.upload], lines)
    directory = work / label
    extract_original_archive(ci, artifact, lane.members, work, directory, WORK_AREA / "cache")
    evidence = {
        "runId": lane.run_id, "attempt": ATTEMPT, "sourceCommit": SOURCE, "headBranch": TAG,
        "jobId": job["id"], "artifactId": identifier, "artifactName": lane.archive,
        "artifactSize": artifact["size_in_bytes"], "artifactSha256": artifact["digest"][7:],
    }
    return directory, evidence, steps, log


def apple_proofs(ci, retained, work):
    directory, pointer, steps, log = retained
    ci.require_step_order(steps, ("Show toolchain", ci.BETA15_APPLE_UPDATE, ci.BETA15_APPLE_TRAILER,
                                 ci.BETA15_APPLE_SHORT_HISTORY, "Verify complete native engine ABI"))
    ci.require_step_order(steps, ("Verify complete native engine ABI", ci.BETA12_LIVE_ABI, ci.BETA12_APPLE_GATE,
                                 ci.BETA12_APPLE_EVIDENCE, ci.BETA12_AETHER_RESOLVE,
                                 "Capture exact native SDK and player inputs before app compilation", "Build tvOS (Full)"))
    ci.require_step_order(steps, ("Build macOS", "Final-sign macOS before native app acceptance",
                                 "Verify exact native app selection and linked inputs", ci.BETA12_AETHER_VERIFY,
                                 "Package the IPAs", ci.BETA12_AETHER_EVIDENCE, APPLE.upload))
    for step, prefix, suffix in (
        (ci.BETA15_APPLE_UPDATE, ci.BETA15_APPLE_UPDATE_MARKER, ""),
        (ci.BETA15_APPLE_TRAILER, ci.BETA15_APPLE_TRAILER_MARKER, ""),
        (ci.BETA15_APPLE_SHORT_HISTORY, ci.BETA15_APPLE_SHORT_HISTORY_MARKER, r"[1-9][0-9]{0,3} checks passed"),
        (ci.BETA15_APPLE_SHORT_HISTORY, ci.BETA15_APPLE_WATCHED_CALLSITE_MARKER, ""),
        (ci.BETA12_LIVE_ABI, "app/Tests/VortxNativeLiveABITests.swift: OK", ""),
        (ci.BETA12_LIVE_ABI, ci.BETA15_APPLE_HOST_PREFS_MARKER, ""),
        ("Final-sign macOS before native app acceptance", "Protected Mac Aether link output sealed across final signing", ""),
    ):
        ci.unique_step_marker(log, steps[step], prefix, re.escape(prefix) + suffix)
    live_abi = {}
    for kind in ("library", "header"):
        prefix = f"Verified unchanged {kind} "
        marker = ci.unique_step_marker(log, steps[ci.BETA12_LIVE_ABI], prefix, re.escape(prefix) + r"[0-9a-f]{64}")
        live_abi[f"{kind}Sha256"] = marker.rsplit(" ", 1)[1]
    # The two account/JNI validators below take a tag only to select the reviewed
    # engine pin. The stable workflow uses exactly the Beta 15 engine and fixtures.
    require(ci.expected_engine(ci.NATIVE_BETA15_TAG) == ENGINE, "shared account gate pin differs")
    name = f"VortX-account-backup-abi-evidence-{APPLE.run_id}-{ATTEMPT}"
    members = {"eligibility.json", "gate.json", "workflow-step.json", "converter.json", "service.json", "restore.json"}
    contents, account_zip = ci.protected_gate_zip(name, members, APPLE.run_id, REPO_ID, TAG, SOURCE,
                                                  steps[ci.BETA12_APPLE_EVIDENCE], log, work)
    account = ci.protected_apple_gate(contents, pointer, ci.NATIVE_BETA15_TAG, SOURCE)
    aether_members = {"aether-resolved.json"} | {f"aether-{key}.json" for key in ci.BETA12_AETHER_APPS}
    contents, aether_zip = ci.protected_gate_zip("VortX-Apple-Aether-release-evidence", aether_members,
                                                 APPLE.run_id, REPO_ID, TAG, SOURCE,
                                                 steps[ci.BETA12_AETHER_EVIDENCE], log, work)
    aether = ci.protected_aether_gate(contents, pointer, TAG, SOURCE, directory)
    feed, feed_zip = ci.protected_gate_zip("VortX-release-feed", APPLE_FEED_MEMBERS,
                                           APPLE.run_id, REPO_ID, TAG, SOURCE,
                                           steps["Upload the immutable feed handoff"], log, work)
    validate_feed_handoff(ci, feed, directory)
    receipt_hashes = {path.name: ci.digest(path) for path in sorted(directory.glob("native-*.json"))}
    return aether, {"account": {**account_zip, **account, "fullLiveAbi": live_abi}, "aether": aether_zip,
                    "feed": feed_zip, "aetherResolutionSha256": aether["resolutionReceiptSha256"],
                    "nativeReceiptSha256": receipt_hashes}, feed


def validate_feed_handoff(ci, feed, directory):
    manifest = json.loads(feed["manifest.json"])
    require(manifest.get("schemaVersion") == 2 and manifest.get("tag") == TAG and
            manifest.get("sourceCommit") == SOURCE and manifest.get("releaseId") == str(DRAFT) and
            manifest.get("version") == VERSION and
            str(manifest.get("build")) == BUILD and manifest.get("prerelease") is False and
            "android" in manifest and manifest["android"] is None, "Apple feed handoff identity differs")
    for field, name in (("sourceSha256", "source.json"), ("appcastSha256", "appcast.json"),
                        ("checksumSha256", APPLE_CHECKSUM)):
        require(manifest.get(field) == hashlib.sha256(feed[name]).hexdigest(),
                f"Apple feed handoff {name} does not match its manifest")
    require(feed[APPLE_CHECKSUM] == (directory / APPLE_CHECKSUM).read_bytes(),
            "Apple feed checksum bytes differ from app handoff")
    expect = {"ios": "ios", "tvos": "tvos", "tvosLite": "tvos-lite", "mac": "macos"}
    require(set(manifest["assets"]) == set(expect), "Apple feed package roster differs")
    for key, platform in expect.items():
        name = APPLE_PACKAGES[platform]
        path = directory / name
        row = manifest["assets"][key]
        require(row == {"name": name, "checksumName": name, "size": path.stat().st_size,
                        "sha256": ci.digest(path), "url": f"https://github.com/{REPO}/releases/download/{TAG}/{name}",
                        "state": "trusted-local", "assetId": None},
                f"Apple feed manifest does not describe the original {name}")


def inspect_apple(ci, helper, hashes, retained, aether):
    directory = retained[0]
    provenance = ci.read_json(directory / "native-workflow-provenance.json")
    require(provenance == {
        "schemaVersion": 1, "sourceCommit": SOURCE, "workflowCommit": SOURCE,
        "verifierSha256": hashes["scripts/verify-native-apple-package.py"], "tag": TAG,
        "runId": APPLE.run_id, "attempt": ATTEMPT,
    }, "original stable Apple verifier receipt differs")
    inputs = ci.read_json(directory / "native-build-inputs.json")
    require(inputs.get("schema") == 1 and inputs.get("engineSourceRevision") == ENGINE and
            inputs.get("features") == helper.EXPECTED_NATIVE_FEATURES, "captured native Apple SDK identity differs")
    index = {}
    for row in inputs["inputs"]:
        identity = (row.get("kind"), row.get("slice"), row.get("target"))
        require(identity not in index, "duplicate native Apple SDK input")
        index[identity] = ci.sha(row["sha256"])
    native = helper.NATIVE
    expected = {("engine", value, None) for value in native.ENGINE_SLICES.values()}
    expected |= {("header", value, None) for value in native.ENGINE_SLICES.values()}
    expected |= {("mpv", value, target) for value in native.MPV_SLICES.values() for target in native.MPV_TARGETS}
    expected |= {("mpv-manifest", None, None), ("mac-server", None, None)}
    require(set(index) == expected and len({value for row, value in index.items() if row[0] == "header"}) == 1,
            "Apple captured engine/player SDK matrix differs")
    files = {name: directory / name for name in APPLE_PACKAGES.values()}
    ci.checksums(directory / APPLE_CHECKSUM, files, "out/")
    for target in (*APPLE_PACKAGES, *APPLE_SIMULATORS):
        platform = {"tvos-lite": "tvos", "ios-simulator": "ios-sim", "tvos-simulator": "tvos-sim"}.get(target, target)
        receipt = ci.read_json(directory / f"native-{target}.json")
        accepted = helper._portable_receipt(receipt, platform)
        require(accepted["engineSourceRevision"] == ENGINE and accepted["version"] == VERSION and
                accepted["build"] == BUILD, f"{target}: native app version, build or SDK pin differs")
        for archive, value in accepted["loadedArchives"].items():
            if archive == "libvortx_ffi.a":
                key = ("engine", native.ENGINE_SLICES[platform], None)
            else:
                mpv = [component for component, binary in native.MPV_TARGETS.items() if binary == archive]
                require(len(mpv) == 1, f"{target}: unrecognized loaded native archive")
                key = ("mpv", native.MPV_SLICES[platform], mpv[0])
            require(index.get(key) == value, f"{target}: archive hash does not match original captured SDK")
        if target not in APPLE_PACKAGES:
            continue
        artifact = files[APPLE_PACKAGES[target]]
        spec = helper.ARTIFACTS[target]
        # Archive receipts precede the coordinator's filename-only stable rename.
        original_name = artifact.name.replace(f"-{TAG}-ci.", "-ci.")
        expected_package = {name: receipt[name] for name in
                            ("engineSourceRevision", "platform", "bundleIdentifier", "version", "build")}
        expected_package.update(schema=1, artifact=original_name, artifactSha256=ci.digest(artifact))
        require(ci.read_json(directory / f"native-package-{target}.json") == expected_package and
                receipt["bundleIdentifier"] == spec[3], f"{target}: original archive receipt differs")
        helper.inspect_artifact(artifact, {
            "size": artifact.stat().st_size, "sha256": expected_package["artifactSha256"],
            "acceptedAppReceipt": accepted, "bundleIdentifier": spec[3], "version": VERSION, "build": BUILD,
        }, target)
        with helper.open_app(artifact, platform) as app:
            for binary in aether["apps"][target]["binaries"].values():
                file = app / binary["path"]
                require(file.is_file() and file.resolve(strict=True) == app.resolve() / binary["path"] and
                        ci.digest(file) == binary["rawSha256"], f"{target}: packaged Aether framework differs")
    return {**files, APPLE_CHECKSUM: directory / APPLE_CHECKSUM}


def android_proofs(ci, retained, work):
    _, _, steps, log = retained
    require(ci.expected_engine(ci.NATIVE_BETA15_TAG) == ENGINE, "shared Android account gate pin differs")
    ci.require_step_order(steps, ("Build exact host JNI for native sync release tests",
                                 ci.BETA12_ANDROID_GATE, ci.BETA12_ANDROID_EVIDENCE, ci.BETA13_ANDROID_BACKUP_CAS,
                                 ci.BETA14_ANDROID_REGRESSIONS, "Build release APKs and Play bundle", ANDROID.upload))
    jni = (f"Verified exact JUnit XML: {ci.BETA12_JNI_TOTAL} executed, {ci.BETA12_REAL_JNI} real-JNI-required cases; "
           "zero skips/failures/errors")
    ci.unique_step_marker(log, steps[ci.BETA12_ANDROID_GATE], "Verified exact JUnit XML:", re.escape(jni))
    members = {f"test-results/testPlayDebugUnitTest/TEST-{key}.xml" for key in ci.BETA12_JNI_CLASSES}
    members |= {"reports/native-sync-host/host-jni.json", "reports/native-sync-host/host-jni-accepted.json"}
    contents, artifact = ci.protected_gate_zip("VortX-Android-native-sync-host-tests", members, ANDROID.run_id,
                                               REPO_ID, TAG, SOURCE, steps[ci.BETA12_ANDROID_EVIDENCE], log, work)
    account = ci.protected_android_gate(contents, ci.NATIVE_BETA15_TAG, SOURCE)
    prefix = "Verified protected Android backup CAS: 16 cases; XML SHA256 "
    cas = ci.unique_step_marker(log, steps[ci.BETA13_ANDROID_BACKUP_CAS], prefix, re.escape(prefix) + r"[0-9a-f]{64}")
    # Stable runs add the issue #297 TV contract to the Beta 15 suite roster.
    extra = "com.vortx.android.player.PlayerTvExitContractTest"
    check_regression = read_android_regression(ci, log, steps[ci.BETA14_ANDROID_REGRESSIONS],
                                               (*ci.BETA15_ANDROID_SUITES, extra))
    return {"account": {**artifact, **account}, "backupCasXmlSha256": cas.rsplit(" ", 1)[1],
            "regression": check_regression}


def read_android_regression(ci, log, step, expected_classes):
    suites = {}
    for suite in expected_classes:
        prefix = f"Verified protected Android regression: {suite} "
        pattern = re.escape(prefix) + r"\(([1-9][0-9]{0,3}) cases\); XML SHA256 ([0-9a-f]{64})"
        marker = ci.unique_step_marker(log, step, prefix, pattern)
        cases, digest = re.fullmatch(pattern, marker).groups()
        path = suite.replace(".", "/") + ".kt"
        source = source_bytes(f"android/app/src/test/kotlin/{path}").decode()
        declared = re.findall(r"^[ \t]*@Test\s+fun\s+(`[^`\r\n]+`|[A-Za-z_][A-Za-z0-9_]*)\s*\(", source, re.M)
        require(int(cases) == len(set(declared)) == len(re.findall(r"^[ \t]*@Test\b", source, re.M)),
                f"Android stable regression case count differs from frozen source: {suite}")
        suites[suite] = {"cases": int(cases), "xmlSha256": digest}
    total = sum(record["cases"] for record in suites.values())
    prefix = "Verified protected Android account setup and release regressions: "
    ci.unique_step_marker(log, step, prefix, re.escape(f"{prefix}{total} cases"))
    return {"cases": total, "suites": suites}


def check_android_signing_receipt(ci, receipt):
    lines = receipt.read_text().splitlines()
    expected = {
        "release tag": TAG, "release tag commit": SOURCE, "source commit": SOURCE,
        "native engine source commit": ENGINE, "native engine Cargo features": "jni,server,resource-host",
        "workflow run": f"https://github.com/{REPO}/actions/runs/{ANDROID.run_id}",
        "workflow run attempt": str(ATTEMPT), "Android versionCode": BUILD, "Android versionName": VERSION,
    }
    for key, value in expected.items():
        require([line for line in lines if line.startswith(key + ": ")] == [f"{key}: {value}"],
                f"Android signing receipt identity differs: {key}")
    require(not any(line.startswith("legacy Stremio source commit") for line in lines),
            "unexpected legacy Android engine receipt")
    signer = "FC:22:B8:7E:CD:9E:4F:A2:69:30:A1:C3:E2:27:D8:F7:D9:18:C6:46:B2:16:03:2B:5D:A8:20:EF:1A:C2:18:CA"
    sections = re.split(r"(?m)^verified (?:APK|AAB): ", receipt.read_text())[1:]
    for name in ANDROID_PACKAGES:
        kind = "APK" if name.endswith(".apk") else "AAB"
        found = [section for section in sections if section.startswith(name + "\n")]
        require(lines.count(f"verified {kind}: {name}") == 1 and len(found) == 1 and
                [line.strip() for line in found[0].splitlines()].count("signer SHA-256: " + signer) == 1,
                f"{name}: production signer receipt differs")


def inspect_android(ci, retained, args):
    directory = retained[0]
    packages = {name: directory / name for name in ANDROID_PACKAGES}
    ci.checksums(directory / ANDROID_CHECKSUM, packages)
    signing = directory / ANDROID_SIGNING
    check_android_signing_receipt(ci, signing)
    require(ci.digest(args.bundletool) == ci.BUNDLETOOL_SHA, "bundletool differs from the exact release dependency")
    java = args.java_home / "bin"
    android = args.android_sdk / "build-tools/36.0.0"
    env = dict(os.environ, JAVA_HOME=str(args.java_home), BUNDLETOOL_JAR=str(args.bundletool),
               PATH=f"{java}:{android}:{os.environ['PATH']}", APKSIGNER_BIN=str(android / "apksigner"),
               AAPT2_BIN=str(android / "aapt2"), JARSIGNER_BIN=str(java / "jarsigner"),
               JAVA_BIN=str(java / "java"), KEYTOOL_BIN=str(java / "keytool"), TMPDIR=str(directory.parent))
    paths = [str(path) for path in packages.values()]
    for command, inputs in (("verify-android-release-signing.sh", ["verify"]),
                            ("verify-android-release-version.sh", [BUILD, VERSION])):
        subprocess.run(["bash", str(ROOT / "scripts" / command), *inputs, *paths],
                       check=True, env=env, timeout=180)
    for name, path in packages.items():
        with zipfile.ZipFile(path) as archive:
            require(archive.testzip() is None, f"{name}: corrupt Android package")
            entries = archive.namelist()
            require(len(entries) == len(set(entries)), f"{name}: duplicate Android package entries")
            prefix = "base/" if name.endswith(".aab") else ""
            native = {path for path in entries if path.endswith("/libvortx_ffi.so")}
            require(native == {f"{prefix}lib/{abi}/libvortx_ffi.so" for abi in ANDROID_ABIS},
                    f"{name}: native Android ABI matrix differs")
            require(not any("libstremiox" in path or "libnode" in path for path in entries),
                    f"{name}: legacy Android engine payload")
            if "-play-" in name:
                require(not any(re.search(r"/lib(mpv|vortx_mpv_seam|player|avcodec|avformat|avutil)\.so$", path) for path in entries),
                        f"{name}: GPL player payload found in Play package")
            else:
                mpv = {path for path in entries if re.search(r"/lib(mpv|vortx_mpv_seam)\.so$", path)}
                require(mpv == {f"lib/{abi}/{library}" for abi in ANDROID_ABIS
                                for library in ("libmpv.so", "libvortx_mpv_seam.so")} and
                        not any(path.endswith("/libplayer.so") for path in entries),
                        f"{name}: Full APK native mpv or JNI seam payload differs")
    return {**packages, ANDROID_CHECKSUM: directory / ANDROID_CHECKSUM, ANDROID_SIGNING: signing}


def verify_draft_assets(ci, release, originals, work):
    records = {name: {"size": path.stat().st_size, "sha256": ci.digest(path)}
               for name, path in originals.items()}
    return verify_draft_records(ci, release, records, work)


def verify_draft_records(ci, release, originals, work, *, evidence_only_downloads=False):
    check_release(release)
    metadata = ci.release_assets(release, set(originals))
    require(len({asset["id"] for asset in metadata.values()}) == len(metadata), "draft asset IDs repeat")
    for name, original in sorted(originals.items()):
        row = metadata[name]
        size, sha = original["size"], original["sha256"]
        ci.validate_asset_url("verify-draft", release, TAG, name, row["browser_download_url"])
        require(row["size"] == size and row["digest"] == f"sha256:{sha}",
                f"{name}: draft size/digest differs from original CI bytes")
        if evidence_only_downloads and name not in {APPLE_CHECKSUM, ANDROID_CHECKSUM, ANDROID_SIGNING}:
            continue
        download = work / f"draft-{row['id']}.tmp"
        ci.api_download(f"releases/assets/{row['id']}", download, size, "application/octet-stream")
        try:
            require(download.stat().st_size == size and ci.digest(download) == sha,
                    f"{name}: authenticated draft download differs from original CI bytes")
        finally:
            download.unlink()
    current = ci.api(f"releases/{DRAFT}")
    check_release(current)
    require(ci.release_assets(current, set(originals)) == metadata and
            (current.get("name"), current.get("body")) == (release.get("name"), release.get("body")),
            "draft metadata, notes or asset set changed during verification")
    return metadata


def emitted_files(ci, build_records, metadata, output):
    names = sorted(set(APPLE_PACKAGES.values()) | set(ANDROID_PACKAGES))
    rows = [{"name": name, "size": metadata[name]["size"], "sha256": metadata[name]["digest"][7:]} for name in names]
    sums = "".join(f"{row['sha256']}  {row['name']}\n" for row in rows)
    provenance = {"schemaVersion": 1, "repository": REPO, "releaseId": DRAFT,
                  "sourceCommit": SOURCE, "tag": TAG, "build": BUILD, "version": VERSION,
                  "builds": build_records, "artifacts": rows}
    with (output / COMBINED_CHECKSUM).open("x") as handle:
        handle.write(sums)
    with (output / COMBINED_PROVENANCE).open("xb") as handle:
        handle.write(ci.canonical(provenance))


def retain_release_evidence(output, files, *, apple_feed=None):
    for name in (APPLE_CHECKSUM, ANDROID_CHECKSUM, ANDROID_SIGNING):
        if name in files:
            (output / name).write_bytes(files[name].read_bytes())
    if apple_feed is not None:
        directory = output / "apple-feed"
        directory.mkdir()
        for name, data in apple_feed.items():
            (directory / name).write_bytes(data)


def original_receipt(ci, output, label, lane, gate, files, hashes):
    (output / f"{label}-original.json").write_bytes(ci.canonical({
        "sourceCommit": SOURCE, "tagObject": TAG_OBJECT, "releaseId": DRAFT,
        label: lane[1], f"{label}Gate": gate, "frozenVerifierHashes": hashes,
        "files": {name: {"size": file.stat().st_size, "sha256": ci.digest(file)}
                  for name, file in files.items()},
    }))


def receipt_members(mode):
    apple = {APPLE_CHECKSUM, "apple-original.json", *(f"apple-feed/{name}" for name in APPLE_FEED_MEMBERS)}
    android = {ANDROID_CHECKSUM, ANDROID_SIGNING, "android-original.json"}
    return {
        "apple-original": apple,
        "android-original": android,
        "ci-originals": apple | android,
        "draft": (apple | android) - {"apple-original.json", "android-original.json"} |
                 {COMBINED_CHECKSUM, COMBINED_PROVENANCE, "verification.json"},
    }[mode]


def check_output(path, mode):
    members = receipt_members(mode)
    require(path.is_dir() and not path.is_symlink(), "missing verified evidence directory")
    files = {}
    for child in path.rglob("*"):
        relative = child.relative_to(path).as_posix()
        require(not child.is_symlink() and (relative in members or
                (relative == "apple-feed" and child.is_dir())), "unexpected verified evidence member")
        if relative in members:
            require(child.is_file() and 0 < child.stat().st_size <= 4 * 1024**2,
                    "unsafe verified evidence file")
            files[relative] = child.read_bytes()
    require(set(files) == members and sum(map(len, files.values())) <= 16 * 1024**2,
            "incomplete or oversized verified evidence")
    return files


def authenticate_hosted_receipts(ci, work, pointer, rendered_workflow):
    run_id, revision, artifact_id = pointer
    run_id, artifact_id = ci.positive(int(run_id)), ci.positive(int(artifact_id))
    ci.sha(revision, 40)
    run = ci.api(f"actions/runs/{run_id}")
    require((run["id"], run["workflow_id"], run["head_branch"], run["head_sha"], run["run_attempt"],
             run["event"], run["status"], run["conclusion"], run["path"].split("@")[0]) ==
            (run_id, HOSTED_WORKFLOW_ID, HOSTED_REF, revision, ATTEMPT, "workflow_dispatch",
             "completed", "success", HOSTED_WORKFLOW) and
            all(run[field]["id"] == REPO_ID and run[field]["full_name"] == REPO
                for field in ("repository", "head_repository")) and
            all(run[field]["login"] == "mamaclapper" for field in ("actor", "triggering_actor")),
            "hosted verification was not the successful reviewed operations run")
    commit = ci.api(f"commits/{revision}")
    require([parent["sha"] for parent in commit["parents"]] == [SOURCE] and
            len(commit["files"]) == 2 and {file["filename"] for file in commit["files"]} ==
            {HOSTED_WORKFLOW, HOSTED_SOURCE_PATH}, "hosted verification commit differs from the scoped overlay")
    for path, approved in ((HOSTED_WORKFLOW, rendered_workflow), (HOSTED_SOURCE_PATH, Path(__file__))):
        blob = ci.api(f"contents/{path}?ref={revision}")
        require(blob["encoding"] == "base64" and
                base64.b64decode("".join(blob["content"].splitlines()), validate=True) == approved.read_bytes(),
                f"hosted verification bytes differ from reviewed file: {path}")
    page = ci.api(f"actions/runs/{run_id}/attempts/{ATTEMPT}/jobs?per_page=100")
    require(len(page["jobs"]) == page["total_count"] == 1, "expected the one hosted verification job")
    job = page["jobs"][0]
    require((job["name"], job["run_id"], job["run_attempt"], job["head_sha"], job["status"], job["conclusion"]) ==
            ("verify", run_id, ATTEMPT, revision, "completed", "success"), "hosted verification job differs")
    steps = {step["name"]: step for step in job["steps"]}
    require(len(steps) == len(job["steps"]) and
            all(steps[name]["status"] == "completed" and steps[name]["conclusion"] == "success"
                for name in (HOSTED_VERIFY, HOSTED_UPLOAD)), "hosted verification or receipt upload did not pass")
    ci.require_step_order(steps, (HOSTED_VERIFY, HOSTED_UPLOAD))
    log = work / "hosted-receipt-upload.log"
    original_logs(ci, job, log)
    row = ci.api(f"actions/artifacts/{artifact_id}")
    require(row["id"] == artifact_id and row["name"] == HOSTED_ARTIFACT and
            row["workflow_run"]["id"] == run_id, "claimed hosted receipt artifact differs")
    contents, evidence = ci.protected_gate_zip(HOSTED_ARTIFACT, receipt_members("ci-originals"),
                                               run_id, REPO_ID, HOSTED_REF, revision, steps[HOSTED_UPLOAD], log, work)
    require(evidence["artifactId"] == artifact_id, "exact hosted receipt ID differs")
    return contents, {"runId": run_id, "operationsCommit": revision, **evidence}


def hosted_package_records(ci, contents, hashes):
    builds, files, gates = {}, {}, {}
    for label, lane, required in (
        ("apple", APPLE, set(APPLE_PACKAGES.values()) | {APPLE_CHECKSUM}),
        ("android", ANDROID, set(ANDROID_PACKAGES) | {ANDROID_CHECKSUM, ANDROID_SIGNING}),
    ):
        raw = contents[f"{label}-original.json"]
        receipt = json.loads(raw)
        require(raw == ci.canonical(receipt) and receipt["sourceCommit"] == SOURCE and
                receipt["tagObject"] == TAG_OBJECT and receipt["releaseId"] == DRAFT and
                receipt["frozenVerifierHashes"] == hashes and set(receipt["files"]) == required,
                f"hosted {label} package receipt is inconsistent with frozen source or package set")
        build = receipt[label]
        require(set(build) == {"runId", "attempt", "sourceCommit", "headBranch", "jobId", "artifactId",
                               "artifactName", "artifactSize", "artifactSha256"} and
                (build["runId"], build["attempt"], build["sourceCommit"], build["headBranch"], build["artifactName"]) ==
                (lane.run_id, ATTEMPT, SOURCE, TAG, lane.archive), f"hosted {label} build pointer differs")
        check_run(ci.api(f"actions/runs/{lane.run_id}"), lane)
        identifier = ci.positive(build["artifactId"])
        artifact = ci.api(f"actions/artifacts/{identifier}")
        check_artifact(ci, artifact, lane, lane.archive, identifier, ci.MAX_ARCHIVE)
        require((artifact["size_in_bytes"], artifact["digest"][7:]) ==
                (build["artifactSize"], build["artifactSha256"]), f"hosted {label} archive bytes differ")
        for name, row in receipt["files"].items():
            require(set(row) == {"size", "sha256"} and ci.positive(row["size"]) <= 2 * 1024**3,
                    f"hosted package receipt has an invalid size: {name}")
            ci.sha(row["sha256"])
            if name in contents:
                require(len(contents[name]) == row["size"] and hashlib.sha256(contents[name]).hexdigest() == row["sha256"],
                        f"hosted evidence bytes differ from package receipt: {name}")
        builds[label] = build
        gates[f"{label}Gate"] = receipt[f"{label}Gate"]
        files.update(receipt["files"])
    return builds, files, gates


def main():
    global ROOT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT, help="checkout of the frozen release source")
    parser.add_argument("--check-output", type=Path, help="check only the strict receipt export file set")
    parser.add_argument("--output-mode", choices=("apple-original", "android-original", "ci-originals", "draft"))
    parser.add_argument("--hosted-receipt", nargs=3, metavar=("RUN", "COMMIT", "ARTIFACT"),
                        help="authenticate the successful ci-originals hosted proof before exact draft downloads")
    parser.add_argument("--hosted-workflow", type=Path, help="reviewed rendered hosted workflow used by this proof")
    parser.add_argument("--evidence-only-downloads", action="store_true",
                        help="compare package digests and download the three original evidence files only")
    parser.add_argument("--name", help="fresh verifier-owned output directory basename")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apple-original", action="store_true",
                      help="verify original Apple packages before the draft attachment job runs")
    mode.add_argument("--android-original", action="store_true",
                      help="verify original Android packages independently while Apple CI runs")
    mode.add_argument("--ci-originals", action="store_true",
                      help="verify both original builds and Apple attachment without accessing draft release APIs")
    for lane in ("apple", "android"):
        parser.add_argument(f"--{lane}-archive", nargs=3, metavar=("ID", "SIZE", "SHA256"),
                            help=f"approved exact original {lane} archive")
    parser.add_argument("--bundletool", type=Path,
                        default=Path("/Users/daksh/VortXTV/_recovery/backup-repair-20261103/beta12-protected-builds.WTJE177T/bundletool.jar"))
    parser.add_argument("--java-home", type=Path, default=Path("/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"))
    parser.add_argument("--android-sdk", type=Path, default=Path("/Users/daksh/Library/Android/sdk"))
    args = parser.parse_args()
    if args.check_output is not None:
        require(args.output_mode is not None, "an exact output mode is required")
        check_output(args.check_output, args.output_mode)
        return
    args.name = args.name or ("apple-original" if args.apple_original else "android-original" if args.android_original
                              else "ci-originals" if args.ci_originals else "accepted")
    require(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,55}", args.name), "unsafe verification output name")
    ROOT = args.repo_root.resolve(strict=True)
    for pointer in (args.apple_archive, args.android_archive):
        if pointer is not None:
            identifier, size, artifact_digest = pointer
            require(all(re.fullmatch(r"[1-9][0-9]{0,17}", item) for item in (identifier, size)) and
                    re.fullmatch(r"[0-9a-f]{64}", artifact_digest), "invalid reviewed archive pointer")
    require(bool(args.hosted_receipt) == bool(args.hosted_workflow) and
            not (args.hosted_receipt and (args.apple_original or args.android_original or args.ci_originals)) and
            (not args.evidence_only_downloads or args.hosted_receipt),
            "a hosted receipt and reviewed workflow are allowed together for draft verification only")
    if not (args.apple_original or args.hosted_receipt):
        for name in ("bundletool", "java_home", "android_sdk"):
            setattr(args, name, getattr(args, name).resolve(strict=True))
    os.umask(0o077)
    sys.dont_write_bytecode = True
    hashes = source_contract()
    ci = load_tool("scripts/verify-ci-direct-beta.py", "frozen_stable_ci_primitives")
    helper = load_tool("scripts/verify-apple-direct-test-release.py", "frozen_stable_apple_inspector")
    check_tag(ci)
    release = None
    if not (args.apple_original or args.android_original or args.ci_originals):
        release = ci.api(f"releases/{DRAFT}")
        check_release(release)
    output = WORK_AREA / args.name
    require(not output.exists() and not output.is_symlink(), "a verification output with this name already exists")
    with tempfile.TemporaryDirectory(prefix="stable-evidence-", dir=WORK_AREA) as temp:
        work = Path(temp)
        tempfile.tempdir = temp
        try:
            if args.hosted_receipt:
                contents, evidence = authenticate_hosted_receipts(ci, work, args.hosted_receipt, args.hosted_workflow)
                records, files, gates = hosted_package_records(ci, contents, hashes)
                draft = ci.api(f"releases/{DRAFT}")
                require((draft.get("name"), draft.get("body")) == (release["name"], release["body"]),
                        "draft notes or name changed during verification")
                metadata = verify_draft_records(ci, draft, files, work,
                                                evidence_only_downloads=args.evidence_only_downloads)
                check_tag(ci)
                temporary_output = work / "receipts"
                temporary_output.mkdir()
                emitted_files(ci, records, metadata, temporary_output)
                flat_files = {}
                for name in (APPLE_CHECKSUM, ANDROID_CHECKSUM, ANDROID_SIGNING):
                    flat_files[name] = work / name
                    flat_files[name].write_bytes(contents[name])
                retain_release_evidence(temporary_output, flat_files,
                                        apple_feed={name: contents[f"apple-feed/{name}"] for name in APPLE_FEED_MEMBERS})
                (temporary_output / "verification.json").write_bytes(ci.canonical({
                    "schemaVersion": 1, "sourceCommit": SOURCE, "tagObject": TAG_OBJECT, "releaseId": DRAFT,
                    "releaseBodySha256": hashlib.sha256(draft["body"].encode()).hexdigest(), "assets": metadata,
                    "frozenVerifierHashes": hashes, "hostedVerification": evidence,
                    "draftDownloadScope": ("original-evidence-files" if args.evidence_only_downloads else "all-assets"),
                    **gates,
                }))
                temporary_output.rename(output)
                print(f"Hosted originals and exact draft downloads verified. Receipts: {output}", flush=True)
                return
            if args.apple_original:
                apple = download_lane(ci, APPLE, work, "apple", original_only=True, reviewed_archive=args.apple_archive)
                aether, gate, feed = apple_proofs(ci, apple, work)
                files = inspect_apple(ci, helper, hashes, apple, aether)
                check_tag(ci)
                check_run(ci.api(f"actions/runs/{APPLE.run_id}"), APPLE, original_only=True)
                temporary_output = work / "receipts"
                temporary_output.mkdir()
                retain_release_evidence(temporary_output, files, apple_feed=feed)
                original_receipt(ci, temporary_output, "apple", apple, gate, files, hashes)
                temporary_output.rename(output)
                print(f"Original Apple packages verified before attachment. Receipt: {output}", flush=True)
                return
            android = download_lane(ci, ANDROID, work, "android", reviewed_archive=args.android_archive)
            android_gate = android_proofs(ci, android, work)
            android_files = inspect_android(ci, android, args)
            print("Android immutable package and protected account verification passed", flush=True)
            if args.android_original:
                check_tag(ci)
                check_run(ci.api(f"actions/runs/{ANDROID.run_id}"), ANDROID)
                temporary_output = work / "receipts"
                temporary_output.mkdir()
                retain_release_evidence(temporary_output, android_files)
                original_receipt(ci, temporary_output, "android", android, android_gate, android_files, hashes)
                temporary_output.rename(output)
                print(f"Original Android packages verified. Receipt: {output}", flush=True)
                return
            apple = download_lane(ci, APPLE, work, "apple", reviewed_archive=args.apple_archive)
            aether, apple_gate, feed = apple_proofs(ci, apple, work)
            apple_files = inspect_apple(ci, helper, hashes, apple, aether)
            print("Apple immutable package, protected account and Aether verification passed", flush=True)
            if args.ci_originals:
                check_tag(ci)
                for lane in (APPLE, ANDROID):
                    check_run(ci.api(f"actions/runs/{lane.run_id}"), lane)
                temporary_output = work / "receipts"
                temporary_output.mkdir()
                retain_release_evidence(temporary_output, {**apple_files, **android_files}, apple_feed=feed)
                original_receipt(ci, temporary_output, "apple", apple, apple_gate, apple_files, hashes)
                original_receipt(ci, temporary_output, "android", android, android_gate, android_files, hashes)
                temporary_output.rename(output)
                print(f"Both exact original builds verified. Receipts: {output}", flush=True)
                return
            final_draft = ci.api(f"releases/{DRAFT}")
            require((final_draft.get("body"), final_draft.get("name")) == (release["body"], release["name"]),
                    "draft notes or name changed while packages were being verified")
            metadata = verify_draft_assets(ci, final_draft, {**apple_files, **android_files}, work)
            check_tag(ci)
            for lane in (APPLE, ANDROID):
                check_run(ci.api(f"actions/runs/{lane.run_id}"), lane)
            temporary_output = work / "receipts"
            temporary_output.mkdir()
            emitted_files(ci, {"apple": apple[1], "android": android[1]}, metadata, temporary_output)
            retain_release_evidence(temporary_output, {**apple_files, **android_files}, apple_feed=feed)
            (temporary_output / "verification.json").write_bytes(ci.canonical({
                "schemaVersion": 1, "sourceCommit": SOURCE, "tagObject": TAG_OBJECT, "releaseId": DRAFT,
                "releaseBodySha256": hashlib.sha256(release["body"].encode()).hexdigest(),
                "assets": metadata, "appleGate": apple_gate, "androidGate": android_gate,
                "frozenVerifierHashes": hashes,
            }))
            temporary_output.rename(output)
        finally:
            tempfile.tempdir = None
    print(f"Seven packages and matching draft evidence verified. Receipts: {output}", flush=True)


if __name__ == "__main__":
    main()
