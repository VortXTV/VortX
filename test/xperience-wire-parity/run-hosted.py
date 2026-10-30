#!/usr/bin/env python3
"""Explicit hosted-only experiment. Reading this source launches no subprocesses."""
import base64
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
NAMESPACE_PRODUCTION_PATH = "android/app/src/main/kotlin/com/vortx/android/xperience/XperienceImportNamespace.kt"
NAMESPACE_FIXTURE_PATH = "test/xperience-wire-parity/NamespacePublicApiFixture.kt"
NAMESPACE_MAIN_CLASS = "com.vortx.android.xperience.NamespacePublicApiFixture"
NAMESPACE_CASE_IDS = (
    "read-replace-unknown-raw", "semantic-full-register-stale", "detached-observation-bytes",
    "duplicate-precision-invalid-shortcut", "small-depth-unknown-cas", "exact-integer-unknown-conservation",
    "actual-canonical-expansion-quota", "concurrent-original-observations", "tombstone-namespace-future-format",
)
NAMESPACE_ASSERTION_MINIMUM = 9
NAMESPACE_ASSERTION_MAXIMUM = 128
NAMESPACE_MAX_INPUT_BYTES = 16 * 1024
TRANSPORT_CORPUS_SHA256 = "de132e69bd605de930fdbc552534b31216232463e4900de93e4646ec74c1e296"
TRANSPORT_SOURCE_PATHS = {
    "appleBinding": "app/SourcesShared/XperienceAddonBinding.swift",
    "androidBinding": "android/app/src/main/kotlin/com/vortx/android/xperience/XperienceAddonBinding.kt",
    "swiftDocumentFixture": "test/xperience-wire-parity/SwiftFixture.swift",
    "kotlinDocumentFixture": "test/xperience-wire-parity/KotlinFixture.kt",
    "transportSwiftFixture": "test/xperience-wire-parity/TransportFixture.swift",
    "transportKotlinFixture": "test/xperience-wire-parity/TransportFixture.kt",
    "transportCorpus": "test/xperience-wire-parity/transport-cases.json",
    "transportGuardTests": "test/xperience-wire-parity/test_toolchain_layout.py",
}
TRANSPORT_DESCRIPTOR = {"manifestID": "fixture.xperience.synthetic", "catalog": {
    "type": "movie", "id": "fixture-popular", "acceptsGenre": True, "requiresGenre": False, "supportsSkip": True}}
TRANSPORT_MODE_COUNTS = {"LITERAL_CONTRACT_UNOBSERVED": 25, "GUARD_REJECTION_UNOBSERVED": 11,
                         "PLATFORM_PARITY_PROBE_UNOBSERVED": 16}
TRANSPORT_RELATIONS = [
    {"kind": "same-normalized-bytes", "caseIDs": ["ascii-https", "scheme-host-case"]},
    {"kind": "distinct-normalized-bytes-if-admitted", "caseIDs": ["ascii-https", "explicit-default-https"]},
    {"kind": "distinct-normalized-bytes-if-admitted", "caseIDs": ["escaped-path-slash-upper", "literal-path-slash"]},
    {"kind": "distinct-normalized-bytes-if-admitted", "caseIDs": ["escaped-path-slash-upper", "escaped-path-slash-lower"]},
    {"kind": "distinct-normalized-bytes-if-admitted", "caseIDs": ["query-plus", "query-encoded-space"]},
    {"kind": "distinct-normalized-bytes-if-admitted", "caseIDs": ["ascii-https", "query-empty"]},
]
TRANSPORT_RUNTIMES = ("apple", "jdk17", "jdk21")
NORMALIZATION_SOURCE_PATHS = {
    "normalizationSwiftFixture": "test/xperience-wire-parity/NormalizationRegressionFixture.swift",
    "normalizationKotlinFixture": "test/xperience-wire-parity/NormalizationRegressionFixture.kt",
    "appleCatalogClient": "app/SourcesShared/XperienceCatalogClient.swift",
}
NORMALIZATION_ROSTERS = {
    "swift": {"accepted": 15, "rejected": 18, "distinct": 7, "longQueries": 2, "unicodeExpansion": 1,
              "capacity": 4, "requestProjection": 2, "oldHashRebind": 2, "sourceGuards": 3},
    "kotlin": {"accepted": 15, "rejected": 19, "distinct": 7, "longQueries": 2, "unicodeExpansion": 1,
               "capacity": 4, "oldHashRebind": 2, "methods": 4},
}


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


def namespace_results(output, major):
    require(len(output) <= 4096, "Namespace PASS output byte limit")
    try:
        lines = output.decode("ascii").splitlines()
    except UnicodeDecodeError:
        raise RuntimeError("Namespace PASS output must be ASCII") from None
    require(len(lines) == len(NAMESPACE_CASE_IDS) + 1, "Namespace PASS line count mismatch")
    prefix = "PASS namespace-public-api "
    passed = []
    for line in lines[:-1]:
        require(line.startswith(prefix), "Namespace case PASS format mismatch")
        name = line[len(prefix):]
        require(name in NAMESPACE_CASE_IDS and name not in passed, "unknown or duplicate Namespace case ID")
        passed.append(name)
    require(set(passed) == set(NAMESPACE_CASE_IDS), "Namespace required case missing")
    summary = re.fullmatch(r"PASS namespace-public-api assertions=([1-9][0-9]{0,2}) cases=9 maxInputBytes=16384", lines[-1])
    require(summary, "Namespace PASS summary format mismatch")
    assertions = int(summary.group(1))
    require(NAMESPACE_ASSERTION_MINIMUM <= assertions <= NAMESPACE_ASSERTION_MAXIMUM, "Namespace assertion count outside reviewed bound")
    record = {"caseIds": sorted(passed), "cases": len(passed), "assertions": assertions,
              "maxInputBytes": NAMESPACE_MAX_INPUT_BYTES, "passed": True}
    for name in passed:
        emit("namespace-case", {"id": name, "jdkMajor": major, "passed": True})
    emit("namespace-summary", {"jdkMajor": major, **record})
    return record


def transport_cases(data):
    require(0 < len(data) <= 128 * 1024 and digest(data) == TRANSPORT_CORPUS_SHA256, "exact bounded transport corpus pin mismatch")
    try:
        corpus = json.loads(data.decode("utf-8"))
    except (UnicodeError, ValueError):
        raise RuntimeError("invalid transport corpus JSON") from None
    require(type(corpus) is dict and type(corpus.get("schema")) is int and corpus["schema"] == 1
            and corpus.get("fixtureDescriptor") == TRANSPORT_DESCRIPTOR, "transport descriptor/schema mismatch")
    require(all(type(corpus["fixtureDescriptor"]["catalog"][key]) is bool for key in
                ("acceptsGenre", "requiresGenre", "supportsSkip")), "transport descriptor boolean types mismatch")
    cases = corpus.get("cases")
    require(type(cases) is list and len(cases) == 52 and len(cases) <= 64, "transport corpus case count")
    counts = {mode: 0 for mode in TRANSPORT_MODE_COUNTS}
    seen = set()
    fields = {"id", "input", "mode", "expectedAdmission", "expectedCanonicalUTF8", "referenceSHA256", "note",
              "inputUTF8SHA256", "observedApple", "observedJDK17", "observedJDK21", "comparisonExpected"}
    for case in cases:
        require(type(case) is dict and set(case) == fields, "transport case fields mismatch")
        require(type(case["id"]) is str and ID.fullmatch(case["id"]) and case["id"] not in seen, "unsafe or duplicate transport case ID")
        seen.add(case["id"])
        require(type(case["input"]) is str, "transport input must be text")
        raw = case["input"].encode("utf-8")
        require(0 < len(raw) <= 4096 and type(case["inputUTF8SHA256"]) is str
                and HEX.fullmatch(case["inputUTF8SHA256"]) and digest(raw) == case["inputUTF8SHA256"], "transport input byte/hash mismatch")
        require(all(case[key] is None for key in ("observedApple", "observedJDK17", "observedJDK21")), "transport authored observations must remain null")
        mode = case["mode"]
        require(type(mode) is str and mode in counts, "unknown transport expectation mode")
        counts[mode] += 1
        if mode == "LITERAL_CONTRACT_UNOBSERVED":
            require(case["expectedAdmission"] == case["comparisonExpected"] == "ACCEPTED"
                    and type(case["expectedCanonicalUTF8"]) is str and type(case["referenceSHA256"]) is str,
                    "transport literal expectation mismatch")
            literal = case["expectedCanonicalUTF8"].encode("utf-8")
            require(0 < len(literal) <= 16 * 1024 and HEX.fullmatch(case["referenceSHA256"])
                    and digest(literal) == case["referenceSHA256"], "transport literal reference byte/hash mismatch")
        else:
            expected = "REJECTED" if mode == "GUARD_REJECTION_UNOBSERVED" else "OBSERVE"
            admission = "REJECTED" if expected == "REJECTED" else None
            require(case["expectedAdmission"] == admission and case["comparisonExpected"] == expected
                    and case["expectedCanonicalUTF8"] is None and case["referenceSHA256"] is None,
                    "transport rejection/probe expectation mismatch")
    require(counts == TRANSPORT_MODE_COUNTS and corpus.get("relations") == TRANSPORT_RELATIONS,
            "transport exact mode counts or six relations mismatch")
    require(all(name in seen for relation in TRANSPORT_RELATIONS for name in relation["caseIDs"]), "transport relation case missing")
    return cases, corpus["relations"]


def transport_bounded_file(path, maximum):
    require(not path.is_symlink() and path.is_file(), "transport output missing or unsafe")
    with path.open("rb") as source:
        data = source.read(maximum + 1)
    require(len(data) <= maximum, "transport output byte limit")
    return data


def read_transport_results(directory, cases, runtime):
    expected = {case["id"]: case for case in cases}
    records, canonical, issues, seen = {}, {}, {}, set()
    def note(name, reason):
        issues.setdefault(name, set()).add(reason)
    directory_entries = set()
    try:
        require(not directory.is_symlink() and directory.is_dir(), "transport output directory missing or unsafe")
        # Shallow, bounded inventory only: 52 possible canonical files + metadata + one sentinel.
        with os.scandir(directory) as entries:
            for index, entry in enumerate(entries):
                if index >= len(cases) + 1:
                    note("transport-report", "output-entry-limit")
                    break
                directory_entries.add(entry.name)
                if entry.is_symlink() or not entry.is_file(follow_symlinks=False):
                    note("transport-report", "output-entry-not-regular")
    except (OSError, RuntimeError):
        return {"records": {}, "canonical": {}, "failures": [{"id": "transport-report", "runtime": runtime,
                "reasons": ["output-directory-missing-or-unsafe"]}]}
    try:
        rows = transport_bounded_file(directory / "results.tsv", 32 * 1024).decode("ascii").splitlines()
    except (OSError, RuntimeError, UnicodeError):
        note("transport-report", "metadata-missing-unsafe-nonascii-or-limit")
        rows = []
    if len(rows) != len(cases):
        note("transport-report", "result-row-count")
    for line in rows:
        row = line.split("\t")
        name = row[0]
        if name not in expected:
            note("transport-report", "unknown-result-id")
            continue
        if name in seen:
            note(name, "duplicate-result-id")
            continue
        seen.add(name)
        if len(row) != 6:
            note(name, "result-column-count")
            continue
        category = row[1] if row[1] in ("ACCEPTED", "INVALID_REGISTRY") else None
        size = int(row[2]) if re.fullmatch(r"0|[1-9][0-9]{0,4}", row[2]) else None
        sha = row[3] if row[3] == "-" or HEX.fullmatch(row[3]) else None
        fingerprint = row[4] if row[4] == "-" or HEX.fullmatch(row[4]) else None
        input_sha = row[5] if HEX.fullmatch(row[5]) else None
        record = {"id": name, "category": category, "bytes": size, "sha256": sha,
                  "fingerprint": fingerprint, "inputSHA256": input_sha}
        records[name] = record
        if category is None:
            note(name, "invalid-category")
        if input_sha != expected[name]["inputUTF8SHA256"]:
            note(name, "input-identity-mismatch")
        path = directory / (name + ".canonical")
        if category == "ACCEPTED":
            try:
                actual = transport_bounded_file(path, 16 * 1024)
                canonical[name] = actual
                record["actualBytes"], record["independentSHA256"] = len(actual), digest(actual)
                if not actual or size != len(actual):
                    note(name, "canonical-size-mismatch")
                if sha != digest(actual):
                    note(name, "reported-canonical-hash-mismatch")
                if fingerprint != digest(actual):
                    note(name, "actual-producer-fingerprint-mismatch")
            except (OSError, RuntimeError):
                note(name, "canonical-missing-unsafe-or-limit")
        elif category == "INVALID_REGISTRY":
            if row[2:5] != ["0", "-", "-"] or path.exists() or path.is_symlink():
                note(name, "rejection-has-canonical-or-fingerprint")
        elif path.exists() or path.is_symlink():
            note(name, "invalid-category-has-canonical")
    for name in expected:
        if name not in records:
            note(name, "missing-observation")
    allowed_entries = {"results.tsv"} | {name + ".canonical" for name, record in records.items()
                                         if record["category"] == "ACCEPTED"}
    if directory_entries != allowed_entries:
        note("transport-report", "output-membership-mismatch")
    return {"records": records, "canonical": canonical, "failures": [
        {"id": name, "runtime": runtime, "reasons": sorted(reasons)} for name, reasons in sorted(issues.items())]}


def transport_comparison(cases, relations, outputs):
    require(len(cases) == 52 and set(outputs) == set(TRANSPORT_RUNTIMES) and relations == TRANSPORT_RELATIONS,
            "transport comparison closure mismatch")
    failures, case_results, relation_results = [], [], []
    for runtime in TRANSPORT_RUNTIMES:
        failures.extend(outputs[runtime]["failures"])
    def note(name, runtime, reason, related=None):
        item = {"id": name, "runtime": runtime, "reasons": [reason]}
        if related is not None:
            item["relatedID"] = related
        failures.append(item)
    for case in cases:
        name = case["id"]
        observed = {runtime: outputs[runtime]["records"].get(name) for runtime in TRANSPORT_RUNTIMES}
        for runtime, record in observed.items():
            if record is None:
                note(name, runtime, "expected-observation-missing")
                continue
            actual = outputs[runtime]["canonical"].get(name)
            if case["mode"] == "LITERAL_CONTRACT_UNOBSERVED":
                if record["category"] != "ACCEPTED":
                    note(name, runtime, "literal-admission-mismatch")
                if actual != case["expectedCanonicalUTF8"].encode("utf-8"):
                    note(name, runtime, "literal-canonical-bytes-mismatch")
            elif case["mode"] == "GUARD_REJECTION_UNOBSERVED" and record["category"] != "INVALID_REGISTRY":
                note(name, runtime, "guard-rejection-mismatch")
        for runtime in ("jdk17", "jdk21"):
            apple, other = observed["apple"], observed[runtime]
            if apple is None or other is None or apple != other:
                note(name, "apple-vs-" + runtime, "cross-runtime-category-metadata-or-fingerprint")
            if apple is not None and other is not None and apple["category"] == other["category"] == "ACCEPTED":
                if outputs["apple"]["canonical"].get(name) != outputs[runtime]["canonical"].get(name):
                    note(name, "apple-vs-" + runtime, "cross-runtime-canonical-bytes")
        case_results.append({"id": name, "byRuntime": observed})
    for runtime in TRANSPORT_RUNTIMES:
        for relation in relations:
            left, right = relation["caseIDs"]
            a, b = outputs[runtime]["records"].get(left), outputs[runtime]["records"].get(right)
            admitted = a is not None and b is not None and a["category"] == b["category"] == "ACCEPTED"
            x, y = outputs[runtime]["canonical"].get(left), outputs[runtime]["canonical"].get(right)
            same = relation["kind"] == "same-normalized-bytes"
            applicable = same or admitted
            passed = admitted and x is not None and y is not None and ((x == y) if same else (x != y)) if applicable else None
            if applicable and not passed:
                note(left, runtime, "relation-same-bytes" if same else "relation-distinct-bytes", right)
            relation_results.append({"runtime": runtime, "relation": relation["kind"], "caseIDs": [left, right],
                                     "applicable": applicable, "passed": passed})
    failed_ids = {item[key] for item in failures for key in ("id", "relatedID") if key in item}
    summary = {"cases": len(cases), "runtimeComparisons": len(cases) * 2, "runtimes": len(TRANSPORT_RUNTIMES),
               "literalContracts": 25, "guardRejections": 11, "observeProbes": 16, "relationChecks": len(relation_results),
               "mismatchedCases": sum(case["id"] in failed_ids for case in cases), "failureRecords": len(failures),
               "passed": not failures}
    return {"summary": summary, "failures": failures, "cases": case_results, "relations": relation_results}


def transport_mismatch_witnesses(cases, outputs, report, corpus_sha256):
    # Only the exact reviewed public synthetic corpus may reach this code-emitted diagnostic.
    require(corpus_sha256 == TRANSPORT_CORPUS_SHA256 and len(cases) == 52, "transport byte witness corpus closure")
    if report["summary"]["passed"]:
        return []
    affected = {item[key] for item in report["failures"] for key in ("id", "relatedID") if key in item}
    witnesses = []
    for case in cases:
        name = case["id"]
        if name not in affected:
            continue
        for runtime in TRANSPORT_RUNTIMES:
            record = outputs[runtime]["records"].get(name)
            actual = outputs[runtime]["canonical"].get(name)
            if record is None or record["category"] != "ACCEPTED" or actual is None:
                continue
            # Canonical bytes came from the bounded real .canonical file read above, not an input string.
            if record["inputSHA256"] != case["inputUTF8SHA256"]:
                continue
            require(0 <= len(actual) <= 16 * 1024 and record.get("actualBytes") == len(actual)
                    and record.get("independentSHA256") == digest(actual), "transport byte witness independent file identity")
            prefix = actual[:512]
            witnesses.append({"id": name, "runtime": runtime, "corpusSHA256": corpus_sha256,
                "provenance": "original-job-code-emitted-public-synthetic-canonical-file",
                "fullBytes": len(actual), "fullSHA256": digest(actual), "prefixBytes": len(prefix),
                "prefixBase64": base64.b64encode(prefix).decode("ascii"), "truncated": len(actual) > len(prefix)})
    return witnesses


def normalization_results(output, runtime, cases):
    require(runtime in TRANSPORT_RUNTIMES and len(output) <= 8192 and len(cases) == 52,
            "normalization regression output closure/byte limit")
    try:
        lines = output.decode("ascii").splitlines()
    except UnicodeError:
        raise RuntimeError("normalization regression output must be ASCII") from None
    language = "swift" if runtime == "apple" else "kotlin"
    summary = "PASS normalization-regressions " + language + " " + " ".join(
        name + "=" + str(count) for name, count in NORMALIZATION_ROSTERS[language].items())
    expected = ["transport-case-start\t" + case["id"] for case in cases] + [summary]
    require(lines == expected, "normalization regression roster/PASS or original collector ID order mismatch")
    record = {"runtime": runtime, "collectorCases": len(cases), "rosterFields": len(NORMALIZATION_ROSTERS[language]),
              "roster": NORMALIZATION_ROSTERS[language], "passed": True}
    emit("normalization-regression-summary", record)
    return record


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
    require(pins["schema"] == 4 and pins["repository"] == REPOSITORY and pins["ref"] == REF, "manifest identity mismatch")
    require(pins["reviewState"] == "ROOT_AND_INDEPENDENT_SOURCE_SECURITY_REVIEWED", "source/security review remains unfinished")
    for key in ("appleDomain", "appleJSON", "androidDomain", "androidJSON", "namespaceSource", "namespaceFixture"):
        require(HEX.fullmatch(pins[key]["sha256"]), "unfinished source pin: " + key)
    model = pins["finalModel"]
    require(type(model["version"]) is int and model["version"] > 0
            and model["packet"] == "android-xperience-domain-source-v" + str(model["version"])
            and model["reviewState"] == "SOURCE_SECURITY_REVIEWED"
            and HEX.fullmatch(model["frozenReceiptSHA256"])
            and HEX.fullmatch(model["reviewReceiptSHA256"])
            and model["domainSourceSHA256"] == pins["androidDomain"]["sha256"],
            "actual final-model version/source/frozen/review identity remains unfinished")
    namespace_check = pins["namespaceCheck"]
    require(pins["namespaceSource"]["path"] == NAMESPACE_PRODUCTION_PATH
            and pins["namespaceFixture"]["path"] == NAMESPACE_FIXTURE_PATH,
            "Namespace implementation/fixture must use their exact real source paths")
    require(namespace_check["reviewState"] == "SOURCE_AND_FIXTURE_SECURITY_REVIEWED"
            and re.fullmatch(r"[a-z][a-z0-9-]{1,95}", namespace_check["packet"])
            and HEX.fullmatch(namespace_check["frozenReceiptSHA256"])
            and HEX.fullmatch(namespace_check["namespaceReviewReceiptSHA256"])
            and HEX.fullmatch(namespace_check["fixtureReviewReceiptSHA256"])
            and namespace_check["namespaceSourceSHA256"] == pins["namespaceSource"]["sha256"]
            and namespace_check["fixtureSourceSHA256"] == pins["namespaceFixture"]["sha256"]
            and namespace_check["mainClass"] == NAMESPACE_MAIN_CLASS
            and namespace_check["caseIds"] == list(NAMESPACE_CASE_IDS)
            and namespace_check["assertionMinimum"] == NAMESPACE_ASSERTION_MINIMUM
            and namespace_check["assertionMaximum"] == NAMESPACE_ASSERTION_MAXIMUM
            and namespace_check["maximumInputBytes"] == NAMESPACE_MAX_INPUT_BYTES,
            "exact Namespace source/fixture/freeze/review/output identity remains unfinished")
    transport_check = pins["transportCheck"]
    for key, path in TRANSPORT_SOURCE_PATHS.items():
        require(pins[key]["path"] == path and type(pins[key]["sha256"]) is str and HEX.fullmatch(pins[key]["sha256"]),
                "unfinished transport whole-file source pin: " + key)
    require(pins["transportCorpus"]["sha256"] == TRANSPORT_CORPUS_SHA256
            and transport_check["reviewState"] == "SOURCE_COLLECTORS_AND_GUARDS_SECURITY_REVIEWED"
            and transport_check["contractPacket"] == "xperience-transport-fingerprint-source-v1/final-v2"
            and re.fullmatch(r"[a-z][a-z0-9-]{1,95}", transport_check["collectorsPacket"])
            and all(type(transport_check[key]) is str and HEX.fullmatch(transport_check[key]) for key in
                    ("contractFreezeSHA256", "contractReviewReceiptSHA256", "bindingSourceReviewReceiptSHA256",
                     "collectorsFreezeSHA256", "collectorsInventorySHA256", "collectorsReviewReceiptSHA256",
                     "collectorsReviewIdentitySHA256", "driverGuardReviewReceiptSHA256"))
            and set(transport_check["sourceSHA256s"]) == set(TRANSPORT_SOURCE_PATHS)
            and all(transport_check["sourceSHA256s"][key] == pins[key]["sha256"] for key in TRANSPORT_SOURCE_PATHS)
            and transport_check["corpusSHA256"] == TRANSPORT_CORPUS_SHA256
            and transport_check["modeCounts"] == TRANSPORT_MODE_COUNTS
            and transport_check["cases"] == 52 and transport_check["relations"] == 6,
            "exact transport source/collector/corpus/freeze/review closure remains unfinished")
    normalization_check = pins["normalizationCheck"]
    for key, path in NORMALIZATION_SOURCE_PATHS.items():
        require(pins[key]["path"] == path and type(pins[key]["sha256"]) is str and HEX.fullmatch(pins[key]["sha256"]),
                "unfinished normalization whole-file pin: " + key)
    normalization_keys = set(NORMALIZATION_SOURCE_PATHS) | {"appleBinding", "androidBinding", "swiftDocumentFixture", "kotlinDocumentFixture"}
    require(normalization_check["reviewState"] == "SOURCE_AND_PORTABLE_REGRESSIONS_SECURITY_REVIEWED"
            and normalization_check["sourcePacket"] == "xperience-transport-normalization-source-v2"
            and normalization_check["sourceFreezeSHA256"] == "7b1c9bf03dd85557eb18a17a16f1d42806153eefef96c70ffbfcf5cd91bc174e"
            and normalization_check["sourceInventorySHA256"] == "c1f0d651012f38d2d9c1ae7eb3ff620282beb940a9ece8adfc587d32c2448858"
            and normalization_check["originSwiftSHA256"] == "e486dda617f826a8b0908df4d38c6246703b5a8fc0a79f6a342b45574a4cd5bd"
            and normalization_check["originKotlinSHA256"] == "082662d8ec092e6d64256fa9a5af4f841c94a5ff81730f23bb567e5980cd3d22"
            and pins["normalizationSwiftFixture"]["sha256"] == normalization_check["originSwiftSHA256"]
            and pins["appleBinding"]["sha256"] == "3cdcddcc7ce859bfef4e0f509e03f4a3c53ff9e70e865ac936c04fff3970bb5f"
            and pins["androidBinding"]["sha256"] == "973ade6aede460a3d75b077ef4d9d2d0d121c0f5525cc04e5c8fa99a0a7dd268"
            and all(type(normalization_check[key]) is str and HEX.fullmatch(normalization_check[key]) for key in
                    ("sourceReviewReceiptSHA256", "sourceReviewIdentitySHA256", "portableHarnessReviewReceiptSHA256"))
            and set(normalization_check["sourceSHA256s"]) == normalization_keys
            and all(normalization_check["sourceSHA256s"][key] == pins[key]["sha256"] for key in normalization_keys)
            and normalization_check["rosters"] == NORMALIZATION_ROSTERS,
            "exact normalization V2 source/portable regression/roster/review join remains unfinished")
    require(pins["hostToolchain"]["kotlinVersion"] == "2.4.21"
            and pins["hostToolchain"]["requiredJDKMajors"] == [17, 21]
            and pins["hostToolchain"]["requiredJDKEnvironment"] == ["JAVA_HOME_17_arm64", "JAVA_HOME_21_arm64"]
            and pins["hostToolchain"]["compileJDKMajor"] == 21
            and pins["hostToolchain"]["bytecodeTarget"] == 17
            and pins["hostToolchain"]["downloadOrInstallPermitted"] is False, "unreviewed host toolchain requirements")
    require(HEX.fullmatch(pins["appleJSON"]["spanSHA256"]) and HEX.fullmatch(pins["androidJSON"]["spanSHA256"]), "unfinished literal-span pins")
    source_keys = ("appleDomain", "appleJSON", "androidDomain", "androidJSON", "namespaceSource", "namespaceFixture") + tuple(TRANSPORT_SOURCE_PATHS) + tuple(NORMALIZATION_SOURCE_PATHS)
    source = {key: read_owner(root, pins[key], 128 * 1024 if key == "transportCorpus" else 256 * 1024) for key in source_keys}
    require(source["namespaceFixture"].count(b'@file:JvmName("NamespacePublicApiFixture")') == 1
            and source["namespaceFixture"].count(b'\npackage com.vortx.android.xperience\n') == 1,
            "Namespace fixture explicit main declaration changed")
    apple_begin, apple_span = literal_span(source["appleJSON"], pins["appleJSON"])
    android_begin, android_span = literal_span(source["androidJSON"], pins["androidJSON"])
    actual_import = pins["appleJSON"]["actualImportPrefix"].encode("utf-8")
    require(actual_import == b"import Foundation\n" and source["appleJSON"].startswith(actual_import) and apple_begin > len(actual_import), "Apple actual import changed")
    android_preamble = source["androidJSON"][:android_begin]
    require(digest(android_preamble) == pins["androidJSON"]["preambleSHA256"], "Android actual package/import preamble changed")
    corpus_data, cases = corpus_cases(fixture / "corpus.tsv")
    transport_data = source["transportCorpus"]
    transport_case_list, transport_relations = transport_cases(transport_data)
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
             "androidPreambleSHA256": digest(android_preamble), "finalModel": model, "namespaceCheck": namespace_check,
             "transportCheck": transport_check, "normalizationCheck": normalization_check,
             "transportCorpusSHA256": digest(transport_data), "transportCases": len(transport_case_list),
             "corpusSHA256": digest(corpus_data), "corpusCases": len(cases), "runDirectory": str(run_dir)}
    generated = {"VortxJSON.swift": actual_import + b"\n" + apple_span,
                 "XperienceCollections.swift": source["appleDomain"],
                 "OHJson.kt": android_preamble + android_span,
                 "XperienceCollections.kt": source["androidDomain"],
                 "XperienceImportNamespace.kt": source["namespaceSource"],
                 "NamespacePublicApiFixture.kt": source["namespaceFixture"]}
    transport_copy = {"XperienceAddonBinding.swift": "appleBinding", "XperienceAddonBinding.kt": "androidBinding",
                      "SwiftFixture.swift": "swiftDocumentFixture", "KotlinFixture.kt": "kotlinDocumentFixture",
                      "TransportFixture.swift": "transportSwiftFixture", "TransportFixture.kt": "transportKotlinFixture",
                      "transport-cases.json": "transportCorpus", "test_toolchain_layout.py": "transportGuardTests"}
    transport_copy.update({"NormalizationRegressionFixture.swift": "normalizationSwiftFixture",
                           "NormalizationRegressionFixture.kt": "normalizationKotlinFixture",
                           "XperienceCatalogClient.swift.readonly": "appleCatalogClient"})
    generated.update({name: source[key] for name, key in transport_copy.items()})
    for name, data in generated.items():
        (run_dir / name).write_bytes(data)
    # Read back bytes and compare all copied bodies and declaration slices before compiling.
    require((run_dir / "XperienceCollections.swift").read_bytes() == source["appleDomain"]
            and (run_dir / "XperienceCollections.kt").read_bytes() == source["androidDomain"], "domain source equivalence failed")
    require((run_dir / "XperienceImportNamespace.kt").read_bytes() == source["namespaceSource"]
            and (run_dir / "NamespacePublicApiFixture.kt").read_bytes() == source["namespaceFixture"],
            "complete Namespace implementation/fixture source equivalence failed")
    require((run_dir / "VortxJSON.swift").read_bytes()[len(actual_import) + 1:] == apple_span
            and (run_dir / "OHJson.kt").read_bytes()[len(android_preamble):] == android_span, "declaration source equivalence failed")
    for name, key in transport_copy.items():
        require((run_dir / name).read_bytes() == source[key], "complete transport source/corpus readback mismatch: " + name)
    graph["generatedInputs"] = {name: digest(data) for name, data in generated.items()}
    graph["fixtureSources"] = {name: digest((fixture / name).read_bytes()) for name in
                               ("SwiftFixture.swift", "KotlinFixture.kt", "NamespacePublicApiFixture.kt", "TransportFixture.swift", "TransportFixture.kt",
                                "NormalizationRegressionFixture.swift", "NormalizationRegressionFixture.kt",
                                "transport-cases.json", "run-hosted.py", "source-pins.json", "corpus.tsv", "test_toolchain_layout.py")}
    graph["readonlySources"] = {"appleCatalogClient": {"path": pins["appleCatalogClient"]["path"],
        "sha256": digest(source["appleCatalogClient"]), "scratchPath": str(run_dir / "XperienceCatalogClient.swift.readonly"), "compiled": False}}
    graph["kotlinMainClasses"] = ["com.vortx.android.xperience.KotlinFixtureKt", NAMESPACE_MAIN_CLASS]
    swift_inputs = (run_dir / "VortxJSON.swift", run_dir / "XperienceCollections.swift", run_dir / "XperienceAddonBinding.swift",
                    run_dir / "SwiftFixture.swift", run_dir / "TransportFixture.swift", run_dir / "NormalizationRegressionFixture.swift")
    kotlin_inputs = (run_dir / "OHJson.kt", run_dir / "XperienceCollections.kt", run_dir / "KotlinFixture.kt",
                     run_dir / "XperienceImportNamespace.kt", run_dir / "NamespacePublicApiFixture.kt",
                     run_dir / "XperienceAddonBinding.kt", run_dir / "TransportFixture.kt", run_dir / "NormalizationRegressionFixture.kt")
    graph["compilerInputs"] = {path.name: digest(path.read_bytes()) for path in (*swift_inputs, *kotlin_inputs)}
    graph["swiftCompilerInputOrder"] = [{"path": str(path), "sha256": digest(path.read_bytes())} for path in swift_inputs]
    graph["kotlinCompilerInputOrder"] = [{"path": str(path), "sha256": digest(path.read_bytes())} for path in kotlin_inputs]
    write_json(run_dir / "source-graph.json", graph)
    write_json(run_dir / "corpus-manifest.json", cases)
    transport_manifest = [{"id": case["id"], "mode": case["mode"], "inputBytes": len(case["input"].encode("utf-8")),
                           "inputSHA256": case["inputUTF8SHA256"], "referenceSHA256": case["referenceSHA256"]} for case in transport_case_list]
    write_json(run_dir / "transport-corpus-manifest.json", transport_manifest)
    emit("source-graph", graph)
    for case in cases:
        emit("corpus-case", case)
    for case in transport_manifest:
        emit("transport-corpus-case", case)
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
              "-j", "1", "-num-threads", "1", "-sdk", sdk, "-o", str(run_dir / "swift-fixture")] + [str(path) for path in swift_inputs],
              240, run_dir, environment)
    swift_output = run_child("swift-corpus", [str(run_dir / "swift-fixture"), str(fixture / "corpus.tsv"), str(run_dir / "apple"),
              str(run_dir / "transport-cases.json"), str(run_dir / "apple-transport")], 30, run_dir, environment)
    normalization_by_runtime = {"apple": normalization_results(swift_output, "apple", transport_case_list)}
    require(exact_kotlin_classpath(kotlin) == kotlin_classpath, "Kotlin compiler classpath changed before compilation")
    run_child("kotlin-compile", kotlin_command + ["-Werror", "-Xbackend-threads=1", "-jvm-target", "17", "-include-runtime",
              "-d", str(run_dir / "kotlin-fixture.jar")] + [str(path) for path in kotlin_inputs],
              240, run_dir, environment)
    jar = run_dir / "kotlin-fixture.jar"
    jar_identity = file_identity(jar, 32 * 1024 * 1024)
    emit("compiled-fixture", {"kotlinJar": jar_identity, "swiftExecutable": file_identity(run_dir / "swift-fixture")})
    namespace_by_jdk = {}
    for major in (17, 21):
        runtime_environment = environment.copy()
        runtime_environment["JAVA_HOME"] = jdks[major]["home"]
        runtime_java = str(Path(jdks[major]["home"]) / "bin/java")
        require(file_identity(jar, 32 * 1024 * 1024) == jar_identity, "compiled jar changed before runtime comparison")
        kotlin_output = run_child("kotlin-corpus-jdk" + str(major), [runtime_java, "-Xmx256m", "-XX:ActiveProcessorCount=1", "-cp", str(jar),
                  "com.vortx.android.xperience.KotlinFixtureKt",
                  str(fixture / "corpus.tsv"), str(run_dir / ("android-jdk" + str(major))),
                  str(run_dir / "transport-cases.json"), str(run_dir / ("transport-jdk" + str(major)))], 30, run_dir, runtime_environment)
        require(file_identity(jar, 32 * 1024 * 1024) == jar_identity, "compiled jar changed during runtime comparison")
        normalization_by_runtime["jdk" + str(major)] = normalization_results(kotlin_output, "jdk" + str(major), transport_case_list)
        require(file_identity(jar, 32 * 1024 * 1024) == jar_identity, "compiled jar changed before Namespace invocation")
        namespace_output = run_child("kotlin-namespace-jdk" + str(major),
                  [runtime_java, "-Xmx256m", "-XX:ActiveProcessorCount=1", "-cp", str(jar), NAMESPACE_MAIN_CLASS],
                  30, run_dir, runtime_environment)
        require(file_identity(jar, 32 * 1024 * 1024) == jar_identity, "compiled jar changed during Namespace invocation")
        namespace_by_jdk[major] = namespace_results(namespace_output, major)
        write_json(run_dir / ("namespace-jdk" + str(major) + "-results.json"), namespace_by_jdk[major])
    require(namespace_by_jdk[17] == namespace_by_jdk[21], "Namespace assertion summaries differ across required JDKs")
    require(normalization_by_runtime["jdk17"]["roster"] == normalization_by_runtime["jdk21"]["roster"], "normalization JDK roster mismatch")
    write_json(run_dir / "normalization-regressions.json", normalization_by_runtime)
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
               "scope": "hosted JDK17/JDK21 document wire comparison and pure Namespace public API assertions; Android/libcore/device/native/whole-profile unproven",
               "namespacePassed": True, "namespaceCases": len(NAMESPACE_CASE_IDS), "namespaceRuntimeCases": len(NAMESPACE_CASE_IDS) * 2,
               "namespaceAssertionsByJDK": {str(major): namespace_by_jdk[major]["assertions"] for major in (17, 21)},
               "artifactUploads": 0, "downloads": 0, "kotlinCompileCount": 1, "kotlinJarSHA256": jar_identity["sha256"]}
    transport_outputs = {"apple": read_transport_results(run_dir / "apple-transport", transport_case_list, "apple")}
    for major in (17, 21):
        runtime = "jdk" + str(major)
        transport_outputs[runtime] = read_transport_results(run_dir / ("transport-" + runtime), transport_case_list, runtime)
    transport_report = transport_comparison(transport_case_list, transport_relations, transport_outputs)
    transport_report["byteWitnesses"] = transport_mismatch_witnesses(
        transport_case_list, transport_outputs, transport_report, digest(transport_data))
    write_json(run_dir / "transport-comparison.json", transport_report)
    for record in transport_report["cases"]:
        emit("transport-result", record)
    for record in transport_report["relations"]:
        emit("transport-relation", record)
    for record in transport_report["failures"]:
        emit("transport-mismatch", record)
    for record in transport_report["byteWitnesses"]:
        emit("transport-mismatch-byte-witness", record)
    emit("transport-summary", transport_report["summary"])
    summary["transportPassed"] = transport_report["summary"]["passed"]
    summary["transportCases"] = len(transport_case_list)
    summary["transportRuntimeComparisons"] = len(transport_case_list) * 2
    summary["normalizationRegressionsPassed"] = True
    summary["normalizationRuntimes"] = list(TRANSPORT_RUNTIMES)
    summary["passed"] = not failures and transport_report["summary"]["passed"]
    summary["scope"] = "hosted document/Namespace/transport producer cases only; Android/libcore/device/network/account/UI/native/whole-profile unproven"
    write_json(run_dir / "comparison.json", {"summary": summary, "failures": failures,
               "transportFailures": transport_report["failures"]})
    emit("summary", summary)
    require(summary["passed"], "combined document/Namespace/transport acceptance failed")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        emit("failure", {"type": type(error).__name__, "message": str(error)[:2048]})
        sys.exit(1)
