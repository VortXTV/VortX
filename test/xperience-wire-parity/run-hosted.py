#!/usr/bin/env python3
"""Explicit hosted-only experiment. Reading this source launches no subprocesses."""
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time

REPOSITORY = "VortXTV/VortX"
REF = "refs/heads/beta-xperience-wire-parity-20261030"
HEX = re.compile(r"[0-9a-f]{64}")
ID = re.compile(r"[a-z0-9-]{1,80}")
LOG_LIMIT = 256 * 1024


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def emit(kind, value):
    # Only fixed source/corpus/compiler metadata and synthetic case diagnostics.
    print(json.dumps({"kind": kind, **value}, sort_keys=True, ensure_ascii=True), flush=True)


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def terminate_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
    # A compiler child must not survive a normally exited parent either.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def run_child(label, command, seconds, run_dir, environment):
    started = time.monotonic()
    process = subprocess.Popen(command, cwd=run_dir, env=environment,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    output = bytearray()
    failure = None
    try:
        while selector.get_map():
            if time.monotonic() - started > seconds:
                failure = "deadline"
                break
            for key, _ in selector.select(timeout=0.25):
                chunk = os.read(key.fd, 8192)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                if len(output) + len(chunk) > LOG_LIMIT:
                    failure = "diagnostic-limit"
                    break
                output.extend(chunk)
            if failure:
                break
        if not failure:
            process.wait(timeout=max(0.1, seconds - (time.monotonic() - started)))
    except subprocess.TimeoutExpired:
        failure = "deadline"
    finally:
        terminate_group(process)
        selector.close()
        process.stdout.close()
    log_path = run_dir / (label + ".log")
    log_path.write_bytes(output)
    record = {"label": label, "exit": process.returncode, "failure": failure,
              "seconds": round(time.monotonic() - started, 3), "logBytes": len(output),
              "logSHA256": digest(output)}
    write_json(run_dir / (label + ".json"), record)
    emit("child", record)
    if failure or process.returncode != 0:
        # Synthetic compiler diagnostics only, bounded to 16 KiB in the job log.
        print(bytes(output[:16384]).decode("utf-8", errors="replace"), flush=True)
        raise RuntimeError(label + " did not complete successfully")
    return bytes(output)


def read_owner(root, item, maximum=256 * 1024):
    relative = Path(item["path"])
    require(not relative.is_absolute() and ".." not in relative.parts, "unsafe source path")
    path = root / relative
    require(not path.is_symlink() and path.is_file(), "source missing or symlinked")
    data = path.read_bytes()
    require(len(data) <= maximum and digest(data) == item["sha256"], "whole source pin mismatch: " + item["path"])
    return data


def literal_span(owner, item):
    start = item["start"].encode("utf-8")
    end = item["endBefore"].encode("utf-8")
    require(owner.count(start) == 1 and owner.count(end) == 1, "missing or ambiguous declaration boundaries")
    begin = owner.index(start)
    finish = owner.index(end)
    require(begin < finish and owner[finish - 1:finish] == b"}", "declaration boundary order changed")
    # Newline included in the reviewed sed line-span hash; no declaration edits.
    span = owner[begin:finish] + b"\n"
    require(digest(span) == item["spanSHA256"], "literal declaration span pin mismatch")
    require(owner[begin:finish + 1] == span, "literal span is not source-equivalent")
    return begin, span


def file_identity(path, maximum=512 * 1024 * 1024):
    resolved = path.resolve(strict=True)
    require(resolved.is_file() and 0 < resolved.stat().st_size <= maximum, "toolchain file missing or over hash budget")
    checksum = hashlib.sha256()
    total = 0
    with resolved.open("rb") as source:
        while True:
            block = source.read(1024 * 1024)
            if not block:
                break
            total += len(block)
            require(total <= maximum, "toolchain changed during bounded hash read")
            checksum.update(block)
    require(total == resolved.stat().st_size, "toolchain changed during hash read")
    return {"path": str(path), "resolved": str(resolved), "bytes": total, "sha256": checksum.hexdigest()}


def installed_jdk(major, environment, run_dir):
    variable = "JAVA_HOME_" + str(major) + "_arm64"
    configured = environment.get(variable)
    require(configured and Path(configured).is_absolute(), "required preinstalled " + variable + " unavailable")
    home = Path(configured).resolve(strict=True)
    java = home / "bin/java"
    version = run_child("java-" + str(major) + "-version", [str(java), "-version"], 15, run_dir, environment).decode().strip()
    match = re.search(r'version "([0-9]+)(?:\.|\")', version)
    require(match and int(match.group(1)) == major, "preinstalled runtime major changed: " + variable)
    release = home / "release"
    require(release.stat().st_size <= 16384, "JDK release metadata budget")
    metadata = release.read_text(encoding="utf-8")
    require(re.search(r'^OS_ARCH="(?:aarch64|arm64)"$', metadata, re.MULTILINE), "preinstalled JDK architecture changed")
    files = {name: file_identity(home / name) for name in
             ("bin/java", "lib/libjli.dylib", "lib/server/libjvm.dylib", "lib/modules", "release")}
    return {"major": major, "variable": variable, "home": str(home), "version": version[:2048], "files": files}


def kotlin_layout_candidate(home):
    library = home / "lib"
    launcher = home / "bin/kotlinc"
    report = {"home": str(home)[:1024], "library": str(library)[:1024], "compilerLauncher": str(launcher)[:1024],
              "jarCount": 0, "jarCountComplete": True, "jarBytes": 0, "jarBytesComplete": True,
              "directoryEntries": 0, "requiredPresent": [], "qualifies": False, "reasons": []}
    jars = []
    try:
        if not library.is_dir():
            report["reasons"].append("library-directory-missing")
        else:
            with os.scandir(library) as entries:
                for entry in entries:
                    report["directoryEntries"] += 1
                    if report["directoryEntries"] > 256:
                        report["reasons"].append("directory-entry-budget")
                        report["jarCountComplete"] = False
                        break
                    if entry.name.endswith(".jar"):
                        jars.append(Path(entry.path))
                        if len(jars) > 96:
                            report["reasons"].append("jar-count-budget")
                            report["jarCountComplete"] = False
                            break
        jars.sort()
        report["jarCount"] = len(jars)
        if not 1 <= len(jars) <= 96:
            report["reasons"].append("jar-count-budget")
        for path in jars:
            size = path.stat().st_size
            report["jarBytes"] += size
            if not path.is_file() or not 0 < size <= 128 * 1024 * 1024:
                report["reasons"].append("jar-file-budget-or-type")
        report["jarBytesComplete"] = report["jarCountComplete"]
        if report["jarBytes"] > 512 * 1024 * 1024:
            report["reasons"].append("jar-aggregate-budget")
        required = {"kotlin-compiler.jar", "kotlin-stdlib.jar", "kotlin-reflect.jar"}
        report["requiredPresent"] = sorted(required.intersection(path.name for path in jars))
        if len(report["requiredPresent"]) != len(required):
            report["reasons"].append("required-jars-missing")
        if not launcher.is_file() or not 0 < launcher.stat().st_size <= 1024 * 1024:
            report["reasons"].append("compiler-launcher-missing-or-budget")
    except OSError as error:
        report["reasons"].append("filesystem-error")
        report["filesystemError"] = {"type": type(error).__name__, "errno": error.errno}
        report["jarCount"] = len(jars)
        report["jarCountComplete"] = False
        report["jarBytesComplete"] = False
    report["reasons"] = sorted(set(report["reasons"]))
    report["qualifies"] = not report["reasons"]
    return report, jars


def installed_kotlin(environment):
    configured = shutil.which("kotlinc", path=environment.get("PATH"))
    discovery = {"originalLauncher": str(configured)[:1024] if configured else None,
                 "resolvedLauncher": None, "candidates": []}
    if not configured:
        emit("kotlin-layout-discovery", discovery)
        require(False, "preinstalled Kotlin compiler unavailable")
    try:
        launcher = Path(configured).resolve(strict=True)
    except OSError as error:
        discovery["launcherError"] = {"type": type(error).__name__, "errno": error.errno}
        emit("kotlin-layout-discovery", discovery)
        require(False, "preinstalled Kotlin launcher cannot be resolved")
    discovery["resolvedLauncher"] = str(launcher)[:1024]
    if launcher.name != "kotlinc" or launcher.parent.name != "bin":
        emit("kotlin-layout-discovery", discovery)
        require(False, "unrecognized preinstalled Kotlin layout")
    prefix = launcher.parent.parent
    candidates = [(home, *kotlin_layout_candidate(home)) for home in (prefix, prefix / "libexec")]
    discovery["candidates"] = [report for _, report, _ in candidates]
    emit("kotlin-layout-discovery", discovery)
    valid = [(home, jars) for home, report, jars in candidates if report["qualifies"]]
    require(len(valid) == 1, "preinstalled Kotlin layout requires exactly one complete bounded candidate")
    home, jars = valid[0]
    files = {path.name: file_identity(path, 128 * 1024 * 1024) for path in jars}
    entries = [record["resolved"] for record in files.values()]
    require(all(entry and os.pathsep not in entry and not any(c in entry for c in ("\x00", "\n", "\r", "*")) for entry in entries),
            "unsafe explicit Kotlin classpath entry")
    require(len({entry.casefold() for entry in entries}) == len(entries), "duplicate resolved Kotlin classpath path")
    identities = [(Path(entry).stat().st_dev, Path(entry).stat().st_ino) for entry in entries]
    require(len(set(identities)) == len(entries), "duplicate physical Kotlin classpath jar")
    original_identity = file_identity(Path(configured), 1024 * 1024)
    compiler_identity = file_identity(home / "bin/kotlinc", 1024 * 1024)
    return {"home": str(home), "launcher": original_identity, "compilerLauncher": compiler_identity,
            "launcherDiffersFromCompilerLauncher": original_identity["resolved"] != compiler_identity["resolved"],
            "layoutDiscovery": discovery, "libraries": files,
            "classpathEntries": entries, "classpath": os.pathsep.join(entries), "classpathSuffixPolicy": "lowercase .jar only"}


def exact_kotlin_classpath(kotlin):
    records = list(kotlin["libraries"].values())
    require([record["resolved"] for record in records] == kotlin["classpathEntries"], "Kotlin classpath inventory order changed")
    require(os.pathsep.join(kotlin["classpathEntries"]) == kotlin["classpath"], "Kotlin classpath manifest join changed")
    for record in records:
        require(file_identity(Path(record["path"]), 128 * 1024 * 1024) == record, "Kotlin classpath jar identity changed before use")
    return kotlin["classpath"]


def corpus_cases(path):
    data = path.read_bytes()
    require(len(data) <= 128 * 1024, "corpus byte limit")
    cases = []
    for line in data.decode("utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t", 2)
        require(len(fields) == 3 and ID.fullmatch(fields[0]), "invalid corpus row")
        raw = fields[2].encode("utf-8")
        require(0 < len(raw) <= 4096, "case byte limit")
        cases.append({"id": fields[0], "expected": fields[1], "bytes": len(raw), "sha256": digest(raw)})
    require(1 <= len(cases) <= 64 and len({x["id"] for x in cases}) == len(cases), "corpus count or duplicate ID")
    return data, cases


def read_results(directory, cases):
    report = directory / "results.tsv"
    require(report.stat().st_size <= 32 * 1024, "result report budget")
    rows = [line.split("\t") for line in report.read_text(encoding="utf-8").splitlines()]
    require(len(rows) == len(cases), "missing or extra results")
    results = {}
    for row, case in zip(rows, cases):
        require(len(row) == 6 and row[0] == case["id"] and row[5] == case["sha256"], "result/input identity mismatch")
        require(row[1] == "ACCEPTED" or re.fullmatch(r"[A-Z_]{1,40}", row[1]), "invalid result category")
        record = {"id": row[0], "category": row[1], "bytes": int(row[2]), "sha256": row[3], "fingerprint": row[4]}
        if row[1] == "ACCEPTED":
            canonical = (directory / (row[0] + ".canonical")).read_bytes()
            require(len(canonical) <= 512 * 1024 and len(canonical) == record["bytes"], "canonical size mismatch")
            require(HEX.fullmatch(row[3]) and row[3] == digest(canonical) == row[4], "canonical digest/fingerprint mismatch")
        else:
            require(row[2:5] == ["0", "-", "-"] and not (directory / (row[0] + ".canonical")).exists(), "rejected result has canonical output")
        results[row[0]] = record
    return results


def main():
    # This guard precedes reads, output directories and every child call.
    require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("GITHUB_REPOSITORY") == REPOSITORY
            and os.environ.get("GITHUB_REF") == REF and os.environ.get("GITHUB_EVENT_NAME") == "push",
            "hosted exact-repository/ref push guard: local execution is disabled")
    require(os.environ.get("RUNNER_OS") == "macOS" and os.environ.get("RUNNER_ARCH") == "ARM64", "expected standard macos-26 ARM runner")
    event_path = Path(os.environ["GITHUB_EVENT_PATH"])
    require(event_path.stat().st_size <= 4 * 1024 * 1024, "push payload byte limit")
    event = json.loads(event_path.read_text(encoding="utf-8"))
    require(event.get("repository", {}).get("private") is False
            and event.get("repository", {}).get("full_name") == REPOSITORY
            and event.get("ref") == REF, "public exact-repository/ref push payload required")
    root = Path(__file__).resolve().parents[2]
    fixture = root / "test/xperience-wire-parity"
    pins = json.loads((fixture / "source-pins.json").read_text(encoding="utf-8"))
    require(pins["schema"] == 2 and pins["repository"] == REPOSITORY and pins["ref"] == REF, "manifest identity mismatch")
    require(pins["reviewState"] == "ROOT_AND_INDEPENDENT_SOURCE_SECURITY_REVIEWED", "source/security review remains unfinished")
    for key in ("appleDomain", "appleJSON", "androidDomain", "androidJSON"):
        require(HEX.fullmatch(pins[key]["sha256"]), "unfinished source pin: " + key)
    model = pins["finalModel"]
    require(type(model["version"]) is int and model["version"] > 0
            and model["packet"] == "android-xperience-domain-source-v" + str(model["version"])
            and model["reviewState"] == "SOURCE_SECURITY_REVIEWED"
            and HEX.fullmatch(model["frozenReceiptSHA256"])
            and HEX.fullmatch(model["reviewReceiptSHA256"])
            and model["domainSourceSHA256"] == pins["androidDomain"]["sha256"],
            "actual final-model version/source/frozen/review identity remains unfinished")
    require(pins["hostToolchain"]["kotlinVersion"] == "2.4.21"
            and pins["hostToolchain"]["requiredJDKMajors"] == [17, 21]
            and pins["hostToolchain"]["requiredJDKEnvironment"] == ["JAVA_HOME_17_arm64", "JAVA_HOME_21_arm64"]
            and pins["hostToolchain"]["compileJDKMajor"] == 21
            and pins["hostToolchain"]["bytecodeTarget"] == 17
            and pins["hostToolchain"]["downloadOrInstallPermitted"] is False, "unreviewed host toolchain requirements")
    require(HEX.fullmatch(pins["appleJSON"]["spanSHA256"]) and HEX.fullmatch(pins["androidJSON"]["spanSHA256"]), "unfinished literal-span pins")
    source = {key: read_owner(root, pins[key]) for key in ("appleDomain", "appleJSON", "androidDomain", "androidJSON")}
    apple_begin, apple_span = literal_span(source["appleJSON"], pins["appleJSON"])
    android_begin, android_span = literal_span(source["androidJSON"], pins["androidJSON"])
    actual_import = pins["appleJSON"]["actualImportPrefix"].encode("utf-8")
    require(actual_import == b"import Foundation\n" and source["appleJSON"].startswith(actual_import) and apple_begin > len(actual_import), "Apple actual import changed")
    android_preamble = source["androidJSON"][:android_begin]
    require(digest(android_preamble) == pins["androidJSON"]["preambleSHA256"], "Android actual package/import preamble changed")
    corpus_data, cases = corpus_cases(fixture / "corpus.tsv")
    runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve()
    require(runner_temp.is_dir(), "runner temporary directory unavailable")
    run_dir = Path(tempfile.mkdtemp(prefix="xperience-wire-parity-", dir=runner_temp))
    environment = os.environ.copy()
    environment.update({"OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1", "VECLIB_MAXIMUM_THREADS": "1",
                        "SWIFT_MODULE_CACHE_PATH": str(run_dir / "swift-module-cache"),
                        "CLANG_MODULE_CACHE_PATH": str(run_dir / "clang-module-cache")})
    graph = {"commit": os.environ.get("GITHUB_SHA"), "repository": REPOSITORY, "ref": REF,
             "domainBodiesUnmodified": True, "declarationTransformations": [],
             "appleExcludedOwnerImport": "VortxEngine (not referenced by the extracted enum)",
             "sources": {key: {"path": pins[key]["path"], "bytes": len(data), "sha256": digest(data)} for key, data in source.items()},
             "literalSpans": {"VortxJSON": digest(apple_span), "OHJson": digest(android_span)},
             "androidPreambleSHA256": digest(android_preamble), "finalModel": model,
             "corpusSHA256": digest(corpus_data), "corpusCases": len(cases), "runDirectory": str(run_dir)}
    generated = {"VortxJSON.swift": actual_import + b"\n" + apple_span,
                 "XperienceCollections.swift": source["appleDomain"],
                 "OHJson.kt": android_preamble + android_span,
                 "XperienceCollections.kt": source["androidDomain"]}
    for name, data in generated.items():
        (run_dir / name).write_bytes(data)
    # Read back bytes and compare all copied bodies and declaration slices before compiling.
    require((run_dir / "XperienceCollections.swift").read_bytes() == source["appleDomain"]
            and (run_dir / "XperienceCollections.kt").read_bytes() == source["androidDomain"], "domain source equivalence failed")
    require((run_dir / "VortxJSON.swift").read_bytes()[len(actual_import) + 1:] == apple_span
            and (run_dir / "OHJson.kt").read_bytes()[len(android_preamble):] == android_span, "declaration source equivalence failed")
    graph["compilerInputs"] = {name: digest(data) for name, data in generated.items()}
    graph["fixtureSources"] = {name: digest((fixture / name).read_bytes()) for name in
                               ("SwiftFixture.swift", "KotlinFixture.kt", "run-hosted.py", "source-pins.json", "corpus.tsv", "test_toolchain_layout.py")}
    write_json(run_dir / "source-graph.json", graph)
    write_json(run_dir / "corpus-manifest.json", cases)
    emit("source-graph", graph)
    for case in cases:
        emit("corpus-case", case)
    swiftc = run_child("resolve-swiftc", ["/usr/bin/xcrun", "--find", "swiftc"], 15, run_dir, environment).decode().strip()
    sdk = run_child("resolve-sdk", ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], 15, run_dir, environment).decode().strip()
    require(Path(swiftc).is_absolute() and Path(swiftc).is_file() and Path(sdk).is_dir(), "host Swift SDK resolution failed")
    # BOTH preinstalled runtimes are mandatory. No installer, downloader or fallback.
    jdks = {major: installed_jdk(major, environment, run_dir) for major in (17, 21)}
    environment["JAVA_HOME"] = jdks[21]["home"]
    java = str(Path(jdks[21]["home"]) / "bin/java")
    swift_version = run_child("swift-version", [swiftc, "--version"], 15, run_dir, environment).decode().strip()
    kotlin = installed_kotlin(environment)
    compiler = Path(kotlin["home"])
    kotlin_classpath = exact_kotlin_classpath(kotlin)
    kotlin_command = [java, "-Xmx768m", "-XX:ActiveProcessorCount=1", "-cp", kotlin_classpath,
                      "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-kotlin-home", str(compiler)]
    kotlin_version = run_child("kotlin-version", kotlin_command + ["-version"], 30, run_dir, environment).decode().strip()
    version_match = re.search(r'kotlinc-jvm ([^\s]+)', kotlin_version)
    require(version_match and version_match.group(1) == "2.4.21", "preinstalled Kotlin version missing or changed")
    image = {name: environment.get(name) for name in ("ImageOS", "ImageVersion", "RUNNER_OS", "RUNNER_ARCH")}
    require(image["ImageOS"] and image["ImageVersion"], "actual runner image identity unavailable")
    swift_files = {"swiftc": file_identity(Path(swiftc)),
                   "swift-frontend": file_identity(Path(swiftc).parent / "swift-frontend")}
    toolchain = {"image": image, "referenceImage": pins["hostToolchain"]["referenceImage"],
                 "swiftVersion": swift_version[:2048], "swiftFiles": swift_files, "sdk": sdk,
                 "kotlinVersion": kotlin_version[:2048], "kotlinInstallation": kotlin, "jdks": jdks,
                 "compileJDKMajor": 21, "bytecodeTarget": 17, "executionJDKMajors": [17, 21], "workerCount": 1,
                 "downloadedFiles": 0, "scope": "hosted JVM evidence; Android/libcore/device unproven"}
    write_json(run_dir / "toolchain-manifest.json", toolchain)
    emit("toolchain", toolchain)
    run_child("swift-compile", [swiftc, "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
              "-j", "1", "-num-threads", "1", "-sdk", sdk, "-o", str(run_dir / "swift-fixture"),
              str(run_dir / "VortxJSON.swift"), str(run_dir / "XperienceCollections.swift"), str(fixture / "SwiftFixture.swift")],
              240, run_dir, environment)
    run_child("swift-corpus", [str(run_dir / "swift-fixture"), str(fixture / "corpus.tsv"), str(run_dir / "apple")], 30, run_dir, environment)
    require(exact_kotlin_classpath(kotlin) == kotlin_classpath, "Kotlin compiler classpath changed before compilation")
    run_child("kotlin-compile", kotlin_command + ["-Werror", "-Xbackend-threads=1", "-jvm-target", "17", "-include-runtime",
              "-d", str(run_dir / "kotlin-fixture.jar"), str(run_dir / "OHJson.kt"), str(run_dir / "XperienceCollections.kt"), str(fixture / "KotlinFixture.kt")],
              240, run_dir, environment)
    jar = run_dir / "kotlin-fixture.jar"
    jar_identity = file_identity(jar, 32 * 1024 * 1024)
    emit("compiled-fixture", {"kotlinJar": jar_identity, "swiftExecutable": file_identity(run_dir / "swift-fixture")})
    for major in (17, 21):
        runtime_environment = environment.copy()
        runtime_environment["JAVA_HOME"] = jdks[major]["home"]
        runtime_java = str(Path(jdks[major]["home"]) / "bin/java")
        require(file_identity(jar, 32 * 1024 * 1024) == jar_identity, "compiled jar changed before runtime comparison")
        run_child("kotlin-corpus-jdk" + str(major), [runtime_java, "-Xmx256m", "-XX:ActiveProcessorCount=1", "-jar", str(jar),
                  str(fixture / "corpus.tsv"), str(run_dir / ("android-jdk" + str(major)))], 30, run_dir, runtime_environment)
        require(file_identity(jar, 32 * 1024 * 1024) == jar_identity, "compiled jar changed during runtime comparison")
    apple = read_results(run_dir / "apple", cases)
    android = {major: read_results(run_dir / ("android-jdk" + str(major)), cases) for major in (17, 21)}
    failures = []
    failed_cases = set()
    for case in cases:
        key = case["id"]
        a = apple[key]
        for major in (17, 21):
            b = android[major][key]
            reasons = []
            if case["expected"] != "OBSERVE" and (a["category"] != case["expected"] or b["category"] != case["expected"]):
                reasons.append("required-category")
            if a != b:
                reasons.append("result-metadata")
            if a["category"] == b["category"] == "ACCEPTED":
                if (run_dir / "apple" / (key + ".canonical")).read_bytes() != (run_dir / ("android-jdk" + str(major)) / (key + ".canonical")).read_bytes():
                    reasons.append("canonical-bytes")
            record = {"id": key, "jdkMajor": major, "apple": a, "android": b, "equal": not reasons, "mismatches": reasons}
            emit("result", record)
            if reasons:
                failures.append(record)
                failed_cases.add(key)
    summary = {"cases": len(cases), "runtimeComparisons": len(cases) * 2,
               "mismatchedCases": len(failed_cases), "mismatchedRuntimeCases": len(failures), "passed": not failures,
               "scope": "hosted JDK17/JDK21 document admission, canonical bytes and fingerprint only; Android/libcore/device unproven",
               "artifactUploads": 0, "downloads": 0, "kotlinCompileCount": 1, "kotlinJarSHA256": jar_identity["sha256"]}
    write_json(run_dir / "comparison.json", {"summary": summary, "failures": failures})
    emit("summary", summary)
    require(not failures, "Apple/Android document wire parity mismatch")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        emit("failure", {"type": type(error).__name__, "message": str(error)[:2048]})
        sys.exit(1)
