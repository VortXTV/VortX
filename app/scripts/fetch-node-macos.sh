#!/bin/sh
# Fetch a standalone Node.js binary for the macOS streaming server.
#
# StremioXMac runs Stremio's server.js (the torrent engine + /proxy + HLS) in a child
# process so TORRENT streams play on the Mac. iOS/tvOS embed nodejs-mobile (a node
# *library*), but nodejs-mobile has no macOS slice, so on macOS we ship the ordinary
# standalone `node` executable from nodejs.org and spawn it (see MacNodeServer.swift).
#
# The binary lands at Resources/node-darwin-arm64 and is bundled into the .app as a
# resource by project.yml. It is large (~95 MB) so it is .gitignored and produced on
# demand: this script is idempotent (skips the download if the binary is present and
# runnable) and runs both as an Xcode pre-build phase and standalone before a build.
#
# Apple-silicon only for now (the Mac target builds arch=arm64). A universal binary
# would require lipo-ing in the x86_64 slice from a second tarball; not needed today.
set -eu

NODE_VERSION="v20.18.1"          # current LTS; only system frameworks as deps (otool-verified)
NODE_ARCH="darwin-arm64"
PKG="node-${NODE_VERSION}-${NODE_ARCH}"
URL="https://nodejs.org/dist/${NODE_VERSION}/${PKG}.tar.gz"

# Resolve Resources/ relative to this script, so it works from any CWD (Xcode runs it
# from the project dir; a developer may run it from anywhere).
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RES_DIR="${SCRIPT_DIR}/../Resources"
DEST="${RES_DIR}/node-${NODE_ARCH}"

# Idempotent: if a runnable binary of the right version is already there, do nothing.
if [ -x "${DEST}" ] && "${DEST}" --version 2>/dev/null | grep -q "${NODE_VERSION}"; then
  echo "fetch-node-macos: ${DEST} already present (${NODE_VERSION}), skipping."
  exit 0
fi

echo "fetch-node-macos: downloading ${URL}"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

curl -fsSL "${URL}" -o "${TMP}/node.tar.gz"
tar -xzf "${TMP}/node.tar.gz" -C "${TMP}"

mkdir -p "${RES_DIR}"
cp "${TMP}/${PKG}/bin/node" "${DEST}"
chmod +x "${DEST}"

echo "fetch-node-macos: installed $("${DEST}" --version) at ${DEST}"
