#!/usr/bin/env bash
# DRAFT FOR ROOT REVIEW: no local execution in this investigation.
# Caller installs dated nightly + rust-src and locked cargo-c into its tool directory.
set -euo pipefail
[[ $# == 4 ]] || { echo 'usage: build-aether-dovi-tv-simulator.sh DOVI_SOURCE LIBDOVI_PACKAGE FRESH_OUTPUT OWNED_BUILD_ROOT' >&2; exit 2; }
dovi_source="$(cd "$1" && pwd -P)"
libdovi_package="$(cd "$2" && pwd -P)"
producer_output="$3"
owned_root="$4"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
python3 "$script_dir/aether-dovi-provider.py" preflight --source "$dovi_source" \
 --package "$libdovi_package" --provider "$producer_output" --owned-root "$owned_root"
rustc_real="$(rustup which --toolchain nightly-2026-07-19 rustc)"
cargo_real="$(rustup which --toolchain nightly-2026-07-19 cargo)"
cargo_c_real="$(command -v cargo-cinstall)"
sdk_root="$(xcrun --sdk appletvsimulator --show-sdk-path)"
clang_real="$(xcrun --sdk appletvsimulator --find clang)"
ar_real="$(xcrun --sdk appletvsimulator --find ar)"
mkdir -p "$producer_output/cargo-home" "$producer_output/tmp"
"$cargo_c_real" cinstall --version > "$producer_output/cargo-c-version.txt"
grep -Eq '(^|[[:space:]])0\.10\.26\+cargo-0\.100\.0([[:space:]]|$)' "$producer_output/cargo-c-version.txt"
"$rustc_real" -vV > "$producer_output/rustc-version.txt"
"$cargo_real" -vV > "$producer_output/cargo-version.txt"
xcodebuild -version > "$producer_output/xcode-version.txt"
xcrun --sdk appletvsimulator --show-sdk-version > "$producer_output/sdk-version.txt"
xcrun --sdk appletvsimulator --show-sdk-build-version > "$producer_output/sdk-build-version.txt"
# No ambient Cargo home, Rust flags, compiler wrappers, PATH tools or Cargo config.
# Public registry acquisition is allowed here and explicitly not described as offline.
build_env=(
 "PATH=$(dirname "$rustc_real"):$(dirname "$cargo_c_real"):/usr/bin:/bin"
 'LC_ALL=C' "TMPDIR=$producer_output/tmp" "CARGO_HOME=$producer_output/cargo-home"
 "CARGO=$cargo_real" "CARGO_C_CARGO=$cargo_real" "RUSTC=$rustc_real"
 "RUSTDOC=$(dirname "$rustc_real")/rustdoc"
 'CARGO_BUILD_JOBS=1' 'CARGO_INCREMENTAL=0' 'CARGO_PROFILE_RELEASE_PANIC=abort'
 "CARGO_TARGET_DIR=$producer_output/target" "CARGO_TARGET_X86_64_APPLE_TVOS_LINKER=$clang_real"
 "SDKROOT=$sdk_root" 'TVOS_DEPLOYMENT_TARGET=17.0' "CC=$clang_real" "AR=$ar_real"
 "CFLAGS=-target x86_64-apple-tvos17.0-simulator -isysroot $sdk_root"
 "CXXFLAGS=-target x86_64-apple-tvos17.0-simulator -isysroot $sdk_root")
command=("$cargo_c_real" cinstall --locked --release -j1 -Zbuild-std=std,panic_abort
 --library-type=staticlib --no-default-features --features=capi
 "--manifest-path=$dovi_source/dolby_vision/Cargo.toml"
 --target=x86_64-apple-tvos "--prefix=$producer_output/install" --libdir=lib -vv)
printf '%s\n' "${build_env[@]}" > "$producer_output/build-environment.txt"
printf '%q ' "${command[@]}" > "$producer_output/build-command.txt"
printf '\n' >> "$producer_output/build-command.txt"
# Cargo searches source cwd ancestors, checked by preflight; never use ambient caller cwd.
(cd "$dovi_source/dolby_vision" && env -i "${build_env[@]}" "${command[@]}") \
 > "$producer_output/build.log" 2>&1
[[ -z "$(git -C "$dovi_source" status --porcelain --untracked-files=all)" ]]
[[ -z "$(git -C "$dovi_source" ls-files --others --ignored --exclude-standard)" ]]
cp "$dovi_source/dolby_vision/LICENSE" "$producer_output/LICENSE-libdovi.txt"
cp "$libdovi_package/LICENSE" "$producer_output/LICENSE-packaging.txt"
python3 "$script_dir/aether-dovi-provider.py" link-probe --package "$libdovi_package" \
 --provider "$producer_output" --owned-root "$owned_root" --clang "$clang_real" --sdk "$sdk_root"
python3 - "$dovi_source" "$libdovi_package" "$producer_output" "$rustc_real" "$cargo_real" "$cargo_c_real" "$clang_real" "$ar_real" "$sdk_root" <<'PY'
import hashlib,json,pathlib,subprocess,sys
source,package,out,rustc,cargo,cargo_c,clang,ar,sdk=map(pathlib.Path,sys.argv[1:])
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def git(*args):return subprocess.check_output(['git','-C',str(source),*args],text=True).strip()
assert git('rev-parse','HEAD')=='d1abe0e27ff2c7ab3339614d06db9f8a058af6b2'
assert not git('status','--porcelain','--untracked-files=all')
assert digest(source/'dolby_vision/Cargo.lock')=='5c9f344b8a49f684e409af8304e4e175618098c9b24ed8acafc5f1a469088814'
files=['install/lib/libdovi.a','install/include/libdovi/rpu_parser.h','install/lib/pkgconfig/dovi.pc',
 'LICENSE-libdovi.txt','LICENSE-packaging.txt','build-command.txt','build-environment.txt','build.log',
 'cargo-c-version.txt','cargo-version.txt','rustc-version.txt','xcode-version.txt','sdk-version.txt','sdk-build-version.txt',
 'probe.c','probe.o','probe.dylib','probe-link-command.json','probe-symbols.txt']
receipt={'schema':1,'sourceCommit':git('rev-parse','HEAD'),'sourceTree':git('rev-parse','HEAD^{tree}'),
 'packageCommit':subprocess.check_output(['git','-C',str(package),'rev-parse','HEAD'],text=True).strip(),
 'sourceFiles':{p:digest(source/p) for p in ['dolby_vision/Cargo.toml','dolby_vision/Cargo.lock','dolby_vision/cbindgen.toml','dolby_vision/LICENSE']},
 'toolchain':'nightly-2026-07-19','cargoCVersion':'0.10.26+cargo-0.100.0','sdkPath':str(sdk.resolve()),
 'tools':{name:{'path':str(p.resolve()),'sha256':digest(p)} for name,p in [('rustc',rustc),('cargo',cargo),('cargo-cinstall',cargo_c),('clang',clang),('ar',ar)]},
 'outputs':{p:digest(out/p) for p in files},'compiled':True,'apiLinked':True,'runtimeTested':False,'offline':False}
(out/'build-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
PY
python3 "$script_dir/aether-dovi-provider.py" verify-provider --package "$libdovi_package" \
 --provider "$producer_output" --owned-root "$owned_root"
