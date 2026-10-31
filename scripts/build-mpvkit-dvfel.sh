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
# libplacebo now has a stable FEL release; it remains coupled to the custom mpv base:
# every line of mpv's FEL code sits behind
# `#if PL_API_VER >= 367`, and the extra gate at video/mp_image.c:1191 (`#elif PL_API_VER < 370`)
# is what stops P7 FEL streams being filtered out of DV metadata mapping entirely. Upstream MPVKit
# links a PREBUILT libplacebo 7.360.1 = PL_API_VER 360, so bumping only mpv would compile the whole
# feature out SILENTLY with a green build, while still paying for a second decoder whose output is
# discarded. That is why libplacebo must be built FROM SOURCE at >= 370 and why this script exists.
#
# WHAT IS PINNED (exact SHAs, never a moving master, so builds are reproducible)
#   mpv        8c67647b50059406c5c0444903597281b81516cf  master, 2026-07-24
#   libplacebo 275f7dea27924cdd34ab2e6c20e448b6bc4fab65  v7.387.0 stable, PL_API_VER 387
#   LittleCMS  1315434113566bcf3eb46c2485fcc1c0a56ab806  lcms2.20rc1 PRERELEASE TEST CANDIDATE
#   dav1d      54706fc6bc0cdecab7e9593974a4039cc038fca7  1.5.4 source candidate
#   Shaderc    2026.1.0 wrapper; paired published all-ZIP/XCFramework identities checked
#   OpenSSL    2f4e3a5fec05394068cfa7379890ab552483a8a6 4.1.0 latest-stable source candidate
#   FFmpeg     946fcce07b6dcd0331c8cc609192aeff5e1924f8  n9.0.2 maintenance
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
# Before the move, this file recorded a direct-Swift-API risk. A source audit refuted it: the 67
# distinct FFmpeg functions VortX calls had zero removals or signature changes through master, and
# libavutil/dovi_meta.h was byte-identical, so the synthetic DV record was unaffected. The remaining
# unmeasured cost was MPVKit patch rebasing; the measured result below closed that gate.
#
# Apple TLS is pinned deliberately too. FFmpeg must select SecureTransport and explicitly disable
# GnuTLS. The GnuTLS artifact stays available to libsmbclient, but its system-trust loader is
# unavailable on tvOS. FFmpeg 9 enables peer verification, so selecting that backend leaves HTTPS
# with no trust anchors and every open fails with EIO. SecureTransport uses the Apple trust store
# while retaining certificate and hostname verification.
#
# The original release/9.0 pin was 6e85193417f898868f04f8f6fc30db92a874a8cf. n9.0.2 is its
# descendant (169 commits ahead / none behind), retaining the DV/FEL APIs while adding maintenance
# fixes. BuildFFMPEG.beforeBuild now clones the exact n9.0.2 tag and detaches at 946fcce07b6d.
# The versioned FFmpeg-9.0.2-946fcce0 source/output directory cannot reuse the old 9.0 source cache.
#
# WHAT THE ORIGINAL REBASE COST. Upstream MPVKit shipped no FFmpeg patches, so that version
# move initially needed only configure changes. Our later response-witness patch is separate,
# based on the exact n9.0.2 http.c, and does not activate a remote subtitle reader.
# Exactly one original configure option died: `--enable-libshaderc`, removed upstream
# by 062de19095 "configure: remove libshaderc and libglslang support", which release/9.0 contains.
# The flag appears 7 times in n8.1.2's configure and 0 times in release/9.0's, and FFmpeg's configure
# dies on unknown options, so `.libshaderc` had to come out of the dependencyLibrary array in
# main.swift. A dry configure run of the full 224-flag option set against release/9.0 otherwise
# succeeded, with `--enable-decoder=sonic` warning ("did not match anything") and not dying. shaderc
# itself is still built and still shipped; only FFmpeg stopped linking it.
#
# Our delta to MPVKit is kept in separate reviewable patches:
#   scripts/mpvkit-dvfel.patch        patches MPVKit's Package.swift and build driver: dependency
#                                     pins, libplacebo source build, Security.framework linkage,
#                                     Apple TLS selection, and the E-AC-3 encoder.
#                                     Also carries exact 0002 frontend WMO for one Swift object.
#                                     base.swift keeps pkg-config metadata within each target.
#   scripts/mpv-moltenvk-resize.patch patches MPV itself. Installed below as patch 0004 next to
#                                     MPVKit's own 0001-0003, because it edits the file MPVKit's 0001
#                                     creates and so must be applied after it.
#   scripts/mpv-coreaudio-hotplug-lifecycle.patch patches MPV's native CoreAudio init-failure
#                                     cleanup. Installed as 0005; no mpv version/audio policy bump.
#   scripts/mpv-http-seek-interrupt.patch interrupts obsolete HTTP I/O for an accepted seek
#                                     and reopens only that source at its exact byte offset (0006).
# LittleCMS is also built from exact official RC source and assembled as a local target.
# Every other unlisted library retains the MPVKit 1.0.0 wrapper pin.
#
# Cost: a full clean run builds 9 slices (ios, isimulator x2, tvos x2, tvsimulator x2, macos x2)
# of FFmpeg, libplacebo and mpv from source. Budget hours, not minutes, and ~20 GB of scratch.
set -euo pipefail

# Fixture-only source/ref/patch overrides are accepted only in preflight mode; ordinary builds
# retain the pinned source and patch below. The explicit worktree and destination overrides remain
# available to the release/build orchestration after its compatibility gates.
PREFLIGHT_ONLY="${MPVKIT_DVFEL_PREFLIGHT_ONLY:-0}"
MPVKIT_REF="2103893078c5e339073b11737b86f7f22b9c4491"   # MPVKit 1.0.0 tip, the base for our patch
if [ "$PREFLIGHT_ONLY" = "1" ] && [ -n "${MPVKIT_DVFEL_REF:-}" ]; then
  MPVKIT_REF="$MPVKIT_DVFEL_REF"
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# The canonical source checkout is deliberately a sibling of VortX, so the build does not silently
# fall back to a second HOME cache that can retain a different MPVKit history. MPVKIT_DVFEL_WORK is
# an explicit override for an isolated checkout (it names the checkout itself, not its parent).
MPVKIT_DIR="${MPVKIT_DVFEL_WORK:-$REPO/../MPVKit}"
# Keep the short name for the focused archive-gate fixture and older local wrappers; it aliases the
# exact checkout above rather than reintroducing a second cache root.
WORK="$MPVKIT_DIR"
MPVKIT_SOURCE_URL="https://github.com/mpvkit/MPVKit.git"
if [ "$PREFLIGHT_ONLY" = "1" ] && [ -n "${MPVKIT_DVFEL_SOURCE_URL:-}" ]; then
  MPVKIT_SOURCE_URL="$MPVKIT_DVFEL_SOURCE_URL"
fi
# Keep the rebuilt package in the canonical stage directory until the application compatibility
# build accepts it. Callers may provide an explicit destination after that gate has passed.
DEST="${MPVKIT_DVFEL_DEST:-$REPO/_build/MPVKit-DVFEL}"
DEST_ROOT="$(dirname "$DEST")"
PATCH="$REPO/scripts/mpvkit-dvfel.patch"
if [ "$PREFLIGHT_ONLY" = "1" ] && [ -n "${MPVKIT_DVFEL_PATCH:-}" ]; then
  PATCH="$MPVKIT_DVFEL_PATCH"
fi

fail() {
  echo "build-mpvkit-dvfel: $*" >&2
  exit 1
}

# The authenticated release trees are build inputs. HarfBuzz's GPU-header helper
# already handles a denied source copy by comparing it with the generated output.
# Keep source modes/timestamps and the strict before/after verifier unchanged.
run_with_subtitle_sources_readonly() (
  set -euo pipefail
  [ "$#" -ge 2 ] || { echo 'subtitle readonly: work and absolute command required' >&2; exit 1; }
  subtitle_work="$1"
  shift
  [ -d "$subtitle_work" ] && [ ! -L "$subtitle_work" ] &&
    [ "$(cd "$subtitle_work" && pwd -P)" = "$subtitle_work" ] || exit 1
  case "$1" in /*) ;; *) echo 'subtitle readonly: absolute executable required' >&2; exit 1 ;; esac
  [ -f "$1" ] && [ -x "$1" ] || exit 1
  for subtitle_source in \
    "$subtitle_work/dist/libunibreak-8.0-9c4fad6e" \
    "$subtitle_work/dist/libfribidi-1.0.17-6949dcde" \
    "$subtitle_work/dist/libharfbuzz-15.0.0-968536e9" \
    "$subtitle_work/dist/libbluray-1.5.0-f676408e" \
    "$subtitle_work/dist/libfreetype-2.15.0-37515cf5"; do
    [ -d "$subtitle_source" ] && [ ! -L "$subtitle_source" ] &&
      [ "$(cd "$subtitle_source" && pwd -P)" = "$subtitle_source" ] || exit 1
  done
  subtitle_policy='(version 1)
(allow default)
(deny file-write*
  (subpath (param "SRC_UNIBREAK"))
  (subpath (param "SRC_FRIBIDI"))
  (subpath (param "SRC_HARFBUZZ"))
  (subpath (param "SRC_BLURAY"))
  (subpath (param "SRC_FREETYPE")))'
  PYTHONDONTWRITEBYTECODE=1 /usr/bin/sandbox-exec \
    -D "SRC_UNIBREAK=$subtitle_work/dist/libunibreak-8.0-9c4fad6e" \
    -D "SRC_FRIBIDI=$subtitle_work/dist/libfribidi-1.0.17-6949dcde" \
    -D "SRC_HARFBUZZ=$subtitle_work/dist/libharfbuzz-15.0.0-968536e9" \
    -D "SRC_BLURAY=$subtitle_work/dist/libbluray-1.5.0-f676408e" \
    -D "SRC_FREETYPE=$subtitle_work/dist/libfreetype-2.15.0-37515cf5" \
    -p "$subtitle_policy" "$@"
)

mkdir -p "$DEST_ROOT"

matches_exact_patch_tree() {
  local patch_path="$1"
  local temporary path
  temporary="$(mktemp -d "$DEST_ROOT/mpvkit-state.XXXXXX")"

  if ! (cd "$MPVKIT_DIR" && git archive HEAD | tar -x -C "$temporary"); then
    rm -rf "$temporary"
    return 1
  fi
  if ! (cd "$MPVKIT_DIR" && git apply --unsafe-paths --directory="$temporary" "$patch_path"); then
    rm -rf "$temporary"
    return 1
  fi
  while IFS= read -r path; do
    if [ ! -f "$temporary/$path" ] && [ ! -L "$temporary/$path" ]; then
      rm -rf "$temporary"
      return 1
    fi
    if ! cmp -s "$temporary/$path" "$MPVKIT_DIR/$path"; then
      rm -rf "$temporary"
      return 1
    fi
  done < <(git -C "$MPVKIT_DIR" ls-tree -r --name-only HEAD)

  # The native source helpers are deliberately untracked carrier files. If one appears in the
  # candidate checkout, the exact approved patch must also create a regular, byte-identical file
  # in the temporary patched tree. This closes the dirty-check gap without admitting arbitrary
  # untracked files or JSON receipts.
  for helper in Sources/BuildScripts/crypto-release-sources.py Sources/BuildScripts/crypto-chain-gate.py Sources/BuildScripts/subtitle-release-sources.py Sources/BuildScripts/dovi-source-build.py Sources/BuildScripts/dovi-source-map.json Sources/BuildScripts/dovi-source-policy.json; do
    if [ -e "$MPVKIT_DIR/$helper" ] || [ -e "$temporary/$helper" ]; then
      if [ ! -f "$MPVKIT_DIR/$helper" ] || [ -L "$MPVKIT_DIR/$helper" ] ||
         [ ! -f "$temporary/$helper" ] || [ -L "$temporary/$helper" ] ||
         ! cmp -s "$MPVKIT_DIR/$helper" "$temporary/$helper"; then
        rm -rf "$temporary"
        return 1
      fi
    fi
  done

  rm -rf "$temporary"
  return 0
}

for tool in meson ninja cmake pkg-config nasm wget curl; do
  command -v "$tool" >/dev/null || { echo "missing build tool: $tool (brew install $tool)" >&2; exit 1; }
done

# The combined candidate consumes only these fixed release bodies. The download directory is
# deliberately fresh and outside every Git source root; no caller-supplied URL, archive, hash or
# cache is accepted. This function is inert in preflight mode and runs only after the exact MPVKit
# source/patch admission above has succeeded.
prepare_crypto_sources() {
  local helper="$MPVKIT_DIR/Sources/BuildScripts/crypto-release-sources.py"
  local stage="$WORK/dist/crypto-source-download"
  [ -f "$helper" ] && [ ! -L "$helper" ] || fail "crypto source helper is missing or linked"
  [ ! -e "$stage" ] && [ ! -L "$stage" ] || fail "crypto source staging directory must be fresh"
  mkdir -p "$stage"
  local python_bin="$(command -v python3)"
  [ -x "$python_bin" ] || fail "supported python3 executable is required"
  "$python_bin" - <<'PY'
import sys
import zipfile
if sys.version_info < (3, 10):
    raise SystemExit("Python 3.10 or newer is required for strict archive handling")
if not hasattr(zipfile, "ZipFile"):
    raise SystemExit("strict archive reader is unavailable")
PY
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --retry 3 --max-time 600 --max-filesize 8388608 --output "$stage/gmp-6.3.0.tar.xz" \
    https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --retry 3 --max-time 600 --max-filesize 8388608 --output "$stage/nettle-4.0.tar.gz" \
    https://ftp.gnu.org/gnu/nettle/nettle-4.0.tar.gz
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --retry 3 --max-time 600 --max-filesize 8388608 --output "$stage/gnutls-3.8.13.tar.xz" \
    https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz
  [ "$(wc -c <"$stage/gmp-6.3.0.tar.xz" | tr -d ' ')" = 2094196 ] || fail "GMP release size differs"
  [ "$(wc -c <"$stage/gnutls-3.8.13.tar.xz" | tr -d ' ')" = 7275324 ] || fail "GnuTLS release size differs"
  [ "$(wc -c <"$stage/nettle-4.0.tar.gz" | tr -d ' ')" -le 8388608 ] || fail "Nettle release exceeds bound"
  printf '%s  %s\n' \
    a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898 "$stage/gmp-6.3.0.tar.xz" \
    3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094 "$stage/nettle-4.0.tar.gz" \
    ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e "$stage/gnutls-3.8.13.tar.xz" | shasum -a 256 -c - ||
    fail "crypto release body digest differs"
  "$python_bin" "$helper" prepare "$WORK" "$stage"
  "$python_bin" "$helper" verify "$WORK"
}

# The subtitle candidate consumes only these fixed release bodies. The download directory is
# deliberately fresh and outside every Git source root; no caller-supplied URL, archive, hash or
# cache is accepted. This function runs before SwiftPM so source selectors and receipts cannot
# drift after the native build begins.
prepare_subtitle_sources_v3() {
  local helper="$MPVKIT_DIR/Sources/BuildScripts/subtitle-release-sources.py"
  [ -f "$helper" ] && [ ! -L "$helper" ] || fail "subtitle source helper is missing or linked"
  local python_bin="$(command -v python3)"
  [ -x "$python_bin" ] || fail "supported python3 executable is required"
  "$python_bin" - <<'PY'
import sys
import zipfile
if sys.version_info < (3, 10):
    raise SystemExit("Python 3.10 or newer is required for strict archive handling")
if not hasattr(zipfile, "ZipFile"):
    raise SystemExit("strict archive reader is unavailable")
PY
  # v6 never reinterprets or overwrites the legacy schema2/three-source state.
  # A complete current state is reusable only after the helper's strict recheck.
  if [ -e "$WORK/dist/subtitle-sources-v3" ] || [ -L "$WORK/dist/subtitle-sources-v3" ]; then
    "$python_bin" "$helper" verify-v3 "$WORK"
    return
  fi
  local source_mode=prepare-v3
  local stage="$WORK/dist/subtitle-source-download-v3"
  if [ -e "$WORK/dist/subtitle-sources" ] || [ -L "$WORK/dist/subtitle-sources" ]; then
    source_mode=extend-bluray
    stage="$WORK/dist/subtitle-bluray-download"
  fi
  [ ! -e "$stage" ] && [ ! -L "$stage" ] || fail "subtitle source staging directory must be fresh"
  mkdir -p "$stage"
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --retry 3 --max-time 600 --max-filesize 8388608 --output "$stage/libbluray-1.5.0.tar.xz" \
    https://download.videolan.org/pub/videolan/libbluray/1.5.0/libbluray-1.5.0.tar.xz
  [ "$(wc -c <"$stage/libbluray-1.5.0.tar.xz" | tr -d ' ')" = 473072 ] || fail "libbluray release size differs"
  printf '%s  %s\n' \
    f676408e91a5d321abf8b8d4dfdae36205c297dab5c54c3ec519639025f474a2 "$stage/libbluray-1.5.0.tar.xz" | shasum -a 256 -c - ||
    fail "libbluray release body digest differs"
  if [ "$source_mode" = extend-bluray ]; then
    # The fixed helper requires exact old receipt35c plus all old raw/member/source
    # identities before publishing only fresh bluray/v3 destinations.
    "$python_bin" "$helper" extend-bluray "$WORK" "$stage"
    "$python_bin" "$helper" verify-v3 "$WORK"
    return
  fi
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --retry 3 --max-time 600 --max-filesize 8388608 --output "$stage/libunibreak-8.0.tar.gz" \
    https://github.com/adah1972/libunibreak/releases/download/libunibreak_8_0/libunibreak-8.0.tar.gz
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --retry 3 --max-time 600 --max-filesize 8388608 --output "$stage/fribidi-1.0.17.tar.xz" \
    https://github.com/fribidi/fribidi/releases/download/v1.0.17/fribidi-1.0.17.tar.xz
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --retry 3 --max-time 600 --max-filesize 33554432 --output "$stage/harfbuzz-15.0.0.tar.xz" \
    https://github.com/harfbuzz/harfbuzz/releases/download/15.0.0/harfbuzz-15.0.0.tar.xz
  [ "$(wc -c <"$stage/libunibreak-8.0.tar.gz" | tr -d ' ')" = 1088508 ] || fail "libunibreak release size differs"
  [ "$(wc -c <"$stage/fribidi-1.0.17.tar.xz" | tr -d ' ')" = 1203284 ] || fail "FriBidi release size differs"
  [ "$(wc -c <"$stage/harfbuzz-15.0.0.tar.xz" | tr -d ' ')" = 20396372 ] || fail "HarfBuzz release size differs"
  printf '%s  %s\n' \
    9c4fad6e517338a098373acc9f35579ae2c325e6446666fb9ac2666ba15ceba4 "$stage/libunibreak-8.0.tar.gz" \
    6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2 "$stage/fribidi-1.0.17.tar.xz" \
    968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df "$stage/harfbuzz-15.0.0.tar.xz" | shasum -a 256 -c - ||
    fail "subtitle release body digest differs"
  "$python_bin" "$helper" prepare-v3 "$WORK" "$stage"
  "$python_bin" "$helper" verify-v3 "$WORK"
}

prepare_subtitle_sources() {
  local helper="$MPVKIT_DIR/Sources/BuildScripts/subtitle-release-sources.py"
  local python_bin="$(command -v python3)"
  if [ -e "$WORK/dist/subtitle-sources-v4" ] || [ -L "$WORK/dist/subtitle-sources-v4" ]; then
    "$python_bin" "$helper" verify-freetype "$WORK"
    return
  fi
  prepare_subtitle_sources_v3
  local stage="$WORK/dist/subtitle-freetype-download-v4"
  [ ! -e "$stage" ] && [ ! -L "$stage" ] || fail "FreeType source stage must be fresh"
  mkdir -p "$stage"
  # Fixed immutable official source GET; redirects are not followed. Source
  # preparation authenticates every Git body/mode before publishing a tree.
  curl --proto '=https' --tlsv1.2 --fail --max-time 600 --max-filesize 2594500 \
    --output "$stage/freetype-37515cf56ba3349656049edbed89ffc6f6466f2d.tar.gz" \
    'https://gitlab.freedesktop.org/freetype/freetype/-/archive/37515cf56ba3349656049edbed89ffc6f6466f2d/freetype-37515cf56ba3349656049edbed89ffc6f6466f2d.tar.gz'
  [ "$(wc -c <"$stage/freetype-37515cf56ba3349656049edbed89ffc6f6466f2d.tar.gz" | tr -d ' ')" = 2594500 ] || fail "FreeType raw source size differs"
  printf '%s  %s\n' 9efee8b0508e142f38d1c7e2e192d3e5041aa4bbf6c2ab1a901518211f76a914 "$stage/freetype-37515cf56ba3349656049edbed89ffc6f6466f2d.tar.gz" | shasum -a 256 -c - || fail "FreeType raw source SHA256 differs"
  "$python_bin" "$helper" extend-freetype "$WORK" "$stage"
  "$python_bin" "$helper" verify-freetype "$WORK"
}

if [ ! -e "$MPVKIT_DIR" ]; then
  mkdir -p "$(dirname "$MPVKIT_DIR")"
  git clone --no-checkout "$MPVKIT_SOURCE_URL" "$MPVKIT_DIR" ||
    fail "fresh MPVKit clone failed: $MPVKIT_DIR"
  git -C "$MPVKIT_DIR" fetch --quiet --depth 1 origin "$MPVKIT_REF" ||
    fail "fresh MPVKit clone does not contain pinned commit $MPVKIT_REF"
  git -C "$MPVKIT_DIR" checkout --quiet --detach "$MPVKIT_REF" ||
    fail "fresh MPVKit checkout failed for pinned commit $MPVKIT_REF"
  FRESH_HEAD="$(git -C "$MPVKIT_DIR" rev-parse HEAD)" || fail "cannot read fresh MPVKit HEAD"
  [ "$FRESH_HEAD" = "$MPVKIT_REF" ] ||
    fail "fresh MPVKit HEAD mismatch: expected $MPVKIT_REF, got $FRESH_HEAD"
elif [ ! -e "$MPVKIT_DIR/.git" ]; then
  fail "MPVKit path exists but is not a Git checkout: $MPVKIT_DIR"
else
  CURRENT_HEAD="$(git -C "$MPVKIT_DIR" rev-parse HEAD 2>/dev/null)" ||
    fail "cannot read existing MPVKit HEAD: $MPVKIT_DIR"
  [ "$CURRENT_HEAD" = "$MPVKIT_REF" ] ||
    fail "existing MPVKit checkout is on $CURRENT_HEAD, expected pinned $MPVKIT_REF; refusing to switch it"
  if ! git -C "$MPVKIT_DIR" diff --cached --quiet; then
    fail "existing MPVKit checkout has staged changes; refusing to reuse it"
  fi
  STATUS="$(git -C "$MPVKIT_DIR" status --porcelain --untracked-files=all)"
  if [ -n "$STATUS" ] && ! matches_exact_patch_tree "$PATCH"; then
    fail "existing MPVKit checkout differs from the exact approved VortX patch; refusing arbitrary or partial dirty state"
  fi
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      '?? Sources/BuildScripts/patch/FFmpeg/0005-finite-reference-reader.patch'|'?? Sources/BuildScripts/patch/libmpv/0019-finite-reference-reader.patch') ;;
      '?? Sources/BuildScripts/crypto-release-sources.py'|'?? Sources/BuildScripts/crypto-chain-gate.py'|'?? Sources/BuildScripts/subtitle-release-sources.py'|'?? Sources/BuildScripts/dovi-source-build.py'|'?? Sources/BuildScripts/dovi-source-map.json'|'?? Sources/BuildScripts/dovi-source-policy.json')
        helper_path="${line#?? }"
        [ -f "$MPVKIT_DIR/$helper_path" ] && [ ! -L "$MPVKIT_DIR/$helper_path" ] ||
          fail "native source helper must be a regular file: $MPVKIT_DIR/$helper_path" ;;
      ' M Package.swift'|'M Package.swift'|' M Sources/BuildScripts/XCFrameworkBuild/main.swift'|'M Sources/BuildScripts/XCFrameworkBuild/main.swift'|' M Sources/BuildScripts/XCFrameworkBuild/base.swift'|'M Sources/BuildScripts/XCFrameworkBuild/base.swift'|' M Sources/BuildScripts/patch/libmpv/0002-revert-build-static.patch'|'M Sources/BuildScripts/patch/libmpv/0002-revert-build-static.patch') ;;
      '?? .build/'*|'?? dist/'*|'?? Sources/BuildScripts/patch/libmpv/0004-moltenvk-context-check-events-resize.patch'|'?? Sources/BuildScripts/patch/libmpv/0005-coreaudio-hotplug-lifecycle.patch'|'?? Sources/BuildScripts/patch/libmpv/0006-http-seek-interrupt.patch'|'?? Sources/BuildScripts/patch/libmpv/0007-upstream-audio-layout-bounds.patch'|'?? Sources/BuildScripts/patch/libmpv/0008-upstream-gpu-next-seek-reset.patch'|'?? Sources/BuildScripts/patch/libmpv/0009-original-local-file-witness.patch'|'?? Sources/BuildScripts/patch/libmpv/0010-upstream-edition-title-lifetime.patch'|'?? Sources/BuildScripts/patch/libmpv/0011-owned-subtitle-constructor.patch'|'?? Sources/BuildScripts/patch/libmpv/0012-owned-subtitle-publication.patch'|'?? Sources/BuildScripts/patch/libmpv/0013-original-http-reference-recipe.patch'|'?? Sources/BuildScripts/patch/libmpv/0014-original-http-cancel-lifetime.patch'|'?? Sources/BuildScripts/patch/FFmpeg/0001-response-witness.patch'|'?? Sources/BuildScripts/patch/FFmpeg/0002-response-generation.patch'|'?? Sources/BuildScripts/patch/libmpv/0015-completed-response-observation.patch'|'?? Sources/BuildScripts/patch/FFmpeg/0003-sent-request-evidence.patch'|'?? Sources/BuildScripts/patch/libmpv/0016-sent-request-evidence.patch'|'?? Sources/BuildScripts/patch/libmpv/0017-bounded-prefix-request.patch'|'?? Sources/BuildScripts/patch/FFmpeg/0004-original-transport-evidence.patch'|'?? Sources/BuildScripts/patch/libmpv/0018-original-transport-evidence.patch') ;;
      *) fail "existing MPVKit checkout has unexpected dirty state: $line" ;;
    esac
  done <<< "$STATUS"
fi

# Fixed helpers require physical paths; the maintained sibling default contains
# /../ until checkout creation/identity validation has completed above.
MPVKIT_DIR="$(cd "$MPVKIT_DIR" && pwd -P)" || fail "cannot resolve validated MPVKit work directory"
WORK="$MPVKIT_DIR"
cd "$MPVKIT_DIR"
if git apply --check "$PATCH" >/dev/null 2>&1; then
  git apply "$PATCH"
elif git apply --reverse --check "$PATCH" >/dev/null 2>&1; then
  echo "build-mpvkit-dvfel: exact MPVKit patch already applied; reusing it"
else
  fail "MPVKit patch neither applies cleanly nor matches the already-applied exact patch; inspect $MPVKIT_DIR"
fi

# Future producer metadata only; keep the exact canonical patch and retry copy bound.
RESPONSE_PATCH="$REPO/scripts/ffmpeg-response-witness.patch"
RESPONSE_PATCH_HASH="$(shasum -a 256 "$RESPONSE_PATCH")"
[ "${RESPONSE_PATCH_HASH%% *}" = "6a2bf6d0feff31280470ac46e9c56b2e0a4522513959784dcb04aaf196334b9b" ] ||
  fail "FFmpeg response-witness patch differs from the reviewed n9.0.2 delta"
GENERATED_RESPONSE_PATCH="$MPVKIT_DIR/Sources/BuildScripts/patch/FFmpeg/0001-response-witness.patch"
[ ! -L "$GENERATED_RESPONSE_PATCH" ] || fail "generated response-witness patch must not be a symlink"
if [ -e "$GENERATED_RESPONSE_PATCH" ]; then
  cmp -s "$RESPONSE_PATCH" "$GENERATED_RESPONSE_PATCH" ||
    fail "existing generated response-witness patch differs: $GENERATED_RESPONSE_PATCH"
fi

# A completed-header observation remains metadata, not current-request/reader authority.
# Validate both new canonical patches and any retry copies before preflight can succeed.
RESPONSE_GENERATION_PATCH="$REPO/scripts/ffmpeg-response-generation.patch"
RESPONSE_GENERATION_PATCH_HASH="$(shasum -a 256 "$RESPONSE_GENERATION_PATCH")"
[ "${RESPONSE_GENERATION_PATCH_HASH%% *}" = "ddfb68b5d7ed3779cfa69a75a28e9d4b17bd4f28529cccf26a005e790da03098" ] ||
  fail "FFmpeg response-generation patch differs from the reviewed delta"
GENERATED_RESPONSE_GENERATION_PATCH="$MPVKIT_DIR/Sources/BuildScripts/patch/FFmpeg/0002-response-generation.patch"
[ ! -L "$GENERATED_RESPONSE_GENERATION_PATCH" ] || fail "generated response-generation patch must not be a symlink"
if [ -e "$GENERATED_RESPONSE_GENERATION_PATCH" ]; then
  cmp -s "$RESPONSE_GENERATION_PATCH" "$GENERATED_RESPONSE_GENERATION_PATCH" ||
    fail "existing generated response-generation patch differs: $GENERATED_RESPONSE_GENERATION_PATCH"
fi
OBSERVATION_PATCH="$REPO/scripts/mpv-completed-response-observation.patch"
OBSERVATION_PATCH_HASH="$(shasum -a 256 "$OBSERVATION_PATCH")"
[ "${OBSERVATION_PATCH_HASH%% *}" = "c038924be4c9b0ef187e1e9336d201b866dfa6f13457817c6e8c2d484e882e8e" ] ||
  fail "MPV completed-response observation patch differs from the reviewed delta"
GENERATED_OBSERVATION_PATCH="$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0015-completed-response-observation.patch"
[ ! -L "$GENERATED_OBSERVATION_PATCH" ] || fail "generated completed-response observation patch must not be a symlink"
if [ -e "$GENERATED_OBSERVATION_PATCH" ]; then
  cmp -s "$OBSERVATION_PATCH" "$GENERATED_OBSERVATION_PATCH" ||
    fail "existing generated completed-response observation patch differs: $GENERATED_OBSERVATION_PATCH"
fi

# Actual sent-GET evidence only; old source/component profiles remain ineligible.
SENT_FFMPEG_PATCH="$REPO/scripts/ffmpeg-sent-request-evidence.patch"
SENT_MPV_PATCH="$REPO/scripts/mpv-sent-request-evidence.patch"
SENT_FFMPEG_HASH="$(shasum -a 256 "$SENT_FFMPEG_PATCH")"
SENT_MPV_HASH="$(shasum -a 256 "$SENT_MPV_PATCH")"
[ "${SENT_FFMPEG_HASH%% *}" = "085b66cb5623ed8087481d3217b65da587b2970cd345a45896e7e87823dec9c9" ] || fail "FFmpeg sent-request evidence patch differs"
[ "${SENT_MPV_HASH%% *}" = "e3840084725be1f4948fb90c6fec87c35d55665f8310854713ebff496e1358bf" ] || fail "MPV sent-request evidence patch differs"
GENERATED_SENT_FFMPEG_PATCH="$MPVKIT_DIR/Sources/BuildScripts/patch/FFmpeg/0003-sent-request-evidence.patch"
GENERATED_SENT_MPV_PATCH="$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0016-sent-request-evidence.patch"
for generated in "$GENERATED_SENT_FFMPEG_PATCH" "$GENERATED_SENT_MPV_PATCH"; do
  [ ! -L "$generated" ] || fail "generated sent-request evidence patch must not be a symlink"
  if [ -e "$generated" ]; then
    if [ "$generated" = "$GENERATED_SENT_FFMPEG_PATCH" ]; then canonical="$SENT_FFMPEG_PATCH"; else canonical="$SENT_MPV_PATCH"; fi
    cmp -s "$canonical" "$generated" || fail "existing generated sent-request evidence patch differs: $generated"
  fi
done

# Bounded material preparation only; no duplicate open or subtitle-reader activation.
PREFIX_PATCH="$REPO/scripts/mpv-bounded-prefix-request.patch"
PREFIX_HASH="$(shasum -a 256 "$PREFIX_PATCH")"
[ "${PREFIX_HASH%% *}" = "edcfdc7d9d8da7f8a44b19d326a809de844be968cc8061b80744229da801331e" ] || fail "MPV bounded-prefix request patch differs"
GENERATED_PREFIX_PATCH="$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0017-bounded-prefix-request.patch"
[ ! -L "$GENERATED_PREFIX_PATCH" ] || fail "generated bounded-prefix request patch must not be a symlink"
if [ -e "$GENERATED_PREFIX_PATCH" ]; then
  cmp -s "$PREFIX_PATCH" "$GENERATED_PREFIX_PATCH" || fail "existing generated bounded-prefix request patch differs: $GENERATED_PREFIX_PATCH"
fi

# Private original-route observations use a versioned provider ABI. They do not
# authorize a second request, a remote timing reader, or weaker TLS policy.
TRANSPORT_FFMPEG_PATCH="$REPO/scripts/ffmpeg-original-transport-evidence.patch"
TRANSPORT_MPV_PATCH="$REPO/scripts/mpv-original-transport-evidence.patch"
TRANSPORT_FFMPEG_HASH="$(shasum -a 256 "$TRANSPORT_FFMPEG_PATCH")"
TRANSPORT_MPV_HASH="$(shasum -a 256 "$TRANSPORT_MPV_PATCH")"
[ "${TRANSPORT_FFMPEG_HASH%% *}" = "480302686b9fff135cd0665e7af76d635fc21d83f54ee0096578ddd6bd6d83e5" ] || fail "FFmpeg original-transport evidence patch differs"
[ "${TRANSPORT_MPV_HASH%% *}" = "dad7f2d20ea14eb4661ef853978be78806e1b01fce67653e3ffec9b57d4a0e82" ] || fail "MPV original-transport evidence patch differs"
GENERATED_TRANSPORT_FFMPEG_PATCH="$MPVKIT_DIR/Sources/BuildScripts/patch/FFmpeg/0004-original-transport-evidence.patch"
GENERATED_TRANSPORT_MPV_PATCH="$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0018-original-transport-evidence.patch"
for generated in "$GENERATED_TRANSPORT_FFMPEG_PATCH" "$GENERATED_TRANSPORT_MPV_PATCH"; do
  [ ! -L "$generated" ] || fail "generated original-transport evidence patch must not be a symlink"
  if [ -e "$generated" ]; then
    if [ "$generated" = "$GENERATED_TRANSPORT_FFMPEG_PATCH" ]; then canonical="$TRANSPORT_FFMPEG_PATCH"; else canonical="$TRANSPORT_MPV_PATCH"; fi
    cmp -s "$canonical" "$generated" || fail "existing generated original-transport evidence patch differs: $generated"
  fi
done

# The coherent finite-reader source wave follows the original-transport patches.
# Copy validation is source admission only; the matching native/artifact gates still apply.
READER_FFMPEG_PATCH="$REPO/scripts/ffmpeg-finite-reference-reader.patch"
READER_MPV_PATCH="$REPO/scripts/mpv-finite-reference-reader.patch"
READER_FFMPEG_HASH="$(shasum -a 256 "$READER_FFMPEG_PATCH")"
READER_MPV_HASH="$(shasum -a 256 "$READER_MPV_PATCH")"
[ "${READER_FFMPEG_HASH%% *}" = "a06f4b8b9eadc12eace93b1b340e0555116061188d0674f063698ea75d953abd" ] || fail "FFmpeg finite-reference reader patch differs"
[ "${READER_MPV_HASH%% *}" = "42c020f9f6550af5072a8eff1b5860249bb9df5f9418855cb4636cd15854f7f2" ] || fail "MPV finite-reference reader patch differs"
GENERATED_READER_FFMPEG_PATCH="$MPVKIT_DIR/Sources/BuildScripts/patch/FFmpeg/0005-finite-reference-reader.patch"
GENERATED_READER_MPV_PATCH="$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0019-finite-reference-reader.patch"
for generated in "$GENERATED_READER_FFMPEG_PATCH" "$GENERATED_READER_MPV_PATCH"; do
  [ ! -L "$generated" ] || fail "generated finite-reference reader patch must not be a symlink"
  if [ -e "$generated" ]; then
    if [ "$generated" = "$GENERATED_READER_FFMPEG_PATCH" ]; then canonical="$READER_FFMPEG_PATCH"; else canonical="$READER_MPV_PATCH"; fi
    cmp -s "$canonical" "$generated" || fail "existing generated finite-reference reader patch differs: $generated"
  fi
done

if [ "$PREFLIGHT_ONLY" = "1" ]; then
  echo "build-mpvkit-dvfel: preflight-only checkout and patch validation passed"
  exit 0
fi

CRYPTO_SOURCE_HELPER="$MPVKIT_DIR/Sources/BuildScripts/crypto-release-sources.py"
CRYPTO_GATE_HELPER="$MPVKIT_DIR/Sources/BuildScripts/crypto-chain-gate.py"
CRYPTO_SOURCE_HELPER_SHA256="3c310499d446eed72eb16521b27c16f718f23e7ab1472dec1fad79cc40ed1537"
CRYPTO_GATE_HELPER_SHA256="69a180d417c8295d723ec3eb904d93414d668e55e15d9902f93718bdcfbe0485"
SUBTITLE_SOURCE_HELPER="$MPVKIT_DIR/Sources/BuildScripts/subtitle-release-sources.py"
SUBTITLE_SOURCE_HELPER_SHA256="d09496535e49241575093692846de60b9e5948819d6540c4002047d12b5d37f3"
[ -f "$CRYPTO_SOURCE_HELPER" ] && [ ! -L "$CRYPTO_SOURCE_HELPER" ] || fail "crypto release-source helper missing"
[ -f "$CRYPTO_GATE_HELPER" ] && [ ! -L "$CRYPTO_GATE_HELPER" ] || fail "crypto chain gate helper missing"
[ -f "$SUBTITLE_SOURCE_HELPER" ] && [ ! -L "$SUBTITLE_SOURCE_HELPER" ] || fail "subtitle release-source helper missing"
[ "$(shasum -a 256 "$CRYPTO_SOURCE_HELPER" | awk '{print $1}')" = "$CRYPTO_SOURCE_HELPER_SHA256" ] ||
  fail "crypto release-source helper hash is not the resealed parent pin"
[ "$(shasum -a 256 "$CRYPTO_GATE_HELPER" | awk '{print $1}')" = "$CRYPTO_GATE_HELPER_SHA256" ] ||
  fail "crypto chain gate helper hash is not the resealed parent pin"
[ "$(shasum -a 256 "$SUBTITLE_SOURCE_HELPER" | awk '{print $1}')" = "$SUBTITLE_SOURCE_HELPER_SHA256" ] ||
  fail "subtitle release-source helper hash is not the frozen packet pin"

prepare_crypto_sources
prepare_subtitle_sources
# Source/toolchain/vendor bodies are staged and independently admitted first.
# This fixed path contains no resolver/install/download fallback.
python3 "$MPVKIT_DIR/Sources/BuildScripts/dovi-source-build.py" verify "$MPVKIT_DIR"

# Install our mpv-side patch alongside MPVKit's own libmpv patches. SpikeGit.applyPatches (added by
# mpvkit-dvfel.patch) applies that directory in sorted order, so the 0004 prefix guarantees it runs
# after MPVKit's 0001, which is what creates video/out/vulkan/context_moltenvk.m in the first place.
# Copied rather than committed into the patch-of-a-patch above so the mpv diff stays readable and
# reviewable on its own. Existing copies must be byte-identical: an unrelated untracked patch must
# never be silently overwritten during an otherwise pinned rebuild.
copy_exact() {
  local source="$1" destination="$2"
  if [ -e "$destination" ]; then
    cmp -s "$source" "$destination" || fail "existing generated patch differs: $destination"
  else
    cp "$source" "$destination"
  fi
}
copy_exact "$REPO/scripts/mpv-moltenvk-resize.patch" \
  "$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0004-moltenvk-context-check-events-resize.patch"
copy_exact "$REPO/scripts/mpv-coreaudio-hotplug-lifecycle.patch" \
  "$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0005-coreaudio-hotplug-lifecycle.patch"
copy_exact "$REPO/scripts/mpv-http-seek-interrupt.patch" \
  "$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0006-http-seek-interrupt.patch"
copy_exact "$REPO/scripts/mpv-upstream-audio-layout-bounds.patch" \
  "$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0007-upstream-audio-layout-bounds.patch"
copy_exact "$REPO/scripts/mpv-upstream-gpu-next-seek-reset.patch" \
  "$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0008-upstream-gpu-next-seek-reset.patch"
# Read-only original-source evidence; this does not enable subtitle alignment or change the C ABI.
copy_exact "$REPO/scripts/mpv-original-local-file-witness.patch" \
  "$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0009-original-local-file-witness.patch"
copy_exact "$REPO/scripts/mpv-upstream-edition-title-lifetime.patch" \
  "$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0010-upstream-edition-title-lifetime.patch"
# Bounded decoder foundation only; renderer commands and host activation remain separate.
copy_exact "$REPO/scripts/mpv-owned-subtitle-constructor.patch" \
  "$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0011-owned-subtitle-constructor.patch"
# Exact-ticket primary-slot publication; app caller ownership remains a separate gate.
copy_exact "$REPO/scripts/mpv-owned-subtitle-publication.patch" \
  "$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0012-owned-subtitle-publication.patch"
# Immutable INITIAL_REQUEST_ONLY prerequisite; no remote reader/node/UI activation.
copy_exact "$REPO/scripts/mpv-original-http-reference-recipe.patch" \
  "$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0013-original-http-reference-recipe.patch"
# Keep original-source cancellation terminal for retained optional leases; no reader activation.
copy_exact "$REPO/scripts/mpv-original-http-cancel-lifetime.patch" \
  "$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0014-original-http-cancel-lifetime.patch"
# Owned header observation only; no demux/public/worker reader activation.
copy_exact "$REPO/scripts/mpv-completed-response-observation.patch" \
  "$MPVKIT_DIR/Sources/BuildScripts/patch/libmpv/0015-completed-response-observation.patch"
# Private native header/ABI evidence; no demux or reader activation.
copy_exact "$SENT_MPV_PATCH" "$GENERATED_SENT_MPV_PATCH"
copy_exact "$PREFIX_PATCH" "$GENERATED_PREFIX_PATCH"
copy_exact "$TRANSPORT_MPV_PATCH" "$GENERATED_TRANSPORT_MPV_PATCH"
copy_exact "$READER_MPV_PATCH" "$GENERATED_READER_MPV_PATCH"

# FFmpeg has its own sorted sequence. The finite-reader delta follows the earlier
# evidence producers; it must be built with the matching MPV source family below.
mkdir -p "$MPVKIT_DIR/Sources/BuildScripts/patch/FFmpeg"
copy_exact "$RESPONSE_PATCH" "$GENERATED_RESPONSE_PATCH"
copy_exact "$RESPONSE_GENERATION_PATCH" "$GENERATED_RESPONSE_GENERATION_PATCH"
copy_exact "$SENT_FFMPEG_PATCH" "$GENERATED_SENT_FFMPEG_PATCH"
copy_exact "$TRANSPORT_FFMPEG_PATCH" "$GENERATED_TRANSPORT_FFMPEG_PATCH"
copy_exact "$READER_FFMPEG_PATCH" "$GENERATED_READER_FFMPEG_PATCH"

# A prior interrupted experiment installed this retired VortX-only FFmpeg patch as an untracked
# file. Do not delete or overwrite it implicitly; fail with an actionable path instead.
OBSOLETE_PATCH="$MPVKIT_DIR/Sources/BuildScripts/patch/FFmpeg/0001-no-private-secidentity.patch"
[ ! -e "$OBSOLETE_PATCH" ] || fail "remove retired untracked patch before retrying: $OBSOLETE_PATCH"

# GPL variant: VortX consumes the MPVKit-GPL product (libsmbclient + -Dgpl=true).
BUILD_STARTED_MARKER="$(mktemp)"
trap 'rm -f "$BUILD_STARTED_MARKER"' EXIT
run_with_subtitle_sources_readonly "$(cd "$WORK" && pwd -P)" /usr/bin/env swift run --jobs 1 --build-path ./.build --package-path Sources/BuildScripts \
  build enable-gpl platform=ios,tvos,macos version=0.0.0-dvfel

# Post-build source composition gate before artifact/package acceptance. The native
# producer applies these patches inside its build; this is not a precompiler gate.
FFMPEG_RESPONSE_SOURCE="$WORK/dist/FFmpeg-9.0.2-946fcce0"
[ "$(git -C "$FFMPEG_RESPONSE_SOURCE" rev-parse HEAD)" = "946fcce07b6dcd0331c8cc609192aeff5e1924f8" ] ||
  fail "FFmpeg response-witness source has a different upstream pin"
printf '%s  %s\n' d1301474b4389256f9862565a399a8888366a68d2e3630338848289fe8a9c831 \
  "$FFMPEG_RESPONSE_SOURCE/libavformat/http.c" | shasum -a 256 -c - ||
  fail "FFmpeg finite-reader source differs from the reviewed n9.0.2 composition"
# Every affected transport/layout source must come from the same freshly built
# component family. Checking HTTP alone cannot establish this private ABI pair.
printf '%s  %s\n' \
  14e3acc5a6715d48edb3dadb2f5248deaa38c36b30ff763e9be4b89edf2b1a0c "$FFMPEG_RESPONSE_SOURCE/libavformat/url.h" \
  16bf38abc7a5b5586268c71723041df2b90b7b99a8fbaeb06c8b20926534fe7a "$FFMPEG_RESPONSE_SOURCE/libavformat/avio.c" \
  cc9c11534ff5017d5931bb06788f95f10e9809953e5ec1cc03114a3a877cdcce "$FFMPEG_RESPONSE_SOURCE/libavformat/tcp.c" \
  0f07be92b62cefb53c6db5552951c658c756fac36ce22b03ccca8a044f1911f2 "$FFMPEG_RESPONSE_SOURCE/libavformat/tls.c" \
  257c76932de48ed84bf849a44ca9ea6fe85adb93a26bb4f7112b19000084ff19 "$FFMPEG_RESPONSE_SOURCE/libavformat/tls.h" \
  b04fb28df85f1ef3883b4927d0bfab4477f400128c122f794ff13b4b9c85bebc "$FFMPEG_RESPONSE_SOURCE/libavformat/tls_securetransport.c" \
  77d72cb88fc662b984f051335b356abc3e76e97ce39302dde6961ecdbba7a332 "$FFMPEG_RESPONSE_SOURCE/libavformat/tls_mbedtls.c" \
  a8c74f929942423550dba65f738fd4d2ad2d63d975665f64e6da1b00f5001645 "$FFMPEG_RESPONSE_SOURCE/libavformat/vortx_reference_reader.inc" \
  e0ccea8466e28169d0882fd664081baa09d3a39626d5351a31804b6dc4bb4e94 "$FFMPEG_RESPONSE_SOURCE/libavformat/vortx_reference_pin.h" \
  adaeb9d58c20ba3305bce4784205c20d6276ba67a758a9ec7207c850c7ba8d87 "$FFMPEG_RESPONSE_SOURCE/libavformat/vortx_reference_reader_stream.h" \
  fa5f8e163d9368b30db6a9c7f0c69ed36e91d6a23ca409b7ba468c7d2282751c "$FFMPEG_RESPONSE_SOURCE/libavformat/vortx_reference_sparse.h" \
  0e3201c26657765a1e6e7a15fe9db1bcac5cf96a8cb7e9d691533e0f4bf3f15f "$FFMPEG_RESPONSE_SOURCE/libavformat/vortx_reference_sparse.inc" | shasum -a 256 -c - ||
  fail "FFmpeg finite-reader source family differs from the reviewed composition"
MPV_OBSERVATION_SOURCE="$WORK/dist/libmpv-master-8c67647b"
[ "$(git -C "$MPV_OBSERVATION_SOURCE" rev-parse HEAD)" = "8c67647b50059406c5c0444903597281b81516cf" ] ||
  fail "MPV response observation source has a different upstream pin"
printf '%s  %s\n' \
  f5a4cd7bf4e29902ef965e43027755c19ded1423129a3fbe9808ad89e64c0e1c "$MPV_OBSERVATION_SOURCE/demux/demux.c" \
  bee52b38477ce7c8efd9a50e778f720ea8c9eec577afab29998682c26ffe75e2 "$MPV_OBSERVATION_SOURCE/demux/demux.h" \
  d945ae1699d383c3d645d2ab963abb166fd0c19f10a4ab144505e7fbfb0408fb "$MPV_OBSERVATION_SOURCE/demux/demux_lavf.c" \
  222ec8920d38971d386470d8172e45a89a52350eb352124ddf954be9409b792b "$MPV_OBSERVATION_SOURCE/demux/reference_reader.c" \
  59d669fb370bc12f01856031b8f9d908eb1d50a927d955ecb1fe0b4484c2407d "$MPV_OBSERVATION_SOURCE/demux/reference_reader.h" \
  ded5dc02785e98934a966de87df4337e4c6aed0275bce26da2017883917f4c8d "$MPV_OBSERVATION_SOURCE/demux/reference_reader_internal.h" \
  650bf7b94771e70a6b934b21e362bc77f66ceb1d23ee684d2b169c6e694544a5 "$MPV_OBSERVATION_SOURCE/stream/stream_lavf.c" \
  1f606a977b55f18fdb9f9fc7f5e4549b5774bef10a06c33b06ab945531909b29 "$MPV_OBSERVATION_SOURCE/stream/reference_source.h" \
  adaeb9d58c20ba3305bce4784205c20d6276ba67a758a9ec7207c850c7ba8d87 "$MPV_OBSERVATION_SOURCE/stream/vortx_reference_reader_stream.h" \
  c2abd8f89a772717fdd4bcdbb4a2236d9fb28eca029acfe84bf12f7333df5a55 "$MPV_OBSERVATION_SOURCE/meson.build" \
  014b93845488ef873a4d29c4c8dd4ada69d244626e7a7b38bac82809989c6b29 "$MPV_OBSERVATION_SOURCE/player/owned_subtitle.c" \
  8d2f0ee5c972d1da69213cd80fbe249bcf3f19d9de8a2ef87e241d2f08f06284 "$MPV_OBSERVATION_SOURCE/player/owned_subtitle.h" \
  e7a19f392bb69e9d208382f157234ac3c908d22a0d4afee5f372ee8f9d33dade "$MPV_OBSERVATION_SOURCE/player/command.c" \
  23ac96bfedefcab2234afa2a6f329a36fac6735effca6798b4043d777b060217 "$MPV_OBSERVATION_SOURCE/player/reference_owned.inc" \
  63c498dd4bdc9fa9c6d128f1be8f37d7cdf377c853888342897f6639601662f6 "$MPV_OBSERVATION_SOURCE/sub/owned_text_slot.h" \
  9b57ccd08e5777e2bc644cbf8001df0301552edf5cf24e36185a54f4cd667195 "$MPV_OBSERVATION_SOURCE/sub/osd.c" \
  6e2137b90fe7f2915a528bdd83426448afbd099229f65342dbfd85d1ba1d347b "$MPV_OBSERVATION_SOURCE/sub/dec_sub.c" \
  cb9b5af7c3f87a8dda584617c1f20a90a9331182d54a50c7e5fb8e64e74b384f "$MPV_OBSERVATION_SOURCE/sub/dec_sub.h" \
  1b7cc4d40efa0620bd10669dc44a7d6b32d0236e2ae2be3510a3bac0829e39c2 "$MPV_OBSERVATION_SOURCE/demux/demux_mkv.c" \
  38df7814efc3aa7434e5afe269406a989ab6a5fa22a200aa28149a3ab68e46d9 "$MPV_OBSERVATION_SOURCE/demux/reference_mkv.h" \
  3ac442e8ff489d11f4a5df6b86f8d964457753f66ce5f3eb530d7db3746b6f7c "$MPV_OBSERVATION_SOURCE/demux/reference_mkv_reader.c" \
  4b013b6e794257a576bc01f6becb9d120cb878e0851b2e0bdd2225dcf7b18df2 "$MPV_OBSERVATION_SOURCE/demux/reference_mkv_sparse.h" \
  e36c6a879138b26e125f647c9254b41674b22b338ab12838376fe8d38bdae056 "$MPV_OBSERVATION_SOURCE/demux/reference_mkv_sparse_planner.c" \
  c88597a42186ceb81f45f1f44b3734469cf06889ea3bf91e4853b861943e84fe "$MPV_OBSERVATION_SOURCE/demux/reference_mkv_sparse_planner.h" \
  5deae68bf3c680aa4898ca6c8e0c0e76aa4628bffa693d0ae2d6dd287d9a5e64 "$MPV_OBSERVATION_SOURCE/demux/reference_mkv_sparse_worker.c" \
  fa5f8e163d9368b30db6a9c7f0c69ed36e91d6a23ca409b7ba468c7d2282751c "$MPV_OBSERVATION_SOURCE/stream/vortx_reference_sparse.h" | shasum -a 256 -c - ||
  fail "MPV finite-reader source family differs from the reviewed composition"
for private_header in "$FFMPEG_RESPONSE_SOURCE/libavformat/vortx_http_request.h" "$MPV_OBSERVATION_SOURCE/stream/vortx_http_request.h"; do
  [ -f "$private_header" ] && [ ! -L "$private_header" ] || fail "private sent-request header must be a regular source file"
  printf '%s  %s\n' d7730cc3492f6eaf6f6f1134fa50331c13e251fb1ddab8e577e1b912b8679dc9 "$private_header" | shasum -a 256 -c - || fail "private sent-request header differs"
done
cmp -s "$FFMPEG_RESPONSE_SOURCE/libavformat/vortx_http_request.h" "$MPV_OBSERVATION_SOURCE/stream/vortx_http_request.h" || fail "private sent-request headers disagree"
cmp -s "$FFMPEG_RESPONSE_SOURCE/libavformat/vortx_reference_reader_stream.h" "$MPV_OBSERVATION_SOURCE/stream/vortx_reference_reader_stream.h" || fail "private finite-reader headers disagree"
for sparse_header in "$FFMPEG_RESPONSE_SOURCE/libavformat/vortx_reference_sparse.h" "$MPV_OBSERVATION_SOURCE/stream/vortx_reference_sparse.h"; do
  [ -f "$sparse_header" ] && [ ! -L "$sparse_header" ] || fail "private sparse header must be a regular source file"
  printf '%s  %s\n' fa5f8e163d9368b30db6a9c7f0c69ed36e91d6a23ca409b7ba468c7d2282751c "$sparse_header" | shasum -a 256 -c - || fail "private sparse header differs"
done
cmp -s "$FFMPEG_RESPONSE_SOURCE/libavformat/vortx_reference_sparse.h" "$MPV_OBSERVATION_SOURCE/stream/vortx_reference_sparse.h" || fail "private sparse headers disagree"

# Assembly reads the per-library release ZIP, not slice scratch directories. Default
# shipping and v1/v2 verifier APIs retain their contracts. The unshipped v3/v4/v5
# cuts remain archival-readable through their own frozen historical verifiers;
# the current verifier explicitly retires those profiles.
# This caller selects the explicit five-source FreeType v7 contract below.
# Refuse to package a stale ZIP after an interrupted or incorrectly cached run.
# Libmpv must be fresh too: a rebuilt FFmpeg archive alone cannot carry the
# CoreAudio lifetime fix. Never silently repackage the old vulnerable player.
for library in Libmpv Libavcodec Libavdevice Libavfilter Libavformat Libavutil Libswresample Libswscale Libplacebo lcms2 Libdav1d Libssl Libcrypto gmp nettle hogweed gnutls Libsmbclient Libunibreak Libfribidi Libharfbuzz Libbluray Libfreetype Libdovi; do
  library_zip="$WORK/dist/release/$library.xcframework.zip"
  [ -f "$library_zip" ] || {
    echo "missing rebuilt artifact: $library_zip" >&2
    exit 1
  }
  [ "$library_zip" -nt "$BUILD_STARTED_MARKER" ] || {
    echo "refusing stale $library ZIP: $library_zip" >&2
    exit 1
  }
done
rm -f "$BUILD_STARTED_MARKER"
trap - EXIT

mkdir -p "$DEST_ROOT"
STAGED_DEST="$(mktemp -d "${DEST}.staged.XXXXXX")"
PREVIOUS_DEST="${DEST}.previous"
trap 'rm -rf "$STAGED_DEST"' EXIT

# Capture the authenticated archive/tree closure into a fresh path before the artifact gate.
"$(command -v python3)" "$CRYPTO_SOURCE_HELPER" verify "$WORK"
CRYPTO_CAPTURE="$WORK/dist/crypto-capture"
[ ! -e "$CRYPTO_CAPTURE" ] && [ ! -L "$CRYPTO_CAPTURE" ] || fail "crypto capture path must be fresh"
"$(command -v python3)" "$CRYPTO_SOURCE_HELPER" capture "$WORK" "$CRYPTO_CAPTURE"
"$(command -v python3)" "$SUBTITLE_SOURCE_HELPER" verify "$WORK"
SUBTITLE_CAPTURE="$WORK/dist/subtitle-capture"
[ ! -e "$SUBTITLE_CAPTURE" ] && [ ! -L "$SUBTITLE_CAPTURE" ] || fail "subtitle capture path must be fresh"
"$(command -v python3)" "$SUBTITLE_SOURCE_HELPER" capture "$WORK" "$SUBTITLE_CAPTURE"
"$(command -v python3)" "$SUBTITLE_SOURCE_HELPER" verify-capture "$SUBTITLE_CAPTURE"

# Compare the two pinned original Shaderc inputs once with the trusted Apple toolchain.
python3 "$HERE/native-media-hosted/evidence.py" apple-shaderc-inputs "$WORK"
python3 "$HERE/native-media-hosted/evidence.py" apple-openssl-builds "$WORK"
python3 "$HERE/native-media-hosted/evidence.py" apple-subtitle-builds "$WORK"
python3 "$HERE/native-media-hosted/evidence.py" apple-dovi-builds "$WORK"
python3 "$HERE/native-media-hosted/evidence.py" apple-dovi-receipt "$WORK/dist/dovi-builds/vortx-dovi-builds.json"
python3 "$HERE/native-media-hosted/evidence.py" apple-subtitle-receipt \
  "$WORK/dist/subtitle-builds/vortx-subtitle-builds.json"
"$HERE/assemble-mpvkit-dvfel.sh" "$WORK" "$STAGED_DEST"
"$(command -v python3)" "$CRYPTO_SOURCE_HELPER" verify "$WORK"
"$(command -v python3)" "$CRYPTO_GATE_HELPER" capture "$WORK" "$STAGED_DEST" \
  --dependency-profile native-upgrades-crypto-chain-v1
"$HERE/verify-mpvkit-dvfel-artifacts.sh" "$STAGED_DEST" \
  --dependency-profile native-upgrades-openssl410-crypto-subtitles-bluray150-freetype2150-libdovi340-v7 \
  --shaderc-inputs "$WORK/dist/libshaderc-2026.1.0" \
  --openssl-builds "$WORK/dist/openssl/vortx-openssl-builds.json" \
  --crypto-work "$WORK"
# Candidate-only private ABI gate; the universal shipping verifier stays unchanged.
python3 "$HERE/native-media-hosted/evidence.py" apple-sent-abi "$STAGED_DEST"

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
