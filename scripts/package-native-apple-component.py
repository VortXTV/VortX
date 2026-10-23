#!/usr/bin/env python3
"""Offline packaging only: never builds, installs, signs, uploads or executes upstream code."""
import argparse
import configparser
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import zipfile

CHUNK = 1024 * 1024
MAX_FILE = 512 * 1024 * 1024
MAX_ARCHIVE = 2 * 1024 * 1024 * 1024
STAMP = 1792571180  # Producer commit timestamp, 2026-10-21 08:26:20 UTC.


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    with path.open("rb") as stream:
        return stream_digest(stream)


def stream_digest(stream):
    h = hashlib.sha256()
    for data in iter(lambda: stream.read(CHUNK), b""):
        h.update(data)
    return h.hexdigest()


def checked(path, expected, size=None):
    require(path.is_file() and not path.is_symlink(), "missing/linked input: " + str(path))
    require(size is None or path.stat().st_size == size, "input size mismatch: " + path.name)
    require(digest(path) == expected, "input digest mismatch: " + path.name)
    return path


def relative(name):
    require(bool(name) and not name.startswith("/") and "\\" not in name
            and not any(ord(c) < 32 for c in name), "unsafe archive name")
    parts = name.rstrip("/").split("/")
    require(all(p not in ("", ".", "..", ".git") for p in parts), "unsafe archive components")
    return PurePosixPath(*parts)


def link_ok(name, target):
    require(target and not target.startswith("/") and "\\" not in target
            and not any(ord(c) < 32 for c in target), "unsafe link")
    value = posixpath.normpath(posixpath.join(str(PurePosixPath(name).parent), target))
    require(value != ".." and not value.startswith("../"), "link escapes payload")


def ensure_parent(path, root):
    require(path.is_relative_to(root), "path escapes destination")
    for parent in path.parents:
        if parent == root:
            break
        require(not parent.is_symlink(), "linked parent")
    path.parent.mkdir(parents=True, exist_ok=True)


def extract_source(archive, destination, strip_root):
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:*") as source:
        members = source.getmembers()
        require(len(members) <= 100000, "too many source entries")
        seen, selected, total = set(), [], 0
        for member in members:
            original = relative(member.name)
            parts = original.parts
            if strip_root:
                require(parts[0] == strip_root, "unexpected upstream archive root")
                parts = parts[1:]
                if not parts:
                    require(member.isdir(), "non-directory archive root")
                    continue
            name = str(PurePosixPath(*parts))
            require(name.casefold() not in seen, "duplicate/case-colliding source entry")
            seen.add(name.casefold())
            require(member.isdir() or member.isfile() or member.issym(), "unsupported source entry")
            require(0 <= member.size <= MAX_FILE, "oversized source entry")
            total += member.size
            require(total <= MAX_ARCHIVE, "oversized source archive")
            if member.issym():
                link_ok(name, member.linkname)
            selected.append((name, member))
        # Links last: no regular file can be written through an archive-created linked parent.
        for name, member in sorted(selected, key=lambda row: (row[1].issym(), row[0])):
            path = destination / name
            ensure_parent(path, destination)
            if member.isdir():
                path.mkdir(exist_ok=True)
                os.chmod(path, member.mode & 0o777)
            elif member.isfile():
                require(not path.exists() and not path.is_symlink(), "refuse source overwrite")
                with source.extractfile(member) as incoming, path.open("xb") as outgoing:
                    shutil.copyfileobj(incoming, outgoing, CHUNK)
                os.chmod(path, member.mode & 0o777)
            else:
                require(not path.exists() and not path.is_symlink(), "refuse linked overwrite")
                path.symlink_to(member.linkname)


def inventory(root):
    rows = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in list(dirs):
            if (Path(directory) / name).is_symlink():
                files.append(name)
                dirs.remove(name)
        for name in files:
            path = Path(directory) / name
            key = str(path.relative_to(root).as_posix())
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                target = os.readlink(path)
                link_ok(key, target)
                rows[key] = {"kind": "symlink", "mode": stat.S_IMODE(info.st_mode), "target": target}
            else:
                require(stat.S_ISREG(info.st_mode), "unexpected filesystem object")
                rows[key] = {"kind": "file", "mode": stat.S_IMODE(info.st_mode),
                             "bytes": info.st_size, "sha256": digest(path)}
    return rows


def save(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def patch_paths(patch):
    values = []
    for line in patch.read_text().splitlines():
        if line.startswith("--- a/"):
            values.append(str(relative(line[6:])))
    require(values and len(values) == len(set(values)), "unexpected tracked receipt patch paths")
    return values


def apply_patch(tree, patch, commands):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update({"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CEILING_DIRECTORIES": str(tree.parent.resolve()), "LC_ALL": "C"})
    # No .git directories/indices, checkout, reset or build command is created or used.
    for flags in (["--check"], []):
        argv = ["git", "-c", "core.autocrlf=false", "apply", *flags, str(patch.resolve())]
        result = subprocess.run(argv, cwd=tree, env=env, text=True, capture_output=True, timeout=30)
        with commands.open("a") as stream:
            stream.write(json.dumps({"tree": tree.name, "patch": patch.name, "check": bool(flags),
                                     "exit": result.returncode}) + "\n")
        require(result.returncode == 0, "source patch rejected: " + patch.name + ": " + result.stderr[:2000])


def control_tree(component, receipt, control, commands):
    require(not control.exists(), "control directory already exists")
    control.mkdir()
    for name in patch_paths(receipt):
        source = component / name
        require(source.is_file() and not source.is_symlink(), "receipt source is not a regular file")
        target = control / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    apply_patch(control, receipt, commands)
    return inventory(control)


def check_delta(component, before, expected, new_paths):
    after = inventory(component)
    for name, old in before.items():
        require(after.get(name) == expected.get(name, old), "tracked source mismatch: " + name)
    require(set(after) - set(before) == set(new_paths), "unexpected added source paths")
    return after


def unwrap_evidence(archive, out, config):
    checked(archive, config["producer"]["artifactSHA256"], config["producer"]["artifactBytes"])
    out.mkdir()
    with zipfile.ZipFile(archive) as original:
        names = original.namelist()
        require(len(names) == len(set(names)) and set(names) == set(config["artifactMembers"]),
                "unexpected original artifact membership")
        for name in names:
            relative(name)
            item = original.getinfo(name)
            require(item.file_size <= MAX_ARCHIVE and not item.is_dir(), "unexpected evidence entry")
            with original.open(item) as incoming, (out / name).open("xb") as target:
                shutil.copyfileobj(incoming, target, CHUNK)
    for name, value in config["originalArchives"].items():
        checked(out / name, value)
    require(json.loads((out / "artifact-sha256.json").read_text()) == config["originalArchives"],
            "original hash manifest changed")
    receipt = json.loads((out / "result.json").read_text())
    require(receipt["appSourceCommit"] == config["producer"]["commit"]
            and int(receipt["runId"]) == config["producer"]["runId"]
            and int(receipt["attempt"]) == config["producer"]["attempt"]
            and receipt["lane"] == "apple" and receipt["buildExit"] == 0
            and receipt["promotionEligible"] is False and receipt["runtimeSecurityTested"] is False,
            "original receipt is not the admitted unpromoted Apple candidate")
    wanted = {x["commit"] for x in config["sources"] if not x.get("destination")}
    require({x["commit"] for x in receipt["sources"]} == wanted, "component pin mismatch")


def player_zip(tar_path, output):
    expected = {}
    with tarfile.open(tar_path, "r:gz") as payload, zipfile.ZipFile(
            output, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as target:
        seen, total = set(), 0
        for member in payload:
            parts = relative(member.name).parts
            require(parts[0] == "MPVKit-DVFEL", "unexpected package root")
            if len(parts) == 1:
                require(member.isdir(), "invalid package root")
                continue
            name = str(PurePosixPath(*parts[1:]))
            require(name.split("/")[0] in ("artifacts", "Sources", "Package.swift", ".gitignore"),
                    "unexpected top-level package object")
            require(name.casefold() not in seen, "duplicate/case-colliding package object")
            seen.add(name.casefold())
            require(member.isdir() or member.isfile() or member.issym(), "unsupported package object")
            total += member.size
            require(0 <= member.size <= MAX_FILE and total <= MAX_ARCHIVE, "package bound exceeded")
            z = zipfile.ZipInfo(name + ("/" if member.isdir() else ""), (2026, 10, 21, 8, 26, 20))
            z.create_system = 3
            kind = stat.S_IFDIR if member.isdir() else stat.S_IFLNK if member.issym() else stat.S_IFREG
            z.external_attr = ((kind | (member.mode & 0o777)) << 16) | (0x10 if member.isdir() else 0)
            z.compress_type = zipfile.ZIP_DEFLATED
            if member.isdir():
                target.writestr(z, b"")
                expected[name] = {"kind": kind, "mode": member.mode & 0o777,
                                  "sha256": hashlib.sha256(b"").hexdigest()}
            elif member.issym():
                link_ok(name, member.linkname)
                data = member.linkname.encode()
                target.writestr(z, data)
                expected[name] = {"kind": kind, "mode": member.mode & 0o777,
                                  "sha256": hashlib.sha256(data).hexdigest()}
            else:
                h = hashlib.sha256()
                with payload.extractfile(member) as source, target.open(z, "w") as dest:
                    for block in iter(lambda: source.read(CHUNK), b""):
                        h.update(block)
                        dest.write(block)
                expected[name] = {"kind": kind, "mode": member.mode & 0o777, "sha256": h.hexdigest()}
    actual = {}
    with zipfile.ZipFile(output) as result:
        for item in result.infolist():
            with result.open(item) as stream:
                actual[item.filename.rstrip("/")] = {"kind": stat.S_IFMT(item.external_attr >> 16),
                                                      "mode": (item.external_attr >> 16) & 0o777,
                                                      "sha256": stream_digest(stream)}
    require(actual == expected and "Package.swift" in actual, "player ZIP content/mode/link mismatch")
    return expected


def source_tar(source, output):
    with output.open("xb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.PAX_FORMAT) as target:
            for path in sorted(source.rglob("*")):
                name = str(path.relative_to(source).as_posix())
                info = target.gettarinfo(str(path), arcname=name)
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = STAMP
                if info.isfile():
                    with path.open("rb") as stream:
                        target.addfile(info, stream)
                else:
                    target.addfile(info)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-zip", type=Path, required=True)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.manifest.read_text())
    require(config["schema"] == 1, "unsupported source input schema")
    inputs, out = args.inputs.resolve(), args.out.absolute()
    require(out.parent.is_dir() and not out.exists() and not out.is_symlink(), "output must be new")
    require(not out.is_relative_to(inputs) and not inputs.is_relative_to(out), "input/output overlap")
    for row in config["sources"]:
        if row.get("archive"):
            checked(inputs / row["archive"], row["sha256"], row["bytes"])
    for row in config["producerFiles"]:
        checked(inputs / row["input"], row["sha256"])
    checked(inputs / config["derivedContext"]["input"], config["derivedContext"]["sha256"])
    checked(args.artifact_zip, config["producer"]["artifactSHA256"], config["producer"]["artifactBytes"])
    out.mkdir()
    evidence = out / "original-evidence"
    unwrap_evidence(args.artifact_zip, evidence, config)
    source = out / "source-payload"
    source.mkdir()
    packaged_inputs = source / "inputs"
    producer, components = packaged_inputs / "producer", source / "components"
    for row in config["producerFiles"]:
        target = producer / row["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(inputs / row["input"], target)
        os.chmod(target, row["mode"])
    for row in config["sources"]:
        archive = evidence / row["artifactMember"] if row.get("artifactMember") else inputs / row["archive"]
        target = components / row["component"]
        if row.get("destination"):
            target = target / row["destination"]
        extract_source(archive, target, row["stripRoot"])
    submodules = configparser.ConfigParser()
    submodules.read(components / "libplacebo/.gitmodules")
    require({submodules[s]["path"] for s in submodules.sections()} ==
            {r["destination"] for r in config["sources"] if r.get("destination")},
            "libplacebo gitlink closure mismatch")
    before = {name: inventory(components / name) for name in ("MPVKit", "mpv", "ffmpeg", "libplacebo")}
    controls, commands = out / "tracked-controls", out / "packaging-commands.jsonl"
    controls.mkdir()
    expected = {name: control_tree(components / name, evidence / config["receiptSourceFiles"][name],
                                  controls / name, commands) for name in ("MPVKit", "mpv", "ffmpeg")}
    apply_patch(components / "MPVKit", producer / "scripts/mpvkit-dvfel.patch", commands)
    copied = [
        ("mpv-moltenvk-resize.patch", "0004-moltenvk-context-check-events-resize.patch"),
        ("mpv-coreaudio-hotplug-lifecycle.patch", "0005-coreaudio-hotplug-lifecycle.patch"),
        ("mpv-http-seek-interrupt.patch", "0006-http-seek-interrupt.patch")]
    patchdir = components / "MPVKit/Sources/BuildScripts/patch/libmpv"
    for src, name in copied:
        target = patchdir / name
        require(not target.exists(), "copied patch already present")
        shutil.copyfile(producer / ("scripts/" + src), target)
        os.chmod(target, 0o644)
    patches = sorted(patchdir.glob("*.patch"))
    require(len(patches) == 6 and [p.name[:4] for p in patches] ==
            ["0001", "0002", "0003", "0004", "0005", "0006"], "unexpected mpv patch set")
    for patch in patches:
        apply_patch(components / "mpv", patch, commands)
    apply_patch(components / "ffmpeg", evidence / "source-3.patch", commands)
    context = "video/out/vulkan/context_moltenvk.m"
    checked(components / "mpv" / context, config["derivedContext"]["sha256"])
    trees = {
        "MPVKit": check_delta(components / "MPVKit", before["MPVKit"], expected["MPVKit"],
                              ["Sources/BuildScripts/patch/libmpv/" + name for _, name in copied]),
        "mpv": check_delta(components / "mpv", before["mpv"], expected["mpv"], [context]),
        "ffmpeg": check_delta(components / "ffmpeg", before["ffmpeg"], expected["ffmpeg"], []),
        "libplacebo": check_delta(components / "libplacebo", before["libplacebo"], {}, [])}
    # Retain original source archives, not only a newly materialized snapshot.
    archives = packaged_inputs
    archives.mkdir(exist_ok=True)
    derived = archives / config["derivedContext"]["input"]
    derived.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(inputs / config["derivedContext"]["input"], derived)
    for row in config["sources"]:
        original = evidence / row["artifactMember"] if row.get("artifactMember") else inputs / row["archive"]
        shutil.copyfile(original, archives / original.name)
    receipt_dir = source / "evidence"
    receipt_dir.mkdir()
    for name in config["artifactMembers"]:
        if name not in ("apple-candidate.tar.gz", "apple-original-library-zips.tar", "build.log",
                        "original-upstream-source.tar.gz"):
            shutil.copyfile(evidence / name, receipt_dir / name)
    shutil.copyfile(args.manifest, source / "source-inputs.json")
    packaging = source / "packaging"
    packaging.mkdir()
    shutil.copyfile(Path(__file__), packaging / "package-native-apple-component.py")
    save(source / "source-trees.json", trees)
    licenses = {name: [p for p in tree if re.match(r"(?i)^(license|copying|notice|copyright)",
                                                    Path(p).name)] for name, tree in trees.items()}
    require(all(licenses.values()), "component license evidence missing")
    save(source / "license-index.json", licenses)
    player = out / "mpvkit-dvfel-ffmpeg-9.0.2-candidate.zip"
    payload = player_zip(evidence / "apple-candidate.tar.gz", player)
    save(out / "player-content-manifest.json", payload)
    with tarfile.open(evidence / "apple-candidate.tar.gz") as archive:
        manifest = archive.extractfile("MPVKit-DVFEL/Package.swift").read().decode()
    require(hashlib.sha256(manifest.encode()).hexdigest() == config["packageManifestSHA256"],
            "original package manifest mismatch")
    externals = re.findall(r'name:\s*"([^"]+)",\s*url:\s*"([^"]+)",\s*checksum:\s*"([0-9a-f]{64})"',
                           manifest)
    external_rows = [{"target": n, "url": u, "sha256": h, "rebuiltByThisCandidate": False}
                     for n, u, h in externals]
    require(external_rows == config["externalBinaryInputs"], "external binary declaration mismatch")
    save(source / "external-binary-inputs.json", external_rows)
    (source / "REPRODUCTION.md").write_text(
        "This is source/packaging correspondence, not a native build or bit-reproducibility receipt.\n"
        "Four patched component snapshots, all six pinned libplacebo submodules, exact original archives,\n"
        "licenses, app producer scripts and original evidence are included. No .git checkout was made.\n"
        "For an authorized source rebuild use inputs/producer/scripts/build-mpvkit-dvfel.sh from the admitted\n"
        "app source with the existing canonical MPVKit Git checkout at its recorded pin; the original\n"
        "builder fetches exact dependency commits and checks patch state. Toolchain versions are in\n"
        "evidence/toolchain.txt. Original immutable URLs and archive hashes are in source-inputs.json.\n"
        "Remote binary dependencies are separately checksum-pinned in external-binary-inputs.json;\n"
        "they were not rebuilt or upgraded here. Preserve their upstream license/source obligations.\n"
        "The full new context_moltenvk.m is reconstructed from MPVKit0001 plus app0004, not recovered\n"
        "from a nonexistent original untracked-file hash. Do not describe the thin MPVKit baseline\n"
        "alone as the complete source archive. No app engine/private source, credentials or signer data.\n")
    source_archive = out / "mpvkit-dvfel-ffmpeg-9.0.2-correspondence.tar.gz"
    source_tar(source, source_archive)
    original_asset = out / "original-ci-artifact-12333961054.zip"
    shutil.copyfile(args.artifact_zip, original_asset)
    checked(original_asset, config["producer"]["artifactSHA256"], config["producer"]["artifactBytes"])
    provenance = {"schema": 1, "producer": config["producer"],
        "packagerSHA256": digest(Path(__file__)), "sourceInputsSHA256": digest(args.manifest),
        "python": sys.version, "originalCIArchive": original_asset.name,
        "playerZIP": {"name": player.name, "sha256": digest(player), "bytes": player.stat().st_size},
        "sourceArchive": {"name": source_archive.name, "sha256": digest(source_archive),
                          "bytes": source_archive.stat().st_size},
        "componentSourcesAndSubmodules": config["sources"], "derivedContext": config["derivedContext"],
        "upstreamCodeExecuted": False, "nativeBuildExecuted": False, "binaryGateReexecuted": False,
        "runtimeSecurityTested": False, "appCompatibilityAccepted": False, "promotionEligible": False}
    save(out / "component-provenance.json", provenance)
    outputs = [player, source_archive, original_asset, out / "component-provenance.json", out / "player-content-manifest.json"]
    (out / "SHA256SUMS").write_text("".join(digest(p) + "  " + p.name + "\n" for p in outputs))
    print(json.dumps({"status": "packaged-only", "output": str(out), "promotionEligible": False}))


if __name__ == "__main__":
    main()
