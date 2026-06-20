#!/usr/bin/env bash
# Fetch the two pieces the embedded streaming server needs on desktop, into
# src-tauri/resources/ (both gitignored, bundled into the app by tauri.conf.json):
#
#   1) a standalone Node.js runtime for the HOST platform, and
#   2) server.cjs (Stremio's official streaming server — torrent engine + /proxy + HLS).
#
# The Tauri desktop app spawns `node server.cjs` bound to 127.0.0.1:11470 so TORRENT
# streams play (see src-tauri/src/server.rs). This mirrors the macOS app's approach
# (app/SourcesShared/MacNodeServer.swift + app/scripts/fetch-node-macos.sh +
# scripts/fetch-server-deps.sh): the Mac is unsandboxed and spawns the ordinary
# standalone `node` with Process; Tauri does the same with std::process::Command.
#
# Idempotent: skips a download whose output is already present and (for node) runnable
# at the pinned version. Run it before `npm run build` / `npm run tauri build`; it is
# also wired as the Tauri beforeBuildCommand (tauri.conf.json) so a plain build fetches.
#
# CROSS-PLATFORM: this script fetches the runtime for the host it runs on (macOS arm64/
# x64, Linux x64/arm64, Windows x64). Per-platform CI runners each run it for their own
# target. server.cjs is platform-agnostic (plain JS). See README / the comment block at
# the bottom for what each CI job must fetch.
set -euo pipefail

# Resolve src-tauri/resources/ relative to this script, so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RES_DIR="${SCRIPT_DIR}/../src-tauri/resources"
mkdir -p "${RES_DIR}"

# Pinned Node LTS. Standalone builds from nodejs.org depend only on the platform's
# system libraries (otool/ldd-verifiable), so they spawn cleanly from the bundle.
NODE_VERSION="${STREMIOX_NODE_VERSION:-v20.18.1}"

# server.js: the standard desktop build that runs under plain Node. Pinned + checksum-
# verified because it ships inside the app — verify the artifact, don't trust transport.
SERVER_VERSION="${STREMIO_SERVER_VERSION:-4.21.0}"
SERVER_JS_4_21_0_SHA256="82175d7982bce864df071df93b4b3d567a401e65881a8ac579d7db0ce71dafd7"

# --- host platform detection -> nodejs.org package + the bundled binary name ----------
# The bundled node keeps a platform-tagged name so a multi-platform CI build can stage
# several runtimes side by side; server.rs picks the right one for the running OS/arch.
uname_s="$(uname -s)"
uname_m="$(uname -m)"
case "${uname_s}" in
  Darwin)
    case "${uname_m}" in
      arm64) NODE_PLATFORM="darwin-arm64" ;;
      x86_64) NODE_PLATFORM="darwin-x64" ;;
      *) echo "fetch-server-deps: unsupported macOS arch ${uname_m}" >&2; exit 1 ;;
    esac
    NODE_BIN_NAME="node-${NODE_PLATFORM}"
    NODE_BIN_IN_PKG="bin/node"
    NODE_EXT="tar.gz"
    ;;
  Linux)
    case "${uname_m}" in
      x86_64) NODE_PLATFORM="linux-x64" ;;
      aarch64 | arm64) NODE_PLATFORM="linux-arm64" ;;
      *) echo "fetch-server-deps: unsupported Linux arch ${uname_m}" >&2; exit 1 ;;
    esac
    NODE_BIN_NAME="node-${NODE_PLATFORM}"
    NODE_BIN_IN_PKG="bin/node"
    NODE_EXT="tar.gz"
    ;;
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # Windows x64 (the common desktop target). nodejs.org ships a .zip with node.exe.
    NODE_PLATFORM="win-x64"
    NODE_BIN_NAME="node-${NODE_PLATFORM}.exe"
    NODE_BIN_IN_PKG="node.exe"
    NODE_EXT="zip"
    ;;
  *)
    echo "fetch-server-deps: unsupported OS ${uname_s}" >&2
    exit 1
    ;;
esac

PKG="node-${NODE_VERSION}-${NODE_PLATFORM}"
NODE_URL="https://nodejs.org/dist/${NODE_VERSION}/${PKG}.${NODE_EXT}"
NODE_DEST="${RES_DIR}/${NODE_BIN_NAME}"

# --- 1) Node runtime (idempotent) -----------------------------------------------------
if [ -x "${NODE_DEST}" ] && "${NODE_DEST}" --version 2>/dev/null | grep -q "${NODE_VERSION}"; then
  echo "fetch-server-deps: ${NODE_BIN_NAME} already present (${NODE_VERSION}), skipping."
else
  echo "fetch-server-deps: downloading ${NODE_URL}"
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  curl -fsSL "${NODE_URL}" -o "${TMP}/node.${NODE_EXT}"
  if [ "${NODE_EXT}" = "zip" ]; then
    unzip -q "${TMP}/node.${NODE_EXT}" -d "${TMP}"
  else
    tar -xzf "${TMP}/node.${NODE_EXT}" -C "${TMP}"
  fi
  cp "${TMP}/${PKG}/${NODE_BIN_IN_PKG}" "${NODE_DEST}"
  chmod +x "${NODE_DEST}"
  echo "fetch-server-deps: installed $("${NODE_DEST}" --version 2>/dev/null || echo node) at ${NODE_DEST}"
fi

# --- 2) server.cjs (idempotent + checksum-verified) -----------------------------------
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
    echo "fetch-server-deps: no sha256 tool (sha256sum/shasum/openssl/certutil); skipping verify for $3" >&2
    return 0
  fi
  if [ "${actual}" != "$2" ]; then
    echo "ERROR: $3 checksum mismatch" >&2
    echo "  expected: $2" >&2
    echo "  actual:   ${actual}" >&2
    rm -f "$1"
    exit 1
  fi
}

# Staged with a .cjs extension on purpose: server.js is a CommonJS bundle (it `require()`s), but the
# desktop project's package.json declares "type":"module", which would make Node treat a bare
# `server.js` run from the source tree as an ES module ("require is not defined"). The .cjs extension
# forces CommonJS regardless of any ancestor package.json. The checksum is verified on the *bytes*
# (the official server.js download), independent of the on-disk name.
SERVER_DEST="${RES_DIR}/server.cjs"
if [ -f "${SERVER_DEST}" ]; then
  echo "fetch-server-deps: server.cjs already present, skipping."
else
  TMP_SERVER="$(mktemp)"
  # Preference order: a local Stremio install (no network), else Stremio's CDN.
  found=""
  for candidate in "${STREMIO_APP:-}" "/Applications/Stremio.app"; do
    if [ -n "${candidate}" ] && [ -f "${candidate}/Contents/MacOS/server.js" ]; then
      cp "${candidate}/Contents/MacOS/server.js" "${TMP_SERVER}"
      found="${candidate}"
      break
    fi
  done
  if [ -n "${found}" ]; then
    echo "fetch-server-deps: server.js copied from ${found}"
  else
    echo "fetch-server-deps: downloading server.js v${SERVER_VERSION} from dl.strem.io..."
    curl -fsSL "https://dl.strem.io/server/v${SERVER_VERSION}/desktop/server.js" -o "${TMP_SERVER}"
    if [ "${SERVER_VERSION}" = "4.21.0" ]; then
      verify_sha256 "${TMP_SERVER}" "${SERVER_JS_4_21_0_SHA256}" "server.js v${SERVER_VERSION}"
    else
      echo "WARNING: no pinned checksum for server.js v${SERVER_VERSION}; skipping verification." >&2
    fi
  fi
  mv "${TMP_SERVER}" "${SERVER_DEST}"
fi

echo "fetch-server-deps: done. node + server.cjs staged in ${RES_DIR}"

# ---------------------------------------------------------------------------------------
# CI / cross-platform note (what each runner must produce):
#   macOS arm64  -> resources/node-darwin-arm64   (this dev machine; verified here)
#   macOS x64    -> resources/node-darwin-x64
#   Linux x64    -> resources/node-linux-x64
#   Linux arm64  -> resources/node-linux-arm64
#   Windows x64  -> resources/node-win-x64.exe
# server.cjs is the same file on every platform. Run this script on each target runner
# before `npm run tauri build`; server.rs selects the binary matching the running OS/arch.
# ---------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------
# mpv PLAYER BINARY (staged manually for now; NOT fetched by this script yet)
# ---------------------------------------------------------------------------------------
# The desktop player is mpv (libmpv), spawned as a child process and driven over JSON IPC
# (see src-tauri/src/player.rs). Like the node runtime above, mpv ships as a per-platform
# binary under resources/, bundled via tauri.conf.json's `bundle.resources` ("resources/mpv-*").
# player.rs::mpv_binary_name() selects the one matching the running OS/arch:
#
#   macOS arm64  -> resources/mpv-darwin-arm64
#   macOS x64    -> resources/mpv-darwin-x64
#   Linux x64    -> resources/mpv-linux-x64
#   Linux arm64  -> resources/mpv-linux-arm64
#   Windows x64  -> resources/mpv-win-x64.exe
#
# This script does NOT download mpv yet: unlike Node (a single self-contained binary from
# nodejs.org), a portable mpv with vo=gpu-next + libplacebo + the codec set we want is not a
# single canonical public artifact across all three OSes (macOS: a notarized build or the
# mpv.app payload; Windows: shinchiro/zhongfly builds; Linux: usually the system package).
# For now DROP THE REAL BINARY IN BY HAND (or your CI job copies it) at the path above before
# `npm run tauri build`. In `tauri dev`, player.rs also falls back to an `mpv` on PATH, so a
# locally installed mpv (e.g. `brew install mpv`, `apt install mpv`) works without staging.
#
# ALTERNATIVE PACKAGING (Tauri externalBin). Instead of bundle.resources, mpv could be a
# Tauri sidecar via `bundle.externalBin: ["binaries/mpv"]`, which requires the binary be named
# with a `-$TARGET_TRIPLE` suffix (e.g. binaries/mpv-aarch64-apple-darwin) and spawned with
# tauri-plugin-shell's app.shell().sidecar("mpv"). We deliberately mirror the EXISTING node
# pattern (bundle.resources + std::process::Command from the resource dir) instead, so the mpv
# spawn path is identical to the already-shipping embedded server and needs no extra plugin or
# target-triple rename step. If we later move node to externalBin, move mpv with it.
# ---------------------------------------------------------------------------------------
