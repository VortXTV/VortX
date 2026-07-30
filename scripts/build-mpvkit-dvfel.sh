#!/bin/bash
# Rebuild app/Vendor/MPVKit-DVFEL from pinned upstream sources.
#
# WHY WE OWN THIS BUILD
# ---------------------
# Dolby Vision Profile 7 carries a base layer (BL) plus an enhancement layer (EL). Until now we
# decoded the BL and threw the EL away, so P7 titles played as a tone-mapped base layer and, worse,
# got NO Dolby Vision metadata at all on the libmpv lane. mpv master added BL+EL pairing and
# libplacebo master added the renderer-side FEL composite that consumes it.
#
# Neither is in any release, and they are coupled: every line of mpv's FEL code sits behind
# `#if PL_API_VER >= 367`, and the extra gate at video/mp_image.c:1191 (`#elif PL_API_VER < 370`)
# is what stops P7 FEL streams being filtered out of DV metadata mapping entirely. Upstream MPVKit
# links a PREBUILT libplacebo 7.360.1 = PL_API_VER 360, so bumping only mpv would compile the whole
# feature out SILENTLY with a green build, while still paying for a second decoder whose output is
# discarded. That is why libplacebo must be built FROM SOURCE at >= 370 and why this script exists.
#
# WHAT IS PINNED (exact SHAs, never a moving master, so builds are reproducible)
#   mpv        8c67647b50059406c5c0444903597281b81516cf  master, 2026-07-24
#   libplacebo 4c426e466814536def653cb23f1d1c287ea7a7f5  master, 2026-07-24, PL_API_VER 371
#   FFmpeg     6e85193417f898868f04f8f6fc30db92a874a8cf  release/9.0 tip, 2026-07-25
#
# FFmpeg MOVED, and this paragraph is the record of why and of what it cost. The pin was n8.1.2
# (libavcodec 62.28.102, libavformat 62.12.102). At that version the `dovi_split` bitstream filter
# does not exist at all: a symbol count on our own shipped ios-arm64 Libavcodec returned 0 for
# `dovi_split` against 33 for `dovi_rpu`. mpv's Profile 7 splitter therefore always got NULL back
# and logged "rendering base layer only", so single-track NALU-interleaved Dolby Vision Profile 7
# rendered as base layer only. That is the whole reason for the move. release/9.0 carries
# 6026988b75 (the BSF itself) and 5f6dff5e7d (hvcE -> AV_PKT_DATA_HEVC_CONF, which feeds the split
# enhancement layer its extradata), and lands libavcodec/libavformat on 63.1.100, which also clears
# mpv's `LIBAVFORMAT_VERSION_INT >= AV_VERSION_INT(62, 19, 100)` gate on lavf-side dual-track DV
# pairing (MP4/MOV/HLS/DASH; native MKV never needed it).
#
# release/8.1 was not an option: release branches bump micro only, so its tip is still 62.28.102 and
# waiting there delivers those commits never. Cherry-picking was not an option either: raising
# libavcodec past 62.30.100 switches on mpv's demux/packet.c App5 path whose FFmpeg API does not
# exist at n8.1.2, so mpv stops compiling. master was unnecessary.
#
# Apple TLS is pinned deliberately too. FFmpeg must select SecureTransport and explicitly disable
# GnuTLS. The GnuTLS artifact stays available to libsmbclient, but its system-trust loader is
# unavailable on tvOS. FFmpeg 9 enables peer verification, so selecting that backend leaves HTTPS
# with no trust anchors and every open fails with EIO. SecureTransport uses the Apple trust store
# while retaining certificate and hostname verification.
#
# release/9.0 is a BRANCH, not a tag. No n9* tag existed when this pin was taken, so the SHA is the
# pin and BuildFFMPEG.beforeBuild clones `--branch release/9.0` before detaching onto it: the tip of
# a maintenance branch is not reachable from master, so a default-branch clone would not contain it
# at any depth. Re-verify the SHA if you re-cut this; take the n9.0 tag once it exists.
#
# WHAT THE REBASE ACTUALLY COST, measured rather than feared. MPVKit ships NO FFmpeg patches at all
# (Sources/BuildScripts/patch/ contains only libmpv/), so there was nothing to rebase. The entire
# delta is configure options, and exactly one of them died: `--enable-libshaderc`, removed upstream
# by 062de19095 "configure: remove libshaderc and libglslang support", which release/9.0 contains.
# The flag appears 7 times in n8.1.2's configure and 0 times in release/9.0's, and FFmpeg's configure
# dies on unknown options, so `.libshaderc` had to come out of the dependencyLibrary array in
# main.swift. A dry configure run of the full 224-flag option set against release/9.0 otherwise
# succeeded, with `--enable-decoder=sonic` warning ("did not match anything") and not dying. shaderc
# itself is still built and still shipped; only FFmpeg stopped linking it.
#
# Our delta to MPVKit is TWO files, and they are deliberately kept apart:
#   scripts/mpvkit-dvfel.patch        patches MPVKit's Package.swift and build driver: dependency
#                                     pins, libplacebo source build, Security.framework linkage,
#                                     Apple TLS selection, and the E-AC-3 encoder.
#   scripts/mpv-moltenvk-resize.patch patches MPV itself. Installed below as patch 0004 next to
#                                     MPVKit's own 0001-0003, because it edits the file MPVKit's 0001
#                                     creates and so must be applied after it.
# Everything not listed above still comes from upstream MPVKit's own prebuilt zips at the versions
# the 0.41.0-n8.1.2 pin already used.
#
# Cost: a full clean run builds 9 slices (ios, isimulator x2, tvos x2, tvsimulator x2, macos x2)
# of FFmpeg, libplacebo and mpv from source. Budget hours, not minutes, and ~20 GB of scratch.
set -euo pipefail

MPVKIT_REF="2103893078c5e339073b11737b86f7f22b9c4491"   # MPVKit 1.0.0 tip, the base for our patch
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="${MPVKIT_DVFEL_WORK:-$HOME/.cache/vortx-mpvkit-dvfel}"
DEST="$REPO/app/Vendor/MPVKit-DVFEL"

for tool in meson ninja cmake pkg-config nasm wget; do
  command -v "$tool" >/dev/null || { echo "missing build tool: $tool (brew install $tool)" >&2; exit 1; }
done

mkdir -p "$WORK"
if [ ! -d "$WORK/MPVKit/.git" ]; then
  git clone https://github.com/mpvkit/MPVKit.git "$WORK/MPVKit"
fi
cd "$WORK/MPVKit"
git fetch --all --quiet
git checkout --quiet "$MPVKIT_REF"
git checkout --quiet -- .
git apply "$REPO/scripts/mpvkit-dvfel.patch"

# Install our mpv-side patch alongside MPVKit's own libmpv patches. SpikeGit.applyPatches (added by
# mpvkit-dvfel.patch) applies that directory in sorted order, so the 0004 prefix guarantees it runs
# after MPVKit's 0001, which is what creates video/out/vulkan/context_moltenvk.m in the first place.
# Copied rather than committed into the patch-of-a-patch above so the mpv diff stays readable and
# reviewable on its own. `git checkout -- .` above does not remove untracked files, so an existing
# copy from a previous run is simply overwritten.
cp "$REPO/scripts/mpv-moltenvk-resize.patch" \
   "$WORK/MPVKit/Sources/BuildScripts/patch/libmpv/0004-moltenvk-context-check-events-resize.patch"

# A prior interrupted experiment installed this exact VortX-only FFmpeg patch as
# an untracked file. `git checkout -- .` cannot remove untracked files, so clear
# that retired patch explicitly before the build driver scans its patch folder.
find "$WORK/MPVKit/Sources/BuildScripts/patch/FFmpeg" \
  -type f -name '0001-no-private-secidentity.patch' -delete 2>/dev/null || true

# GPL variant: VortX consumes the MPVKit-GPL product (libsmbclient + -Dgpl=true).
BUILD_STARTED_MARKER="$(mktemp)"
trap 'rm -f "$BUILD_STARTED_MARKER"' EXIT
swift run --build-path ./.build --package-path Sources/BuildScripts \
  build enable-gpl platform=ios,tvos,macos version=0.0.0-dvfel

# Assembly reads the per-library release ZIP, not slice scratch directories.
# Refuse to package a stale ZIP after an interrupted or incorrectly cached run.
LIBAVFORMAT_ZIP="$WORK/MPVKit/dist/release/Libavformat.xcframework.zip"
[ -f "$LIBAVFORMAT_ZIP" ] || {
  echo "missing rebuilt artifact: $LIBAVFORMAT_ZIP" >&2
  exit 1
}
[ "$LIBAVFORMAT_ZIP" -nt "$BUILD_STARTED_MARKER" ] || {
  echo "refusing stale Libavformat ZIP: $LIBAVFORMAT_ZIP" >&2
  exit 1
}
rm -f "$BUILD_STARTED_MARKER"
trap - EXIT

STAGED_DEST="$(mktemp -d "${DEST}.staged.XXXXXX")"
PREVIOUS_DEST="${DEST}.previous"
trap 'rm -rf "$STAGED_DEST"' EXIT

"$HERE/assemble-mpvkit-dvfel.sh" "$WORK/MPVKit" "$STAGED_DEST"
"$HERE/verify-mpvkit-dvfel-apple-tls.sh" "$STAGED_DEST"

# Promote only a package that passed every gate. Keep the prior package recoverable
# until the staged move succeeds, so a failed verification or move cannot install a
# known-bad player or destroy the last working one.
rm -rf "$PREVIOUS_DEST"
if [ -e "$DEST" ]; then
  mv "$DEST" "$PREVIOUS_DEST"
fi
if mv "$STAGED_DEST" "$DEST"; then
  rm -rf "$PREVIOUS_DEST"
else
  if [ -e "$PREVIOUS_DEST" ]; then
    mv "$PREVIOUS_DEST" "$DEST"
  fi
  exit 1
fi
trap - EXIT
echo "done -> $DEST"
