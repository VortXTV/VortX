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
#   FFmpeg     n8.1.2                                    UNCHANGED, deliberately
#
# FFmpeg stays put for now, but NOT for the reason first recorded here. The original claim was that
# VortXMKVRemuxStream.swift calls libavformat/libavcodec directly, so libavutil 60 -> 61 deprecation
# removals made a bump too risky. A source-level audit REFUTED that, and the refutation is the point
# of this paragraph: of the 67 distinct FFmpeg functions VortX calls, ZERO were removed or changed
# signature between n8.1.2 and master, and every FF_API_* removal in the range lands on APIs we do
# not touch. The version jump is in fact WIDER than was recorded (762b94e672 moves libavformat and
# libavcodec 62 -> 63 in the same change, and we link both directly) and it is still clean.
# libavutil/dovi_meta.h has a ZERO-byte diff across the range, so the synthetic Dolby Vision record
# built at VortXMKVRemuxStream.swift:3612-3640 is untouched. Audit: vortx-ffmpeg-harvest.md.
#
# So our Swift call sites are NOT the blocker. What actually gates the bump is (a) the DV
# conformance harness being repaired, and (b) one genuinely UNMEASURED cost: whether MPVKit's own
# FFmpeg patches rebase onto FFmpeg release/9.0. Nobody has attempted that rebase yet, and it is the
# only thing here that could turn a small job into a long one. Do not re-derive the Swift-API fear.
#
# The bounded cost of staying put: dual-track P7 MKV (separate BL + EL video tracks) works; single-track
# INTERLEAVED P7 does not, because mpv's splitter needs FFmpeg's `dovi_split` bitstream filter
# (upstream 6026988b75, 2026-05-16) which n8.1.2 does not ship. mpv handles its absence by
# returning NULL, so those files degrade to exactly today's behaviour with no crash.
#
# Our delta to MPVKit is TWO files, and they are deliberately kept apart:
#   scripts/mpvkit-dvfel.patch        patches MPVKit's own Sources/BuildScripts/XCFrameworkBuild/main.swift
#                                     (the pins above, the libplacebo source build, and the FFmpeg
#                                     --enable-encoder=eac3 the Dolby Vision audio transcoder needs).
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

# GPL variant: VortX consumes the MPVKit-GPL product (libsmbclient + -Dgpl=true).
swift run --build-path ./.build --package-path Sources/BuildScripts \
  build enable-gpl platform=ios,tvos,macos version=0.0.0-dvfel

"$HERE/assemble-mpvkit-dvfel.sh" "$WORK/MPVKit" "$DEST"
echo "done -> $DEST"
