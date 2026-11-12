#!/usr/bin/env python3
"""Private input manifest and sanitized #292 host JNI proof."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import xml.etree.ElementTree as ET

APP_SOURCE = "1401e37b295305c98629cd212cb93f1e5fdaa098"
ENGINE_SOURCE = "2ea2e0f27dd2e53b7b28228435ca35a70f92831f"
TEST_CLASS = "com.vortx.android.engine.NativeWebsiteRosterGatewayJniTest"
OP_REF = "refs/tags/vortx-android-website-roster-repair-retry-20261112"
TEST_CASES = frozenset({
    "two real managers admit one encrypted website roster promotion",
    "definitivelyRejectedWebsiteRosterCasRebasesAndSecondDeviceRestoresConfirmedHead",
    "websiteRosterReplayReadbackFloorSurvivesRestart",
    "real complete admission stays detached and ordinary receive starts only after callback release",
    "local evidence changing after preparation prevents submission and expires the candidate",
    "same value auth retirement during actual native import closes the handle without callback",
    "noncooperative callback cancellation retains reservation until actual drain",
    "retiring the exact read revokes detached currency before submission",
    "read retirement wins while candidate action waits for the real lifecycle monitor",
    "candidate action linearizes before concurrent exact read retirement",
    "same account coordinator retirement revokes the reservation currency",
})
MAX_XML = 1024**2
TEST_SOURCE_SHA = "c651b7311891c76db21feaf90f0ef6c2373826fdf96d094ecb391fa648403529"
PUBLIC_EXCEPTIONS = frozenset({
    "java.lang.AssertionError", "java.lang.IllegalStateException", "java.lang.IllegalArgumentException",
    "java.lang.NullPointerException", "java.lang.ExceptionInInitializerError", "java.lang.UnsatisfiedLinkError",
    "java.util.concurrent.TimeoutException", "kotlin.UninitializedPropertyAccessException",
    "kotlinx.coroutines.TimeoutCancellationException", "kotlinx.coroutines.JobCancellationException",
    "org.json.JSONException", "org.junit.ComparisonFailure", "org.junit.internal.ArrayComparisonFailure",
})
GENERIC_FAILURE = "Website roster JVM test stage failed. No bounded public fixture diagnostic was available."


def require(condition, description):
    if not condition:
        raise ValueError(description)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def encode(value):
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=True) + "\n").encode()


def manifest(root, destination):
    require(root.is_dir() and not root.is_symlink() and root.resolve() == root,
            "source manifest requires the exact private workspace directory")
    rows = []
    for path in sorted(root.rglob("*")):
        require(not path.is_symlink(), "unexpected indirect private source entry")
        name = path.relative_to(root).as_posix()
        if path.is_file():
            rows.append({"path": name, "sha256": digest(path), "type": "file",
                         "executable": bool(path.stat().st_mode & 0o111)})
        else:
            require(path.is_dir(), "unexpected private source type")
            rows.append({"path": name, "type": "directory"})
    require(any(row["type"] == "file" and row["path"] == "Cargo.toml" for row in rows),
            "private source manifest is empty or misplaced")
    with destination.open("xb") as stream:
        stream.write(encode(rows))


def read_junit(root):
    expected_xml = root / ("TEST-" + TEST_CLASS + ".xml")
    require(root.is_dir() and not root.is_symlink() and set(root.glob("TEST-*.xml")) == {expected_xml},
            "wrong test report roster")
    require(expected_xml.is_file() and not expected_xml.is_symlink(), "test report is indirect")
    with expected_xml.open("rb") as stream:
        raw = stream.read(MAX_XML + 1)
    require(0 < len(raw) <= MAX_XML and not any(marker in raw for marker in
            (b"<!DOCTYPE", b"<!ENTITY", b"\0")), "invalid or oversized test report")
    suite = ET.fromstring(raw.decode("utf-8"))
    require(suite.tag == "testsuite" and suite.get("name") == TEST_CLASS, "test suite identity differs")
    return raw, suite


def junit_identity(root):
    raw, suite = read_junit(root)
    require(suite.get("tests") == str(len(TEST_CASES)) and
            all(suite.get(key) == "0" for key in ("failures", "errors", "skipped")) and
            suite.get("disabled", "0") == "0", "test summary differs")
    cases = suite.findall("testcase")
    require(len(cases) == len(TEST_CASES) and {node.get("name") for node in cases} == TEST_CASES and
            all(node.get("classname") == TEST_CLASS and node.get("status", "run") == "run" for node in cases) and
            not any(node.tag in ("failure", "error", "skipped", "disabled") for node in suite.iter()),
            "exact eleven test methods did not execute successfully")
    return hashlib.sha256(raw).hexdigest()


def failure_summary(results, source):
    try:
        _, suite = read_junit(results)
        cases = suite.findall("testcase")
        names = [case.get("name") for case in cases]
        require(0 < len(names) <= len(TEST_CASES) and set(names) <= TEST_CASES and len(set(names)) == len(names) and
                all(case.get("classname") == TEST_CLASS for case in cases), "failure test roster is not bounded")
        require(source.is_file() and not source.is_symlink() and source.stat().st_size <= MAX_XML and
                digest(source) == TEST_SOURCE_SHA, "failure line requires the exact public test source")
        public_lines = source.read_text(encoding="utf-8").splitlines()
        frame = re.compile(
            rf"(?m)^\s*at {re.escape(TEST_CLASS)}(?:\$[A-Za-z0-9_$]+)*\.[^()\r\n]{{1,180}}"
            r"\(NativeWebsiteRosterGatewayJniTest\.kt:([1-9][0-9]{0,3})\)[ \t]*$")
        for case in sorted(cases, key=lambda item: item.get("name")):
            failures = [child for child in case if child.tag in ("failure", "error")]
            if not failures:
                continue
            require(len(failures) == 1, "ambiguous fixture failure")
            failure = failures[0]
            kind = failure.get("type")
            require(kind in PUBLIC_EXCEPTIONS, "exception is not on the public allowlist")
            for match in frame.finditer(failure.text or ""):
                line = int(match.group(1))
                if line <= len(public_lines) and public_lines[line - 1].strip():
                    return f"Website roster JVM fixture failed: {case.get('name')} | {kind} | NativeWebsiteRosterGatewayJniTest.kt:{line}"
            return f"Website roster JVM fixture failed: {case.get('name')} | {kind} | JVM test stage"
    except (ValueError, OSError, UnicodeError, ET.ParseError):
        pass
    return GENERIC_FAILURE


def receipt(results, pre_source, post_source, library, before_library, output):
    require(re.fullmatch(r"[0-9a-f]{64}", before_library) is not None and
            library.is_file() and not library.is_symlink() and library.stat().st_size > 0,
            "wrong host JNI library identity")
    after_library = digest(library)
    source_hash = digest(pre_source)
    after_source = digest(post_source)
    require(before_library == after_library and source_hash == after_source,
            "host JNI or private input digest changed during tests")
    xml_hash = junit_identity(results)
    run = os.environ["GITHUB_RUN_ID"]
    ops = os.environ["GITHUB_SHA"]
    require(re.fullmatch(r"[1-9][0-9]{0,17}", run) is not None and
            re.fullmatch(r"[0-9a-f]{40}", ops) is not None and
            os.environ["GITHUB_RUN_ATTEMPT"] == "1" and os.environ["GITHUB_REF"] == OP_REF and
            os.environ["VORTX_JNI_WEBSITE_ROSTER_ADMISSION"] == "1",
            "wrong hosted proof identity")
    public = {
        "schemaVersion": 1, "status": "PASS", "appSource": APP_SOURCE, "engineSource": ENGINE_SOURCE,
        "operationsSource": ops, "operationsRef": OP_REF, "runId": int(run), "attempt": 1,
        "toolchain": "nightly-2026-07-19", "features": "jni,server,resource-host",
        "hostTarget": "x86_64-unknown-linux-gnu", "testClass": TEST_CLASS, "tests": len(TEST_CASES),
        "skipped": 0, "failures": 0, "errors": 0, "sourceInputsSha256": source_hash,
        "postRuntimeSourceInputsSha256": after_source, "librarySha256": before_library,
        "postRuntimeLibrarySha256": after_library, "junitXmlSha256": xml_hash,
    }
    data = encode(public)
    require(len(data) <= 4096 and output.is_dir() and not output.is_symlink() and not list(output.iterdir()),
            "public proof output is unsafe")
    with (output / "website-roster-jni-proof.json").open("xb") as stream:
        stream.write(data)
    checksum = hashlib.sha256(data).hexdigest()
    with (output / "website-roster-jni-proof.sha256").open("x", encoding="ascii") as stream:
        stream.write(f"{checksum}  website-roster-jni-proof.json\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    source = sub.add_parser("manifest")
    source.add_argument("workspace", type=Path)
    source.add_argument("output", type=Path)
    proof = sub.add_parser("receipt")
    for name in ("results", "pre_source", "post_source", "library"):
        proof.add_argument(name, type=Path)
    proof.add_argument("before_library")
    proof.add_argument("output", type=Path)
    diagnosis = sub.add_parser("diagnose")
    diagnosis.add_argument("results", type=Path)
    diagnosis.add_argument("test_source", type=Path)
    args = parser.parse_args()
    if args.command == "manifest":
        manifest(args.workspace, args.output)
    elif args.command == "receipt":
        receipt(args.results, args.pre_source, args.post_source, args.library, args.before_library, args.output)
    else:
        print(failure_summary(args.results, args.test_source))


if __name__ == "__main__":
    main()
