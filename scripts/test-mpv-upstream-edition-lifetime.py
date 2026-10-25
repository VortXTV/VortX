#!/usr/bin/env python3
"""Pinned actual-prefix integrity and sanitized behavior; record ASan baseline.

Synthetic tag/stream carriers only; no FFmpeg/player/network-media/device use.
The changed production C block, common macro and formatter body are extracted
unchanged from SHA-pinned source. This is not a whole-mpv runtime test.
An original bitrate case that returns the correct text without a diagnostic is
recorded as NOT_REPRODUCED, never as a causal ASan failure. Strict sanitizer
flags and all patched behavior requirements remain enforced.
"""
import hashlib
import http.client
import json
import os
import pathlib
import ssl
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "app/build/mpv-edition-lifetime"
PIN = "8c67647b50059406c5c0444903597281b81516cf"
PATCH = ROOT / "scripts/mpv-upstream-edition-title-lifetime.patch"
PATCH_SHA = "c2b8e1524a384e9a9de92ffc061991590a7220bd80b3f951e52073af9f39cb7a"
PATCHED_SOURCE_SHA = "2d29b7e4dd9fd4df4e7e2ee25dce461a4330eb3b2f9f7e79d8a8a70fc9601915"
HASHES = {
    "demux/demux_lavf.c": "9be11d2ce5dbc8e9681b337348826c6138bc8569e0db1f46b9c507f4edf0633c",
    "common/common.h": "823dc6a0ebf64de6daa8c55c9a21f512d11a41587123f45a9f00647a8112fcce",
    "common/common.c": "62366ff8c4b58208840008bf4272a625c8ff54c8fad358e110dfb56f514af1e3",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source(name):
    expected = HASHES[name]
    local = os.environ.get("VORTX_MPV_SOURCE_DIR")
    data = None
    if local:
        # Resolve the exact public commit, not possibly modified working bytes.
        # Never let a partial clone silently fetch while this local route runs.
        result = subprocess.run(
            ["git", "-C", local, "show", f"{PIN}:{name}"],
            capture_output=True, timeout=15,
            env={**os.environ, "GIT_NO_LAZY_FETCH": "1"})
        if result.returncode == 0:
            data = result.stdout
    if data is None:
        cache = BUILD / "source" / name
        if cache.exists():
            data = cache.read_bytes()
        else:
            connection = http.client.HTTPSConnection(
                "raw.githubusercontent.com", timeout=20,
                context=ssl.create_default_context())
            try:
                connection.request("GET", f"/mpv-player/mpv/{PIN}/{name}",
                                   headers={"Accept-Encoding": "identity"})
                response = connection.getresponse()
                if response.status != 200 or response.getheader("Content-Encoding", "identity") != "identity":
                    raise RuntimeError("pinned source refused: HTTP/encoding")
                declared = response.getheader("Content-Length")
                if declared is not None and (not declared.isdecimal() or not 0 < int(declared) <= 1024 * 1024):
                    raise RuntimeError("invalid pinned source length")
                data = response.read(1024 * 1024 + 1)
                if declared is not None and len(data) != int(declared):
                    raise RuntimeError("pinned source length mismatch")
            finally:
                connection.close()
            if not data or len(data) > 1024 * 1024 or digest(data) != expected:
                raise RuntimeError(f"pinned source drift: {name}")
            cache.parent.mkdir(parents=True, exist_ok=True)
            with cache.open("xb") as output:
                output.write(data)
    if not data or len(data) > 1024 * 1024 or digest(data) != expected:
        raise RuntimeError(f"pinned source drift: {name}")
    return data.decode("utf-8")


def once(text, anchor):
    if text.count(anchor) != 1:
        raise RuntimeError(f"production extraction anchor drift: {anchor}")
    return text.index(anchor)


def prefix_block(text):
    start = once(text, '        const char *prefix = mp_tags_get_str(ed.metadata, "title");')
    end = once(text, '        char *title = demux_compose_edition_title(demuxer, demuxer,')
    if end <= start:
        raise RuntimeError("production prefix bounds drift")
    return text[start:end]


HARNESS = r'''
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct mp_tags { const char *title, *service_name, *comment, *variant_bitrate; };
struct sh { struct mp_tags *tags; };
struct stream { struct sh *sh; };
struct priv { struct stream **streams; };
static char *mp_tags_get_str(struct mp_tags *tags, const char *name) {
    if (!strcmp(name, "title")) return (char *)tags->title;
    if (!strcmp(name, "service_name")) return (char *)tags->service_name;
    if (!strcmp(name, "comment")) return (char *)tags->comment;
    if (!strcmp(name, "variant_bitrate")) return (char *)tags->variant_bitrate;
    return NULL;
}
FORMATTER
MACRO
__attribute__((noinline)) static int render(char *out, size_t size,
        struct mp_tags *metadata, struct mp_tags *stream_tags,
        int video_count, int audio_count) {
    struct { struct mp_tags *metadata; } ed = {metadata};
    struct sh sh = {stream_tags};
    struct stream stream = {&sh};
    struct stream *streams[] = {&stream};
    struct priv state = {streams};
    struct priv *priv = &state;
    int video_idx = 0, audio_idx = 0;
PREFIX
    // Real composition consumes the prefix here, after the nested block ends.
    const char *chosen = prefix ? prefix : "NONE";
    volatile unsigned char observed = (unsigned char)chosen[0];
    (void)observed;
    return snprintf(out, size, "%s", chosen);
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    struct mp_tags metadata = {0}, tags = {0};
    int videos = 0, audios = 0;
    if (!strcmp(argv[1], "title")) metadata.title = "Title";
    else if (!strcmp(argv[1], "service")) metadata.service_name = "Service";
    else if (!strcmp(argv[1], "video-comment")) { tags.comment = "Video"; videos = 1; }
    else if (!strcmp(argv[1], "audio-comment")) { tags.comment = "Audio"; audios = 1; }
    else if (!strcmp(argv[1], "bitrate")) metadata.variant_bitrate = argv[2];
    else if (strcmp(argv[1], "none")) return 2;
    char output[128];
    int length = render(output, sizeof(output), &metadata, &tags, videos, audios);
    if (length < 0 || (size_t)length >= sizeof(output)) return 2;
    puts(output);
    return 0;
}
'''


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    run = pathlib.Path(tempfile.mkdtemp(prefix="actual.", dir=BUILD))
    inputs = {name: source(name) for name in HASHES}
    if digest(PATCH.read_bytes()) != PATCH_SHA:
        raise RuntimeError("production patch carrier drift")
    patched = run / "patched/demux/demux_lavf.c"
    patched.parent.mkdir(parents=True)
    patched.write_text(inputs["demux/demux_lavf.c"])
    patch_result = subprocess.run(["patch", "-f", "-p1", "-i", str(PATCH),
                                   "-d", str(run / "patched")],
                                  capture_output=True, timeout=20)
    (run / "patch.stdout").write_bytes(patch_result.stdout)
    (run / "patch.stderr").write_bytes(patch_result.stderr)
    if patch_result.returncode != 0:
        raise RuntimeError("production patch does not apply to pinned source")
    patched_sha = digest(patched.read_bytes())
    if patched_sha != PATCHED_SOURCE_SHA:
        raise RuntimeError("patched production source afterimage drift")
    common_h, common_c = inputs["common/common.h"], inputs["common/common.c"]
    macro_start = once(common_h, "#define mp_tprintf(SIZE, format, ...) \\")
    macro = "\n".join(common_h[macro_start:].splitlines()[:2])
    formatter_start = once(common_c, "char *mp_tprintf_buf(char *buf, size_t buf_size, const char *format, ...)")
    formatter = common_c[formatter_start:common_c.index("\n}", formatter_start)+2]
    env = {**os.environ, "ASAN_OPTIONS": "detect_stack_use_after_return=1:halt_on_error=1:abort_on_error=0:exitcode=1",
           "UBSAN_OPTIONS": "halt_on_error=1"}
    results = []
    compilers = []
    generated_source = {}

    def write_receipt(accepted=False, complete=False, failure=None):
        baseline = [item for item in results
                    if item["source"] == "original" and item["kind"] == "bitrate"]
        reproduced = sum(item["diagnosis"] == "STACK_USE_AFTER_SCOPE_REPRODUCED"
                         for item in baseline)
        if len(baseline) != 2 or any(not item["accepted"] for item in baseline):
            status = "INCOMPLETE_OR_UNEXPECTED"
        elif reproduced == 2:
            status = "REPRODUCED"
        elif reproduced == 0:
            status = "NOT_REPRODUCED"
        else:
            status = "PARTIALLY_REPRODUCED"
        patched_cases = [item for item in results if item["source"] == "patched"]
        original_controls = [item for item in results
                             if item["source"] == "original" and item["kind"] != "bitrate"]
        (run / "result.json").write_text(json.dumps({
            "accepted": accepted, "complete": complete, "failure": failure,
            "acceptanceScope": "pinned source integrity, two original controls and eleven patched sanitized behavior checks; causal reproduction is reported separately",
            "sourceIntegrityAccepted": digest(PATCH.read_bytes()) == PATCH_SHA,
            "patchedBehaviorAccepted": len(patched_cases) == 11 and all(item["accepted"] for item in patched_cases),
            "originalControlsAccepted": len(original_controls) == 2 and all(item["accepted"] for item in original_controls),
            "causalBaseline": {"status": status, "requiredCases": 2,
                               "observedCases": len(baseline),
                               "reproducedCases": reproduced,
                               "causalRequirementSatisfied": status == "REPRODUCED"},
            "results": results, "compilers": compilers,
            "sourceHashes": HASHES, "patchSHA256": PATCH_SHA,
            "patchedSourceSHA256": patched_sha,
            "generatedSource": generated_source,
            "scope": "actual prefix/macro/formatter with synthetic carriers; not whole-player/runtime/device proof; NOT_REPRODUCED is no causal RED",
        }, indent=2)+"\n")

    write_receipt()
    for label, text in [("original", inputs["demux/demux_lavf.c"]),
                        ("patched", patched.read_text())]:
        unit, binary = run / f"{label}.c", run / f"{label}-probe"
        unit.write_text(HARNESS.replace("FORMATTER", formatter).replace("MACRO", macro)
                        .replace("PREFIX", prefix_block(text)))
        generated_source[label] = digest(unit.read_bytes())
        command = ["clang", "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                   "-fno-omit-frame-pointer", "-fsanitize=address,undefined",
                   "-fsanitize-address-use-after-scope", str(unit), "-o", str(binary)]
        compiled = subprocess.run(command, capture_output=True, timeout=60)
        (run / f"{label}.compile.stdout").write_bytes(compiled.stdout)
        (run / f"{label}.compile.stderr").write_bytes(compiled.stderr)
        compilers.append({"source": label, "command": command,
                          "returncode": compiled.returncode})
        if compiled.returncode != 0:
            write_receipt(failure=f"{label} actual-block compiler failure")
            raise RuntimeError(f"{label} actual-block compiler failure")
        cases = [("bitrate", "123000", "Bitrate: 123 kbps"),
                 ("bitrate", "5000000", "Bitrate: 5.000 Mbps")]
        if label == "original":
            cases += [("title", "", "Title"), ("none", "", "NONE")]
        else:
            cases += [("title", "", "Title"), ("service", "", "Service"),
                      ("video-comment", "", "Video"), ("audio-comment", "", "Audio"),
                      ("none", "", "NONE"), ("bitrate", "0", "NONE"),
                      ("bitrate", "-1", "NONE"), ("bitrate", "bad", "NONE"),
                      ("bitrate", "123000garbage", "NONE")]
        for index, (kind, value, expected) in enumerate(cases):
            result = subprocess.run([str(binary), kind, value], capture_output=True,
                                    timeout=15, env=env)
            (run / f"{label}.{index}.stdout").write_bytes(result.stdout)
            (run / f"{label}.{index}.stderr").write_bytes(result.stderr)
            normal_behavior = (result.returncode == 0 and result.stderr == b""
                               and result.stdout.decode().strip() == expected)
            if label == "original" and kind == "bitrate":
                reproduced = (result.returncode == 1
                              and b"AddressSanitizer: stack-use-after-scope" in result.stderr)
                accepted = reproduced or normal_behavior
                diagnosis = ("STACK_USE_AFTER_SCOPE_REPRODUCED" if reproduced else
                             "NOT_REPRODUCED" if normal_behavior else "UNEXPECTED")
            else:
                accepted = normal_behavior
                diagnosis = "SANITIZED_BEHAVIOR_PASS" if accepted else "UNEXPECTED"
            results.append({"source": label, "kind": kind, "value": value,
                            "expectedOutput": expected, "returncode": result.returncode,
                            "diagnosis": diagnosis, "accepted": accepted,
                            "stdoutSHA256": digest(result.stdout),
                            "stderrSHA256": digest(result.stderr),
                            "stdoutFile": f"{label}.{index}.stdout",
                            "stderrFile": f"{label}.{index}.stderr"})
            write_receipt(failure=None if accepted else f"unexpected {label} causal/behavior result {index}")
            if not accepted:
                raise RuntimeError(f"unexpected {label} causal/behavior result {index}")
    conserved = digest(PATCH.read_bytes()) == PATCH_SHA
    if not conserved:
        write_receipt(failure="production patch changed during check")
        raise RuntimeError("production patch changed during check")
    write_receipt(accepted=True, complete=True)
    baseline_status = json.loads((run / "result.json").read_text())["causalBaseline"]["status"]
    print(f"PASS: pinned-source integrity + 2 original controls + 11 patched sanitized behavior checks; original causal baseline {baseline_status}; evidence {run}")


if __name__ == "__main__":
    main()
