#!/usr/bin/env bash
# Fetch the desktop player (mpv) for the HOST platform into src-tauri/resources/ (gitignored, bundled by
# the platform Tauri config). Torrent streaming needs nothing here: the VortX streaming server runs inside
# the app process (src-tauri/src/server.rs).
#
# Idempotent: every reused payload is compared against a freshly extracted copy of its checksum-verified
# archive. Wired as the Tauri beforeBuildCommand, and run by each per-platform CI job for its own target.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RES_DIR="${SCRIPT_DIR}/../src-tauri/resources"
mkdir -p "${RES_DIR}"

fail() {
  echo "fetch-mpv: ERROR - $*" >&2
  exit 1
}

# Every temporary file/directory is registered here immediately after creation; one EXIT trap removes them.
TEMP_PATHS=()
cleanup_temp_paths() {
  local path
  for path in "${TEMP_PATHS[@]-}"; do
    if [ -n "${path}" ]; then
      rm -rf -- "${path}"
    fi
  done
}
trap cleanup_temp_paths EXIT

verify_sha256() { # <file> <expected-hash> <label>
  local actual=""
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$1" | cut -d' ' -f1)"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$1" | cut -d' ' -f1)"
  elif command -v openssl >/dev/null 2>&1; then
    actual="$(openssl dgst -sha256 "$1" | awk '{print $NF}')"
  elif command -v certutil >/dev/null 2>&1; then
    # Windows fallback (Git Bash without coreutils): certutil prints the hash on line 2.
    actual="$(certutil -hashfile "$1" SHA256 | sed -n '2p' | tr -dc '0-9a-fA-F' | tr 'A-F' 'a-f')"
  else
    rm -f "$1"
    fail "cannot verify $3: no SHA-256 tool (sha256sum/shasum/openssl/certutil)"
  fi
  if [ "${actual}" != "$2" ]; then
    echo "fetch-mpv: ERROR - $3 checksum mismatch" >&2
    echo "  expected: $2" >&2
    echo "  actual:   ${actual}" >&2
    rm -f "$1"
    exit 1
  fi
}

# Cache only authenticated archives, never an unsigned "already verified" marker.
fetch_verified_mpv_archive() { # <url> <sha256> <label> <cache-name>
  local cache_dir="${RES_DIR}/.verified-downloads"
  [ ! -L "${cache_dir}" ] || fail "mpv archive cache must not be a symlink"
  mkdir -p "${cache_dir}"
  VERIFIED_MPV_ARCHIVE="${cache_dir}/$4"
  [ ! -L "${VERIFIED_MPV_ARCHIVE}" ] || fail "mpv archive must not be a symlink"
  [ ! -e "${VERIFIED_MPV_ARCHIVE}" ] || [ -f "${VERIFIED_MPV_ARCHIVE}" ] || fail "mpv archive must be a regular file"
  if [ ! -f "${VERIFIED_MPV_ARCHIVE}" ]; then
    local download
    download="$(mktemp "${cache_dir}/.mpv-download.XXXXXX")"
    TEMP_PATHS+=("${download}")
    curl -fsSL "$1" -o "${download}"
    verify_sha256 "${download}" "$2" "$3"
    mv "${download}" "${VERIFIED_MPV_ARCHIVE}"
  fi
  verify_sha256 "${VERIFIED_MPV_ARCHIVE}" "$2" "$3 cached archive"
}

# The staged payload must equal the freshly extracted verified one: file bytes, symlink targets and
# executable bits, recursively. A single executable (Windows) is compared with cmp; a bundle (macOS
# mpv.app) with Python's standard library.
verify_mpv_payload() { # <verified-extracted-source> <staged-destination>
  local mismatch="cached mpv payload differs from its pinned archive; remove only the generated staged mpv payload and retry"
  [ ! -L "$2" ] || fail "${mismatch}"
  if [ -f "$1" ]; then
    [ -f "$2" ] && cmp -s "$1" "$2" || fail "${mismatch}"
    local source_exec=0 staged_exec=0
    [ -x "$1" ] && source_exec=1
    [ -x "$2" ] && staged_exec=1
    [ "${source_exec}" = "${staged_exec}" ] || fail "${mismatch}"
    return 0
  fi
  python3 -I - "$1" "$2" <<'PY' || fail "${mismatch}"
import os, stat, sys

def same(a, b):
    x, y = os.lstat(a), os.lstat(b)
    if stat.S_ISLNK(x.st_mode) or stat.S_ISLNK(y.st_mode):
        return stat.S_ISLNK(x.st_mode) and stat.S_ISLNK(y.st_mode) and os.readlink(a) == os.readlink(b)
    if stat.S_ISDIR(x.st_mode) and stat.S_ISDIR(y.st_mode):
        names = sorted(os.listdir(a))
        return names == sorted(os.listdir(b)) and all(same(os.path.join(a, n), os.path.join(b, n)) for n in names)
    if not (stat.S_ISREG(x.st_mode) and stat.S_ISREG(y.st_mode)):
        return False
    if (x.st_mode & 0o111) != (y.st_mode & 0o111) or x.st_size != y.st_size:
        return False
    with open(a, "rb") as fa, open(b, "rb") as fb:
        while True:
            ca, cb = fa.read(65536), fb.read(65536)
            if ca != cb:
                return False
            if not ca:
                return True

sys.exit(0 if same(sys.argv[1], sys.argv[2]) else 1)
PY
}

uname_s="$(uname -s)"
uname_m="$(uname -m)"

case "${uname_s}" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    MPV_WIN_DEST="${RES_DIR}/mpv-win-x64.exe"
    # Pinned zhongfly release. Baseline x86-64 build (NOT the -v3/AVX2 build) for broad CPU compatibility.
    MPV_WIN_TAG="2026-07-20-94335ab87a"
    MPV_WIN_ASSET="mpv-x86_64-20260720-git-94335ab87a.7z"
    MPV_WIN_SHA256="a77cd53dc8d9e002b612d3bfaffa15be3ca2944713caab508b6f4f26a75400b3"
    MPV_WIN_URL="https://github.com/zhongfly/mpv-winbuild/releases/download/${MPV_WIN_TAG}/${MPV_WIN_ASSET}"
    fetch_verified_mpv_archive "${MPV_WIN_URL}" "${MPV_WIN_SHA256}" "mpv windows ${MPV_WIN_TAG}" "${MPV_WIN_ASSET}"
    TMP_MPV="$(mktemp -d)"
    TEMP_PATHS+=("${TMP_MPV}")
    # 7-Zip ships on the GitHub windows runner; extract just mpv.exe.
    ( cd "${TMP_MPV}" && 7z e -y "${VERIFIED_MPV_ARCHIVE}" mpv.exe >/dev/null )
    [ -f "${TMP_MPV}/mpv.exe" ] && [ ! -L "${TMP_MPV}/mpv.exe" ] || fail "mpv.exe missing from pinned archive"
    if [ ! -e "${MPV_WIN_DEST}" ] && [ ! -L "${MPV_WIN_DEST}" ]; then
      cp "${TMP_MPV}/mpv.exe" "${MPV_WIN_DEST}"
    fi
    verify_mpv_payload "${TMP_MPV}/mpv.exe" "${MPV_WIN_DEST}"
    echo "fetch-mpv: verified mpv-win-x64.exe"
    ;;
  Darwin)
    if [ "${uname_m}" = "arm64" ]; then
      MPV_MAC_DEST="${RES_DIR}/mpv-darwin-arm64.app"
      # Pinned stolendata build (https://laboratory.stolendata.net/~djinn/mpv_osx/), the macOS build listed by
      # mpv.io. Self-contained mpv.app, so spawning Contents/MacOS/mpv as a child works.
      MPV_MAC_VER="0.40.0"
      MPV_MAC_SHA256="3170fb709defebaba33e9755297d70dc3562220541de54fc3d494a8309ef1260"
      MPV_MAC_URL="https://laboratory.stolendata.net/~djinn/mpv_osx/mpv-arm64-${MPV_MAC_VER}.tar.gz"
      fetch_verified_mpv_archive "${MPV_MAC_URL}" "${MPV_MAC_SHA256}" \
        "mpv macOS ${MPV_MAC_VER}" "mpv-arm64-${MPV_MAC_VER}.tar.gz"
      TMP_MPVM="$(mktemp -d)"
      TEMP_PATHS+=("${TMP_MPVM}")
      tar -xzf "${VERIFIED_MPV_ARCHIVE}" -C "${TMP_MPVM}"
      APP_SRC="$(find "${TMP_MPVM}" -maxdepth 2 -name 'mpv.app' -type d | head -1)"
      [ -n "${APP_SRC}" ] || fail "mpv.app not found in the pinned stolendata archive"
      [ -f "${APP_SRC}/Contents/MacOS/mpv" ] || fail "mpv executable missing from pinned app archive"
      if [ -e "${MPV_MAC_DEST}" ] || [ -L "${MPV_MAC_DEST}" ]; then
        verify_mpv_payload "${APP_SRC}" "${MPV_MAC_DEST}"
      else
        cp -pR "${APP_SRC}" "${MPV_MAC_DEST}"
        verify_mpv_payload "${APP_SRC}" "${MPV_MAC_DEST}"
      fi
      echo "fetch-mpv: verified mpv-darwin-arm64.app"
    else
      echo "fetch-mpv: no pinned mpv for macOS arch ${uname_m} (only arm64 wired)." >&2
    fi
    ;;
esac

# Linux x64 builds its mpv AppDir in desktop.yml with separately pinned deployment tools. The platform
# Tauri configs name the exact payload, and release builds never fall back to an mpv on PATH.
if ! ls "${RES_DIR}"/mpv-* >/dev/null 2>&1; then
  echo "fetch-mpv: WARNING - no mpv payload staged in ${RES_DIR}." >&2
fi
