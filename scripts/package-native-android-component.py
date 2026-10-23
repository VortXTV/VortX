#!/usr/bin/env python3
"""Offline source/evidence packaging. No build, inspector, install, signing or publication."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import zipfile

CHUNK = 1024 * 1024
STAMP = 1792576565  # Original producer commit, not packaging wall-clock time.
ROOTS = {"dav1d", "ffmpeg", "fontconfig", "freetype", "fribidi", "harfbuzz", "libass",
         "libplacebo", "libunibreak", "libxml2", "lua", "mbedtls", "mpv"}
LICENSE_REQUIRED = {"deps/ffmpeg/COPYING.GPLv3", "deps/mpv/LICENSE.GPL", "deps/mbedtls/LICENSE",
                    "deps/lua/src/lua.h", "deps/libunibreak/src/linebreak.h"}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def stream_hash(stream):
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(CHUNK), b""):
        digest.update(block)
    return digest.hexdigest()


def file_hash(path):
    with path.open("rb") as stream:
        return stream_hash(stream)


def checked(path, expected, size=None):
    require(path.is_file() and not path.is_symlink(), "Missing/linked input: " + path.name)
    require(size is None or path.stat().st_size == size, "Input size mismatch: " + path.name)
    require(file_hash(path) == expected, "Input digest mismatch: " + path.name)
    return path


def encoded(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def git_blob(repo, commit, path, expected):
    require(re.fullmatch(r"[0-9a-f]{40}", commit) and
            re.fullmatch(r"(?:scripts|\.github)/[A-Za-z0-9_./-]+", path)
            and ".." not in path.split("/"), "Invalid immutable producer path")
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
               GIT_CONFIG_NOSYSTEM="1", GIT_NO_REPLACE_OBJECTS="1", LC_ALL="C")
    def read(*args):
        result = subprocess.run(["git", "-C", str(repo), *args], env=env,
                                capture_output=True, timeout=20, check=False)
        require(result.returncode == 0, "Cannot read pinned producer object: " + path)
        return result.stdout
    entry = read("ls-tree", "-z", commit, "--", path).decode().rstrip("\0")
    identity, name = entry.split("\t", 1)
    mode, kind, oid = identity.split()
    require(name == path and kind == "blob" and mode in {"100644", "100755"}, "Producer file identity")
    data = read("cat-file", "blob", oid)
    require(len(data) <= 4 * CHUNK and hashlib.sha256(data).hexdigest() == expected,
            "Producer file does not match original reviewed manifest: " + path)
    return data, int(mode[-3:], 8)


def source_index(archive):
    # Inspect nested source headers/licenses without extracting or executing upstream files.
    licenses, roots, count = {}, set(), 0
    with archive.open("android-corresponding-sources.tar.gz") as stream, tarfile.open(fileobj=stream, mode="r|gz") as source:
        for member in source:
            count += 1
            require(count <= 100000, "Source archive member bound")
            parts = member.name.rstrip("/").split("/")
            require(parts[0] == "deps" and not any(p in {"", ".", "..", ".git"} for p in parts), "Source root/path")
            if len(parts) > 1:
                roots.add(parts[1])
            if member.isfile() and (re.match(r"(?:LICENSE|COPYING|COPYRIGHT)", parts[-1], re.I)
                                    or member.name in LICENSE_REQUIRED):
                require(member.size <= CHUNK, "License member bound")
                licenses[member.name] = {"bytes": member.size, "sha256": stream_hash(source.extractfile(member))}
    require(roots == ROOTS and LICENSE_REQUIRED <= set(licenses), "Missing retained sources/licenses")
    with archive.open("original-upstream-source.tar.gz") as stream, tarfile.open(fileobj=stream, mode="r|gz") as publisher:
        for member in publisher:
            if member.name == "LICENSE" and member.isfile():
                require(member.size <= CHUNK, "Publisher license bound")
                licenses["publisher/LICENSE"] = {"bytes": member.size, "sha256": stream_hash(publisher.extractfile(member))}
    require("publisher/LICENSE" in licenses, "Missing publisher license")
    return {"sourceRoots": sorted(roots), "sourceMembers": count, "licenseFiles": licenses,
            "scope": "Retained source/license inventory, not a comprehensive legal or runtime acceptance"}


def package(args):
    config = json.loads(args.manifest.read_bytes())
    require(config["schema"] == 1 and config["repository"] == "VortXTV/VortX", "Component manifest")
    require(set(config["assets"]) == {"aar", "sources", "provenance", "checksums"} and
            len(set(config["assets"].values())) == 4 and
            all(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]+", name) for name in config["assets"].values()),
            "Exactly four unique flat output asset names are required")
    # Deliberately unfilled until the exact producer SDK notices are obtained and reviewed.
    notices = config["ndkNotices"]
    require(set(notices) == {"source.properties", "NOTICE", "NOTICE.toolchain"} and
            all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) for value in notices.values()),
            "Exact producer NDK30 notice hashes must be reviewed and frozen before packaging")
    for name, checksum in notices.items():
        checked(args.ndk_notices / name, checksum)
    properties = dict(line.split("=", 1) for line in (args.ndk_notices / "source.properties").read_text().splitlines() if "=" in line)
    require({key.strip(): value.strip() for key, value in properties.items()}.get("Pkg.Revision") == config["producerNDK"],
            "Runtime notices are not from the exact producer NDK")
    checked(args.source_notes, config["sourceNotesSHA256"])
    checked(args.release_notes, config["releaseNotesSHA256"])
    checked(args.artifact_zip, config["artifactSHA256"], config["artifactBytes"])
    checked(args.evidence, config["reinspectionEvidenceSHA256"])
    checked(args.reinspection, config["reinspectionProvenanceSHA256"])
    checked(args.validator, config["validatorSHA256"])
    evidence, receipt = json.loads(args.evidence.read_bytes()), json.loads(args.reinspection.read_bytes())
    require(evidence["aarSHA256"] == receipt["aarSHA256"] == config["aarSHA256"] and
            receipt["originalArchiveSHA256"] == config["artifactSHA256"] and
            receipt["originalBuildExit"] == 1 and receipt["originalCIReclassified"] is False and
            receipt["producerNDK"] == config["producerNDK"] and
            receipt["inspectionNDK"] == config["inspectionNDK"] and
            evidence["inspection"]["validatorSHA256"] == config["validatorSHA256"] and
            evidence["inspection"]["readerSHA256"] == config["readerSHA256"] and
            len(evidence["libraries"]) == 30, "Reinspection lineage mismatch")
    for value in (evidence, receipt):
        require(all(value[key] is False for key in ("promotionEligible", "runtimeSecurityTested", "appAndSeamBindingChanged")),
                "Reinspection must not grant app/runtime/publication acceptance")
    # Public projection omits both local reader filesystem paths; raw receipts stay private.
    inspection = {"aarSHA256": config["aarSHA256"], "inspectionNDK": config["inspectionNDK"],
                  "readerSHA256": config["readerSHA256"], "readerVersion": evidence["inspection"]["readerVersion"],
                  "validatorSHA256": config["validatorSHA256"], "libraries": evidence["libraries"],
                  "originalEvidenceSHA256": config["reinspectionEvidenceSHA256"],
                  "originalProvenanceSHA256": config["reinspectionProvenanceSHA256"],
                  "rawLocalPathsOmitted": True, "runtimeSecurityTested": False,
                  "appAndSeamBindingChanged": False, "promotionEligible": False}
    payload = {}
    with zipfile.ZipFile(args.artifact_zip) as archive:
        names = archive.namelist()
        expected = {"android-corresponding-sources.tar.gz", "artifact-sha256.json", "build.log",
                    "ffmpeg-applied.patch", "libmpv-release-candidate.aar", "original-upstream-source.tar.gz",
                    "python-toolchain.json", "result.json", "reviewed-inputs.sha256",
                    "tls_mbedtls_vortx_distrust.h", "toolchain.txt"} | {f"source-{n}.patch" for n in range(12)}
        require(len(names) == 23 and set(names) == expected, "Original artifact membership")
        manifest_bytes = archive.read("artifact-sha256.json")
        require(hashlib.sha256(manifest_bytes).hexdigest() == config["originalManifestSHA256"], "Original manifest")
        manifest = json.loads(manifest_bytes)
        require(set(manifest) == expected - {"artifact-sha256.json", "build.log"}, "Original hash coverage")
        for name, expected_hash in manifest.items():
            with archive.open(name) as stream:
                require(stream_hash(stream) == expected_hash, "Original member mismatch: " + name)
        require(manifest["android-corresponding-sources.tar.gz"] == config["dependencySourcesSHA256"] and
                manifest["original-upstream-source.tar.gz"] == config["publisherSourcesSHA256"] and
                manifest["libmpv-release-candidate.aar"] == config["aarSHA256"], "Source/AAR pin mismatch")
        original = json.loads(archive.read("result.json"))
        require(original["appSourceCommit"] == config["producerCommit"] and
                original["runId"] == config["producerRun"] and original["attempt"] == config["producerAttempt"] and
                original["buildExit"] == 1 and original["lane"] == "android" and
                original["sources"][0]["commit"] == config["publisherCommit"] and
                original["promotionEligible"] is False and original["runtimeSecurityTested"] is False, "Original failed producer receipt")
        reviewed = archive.read("reviewed-inputs.sha256")
        require(hashlib.sha256(reviewed).hexdigest() == config["originalInputManifestSHA256"], "Original reviewed inputs")
        inputs = {}
        for line in reviewed.decode().splitlines():
            checksum, path = line.split("  ", 1)
            require(path not in inputs and re.fullmatch(r"[0-9a-f]{64}", checksum), "Duplicate/invalid producer pin")
            inputs[path] = checksum
        require(len(inputs) == 18, "Original producer requires exactly eighteen input files")
        inputs["scripts/native-media-hosted/inputs.sha256"] = config["originalInputManifestSHA256"]
        inputs.update(config["producerWorkflows"])
        for path, checksum in inputs.items():
            payload["producer/" + path] = git_blob(args.repo, config["producerCommit"], path, checksum)
        payload["license-index.json"] = (encoded(source_index(archive)), 0o644)
        for name in ("result.json", "artifact-sha256.json", "reviewed-inputs.sha256"):
            payload["producer-evidence/" + name] = (archive.read(name), 0o644)
        require(archive.getinfo("libmpv-release-candidate.aar").file_size == config["aarBytes"], "AAR size")
        # Reserve a fresh output. Failures leave evidence for root; no cleanup/reuse/replacement.
        out = args.out.absolute()
        require(out.parent.is_dir() and out.parent.resolve() == out.parent, "Output parent must be real")
        out.mkdir(mode=0o700, exist_ok=False)
        aar = out / config["assets"]["aar"]
        with archive.open("libmpv-release-candidate.aar") as incoming, aar.open("xb") as outgoing:
            shutil.copyfileobj(incoming, outgoing, CHUNK)
    checked(aar, config["aarSHA256"], config["aarBytes"])
    payload["inspection/public-reinspection.json"] = (encoded(inspection), 0o644)
    payload["inspection/evidence.py"] = (args.validator.read_bytes(), 0o644)
    payload["packaging/package-native-android-component.py"] = (Path(__file__).read_bytes(), 0o644)
    payload["packaging/android-component-inputs.json"] = (args.manifest.read_bytes(), 0o644)
    payload["SOURCE-RECONSTRUCTION.md"] = (args.source_notes.read_bytes(), 0o644)
    payload["RELEASE-NOTES.md"] = (args.release_notes.read_bytes(), 0o644)
    for name in notices:
        payload["toolchain-notices/ndk-" + config["producerNDK"] + "/" + name] = ((args.ndk_notices / name).read_bytes(), 0o644)
    source_tar = out / config["assets"]["sources"]
    content = {}
    with source_tar.open("xb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=STAMP, compresslevel=1) as compressed:
        with tarfile.open(fileobj=compressed, mode="w|") as target:
            for name, (data, mode) in sorted(payload.items()):
                member = tarfile.TarInfo(name)
                member.size, member.mode, member.mtime = len(data), mode, STAMP
                target.addfile(member, io.BytesIO(data))
                content[name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "mode": oct(mode)}
            # The unchanged ZIP is the permanent source/evidence carrier: all 23 original files.
            name = "original-ci-artifact12338601965.zip"
            member = tarfile.TarInfo(name)
            member.size, member.mode, member.mtime = args.artifact_zip.stat().st_size, 0o644, STAMP
            with args.artifact_zip.open("rb") as incoming:
                target.addfile(member, incoming)
            content[name] = {"bytes": member.size, "sha256": config["artifactSHA256"], "mode": "0o644"}
    # Verify the new carrier's content and the original ZIP bytes after writing it.
    with tarfile.open(source_tar, "r:gz") as target:
        seen = set()
        for member in target:
            require(member.name in content and member.name not in seen and member.isfile(), "Packaged source membership")
            seen.add(member.name)
            row = content[member.name]
            require(member.size == row["bytes"] and member.mode == int(row["mode"], 8) and
                    stream_hash(target.extractfile(member)) == row["sha256"], "Packaged source content mismatch")
        require(seen == set(content), "Incomplete packaged source kit")
    provenance = {"schema": 1, "component": "Android Full libmpv", "releaseTag": config["tag"],
                  "releaseTargetCommit": config["producerCommit"], "prerelease": True, "makeLatest": False,
                  "producer": original, "producerNDK": config["producerNDK"],
                  "originalArtifactId": config["artifactId"], "originalArchiveSHA256": config["artifactSHA256"],
                  "originalBuildExit": 1, "originalCIReclassified": False, "inspection": inspection,
                  "sourceKitContent": content, "aar": {"name": aar.name, "bytes": aar.stat().st_size, "sha256": file_hash(aar)},
                  "sourceKit": {"name": source_tar.name, "bytes": source_tar.stat().st_size, "sha256": file_hash(source_tar)},
                  "producerNDKNotices": notices, "generatedFFmpegConfigsRetained": False, "nativeRebuilt": False, "appAndSeamBindingChanged": False,
                  "runtimeSecurityTested": False, "publicationApproved": False, "promotionEligible": False}
    (out / config["assets"]["provenance"]).write_bytes(encoded(provenance))
    rows = [file_hash(out / name) + "  " + name for key, name in config["assets"].items() if key != "checksums"]
    (out / config["assets"]["checksums"]).write_text("\n".join(sorted(rows)) + "\n")
    require({path.name for path in out.iterdir()} == set(config["assets"].values()), "Unexpected output asset")
    print(json.dumps({"status": "packaged-not-published", "assets": sorted(config["assets"].values()),
                      "aarSHA256": config["aarSHA256"], "originalCIReclassified": False}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("artifact-zip", "repo", "manifest", "evidence", "reinspection", "validator", "source-notes", "release-notes", "ndk-notices", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    package(parser.parse_args())
