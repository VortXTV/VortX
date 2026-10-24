#!/usr/bin/env bash
set -euo pipefail

# Hosted, manually requested candidate build only. Never installs into app/Vendor or publishes.
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_EVENT_NAME:-} == workflow_dispatch ]] || exit 1
[[ ${GITHUB_REPOSITORY:-} == VortXTV/VortX ]] || exit 1
lane=${1:?apple or android required}
[[ $lane == apple || $lane == android ]] || exit 1
root=$(cd "$(dirname "$0")/../.." && pwd -P)
[[ $root == "$GITHUB_WORKSPACE" && $(git -C "$root" rev-parse HEAD) == "$GITHUB_SHA" ]] || exit 1
[[ -z $(git -C "$root" status --porcelain --untracked-files=no) ]] || exit 1
cd "$root"
shasum -a 256 -c scripts/native-media-hosted/inputs.sha256
out="$root/_build/native-media/$lane"
mkdir -p "$out"
[[ ! -e "$out/result.json" ]] || { echo 'Refusing an existing build receipt' >&2; exit 1; }
if [[ $lane == apple ]]; then
    upstream="$root/_native-mpvkit"
    expected=2103893078c5e339073b11737b86f7f22b9c4491
else
    upstream="$root/_native-publisher"
    expected=fcf6745703dc1265bca88f12fee8fc355ddf251e
fi
[[ $(git -C "$upstream" rev-parse HEAD) == "$expected" ]] || exit 1
[[ -z $(git -C "$upstream" status --porcelain --untracked-files=all) ]] || exit 1
finish() {
    result=$?
    trap - EXIT
    set +e
    python3 "$root/scripts/native-media-hosted/evidence.py" receipt "$lane" "$out" "$upstream" "$result"
    receipt_result=$?
    [[ $result != 0 || $receipt_result == 0 ]] || result=$receipt_result
    exit "$result"
}
trap finish EXIT
cp scripts/native-media-hosted/inputs.sha256 "$out/reviewed-inputs.sha256"
git -C "$upstream" archive HEAD | gzip > "$out/original-upstream-source.tar.gz"

if [[ $lane == apple ]]; then
    {
        xcodebuild -version
        xcrun --sdk macosx --show-sdk-version
        xcrun --sdk iphoneos --show-sdk-version
        xcrun --sdk appletvos --show-sdk-version
        swift --version
        brew list --versions
    } > "$out/toolchain.txt" 2>&1
    MPVKIT_DVFEL_WORK="$upstream" MPVKIT_DVFEL_DEST="$out/MPVKit-DVFEL" \
        bash scripts/build-mpvkit-dvfel.sh
    # Existing builder already runs these; explicit retained log identifies candidate acceptance only.
    bash scripts/verify-mpvkit-dvfel-artifacts.sh "$out/MPVKit-DVFEL" > "$out/apple-artifact-gate.txt" 2>&1
    tar -czf "$out/apple-candidate.tar.gz" -C "$out" MPVKit-DVFEL
    # Keep the original per-library ZIP bytes used by assembly, separately from the assembled package.
    tar -cf "$out/apple-original-library-zips.tar" -C "$upstream/dist/release" \
        Libmpv.xcframework.zip Libavcodec.xcframework.zip Libavdevice.xcframework.zip \
        Libavfilter.xcframework.zip Libavformat.xcframework.zip Libavutil.xcframework.zip \
        Libswresample.xcframework.zip Libswscale.xcframework.zip Libplacebo.xcframework.zip
else
    # Downstream make/meson generators invoke python3 from PATH. Verify that SAME isolated
    # interpreter and its complete pinned third-party closure before downloading/building.
    unset PYTHONPATH PYTHONHOME
    export PYTHONNOUSERSITE=1
    export PYTHON="$(command -v python3)"
    "$PYTHON" -I - "${RUNNER_TEMP:?hosted temporary directory required}/vortx-native-media-tools" \
        > "$out/python-toolchain.json" <<'PYTHON_TOOLCHAIN'
import importlib
import importlib.metadata
import json
from pathlib import Path
import platform
import site
import sys

tools = Path(sys.argv[1]).resolve()
if (Path(sys.prefix).resolve() != tools or sys.prefix == sys.base_prefix
        or sys.version_info[:2] != (3, 12) or platform.system() != "Linux"
        or platform.machine() != "x86_64" or site.ENABLE_USER_SITE is not False):
    raise SystemExit("Unexpected native media Python interpreter/isolation")
config = dict(line.strip().split(" = ", 1) for line in (tools / "pyvenv.cfg").read_text().splitlines()
              if " = " in line)
if config.get("include-system-site-packages") != "false":
    raise SystemExit("System site packages are not permitted")
packages = {}
for distribution, module_name, expected_version in [
        ("meson", "mesonbuild", "1.12.1"), ("Jinja2", "jinja2", "3.1.6"),
        ("MarkupSafe", "markupsafe", "3.0.4"), ("jsonschema", "jsonschema", "4.26.0"),
        ("attrs", "attrs", "26.1.0"),
        ("jsonschema-specifications", "jsonschema_specifications", "2025.9.1"),
        ("referencing", "referencing", "0.37.0"), ("rpds-py", "rpds", "2026.9.1"),
        ("typing-extensions", "typing_extensions", "4.16.0")]:
    module = importlib.import_module(module_name)
    origin = Path(module.__file__).resolve()
    metadata = importlib.metadata.distribution(distribution)
    if (metadata.version != expected_version or not origin.is_relative_to(tools)
            or not Path(metadata.locate_file("")).resolve().is_relative_to(tools)):
        raise SystemExit("Unexpected native media Python package/version/origin")
    packages[distribution] = {"version": metadata.version, "module": str(origin)}
# Exercise the actual generator libraries' ordinary APIs, not only metadata imports.
jinja_module = importlib.import_module("jinja2")
schema_module = importlib.import_module("jsonschema")
if jinja_module.Environment().from_string("{{ value|e }}").render(value="<probe>") != "&lt;probe&gt;":
    raise SystemExit("Jinja2 rendering preflight failed")
schema_module.validate({"bounded": True}, {"type": "object",
                       "properties": {"bounded": {"type": "boolean"}},
                       "required": ["bounded"], "additionalProperties": False})
json.dump({"executable": sys.executable, "python": sys.version, "basePrefix": sys.base_prefix,
           "platform": platform.platform(), "systemSitePackages": False,
           "userSitePackages": False, "packages": packages}, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PYTHON_TOOLCHAIN
    overlay="$root/scripts/native-media-hosted/android"
    # Exact public checkout plus reviewed overlay; never use an existing dirty dependency directory.
    for relative in buildscripts/include/depinfo.sh buildscripts/include/download-deps.sh \
        buildscripts/include/download-lua.sh buildscripts/include/download-libunibreak.sh \
        buildscripts/scripts/ffmpeg.sh buildscripts/patch.sh \
        buildscripts/patches/ffmpeg/0001-emudhra-spki-distrust.patch; do
        mkdir -p "$upstream/$(dirname "$relative")"
        cp "$overlay/$relative" "$upstream/$relative"
    done
    # Keep the selected producer's HTTP interruption fix and use the same new
    # upstream audio/seek backports as Apple. All patch bytes are input-hash bound.
    mkdir -p "$upstream/buildscripts/patches/mpv"
    cp "$root/scripts/mpv-http-seek-interrupt.patch" "$upstream/buildscripts/patches/mpv/0001-http-seek-interrupt.patch"
    cp "$root/scripts/mpv-upstream-audio-layout-bounds.patch" "$upstream/buildscripts/patches/mpv/0002-upstream-audio-layout-bounds.patch"
    cp "$root/scripts/mpv-upstream-gpu-next-seek-reset.patch" "$upstream/buildscripts/patches/mpv/0003-upstream-gpu-next-seek-reset.patch"
    # Same original-source witness prerequisite as Apple; no renderer/consumer activation.
    cp "$root/scripts/mpv-original-local-file-witness.patch" "$upstream/buildscripts/patches/mpv/0004-original-local-file-witness.patch"
    git -C "$upstream" apply --check "$root/scripts/native-media-hosted/android-assembly.patch"
    git -C "$upstream" apply "$root/scripts/native-media-hosted/android-assembly.patch"
    # Use the hosted SDK; bypass upstream download-sdk.sh's moving gas-preprocessor/master fetch.
    : "${ANDROID_HOME:?hosted Android SDK required}"
    mkdir -p "$upstream/buildscripts/sdk/bin"
    ln -s "$ANDROID_HOME" "$upstream/buildscripts/sdk/android-sdk-linux"
    sdkmanager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
    [[ -x $sdkmanager ]] || exit 1
    printf 'y\n' | "$sdkmanager" --sdk_root="$ANDROID_HOME" \
        'platforms;android-37.0' 'build-tools;37.0.0' 'ndk;30.0.16248370' 'cmake;4.1.2'
    gas="$upstream/buildscripts/sdk/bin/gas-preprocessor.pl"
    curl --fail --location --proto '=https' --proto-redir '=https' --max-time 120 \
        'https://raw.githubusercontent.com/FFmpeg/gas-preprocessor/ac1836309c2e77023c228b7184485597286289d3/gas-preprocessor.pl' -o "$gas"
    printf '%s  %s\n' 7124d70cdecba7c5612f9a71fbf3f28514dd9c2ca3022f58ad793f88bb925fcf "$gas" | shasum -a 256 -c -
    chmod +x "$gas"
    {
        java -version
        meson --version
        cmake --version
        ninja --version
        dpkg-query -W autoconf automake libtool pkgconf meson ninja-build nasm gperf python3-jinja2
        cat "$ANDROID_HOME/ndk/30.0.16248370/source.properties"
    } > "$out/toolchain.txt" 2>&1
    cd "$upstream/buildscripts"
    bash -e include/download-deps.sh
    bash patch.sh
    # Retain exactly the reviewed native source/patch state before any compiler runs.
    git -C deps/ffmpeg diff --binary > "$out/ffmpeg-applied.patch"
    cp deps/ffmpeg/libavformat/tls_mbedtls_vortx_distrust.h "$out/tls_mbedtls_vortx_distrust.h"
    # Includes non-Git Lua/libunibreak and submodule contents; captured before generated build files.
    tar -czf "$out/android-corresponding-sources.tar.gz" --exclude=.git -C "$upstream/buildscripts" deps
    export cores=2 CMAKE_BUILD_PARALLEL_LEVEL=2
    for arch in armv7l arm64 x86_64; do bash -e build.sh --arch "$arch" mpv; done
    cd "$upstream"
    # assemble only: no signing credentials, Maven publication, tests or upload to any package registry.
    ./gradlew --no-daemon --max-workers=2 :libmpv:assembleRelease
    cp libmpv/build/outputs/aar/libmpv-release.aar "$out/libmpv-release-candidate.aar"
    python3 "$root/scripts/native-media-hosted/evidence.py" android "$out" "$upstream" "$ANDROID_HOME"
    # Source manifests are not a substitute for corresponding-source packaging at public distribution.
    tar -czf "$out/android-build-configs.tar.gz" -C buildscripts/deps/ffmpeg \
        _build/ffbuild/config.mak _build/config.h \
        _build-arm64/ffbuild/config.mak _build-arm64/config.h \
        _build-x64/ffbuild/config.mak _build-x64/config.h
fi
