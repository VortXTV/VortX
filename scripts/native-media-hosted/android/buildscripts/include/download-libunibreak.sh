#!/bin/bash
set -euo pipefail

# Run inside buildscripts/deps. Values come from the reviewed depinfo.sh, not a network index.
version=${1:?libunibreak version is required}
expected=${2:?Official archive SHA-256 is required}
[[ "$version" =~ ^[0-9]+_[0-9]+$ ]] || exit 1
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || exit 1
if [ -e libunibreak ] || [ -L libunibreak ]; then
    echo 'Refusing existing libunibreak source: use a fresh build directory; no source is overwritten.' >&2
    exit 1
fi
stage=$(mktemp -d ./libunibreak-download.XXXXXXXX)
archive="$stage/libunibreak.tar.gz"
cleanup() {
    rm -f -- "$archive"
    rmdir -- "$stage" 2>/dev/null || true
}
trap cleanup EXIT
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 20 --max-time 120 --max-filesize 8388608 \
    "https://github.com/adah1972/libunibreak/releases/download/libunibreak_$version/libunibreak-${version//_/.}.tar.gz" --output "$archive"
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$archive")
else
    actual=$(shasum -a 256 "$archive")
fi
[ "${actual%% *}" = "$expected" ] || {
    echo 'libunibreak source archive SHA-256 mismatch; refusing extraction.' >&2
    exit 1
}
# mkdir reserves the exact destination atomically; a concurrently created path is never merged.
mkdir libunibreak
tar -xzf "$archive" -C libunibreak --strip-components=1
echo "Verified libunibreak $version source archive: $expected"
