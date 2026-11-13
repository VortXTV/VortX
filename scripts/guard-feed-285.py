#!/usr/bin/env python3
"""Verify the existing Latest Build 285 and unchanged pre-operation feed evidence."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

REPO = "VortXTV/VortX"
RELEASE = 442166603
TAG = "v0.5.6-beta.13"
SOURCE = "4d3ef04324b887038da4ff4cf3e822cd07cf101e"
CANDIDATE = TAG + "-candidate.1"
TAG_OBJECT = "5dce04bf42d0f4ec2f70b2016e86dfae390c3e80"
CANDIDATE_OBJECT = "d17d7935d27f650feaedd400cb7db7ec7b0157bf"
MAIN = "60ab24bc58fa93d4c2d1d95e98291cc4ee2c6b4d"
OLD_GENERATION = "v0.5.5:274:8816e6f98474c592151ae46c53fe3b6de13847cfbebb3322eeb675ce8a69d227"
OLD_SOURCE = "0a17b80fe8a713bb70b3463b703c257f2d1a4ca1f56ebdb5e20c943f9b14b533"
OLD_APPCAST = "910d3813bd4e251f625d3e38bf09ffb73e59e059c69b48603d5535c77cb6164e"
PROVENANCE_NAME = "VortX-Hosted-Direct-Beta-Provenance.json"
PROVENANCE_SHA = "7c256259f6b04385ae45bd9e675164197ba96ca1686aefdc214787efc81f531a"
SUMS_SHA = "b6c28cdcde3174567bd4503321066158d8e74f42d4b06288deef11c693ea8d8f"
SIGNER = "FC22B87ECD9E4FA26930A1C3E227D8F7D918C646B216032B5DA820EF1AC218CA"
BASENAME = "VortX-0.5.6-"
APK_FULL = BASENAME + "full-mpv-universal.apk"
APK_PLAY = BASENAME + "play-media3-universal.apk"
AAB = BASENAME + "play-media3.aab"
ARTIFACT_IDS = {
    APK_FULL: 736935197,
    APK_PLAY: 736935486,
    AAB: 736935698,
    f"VortX-iOS-{TAG}-ci.ipa": 736935938,
    f"VortX-macOS-{TAG}-ci.dmg": 736936178,
    f"VortX-tvOS-lite-{TAG}-ci.ipa": 736936361,
    f"VortX-tvOS-{TAG}-ci.ipa": 736936605,
}
EXPECTED_ROUTES = {
    "appcast.json": OLD_APPCAST,
    "altstore.json": OLD_SOURCE,
    "vortx-altstore.json": OLD_SOURCE,
}
EVIDENCE_ANDROID = {
    "checksumEvidenceSha256": "9f0cee99b55cc9222858e0cd26d0bce269cd8cb75649437598284d568104e88d",
    "engineSourceCommit": "2ea2e0f27dd2e53b7b28228435ca35a70f92831f",
    "nativeFeatures": "jni,server,resource-host",
    "signingAndVersionEvidenceSha256": "0f3579aed19b29bff9ee6464f6bea30960841673917015d1e9435ec2b9a85269",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(raw):
    return hashlib.sha256(raw).hexdigest()


def unique_json_keys(pairs):
    result = {}
    for name, value in pairs:
        require(name not in result, f"duplicate JSON key {name}")
        result[name] = value
    return result


def load(raw):
    return json.loads(raw, object_pairs_hook=unique_json_keys)


def checksum_records(raw):
    records = {}
    for line in raw.decode("ascii").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9.-]+)", line)
        require(match is not None, "invalid checksum line")
        checksum, name = match.groups()
        require(name not in records, f"duplicate checksum for {name}")
        records[name] = checksum
    return records


def checks_ref(read, prefix, tag, object_sha):
    reference = load(read(prefix + "tag-ref.json"))
    obj = load(read(prefix + "tag-object.json"))
    require(reference["ref"] == f"refs/tags/{tag}" and
            reference["object"]["type"] == "tag" and
            reference["object"]["sha"] == object_sha and
            obj["sha"] == object_sha and obj["tag"] == tag and
            obj["object"]["type"] == "commit" and obj["object"]["sha"] == SOURCE,
            f"protected tag identity differs for {tag}")


def release_identity(record):
    require(record["id"] == RELEASE and record["tag_name"] == TAG and
            record["target_commitish"] == SOURCE and record["draft"] is False and
            record["prerelease"] is False and
            record["published_at"] == "2026-11-11T21:21:27Z" and
            record["name"] == "VortX 0.5.6 beta 13: Profile Recovery, Mac Sign-In and Subtitle Shortcuts (Build 285)",
            "Latest release identity differs")
    body = record["body"]
    for marker in ("<!-- vortx-distribution: hosted-direct-beta -->",
                   f"<!-- vortx-ci-provenance-sha256: {PROVENANCE_SHA} -->"):
        require(body.splitlines().count(marker) == 1, "release body binding differs")
    return record["name"], body


def verified_assets(record, packages):
    expected = {item["name"]: (ARTIFACT_IDS[item["name"]], item["size"], item["sha256"]) for item in packages}
    expected.update({"SHA256SUMS.txt": (736935137, 700, SUMS_SHA),
                     PROVENANCE_NAME: (736935869, 49009, PROVENANCE_SHA)})
    rows = record["assets"]
    require(len(rows) == len(expected), "release asset count differs")
    result = {}
    for row in rows:
        name = row["name"]
        require(name in expected and name not in result, f"unexpected or duplicate release asset {name}")
        aid, size, digest = expected[name]
        url = f"https://github.com/{REPO}/releases/download/{TAG}/{name}"
        require(row["id"] == aid and row["size"] == size and row["digest"] == f"sha256:{digest}" and
                row["state"] == "uploaded" and row["browser_download_url"] == url,
                f"release asset identity differs for {name}")
        result[name] = {"id": aid, "size": size, "sha256": digest, "url": url}
    return result


def verify(evidence, android, repo):
    def read(name):
        path = evidence / name
        require(path.is_file() and path.stat().st_size <= 1024 * 1024, f"invalid evidence file {name}")
        return path.read_bytes()

    checks_ref(read, "", TAG, TAG_OBJECT)
    checks_ref(read, "candidate-", CANDIDATE, CANDIDATE_OBJECT)
    main = load(read("main-ref.json"))
    require(main["ref"] == "refs/heads/main" and main["object"]["type"] == "commit" and
            main["object"]["sha"] == MAIN, "main compare-and-swap base differs")
    require(sha256(read("main-source.json")) == OLD_SOURCE, "main source rollback bytes differ")
    for name, digest in EXPECTED_ROUTES.items():
        require(sha256(read(name)) == digest, f"predecessor bytes differ for {name}")
        headers = read(name + ".headers").decode("ascii").lower().splitlines()
        require(headers.count("x-vortx-feed-generation: " + OLD_GENERATION) == 1 and
                headers.count("x-vortx-feed-state: active") == 1,
                f"public predecessor identity differs for {name}")

    raw_provenance = read(PROVENANCE_NAME)
    require(sha256(raw_provenance) == PROVENANCE_SHA, "approved release provenance bytes differ")
    provenance = load(raw_provenance)
    require(provenance["repository"] == REPO and provenance["releaseId"] == RELEASE and
            provenance["sourceCommit"] == SOURCE and provenance["tag"] == TAG and
            str(provenance["build"]) == "285" and provenance["version"] == "0.5.6" and
            provenance["distribution"] == "hosted-direct-beta", "provenance identity differs")
    for lane, run, artifact in (("apple", 43067463614, 13888908162), ("android", 43032604411, 13863521461)):
        receipt = provenance["builds"][lane]
        require(receipt["runId"] == run and receipt["artifactId"] == artifact and receipt["attempt"] == 1 and
                receipt["sourceCommit"] == SOURCE and receipt["headBranch"] == CANDIDATE,
                f"{lane} build provenance differs")
    for source_path, digest in provenance["sourceFileSha256"].items():
        require(re.fullmatch(r"[.A-Za-z0-9/_-]+", source_path) is not None and
                all(part not in {"", ".", ".."} for part in source_path.split("/")),
                "invalid source contract path")
        content = subprocess.check_output(["git", "-C", str(repo), "show", f"{SOURCE}:{source_path}"])
        require(sha256(content) == digest, f"protected source bytes differ for {source_path}")
    raw_main_source = subprocess.check_output(["git", "-C", str(repo), "show", f"{MAIN}:altstore/source.json"])
    require(sha256(raw_main_source) == OLD_SOURCE, "exact main Git object source differs")

    packages = provenance["artifacts"]
    require(len(packages) == 7 and {row["name"] for row in packages} == set(ARTIFACT_IDS),
            "public provenance package roster differs")
    require(all(row["build"] == "285" and row["version"] == "0.5.6" for row in packages),
            "package build or version differs")
    latest = load(read("latest.json"))
    by_id = load(read("release.json"))
    require(release_identity(latest) == release_identity(by_id), "Latest and numeric release responses differ")
    assets = verified_assets(latest, packages)
    require(assets == verified_assets(by_id, packages), "Latest and numeric release assets differ")
    raw_sums = read("SHA256SUMS.txt")
    require(sha256(raw_sums) == SUMS_SHA, "public checksum asset bytes differ")
    require(checksum_records(raw_sums) == {row["name"]: row["sha256"] for row in packages},
            "public checksums differ from the seven verified packages")

    native = provenance["evidence"]["android"]
    require(native == EVIDENCE_ANDROID, "Android signing/native evidence binding differs")
    android_sums = (android / "SHA256SUMS-android.txt").read_bytes()
    android_signing = (android / "SIGNING_PROVENANCE.txt").read_bytes()
    require(sha256(android_sums) == native["checksumEvidenceSha256"] and
            sha256(android_signing) == native["signingAndVersionEvidenceSha256"],
            "original Android handoff bytes differ")
    require(checksum_records(android_sums) == {name: assets[name]["sha256"] for name in (APK_FULL, APK_PLAY, AAB)},
            "original Android checksums differ from public provenance")
    signer_lines = re.findall(r"(?m)^  signer SHA-256: ([0-9A-F:]+)$", android_signing.decode("utf-8"))
    require([item.replace(":", "") for item in signer_lines] == [SIGNER] * 3,
            "Android signer differs from the production signer")
    return {"releaseId": RELEASE, "tag": TAG, "sourceCommit": SOURCE, "build": 285,
            "provenanceSha256": PROVENANCE_SHA, "expectedMainCommit": MAIN,
            "publicPredecessor": OLD_GENERATION, "sourceSha256": OLD_SOURCE,
            "appcastSha256": OLD_APPCAST, "assets": assets}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--android-original", type=Path, required=True)
    parser.add_argument("--repo", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify(args.evidence, args.android_original, args.repo)
    except (OSError, KeyError, TypeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Feed guard refused: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
