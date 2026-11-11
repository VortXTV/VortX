#!/usr/bin/env python3
"""One-shot hosted verification and attachment for the frozen Beta 13 draft."""
import argparse
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urlencode
import zipfile

REPO = "VortXTV/VortX"
REPO_ID = 1261501126
WORKFLOW_ID = 343149688
WORKFLOW_PATH = ".github/workflows/release-packaging-validation.yml"
OPERATION_TAG = "vortx-beta13-release-ops-20261111"
PREFLIGHT_BRANCH = "beta13-hosted-preflight-20261111"
SOURCE = "4d3ef04324b887038da4ff4cf3e822cd07cf101e"
VERIFIER_SHA = "bba10af16bd18ed6f7c0aa4d4c9fb3b4bbece95e89be71b77c8f7b0e26556b2b"
CANDIDATE = "v0.5.6-beta.13-candidate.1"
TAG = "v0.5.6-beta.13"
APPLE_RUN = 43032603923
ANDROID_RUN = 43032604411
ANDROID_ARTIFACT = 13863521461
ANDROID_ARTIFACT_SHA = "ff6ecb5edfd87ca5cc0975b181a434af4af77978a8b52f286a8407df6f104596"
BUNDLETOOL_SHA = "a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
PREFLIGHT_NAME = "VortX-Beta13-protected-preflight"
PREFLIGHT_STEM = "beta13-preflight"
PREPARE_NAME = "VortX-Beta13-prepared-proof"
PREPARE_STEM = "beta13-prepared-provenance"
VERIFY_STEM = "beta13-draft-verified"
MAX_PROOF = 1024**2
MAX_APP_ASSET = 2 * 1024**3


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(text):
    require(re.fullmatch(r"[1-9][0-9]{0,17}", text) is not None, "expected a positive numeric identity")
    return int(text)


def hex_id(text, size=64):
    require(type(text) is str and re.fullmatch(rf"[0-9a-f]{{{size}}}", text) is not None,
            "expected a lowercase hex digest or source ID")
    return text


def byte_hash(raw):
    return hashlib.sha256(raw).hexdigest()


def admission(env):
    ref = "refs/tags/" + OPERATION_TAG
    require(env.get("GITHUB_REPOSITORY") == REPO and env.get("GITHUB_ACTOR") == "mamaclapper" and
            env.get("GITHUB_EVENT_NAME") == "workflow_dispatch" and env.get("GITHUB_REF") == ref and
            env.get("GITHUB_WORKFLOW_REF") == f"{REPO}/{WORKFLOW_PATH}@{ref}" and
            env.get("GITHUB_SHA") == env.get("GITHUB_WORKFLOW_SHA") and env.get("GITHUB_RUN_ATTEMPT") == "1",
            "unexpected operations workflow, ref, actor or attempt")
    return hex_id(env["GITHUB_SHA"], 40)


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_small(path):
    require(path.is_file() and not path.is_symlink(), "expected a bounded regular evidence file")
    with path.open("rb") as stream:
        data = stream.read(MAX_PROOF + 1)
    require(0 < len(data) <= MAX_PROOF, "evidence file size outside bounds")
    return data


def write_proof(raw, output, stem):
    require(output.is_dir() and not output.is_symlink() and not list(output.iterdir()) and
            0 < len(raw) <= MAX_PROOF, "proof destination or size differs")
    with (output / f"{stem}.json").open("xb") as target:
        target.write(raw)
    digest = byte_hash(raw)
    with (output / f"{stem}.sha256").open("x", encoding="ascii") as target:
        target.write(f"{digest}  {stem}.json\n")
    return digest


def original_proof(ci, directory, run_id, artifact_id, ref, source, artifact_name, stem, digest):
    run = ci.api(f"actions/runs/{run_id}")
    require((run.get("id"), run.get("workflow_id"), run.get("path"), run.get("run_attempt"),
             run.get("head_sha"), run.get("head_branch"), run.get("event"), run.get("status"),
             run.get("conclusion"), run.get("actor", {}).get("login")) ==
            (run_id, WORKFLOW_ID, WORKFLOW_PATH, 1, source, ref, "workflow_dispatch", "completed",
             "success", "mamaclapper"), "proof is not from the exact successful hosted operation")
    for key in ("repository", "head_repository"):
        require((run.get(key, {}).get("id"), run.get(key, {}).get("full_name")) == (REPO_ID, REPO),
                "proof run repository identity differs")
    artifact = ci.api(f"actions/artifacts/{artifact_id}")
    provenance = artifact.get("workflow_run", {})
    require((artifact.get("id"), artifact.get("name"), artifact.get("expired")) ==
            (artifact_id, artifact_name, False) and
            (provenance.get("id"), provenance.get("head_sha"), provenance.get("head_branch"),
             provenance.get("repository_id"), provenance.get("head_repository_id")) ==
            (run_id, source, ref, REPO_ID, REPO_ID),
            "proof artifact does not bind its original run and ref")
    size = artifact.get("size_in_bytes")
    require(type(size) is int and 0 < size <= 2 * MAX_PROOF and
            re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", "")), "proof archive size or digest differs")
    archive = directory / f"{stem}.zip"
    ci.api_download(f"actions/artifacts/{artifact_id}/zip", archive, size)
    names = {f"{stem}.json", f"{stem}.sha256"}
    with zipfile.ZipFile(archive) as proof_zip:
        entries = proof_zip.infolist()
        require(len(entries) == 2 and {entry.filename for entry in entries} == names and
                all(0 < entry.file_size <= MAX_PROOF for entry in entries), "proof ZIP members exceed the proof bounds")
    extracted = directory / stem
    ci.extract_exact(archive, artifact, names, extracted)
    raw = read_small(extracted / f"{stem}.json")
    require(byte_hash(raw) == digest and
            read_small(extracted / f"{stem}.sha256") == f"{digest}  {stem}.json\n".encode(),
            "proof bytes differ from the independently held digest")
    require(raw == ci.canonical(json.loads(raw)), "proof is not canonical JSON")
    return raw, extracted / f"{stem}.json"


def expected_manifest(ci, raw, args):
    preflight = json.loads(raw)
    evidence = preflight["evidence"]
    require((evidence.get("tag"), evidence.get("sourceCommit"), evidence.get("repository"), evidence.get("build"),
             evidence.get("version"), evidence.get("distribution")) ==
            (TAG, SOURCE, REPO, "285", "0.5.6", "hosted-direct-beta"), "preflight has wrong candidate identity")
    require("releaseId" not in evidence and
            evidence["sourceFileSha256"]["scripts/verify-ci-direct-beta.py"] == VERIFIER_SHA,
            "preflight tool or draft independence differs")
    pointers = {
        "apple": {"runId": APPLE_RUN, "attempt": 1, "artifactId": args.apple_artifact},
        "android": {"runId": ANDROID_RUN, "attempt": 1, "artifactId": ANDROID_ARTIFACT},
    }
    require(set(evidence["builds"]) == set(pointers), "preflight build lane roster differs")
    for lane, pointer in pointers.items():
        row = evidence["builds"][lane]
        require(all(type(row.get(k)) is int and row[k] == value for k, value in pointer.items()) and
                row.get("headBranch") == CANDIDATE and row.get("sourceCommit") == SOURCE and
                row.get("repositoryId") == REPO_ID, "preflight original run pointer differs")
    require(evidence["builds"]["android"].get("artifactSha256") == ANDROID_ARTIFACT_SHA and
            evidence["builds"]["android"].get("artifactSize") == 201681040, "Android archive proof differs")
    manifest = {**evidence, "releaseId": args.release_id}
    require(raw == ci.canonical(ci.candidate_receipt(manifest)), "preflight receipt contract differs")
    return manifest, pointers


def outputs(ci, manifest):
    apple, _, android = ci.file_matrix(TAG, "0.5.6")
    expected = {name.replace("-ci.", f"-{TAG}-ci.") for name in apple.values()} | android
    records = manifest["artifacts"]
    require(type(records) is list and len(records) == 7 and
            [row["name"] for row in records] == sorted(expected), "prepared package roster differs")
    package_hashes = {}
    for row in records:
        size = row["size"]
        require(type(size) is int and 0 < size <= MAX_APP_ASSET, "prepared package size is invalid")
        package_hashes[row["name"]] = (size, hex_id(row["sha256"]))
    sums = "".join(f"{digest}  {name}\n" for name, (_, digest) in package_hashes.items()).encode()
    metadata = {ci.SUMS: sums, ci.PROVENANCE: ci.canonical(manifest)}
    expected = {**package_hashes, **{name: (len(raw), byte_hash(raw)) for name, raw in metadata.items()}}
    return expected, metadata


def draft_assets(ci, args, expected, body_hash, manifest_hash):
    release = ci.api(f"releases/{args.release_id}")
    ci.release_identity(release, args.release_id, TAG, True, SOURCE)
    body = release["body"]
    require(type(body) is str and len(body.encode()) <= MAX_PROOF, "draft body is not bounded text")
    if body_hash is not None:
        require(byte_hash(body.encode()) == body_hash and ci.provenance_binding(body) == manifest_hash,
                "draft notes differ from the independently held provenance binding")
    else:
        require("vortx-ci-provenance-sha256:" not in body, "prepare requires a draft without a prior provenance binding")
    rows = release.get("assets")
    require(isinstance(rows, list) and len(rows) <= len(expected), "draft asset roster has extras")
    names = [row.get("name") for row in rows]
    require(len(set(names)) == len(names) and set(names) <= set(expected), "draft asset names are unexpected or duplicated")
    exact = ci.release_assets(release, set(names))
    require(len({asset["id"] for asset in exact.values()}) == len(exact), "draft asset IDs repeat")
    for name, asset in exact.items():
        size, digest = expected[name]
        require(asset["size"] == size and asset["digest"] == "sha256:" + digest,
                "existing draft asset does not match the independently prepared size and digest")
        ci.validate_asset_url("verify-draft", release, TAG, name, asset["browser_download_url"])
    return exact


def verify_file(ci, path, identity):
    size, digest = identity
    require(path.is_file() and not path.is_symlink() and path.stat().st_size == size and ci.digest(path) == digest,
            "file differs from its exact independently accepted size and digest")


def frozen_cli(ci, args, work, mode, manifest_hash, extra):
    command = ["python3", "-B", str(args.repo_root / "scripts/verify-ci-direct-beta.py"), mode,
               "--tag", TAG, "--source-commit", SOURCE, "--repo-root", str(args.repo_root),
               "--work-dir", str(work), "--bundletool", str(args.bundletool),
               "--release-id", str(args.release_id), *extra]
    log = work / (mode + ".log")
    with log.open("xb") as stream:
        result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT)
    require(result.returncode == 0, "frozen verifier did not complete the requested phase")
    lines = read_small(log).decode().splitlines()
    marker = (f"Prepared provenance SHA-256: {manifest_hash}" if mode == "prepare" else
              "Verified verify-draft: original CI evidence, all nine asset bytes, unchanged stable routes")
    require(lines.count(marker) == 1, "frozen verifier terminal marker differs")


def frozen_prepare(ci, args, work, preflight_path, manifest_hash, expected):
    prepared = work / "prepared"
    frozen_cli(ci, args, work, "prepare", manifest_hash, [
        "--output", str(prepared), "--preflight-receipt", str(preflight_path),
        "--apple-run", str(APPLE_RUN), "--apple-attempt", "1", "--apple-artifact", str(args.apple_artifact),
        "--android-run", str(ANDROID_RUN), "--android-attempt", "1", "--android-artifact", str(ANDROID_ARTIFACT)])
    require(prepared.is_dir() and not prepared.is_symlink() and
            {item.name for item in prepared.iterdir()} == set(expected), "frozen prepare produced the wrong files")
    files = {name: prepared / name for name in expected}
    for name, path in files.items():
        verify_file(ci, path, expected[name])
    return files


def regenerate_partial(ci, args, helper, work, manifest, pointers, stable, expected, metadata):
    # Prepare already succeeded on the empty draft. The exact frozen content verifier
    # reauthenticates both handoffs during recovery. The draft now has a valid subset.
    directory = work / "partial-reproduction"
    directory.mkdir()
    observed, records = ci.build_manifest(args, pointers, stable, helper, directory)
    require(ci.canonical(observed) == ci.canonical(manifest), "partial recovery reauthentication changed prepared provenance")
    files = {item["name"]: path for path, item in records}
    for name, raw in metadata.items():
        path = directory / name
        with path.open("xb") as target:
            target.write(raw)
        files[name] = path
    require(set(files) == set(expected), "partial recovery has the wrong file roster")
    for name, path in files.items():
        verify_file(ci, path, expected[name])
    return files


def asset_upload(release_id, path, name, size, token):
    # No redirect and no generic release method. The draft/asset identity was
    # rechecked by exact numeric ID immediately before this POST.
    require(token and "\n" not in token and "\r" not in token, "GitHub token is missing or invalid")
    endpoint = f"/repos/{REPO}/releases/{release_id}/assets?" + urlencode({"name": name})
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/octet-stream",
               "Content-Length": str(size), "Accept": "application/vnd.github+json",
               "User-Agent": "VortX-Beta13-draft-attach"}
    connection = http.client.HTTPSConnection("uploads.github.com", timeout=75)
    try:
        with path.open("rb") as stream:
            connection.request("POST", endpoint, body=stream, headers=headers)
            response = connection.getresponse()
            # Only status is needed. The independent exact-ID GET authenticates state and digests.
            response.close()
            return response.status
    finally:
        connection.close()


def attach_missing(ci, args, expected, files, current, read_draft, upload):
    for name in sorted(expected.keys() - current.keys()):
        require(read_draft() == current, "draft changed before attachment")
        path = files[name]
        size, _ = expected[name]
        verify_file(ci, path, expected[name])
        try:
            upload(args.release_id, path, name, size, os.environ["GH_TOKEN"])
        except (OSError, http.client.HTTPException):
            # An ambiguous POST is never blindly repeated. Accept only a fresh exact readback.
            pass
        updated = read_draft()
        require(set(updated) == set(current) | {name} and
                all(updated[existing] == asset for existing, asset in current.items()),
                "attachment did not produce the single expected asset. Preserve current draft for inspection.")
        current = updated
    return current


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=("prepare", "attach"))
    parser.add_argument("--apple-artifact", type=number, required=True)
    parser.add_argument("--release-id", type=number, required=True)
    parser.add_argument("--preflight-run", type=number, required=True)
    parser.add_argument("--preflight-artifact", type=number, required=True)
    parser.add_argument("--preflight-source", type=lambda value: hex_id(value, 40), required=True)
    parser.add_argument("--preflight-sha", type=hex_id, required=True)
    parser.add_argument("--prepare-run", default="")
    parser.add_argument("--prepare-artifact", default="")
    parser.add_argument("--prepared-sha", default="")
    parser.add_argument("--draft-body-sha", default="")
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--bundletool", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    ops_source = admission(os.environ)
    args.tag, args.source_commit = TAG, SOURCE
    checked = subprocess.check_output(["git", "-C", str(args.repo_root), "rev-parse", "HEAD"], text=True).strip()
    require(checked == SOURCE and not subprocess.check_output(
        ["git", "-C", str(args.repo_root), "status", "--porcelain"]), "frozen checkout differs")
    verifier = args.repo_root / "scripts/verify-ci-direct-beta.py"
    require(byte_hash(read_small(verifier)) == VERIFIER_SHA, "frozen verifier digest differs")
    ci = load_module("vortx_frozen_ci", verifier)
    ci.source_contract(args.repo_root, SOURCE, "0.5.6", TAG)
    helper = load_module("vortx_frozen_apple", args.repo_root / "scripts/verify-apple-direct-test-release.py")
    require(ci.digest(args.bundletool) == BUNDLETOOL_SHA, "bundletool digest differs")
    keys = (args.prepare_run, args.prepare_artifact, args.prepared_sha, args.draft_body_sha)
    if args.phase == "attach":
        require(all(keys), "attach requires actual independently reviewed preparation and notes digests")
        args.prepare_run, args.prepare_artifact = number(args.prepare_run), number(args.prepare_artifact)
        hex_id(args.prepared_sha)
        hex_id(args.draft_body_sha)
    else:
        require(not any(keys), "prepare does not accept mutation or prior-prepare inputs")

    with tempfile.TemporaryDirectory(prefix="beta13-draft-private-", dir=os.environ["RUNNER_TEMP"]) as temporary:
        work = Path(temporary)
        ci.check_tag(OPERATION_TAG, ops_source)
        ci.check_tag(TAG, SOURCE)
        ci.check_tag(CANDIDATE, SOURCE)
        preflight, preflight_path = original_proof(
            ci, work, args.preflight_run, args.preflight_artifact, PREFLIGHT_BRANCH, args.preflight_source,
            PREFLIGHT_NAME, PREFLIGHT_STEM, args.preflight_sha)
        manifest, pointers = expected_manifest(ci, preflight, args)
        expected, metadata = outputs(ci, manifest)
        manifest_bytes = metadata[ci.PROVENANCE]
        manifest_hash = byte_hash(manifest_bytes)
        stable = manifest["stableMustRemain"]
        require(ci.stable_snapshot(TAG, helper) == stable, "stable routes or repository baseline changed")
        if args.phase == "prepare":
            require(not draft_assets(ci, args, expected, None, None), "prepare requires an empty draft")
            files = frozen_prepare(ci, args, work, preflight_path, manifest_hash, expected)
            require(read_small(files[ci.PROVENANCE]) == manifest_bytes and
                    not draft_assets(ci, args, expected, None, None), "prepared provenance or empty draft differs")
            digest = write_proof(manifest_bytes, args.output, PREPARE_STEM)
            print(f"Verified frozen Beta 13 prepare. Prepared provenance SHA-256 {digest}")
            return

        prepared, _ = original_proof(
            ci, work, args.prepare_run, args.prepare_artifact, OPERATION_TAG, ops_source, PREPARE_NAME,
            PREPARE_STEM, args.prepared_sha)
        require(prepared == manifest_bytes and args.prepared_sha == manifest_hash,
                "held actual prepared proof differs from exact preflight plus draft ID")

        def read_draft():
            return draft_assets(ci, args, expected, args.draft_body_sha, manifest_hash)

        current = read_draft()
        if set(current) != set(expected):
            if current:
                for name, asset in current.items():
                    path = work / ("existing-" + name)
                    ci.api_download(f"releases/assets/{asset['id']}", path, asset["size"], "application/octet-stream")
                    verify_file(ci, path, expected[name])
                files = regenerate_partial(ci, args, helper, work, manifest, pointers, stable, expected, metadata)
            else:
                files = frozen_prepare(ci, args, work, preflight_path, manifest_hash, expected)
                require(read_small(files[ci.PROVENANCE]) == prepared, "regenerated provenance differs from accepted preparation")
            require(ci.stable_snapshot(TAG, helper) == stable, "stable routes changed before attaching")
            ci.check_tag(TAG, SOURCE)
            ci.check_tag(CANDIDATE, SOURCE)
            current = attach_missing(ci, args, expected, files, current, read_draft, asset_upload)

        require(set(current) == set(expected), "nine exact draft assets are required")
        frozen_cli(ci, args, work, "verify-draft", manifest_hash, ["--provenance-sha256", manifest_hash])
        require(read_draft() == current, "verified draft assets changed after the frozen verification")
        public = {"schemaVersion": 1, "sourceCommit": SOURCE, "candidate": CANDIDATE, "tag": TAG,
                  "releaseId": args.release_id, "preflightSha256": args.preflight_sha,
                  "preparedProvenanceSha256": manifest_hash, "draftBodySha256": args.draft_body_sha,
                  "assets": [{k: asset[k] for k in ("id", "name", "size", "digest")}
                             for _, asset in sorted(current.items())], "stableMustRemain": stable}
        digest = write_proof(ci.canonical(public), args.output, VERIFY_STEM)
        print(f"Verified nine frozen Beta 13 draft assets. Draft evidence SHA-256 {digest}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError, zipfile.BadZipFile):
        # The workflow also keeps raw process output private. Never export GitHub responses or logs.
        print("Protected Beta 13 draft operation failed closed.")
        raise SystemExit(1)
