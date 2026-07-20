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

NODE_VERSION="v20.18.1"          # pinned LTS; only system frameworks as deps (otool-verified)
NODE_ARCH="darwin-arm64"
PKG="node-${NODE_VERSION}-${NODE_ARCH}"
URL="https://nodejs.org/dist/${NODE_VERSION}/${PKG}.tar.gz"
# Pinned sha256 of node-v20.18.1-darwin-arm64.tar.gz, from the official
# https://nodejs.org/dist/v20.18.1/SHASUMS256.txt. The tarball is verified against this
# before it is unpacked or its `node` is ever run, so a swapped/MITM'd download fails closed
# instead of shipping an unverified interpreter inside the .app. Bump this in lockstep with
# NODE_VERSION above (grab the new line from that release's SHASUMS256.txt).
NODE_SHA256="9e92ce1032455a9cc419fe71e908b27ae477799371b45a0844eedb02279922a4"

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

# Verify the download against the pinned checksum BEFORE unpacking or executing anything from it.
echo "fetch-node-macos: verifying sha256 (${NODE_SHA256})"
printf '%s  %s\n' "${NODE_SHA256}" "${TMP}/node.tar.gz" > "${TMP}/node.sha256"
if ! shasum -a 256 -c "${TMP}/node.sha256"; then
  echo "fetch-node-macos: sha256 mismatch for ${PKG}.tar.gz; refusing to unpack" >&2
  exit 1
fi

tar -xzf "${TMP}/node.tar.gz" -C "${TMP}"

mkdir -p "${RES_DIR}"
cp "${TMP}/${PKG}/bin/node" "${DEST}"
chmod +x "${DEST}"

echo "fetch-node-macos: installed $("${DEST}" --version) at ${DEST}"
