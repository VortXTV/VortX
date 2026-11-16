#!/usr/bin/env python3
"""Verify the published Build 301 channel and its predecessor feed evidence."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

REPO = "VortXTV/VortX"
RELEASE = 446921868
TAG = "v0.5.6-beta.15"
BASE_BODY_SHA = "5e18af2ff49eb7c4d505cacbd310f2b6cace762464e80a514569d99623170176"
BODY_SHA = "9d75515f418b071e44625aaa7570ff4b7faa5a32016e057e45a4c548489e6570"
CHANNEL_MARKER = "<!-- vortx-channel: latest-beta -->"
PREVIOUS_LATEST = 445983818
SOURCE = "44c1fe53ed4012561f5326baba6e2d5951af18d4"
CANDIDATE = TAG + "-candidate.6"
TAG_OBJECT = "66db1a8e8df0bd0d9ea4d19c493000da17341c6c"
CANDIDATE_OBJECT = "65028f8e9b53c0dde79ca77924f54e9fee7807e8"
MAIN = "b212011b0e770017f8908e5c5057da9b585e4cce"
OLD_GENERATION = "v0.5.6-beta.13:285:f1880ad0551005ecd7ff55228513595ac18810a8c72118ea491a2cb99e4aea43"
OLD_SOURCE = "8df281144dd13a92a5e0db4cfcd0d65ebeffba089002bbc5ed9c6b5f11063845"
OLD_APPCAST = "7cee79ed3e6559314dee3a58e303983360a090643cce1dde50dc8caa07dc7819"
PROVENANCE_NAME = "VortX-Hosted-Direct-Beta-Provenance.json"
PROVENANCE_SHA = "5e54e2bf85234686d59880f9f4277865ff53949df1621a32cd1f0adad43d4ac5"
SUMS_SHA = "c22153a3d4e0f57e46db2c2b68413b25342f94e464f45ea97f7f9759d33b2d86"
SIGNER = "FC22B87ECD9E4FA26930A1C3E227D8F7D918C646B216032B5DA820EF1AC218CA"
BASENAME = "VortX-0.5.6-"
APK_FULL = BASENAME + "full-mpv-universal.apk"
APK_PLAY = BASENAME + "play-media3-universal.apk"
AAB = BASENAME + "play-media3.aab"
ARTIFACT_IDS = {
    APK_FULL: 754571395,
    APK_PLAY: 754571679,
    AAB: 754571865,
    f"VortX-iOS-{TAG}-ci.ipa": 754572065,
    f"VortX-macOS-{TAG}-ci.dmg": 754572248,
    f"VortX-tvOS-lite-{TAG}-ci.ipa": 754572543,
    f"VortX-tvOS-{TAG}-ci.ipa": 754572706,
}
EXPECTED_ROUTES = {
    "appcast.json": OLD_APPCAST,
    "altstore.json": OLD_SOURCE,
    "vortx-altstore.json": OLD_SOURCE,
}
EVIDENCE_ANDROID = {
    "checksumEvidenceSha256": "dc034c8924028fd48cb09ed5ef33ac22e3fbfc401f15efb66e1550b110b8df8f",
    "engineSourceCommit": "2ea2e0f27dd2e53b7b28228435ca35a70f92831f",
    "nativeFeatures": "jni,server,resource-host",
    "signingAndVersionEvidenceSha256": "fe53175a5997b8af4a508575d73abe5b2ed4fc560a8ee967fcd6f176d0422b83",
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


def release_identity(record, *, promoted):
    require(record["id"] == RELEASE and record["tag_name"] == TAG and
            record["target_commitish"] == SOURCE and record["draft"] is False and
            record["prerelease"] is (not promoted) and
            record["published_at"] == "2026-11-16T11:23:52Z" and
            record["name"] == "VortX 0.5.6 beta 15 — Account Recovery and Playback Fixes",
            "Build 301 channel identity differs")
    body = record["body"]
    require(sha256(body.encode()) == (BODY_SHA if promoted else BASE_BODY_SHA), "reviewed release body differs")
    require(body.splitlines().count(CHANNEL_MARKER) == int(promoted), "Latest beta channel marker differs")
    for marker in ("<!-- vortx-distribution: hosted-direct-beta -->",
                   f"<!-- vortx-ci-provenance-sha256: {PROVENANCE_SHA} -->"):
        require(body.splitlines().count(marker) == 1, "release body binding differs")
    return record["name"], body


def previous_latest_identity(record):
    require(record["id"] == PREVIOUS_LATEST and record["tag_name"] == "v0.5.6-beta.14" and
            record["target_commitish"] == "c7ae27e7cf4d483eb983552edc8e952e25255ae2" and
            record["published_at"] == "2026-11-15T10:58:14Z" and record["prerelease"] is False and
            record["draft"] is False and sha256(record["body"].encode()) ==
            "a077ef6af27e03c4d1d745c039cf0248f7718e2a2a015fe5747c4b91ea233c9d",
            "previous GitHub Latest identity differs")


def verified_assets(record, packages):
    expected = {item["name"]: (ARTIFACT_IDS[item["name"]], item["size"], item["sha256"]) for item in packages}
    expected.update({"SHA256SUMS.txt": (754571280, 700, SUMS_SHA),
                     PROVENANCE_NAME: (754572000, 56961, PROVENANCE_SHA)})
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
            str(provenance["build"]) == "301" and provenance["version"] == "0.5.6" and
            provenance["distribution"] == "hosted-direct-beta", "provenance identity differs")
    for lane, run, artifact in (("apple", 43825790260, 14216488516), ("android", 43825790387, 14208410177)):
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
    require(all(row["build"] == "301" and row["version"] == "0.5.6" for row in packages),
            "package build or version differs")
    latest = load(read("latest.json"))
    by_id = load(read("release.json"))
    previous_latest_identity(latest)
    release_identity(by_id, promoted=False)
    assets = verified_assets(by_id, packages)
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
    signing_text = android_signing.decode("utf-8")
    require(re.findall(r"(?m)^Android versionCode: (\d+)$", signing_text) == ["301"] and
            re.findall(r"(?m)^Android versionName: ([^\r\n]+)$", signing_text) == ["0.5.6"],
            "Android signing evidence build or version differs")
    signer_lines = re.findall(r"(?m)^  signer SHA-256: ([0-9A-F:]+)$", android_signing.decode("utf-8"))
    require([item.replace(":", "") for item in signer_lines] == [SIGNER] * 3,
            "Android signer differs from the production signer")
    return {"releaseId": RELEASE, "tag": TAG, "sourceCommit": SOURCE, "build": 301,
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
