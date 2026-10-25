#!/usr/bin/env python3
"""Real-SDK compile-only checks for VortX's approved TV no-UI compatibility boundary.

No executable is linked or run; no SecItem operation, account, network, app or package is used.
Run the single worker with nice15. Explicit current source hashes are mandatory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile


HELPER = "VortXTVKeychainAuthenticationUIFailCompatibilityValue"
BRIDGE = "app/Sources/Player/VortX-Bridging.h"
ADAPTER = "app/SourcesShared/XperienceExportSystemKeychain.swift"
HEADERS = [BRIDGE, "app/Sources/Player/VortXRemuxInputProbe.h",
           "app/Sources/Player/VortXCrashSignal.h",
           "app/SourcesShared/SMB/VortXSMBShim.h",
           "app/SourcesShared/JSProviders/QuickJS/VortXQuickJSBridge.h",
           "app/Sources/Player/VXTrailerNetworkOwner.h"]
TARGETS = [("tv", "appletvos", "arm64-apple-tvos18.0", 1),
           ("mac", "macosx", "arm64-apple-macosx14.0", 0),
           ("ios", "iphoneos", "arm64-apple-ios16.0", 0)]
active = None


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def stop_child():
    if active is not None and active.poll() is None:
        try:
            os.killpg(active.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            active.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(active.pid, signal.SIGKILL)
            active.wait()


def interrupted(signum, _frame):
    stop_child()
    raise InterruptedError(f"Interrupted by signal {signum}; no further lane admitted")


def main():
    global active
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--bridge-sha256", required=True)
    parser.add_argument("--adapter-sha256", required=True)
    args = parser.parse_args()
    require(sys.platform == "darwin" and os.getpriority(os.PRIO_PROCESS, 0) >= 15,
            "Requires one macOS worker launched with /usr/bin/nice -n 15")
    for pin in (args.bridge_sha256, args.adapter_sha256):
        require(re.fullmatch(r"[a-f0-9]{64}", pin), "Exact approved SHA256 pins required")
    root = Path(args.root).resolve(strict=True)
    base = Path("/Users/daksh/VortXTV")
    require(root == base / "VortX" or (root.parent == base / ".worktrees/VortX"
            and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", root.name)),
            "Root must be the canonical app or one canonical registered branch workspace")
    registry = base / ".worktrees/REGISTRY.tsv"
    if root != base / "VortX":
        rows = [line.split("\t") for line in registry.read_text().splitlines()]
        matching = [row for row in rows if len(row) >= 6 and row[3] == str(root)]
        status = (matching[-1][6] if len(matching[-1]) >= 7 else matching[-1][5]) if matching else None
        require(status == "active", "Worktree must be registered active")
    require(digest(root / BRIDGE) == args.bridge_sha256, "Bridge differs from approved source")
    require(digest(root / ADAPTER) == args.adapter_sha256, "Adapter differs from approved source")
    build = root / "app/build"
    build.mkdir(exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="tvos-keychain-no-ui.", dir=build))
    require(output.resolve().parent == build.resolve(), "Fresh output escaped app/build")
    print(f"Retained compile-only evidence: {output}", flush=True)
    held, generated, checks = {}, {}, []
    env = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME") if key in os.environ}
    env.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin", LANG="C", LC_ALL="C", TMPDIR=str(output))

    def stamp(path):
        info = path.stat()
        return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]

    def hold(path, tool=False):
        path = Path(path)
        require(path.is_file(), f"Required regular input missing: {path}")
        held[str(path)] = {"realpath": str(path.resolve()), "sha256": digest(path),
                           "tool": tool, "stat": stamp(path)}
        return path

    def write(name, text):
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("xb" if isinstance(text, bytes) else "x") as stream:
            stream.write(text)
        generated[str(path)] = digest(path)
        return path

    def conserve(full_tools=False):
        for name, pin in held.items():
            path = Path(name)
            require(str(path.resolve()) == pin["realpath"] and stamp(path) == pin["stat"],
                    f"Conserved input identity/metadata changed: {name}")
            require(pin["tool"] and not full_tools or digest(path) == pin["sha256"],
                    f"Conserved original/tool/SDK input changed: {name}")
        for name, pin in generated.items():
            require(digest(Path(name)) == pin, f"Generated input/output changed: {name}")

    def run(name, command, expected=0, needles=()):
        global active
        conserve()
        write(name + ".command.json", json.dumps(command) + "\n")
        stdout, stderr = output / (name + ".stdout"), output / (name + ".stderr")
        with stdout.open("xb") as out, stderr.open("xb") as err:
            active = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                      cwd=output, env=env, start_new_session=True)
            try:
                code = active.wait(timeout=120)
            except BaseException:
                stop_child()
                raise
            finally:
                active = None
        require(stdout.stat().st_size <= 32 * 1024 ** 2 and stderr.stat().st_size <= 2 * 1024 ** 2,
                f"Diagnostic/output bound exceeded: {name}")
        generated[str(stdout)], generated[str(stderr)] = digest(stdout), digest(stderr)
        text = stderr.read_text(errors="replace")
        require(code == expected, f"{name} exited {code}, expected {expected}; inspect retained stderr")
        if expected == 0:
            require(not text.strip(), f"Unexpected successful-lane diagnostic: {name}")
        else:
            # Swift may echo its one diagnostic beside a source caret. Count
            # primary file:line:column diagnostics, not duplicate highlighted text.
            primary_errors = re.findall(r"(?m)^[^\n]*:\d+:\d+: error: ([^\n]+)", text)
            require(len(primary_errors) == 1 and all(token in primary_errors[0] for token in needles),
                    f"Negative lane did not fail solely as expected: {name}")
        conserve()
        checks.append({"name": name, "exit": code, "expected": expected})
        return stdout.read_text(errors="replace")

    outcome = {"exit": 1, "scope": "Real SDK/header compile-only; no Keychain/runtime/package proof"}
    try:
        hold(Path(__file__).resolve())
        hold(Path(sys.executable).resolve(), tool=True)
        hold(Path("/usr/bin/xcrun"), tool=True)
        for relative in HEADERS + [ADAPTER, "app/project.yml", "scripts/generate-native-apple-project.rb"]:
            original = hold(root / relative)
            approved = {BRIDGE: args.bridge_sha256, ADAPTER: args.adapter_sha256}.get(relative)
            require(approved is None or held[str(original)]["sha256"] == approved,
                    "Captured source differs from explicit approved pin")
            snapshot = write("inputs/" + relative, original.read_bytes())
            require(generated[str(snapshot)] == held[str(original)]["sha256"], "Snapshot bytes differ")
        bridge = output / "inputs" / BRIDGE
        tools = {}
        for name in ("clang", "swiftc"):
            found = run("find-" + name, ["/usr/bin/xcrun", "--find", name]).strip()
            tool = Path(found)
            require(tool.is_absolute() and tool.name == name, "Unexpected compiler discovery")
            tools[name] = str(hold(tool, tool=True))
        hold(Path(tools["swiftc"]).resolve().with_name("swift-frontend"), tool=True)
        for label, sdk_name, triple, is_tv in TARGETS:
            sdk = Path(run(label + "-sdk", ["/usr/bin/xcrun", "--sdk", sdk_name, "--show-sdk-path"]).strip())
            require(sdk.is_absolute() and sdk.is_dir(), "Genuine SDK discovery failed")
            hold(sdk / "SDKSettings.json")
            hold(sdk / "usr/include/TargetConditionals.h")
            hold(sdk / "System/Library/Frameworks/Security.framework/Headers/SecItem.h")
            cache = output / ("cache-" + label)
            cache.mkdir()
            cflags = [tools["clang"], "-target", triple, "-isysroot", str(sdk), "-x", "objective-c",
                      "-fmodules", "-fobjc-arc", "-fblocks", "-Werror", "-Wdeprecated-declarations",
                      "-fno-color-diagnostics", "-fmodules-cache-path=" + str(cache),
                      '-DCONFIG_VERSION="2025-09-13"']
            base_text = f'#import "{bridge}"\n'
            base_m = write(label + "-base.m", base_text)
            macros = run(label + "-macros", cflags + ["-dM", "-E", str(base_m)])
            require(re.search(rf"^#define TARGET_OS_TV {is_tv}$", macros, re.M), "Unexpected TV target macro")
            body = run(label + "-preprocessed", cflags + ["-E", "-P", str(base_m)])
            require((HELPER + "(") in body if is_tv else HELPER not in body,
                    "TV helper platform boundary differs")
            swift_flags = [tools["swiftc"], "-typecheck", "-parse-as-library", "-swift-version", "6",
                           "-strict-concurrency=complete", "-warnings-as-errors", "-j", "1", "-num-threads", "1",
                           "-module-name", "VortXKeychainNoUIProbe", "-target", triple, "-sdk", str(sdk),
                           "-module-cache-path", str(cache), "-import-objc-header", str(bridge),
                           "-Xcc", '-DCONFIG_VERSION="2025-09-13"']
            swift_body = "import Foundation\n"
            if is_tv:
                positive_m = write("tv-positive.m", base_text + f"CFStringRef VortXProbe(void) {{ return {HELPER}(); }}\n")
                run("tv-clang-positive", cflags + ["-fsyntax-only", str(positive_m)])
                positive_swift = write("tv-positive.swift", swift_body + f"func probe() -> CFString {{ {HELPER}() }}\n")
                run("tv-swift-positive", swift_flags + [str(positive_swift)])
                negative_m = write("tv-deprecated-negative.m", base_text + "CFStringRef VortXNegative(void) { return kSecUseAuthenticationUIFail; }\n")
                run("tv-clang-deprecated-negative", cflags + ["-fsyntax-only", str(negative_m)], 1,
                    ("kSecUseAuthenticationUIFail", "deprecated"))
                negative_swift = write("tv-deprecated-negative.swift", swift_body + "import Security\nfunc probe() -> CFString { kSecUseAuthenticationUIFail }\n")
                run("tv-swift-deprecated-negative", swift_flags + [str(negative_swift)], 1,
                    ("kSecUseAuthenticationUIFail", "deprecated"))
                ir = output / "tv-positive.ll"
                run("tv-public-symbol-ir", cflags + ["-O0", "-S", "-emit-llvm", str(positive_m), "-o", str(ir)])
                require(ir.is_file() and ir.stat().st_size < 2 * 1024 ** 2, "IR output missing/oversized")
                generated[str(ir)] = digest(ir)
                require(re.search(r"\bload\b[^\n]*@kSecUseAuthenticationUIFail\b", ir.read_text()),
                        "Helper did not load the original exported public symbol")
            else:
                run(label + "-clang-positive", cflags + ["-fsyntax-only", str(base_m)])
                positive_swift = write(label + "-positive.swift", swift_body + "func probe() -> Int { 1 }\n")
                run(label + "-swift-positive", swift_flags + [str(positive_swift)])
                negative_swift = write(label + "-helper-absent.swift", swift_body + f"func probe() {{ _ = {HELPER}() }}\n")
                run(label + "-swift-helper-absent", swift_flags + [str(negative_swift)], 1,
                    ("cannot find", HELPER))
        conserve(full_tools=True)
        outcome.update(exit=0, conserved=True, checks=checks)
        print(f"PASS {len(checks)} sequential real-SDK compile/preprocess checks; no runtime or Keychain calls", flush=True)
    except BaseException as error:
        outcome["failure"] = str(error)
        raise
    finally:
        stop_child()
        try:
            conserve(full_tools=outcome["exit"] != 0)
        except BaseException as error:
            outcome.update(exit=1, conserved=False, conservation_error=str(error))
            raise
        finally:
            outcome.update(originals=held, generated=generated, checks=checks,
                           boundaries=["no executable linked/run", "no SecItem operation", "no source/pin/account write",
                                       "critical SDK metadata/headers only; not full SDK binary-tree conservation"])
            with (output / "result.json").open("x") as stream:
                json.dump(outcome, stream, indent=2)
                stream.write("\n")


if __name__ == "__main__":
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    main()
