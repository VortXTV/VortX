#!/usr/bin/env bash
# Build + run the DV rendition/stall repro harness against the production remux +
# HLS server, standalone on macOS. Exit code = RED count, except for the dedicated
# INFRA code below.
#
# =============================================================================
# WHICH BINARY THIS GATE TESTS
# =============================================================================
# This gate is only worth its exit code if it links the SAME FFmpeg / libplacebo
# binaries the branch actually ships. It used to resolve every framework from
#
#   MPV_ROOT="${MPV_ROOT:-$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/\
#     VortX-*/SourcePackages/artifacts/mpvkit 2>/dev/null | head -n 1)}"
#
# i.e. the ALPHABETICALLY FIRST of however many VortX DerivedData directories the
# machine happens to hold (13 of them here), all of which are the SPM download
# cache for UPSTREAM MPVKit. On a branch that builds its own MPVKit - project.yml
# points the MPVKit package at a LOCAL path, as feat/mpvkit-dv-fel does with
# Vendor/MPVKit-DVFEL - the gate therefore exercised a DIFFERENT libavformat,
# libavcodec, libavutil, libswscale and libplacebo than the product does. A gate
# that tests a binary the product does not ship can pass while the product is
# broken. It is the same defect class as a harness that stops compiling against
# the code it guards: the check goes quiet instead of going red.
#
# Resolution now FOLLOWS THE PRODUCT, per framework:
#
#   1. app/project.yml is the single source of truth for the MPVKit package.
#      `path:` means the branch ships a LOCAL package; `url:` means upstream.
#   2. For a local package, its own Package.swift says which binaryTargets are
#      built here (`path: "artifacts/X.xcframework"`) and which are still
#      downloaded (`url:` + checksum). Locally-built targets are taken from the
#      local artifacts/; every other target is taken from the SPM download cache.
#      That hybrid is exactly the link set Xcode gives the app.
#   3. Every framework's SOURCE, PATH and SHA-256 is printed before the run, plus
#      one aggregate fingerprint for the whole link set, so any past result can be
#      traced to the exact binaries that produced it.
#   4. Anything undecidable is INFRA and a non-zero exit, never a quiet choice.
#
# Escape hatches, both announced loudly in the banner:
#   MPV_ROOT=...            override the SPM download cache root. It does NOT
#                           override locally-built frameworks; those follow
#                           Package.swift, because that is what the app links.
#   VORTX_MPV_FORCE_SPM=1   deliberately link the all-upstream set, for A/B
#                           comparison against the branch's own build.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"

# INFRA exit code. It must not collide with a RED count: main.swift ends with
# `exit(Int32(min(redCount, 125)))` over 27 runtime checks, so 0-27 are genuine
# product verdicts, and 126 / 127 / 128+ are reserved by the shell for exec
# failures and signals. 30 sits outside both ranges. The previous script used
# `exit 2` for a missing framework slice, which reads identically to "2 checks
# went RED" - an infrastructure failure wearing a product verdict's clothes.
readonly INFRA_EXIT=30

infra() {
  echo "" >&2
  echo "[INFRA] $*" >&2
  echo "[INFRA] exit $INFRA_EXIT - the gate could not determine, or could not reach," >&2
  echo "[INFRA] the MPVKit binaries this branch ships. NO verdict exists for this run." >&2
  echo "[INFRA] This is NOT a player regression." >&2
  exit "$INFRA_EXIT"
}

# Every harness process uses the production user Caches/VortXHLS parent. Its launch registry is process-local,
# so concurrent harnesses can each scavenge the other's live launch directory. Hold a kernel-backed lock around
# the entire resolver, compile and run. Descriptor mode keeps a harmless inode for FIFO ordering; the kernel
# releases the actual lock when this shell exits, so a crashed runner cannot strand a stale ownership claim.
readonly HARNESS_LOCK_FILE="/tmp/vortx-dv-rendition-stall.lock"
readonly HARNESS_LOCK_TIMEOUT_SECONDS=600
[ -x /usr/bin/lockf ] || infra "/usr/bin/lockf is unavailable; concurrent spool ownership is unsafe."
if ! exec 9>"$HARNESS_LOCK_FILE"; then
  infra "cross-process harness lock file could not be opened."
fi
echo "  harness lock    waiting up to ${HARNESS_LOCK_TIMEOUT_SECONDS}s for $HARNESS_LOCK_FILE"
set +e
/usr/bin/lockf -s -t "$HARNESS_LOCK_TIMEOUT_SECONDS" 9
lock_status=$?
set -e
[ "$lock_status" -eq 0 ] \
  || infra "cross-process harness lock could not be acquired (lockf exit $lock_status)."
echo "  harness lock    acquired $HARNESS_LOCK_FILE"

# ----------------------------------------------------------------------------
# 1. What does app/project.yml say the MPVKit package is?
# ----------------------------------------------------------------------------
PROJECT_YML="$REPO/app/project.yml"
[ -f "$PROJECT_YML" ] || infra "app/project.yml not found at $PROJECT_YML, so there is no way to tell which MPVKit this branch ships."

# Walks the `packages:` block, finds the `MPVKit:` entry, and prints either
# "path <value>" or "url <value>". Comment lines inside the block are indented,
# so they never match the package-name rule and never reset the state.
mpvkit_declaration() {
  awk '
    /^packages:[[:space:]]*$/                        { inpkgs = 1; next }
    inpkgs && /^[^[:space:]#]/                       { inpkgs = 0; inmpv = 0 }
    inpkgs && /^  [A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*$/ {
      inmpv = ($0 ~ /^  MPVKit:[[:space:]]*$/) ? 1 : 0; next
    }
    inmpv && /^    path:/ { sub(/^    path:[[:space:]]*/, ""); print "path " $0; exit }
    inmpv && /^    url:/  { sub(/^    url:[[:space:]]*/,  ""); print "url "  $0; exit }
  ' "$1"
}

MPVKIT_DECL="$(mpvkit_declaration "$PROJECT_YML" || true)"
[ -n "$MPVKIT_DECL" ] || infra "no MPVKit package declaration (neither 'path:' nor 'url:') found under 'packages:' in $PROJECT_YML. Refusing to guess which framework set the branch links."
MPVKIT_KIND="${MPVKIT_DECL%% *}"
MPVKIT_REF="${MPVKIT_DECL#* }"

# ----------------------------------------------------------------------------
# 2. If the package is local, which of its binaryTargets are built here?
# ----------------------------------------------------------------------------
# Prints the name of every `.binaryTarget` declared with `path:` (built locally)
# and skips every one declared with `url:` (downloaded by SPM).
local_binary_targets() {
  awk '
    /\.binaryTarget\(/                     { inbt = 1; nm = ""; kind = ""; next }
    inbt && /name:[[:space:]]*"/           { l = $0; sub(/.*name:[[:space:]]*"/, "", l); sub(/".*/, "", l); nm = l; next }
    inbt && /[[:space:]]path:[[:space:]]*"/ { kind = "path"; next }
    inbt && /[[:space:]]url:[[:space:]]*"/  { kind = "url";  next }
    inbt && /^[[:space:]]*\)/              { if (kind == "path" && nm != "") print nm; inbt = 0; nm = ""; kind = ""; next }
  ' "$1"
}

LOCAL_PKG=""
LOCAL_ART=""
LOCAL_KEYS=""
FORCED_SPM="${VORTX_MPV_FORCE_SPM:-0}"

if [ "$MPVKIT_KIND" = "path" ] && [ "$FORCED_SPM" != "1" ]; then
  LOCAL_PKG="$REPO/app/$MPVKIT_REF"
  [ -f "$LOCAL_PKG/Package.swift" ] || infra "app/project.yml points the MPVKit package at '$MPVKIT_REF', but $LOCAL_PKG/Package.swift does not exist. The branch's own link set is undeterminable."
  LOCAL_KEYS="$(local_binary_targets "$LOCAL_PKG/Package.swift" | tr '\n' ' ')"
  [ -n "${LOCAL_KEYS// /}" ] || infra "$LOCAL_PKG/Package.swift declares no locally-built binaryTargets (no '.binaryTarget(... path: \"artifacts/...\")'). Either the package is not what this gate thinks it is, or the parse is wrong; both are ambiguity, not a verdict."
  LOCAL_ART="$LOCAL_PKG/artifacts"
  [ -d "$LOCAL_ART" ] || infra "the branch ships a LOCAL MPVKit ('$MPVKIT_REF') whose Package.swift builds ${LOCAL_KEYS} here, but $LOCAL_ART does not exist. artifacts/ is gitignored build output; build it (scripts/build-mpvkit-dvfel.sh) before running this gate. Refusing to silently substitute upstream MPVKit, which is not what this branch ships."
fi

# ----------------------------------------------------------------------------
# 3. The SPM download cache, resolved only if some framework actually needs it.
# ----------------------------------------------------------------------------
SPM_ROOT=""
SPM_ORIGIN=""

require_spm_root() {
  [ -z "$SPM_ROOT" ] || return 0
  if [ -n "${MPV_ROOT:-}" ]; then
    SPM_ROOT="$MPV_ROOT"
    SPM_ORIGIN="MPV_ROOT override"
  else
    # Most RECENTLY MODIFIED wins. The old `ls -d ... | head -n 1` took the
    # alphabetically first of every VortX DerivedData directory on the machine,
    # which is arbitrary and frequently months stale.
    SPM_ROOT="$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/VortX-*/SourcePackages/artifacts/mpvkit 2>/dev/null | head -n 1)"
    SPM_ORIGIN="newest DerivedData VortX-*/SourcePackages/artifacts/mpvkit"
  fi
  [ -n "$SPM_ROOT" ] || infra "no SPM mpvkit artifact cache found under $HOME/Library/Developer/Xcode/DerivedData/VortX-*/SourcePackages/artifacts/mpvkit, and MPV_ROOT is unset. Build the app once so SPM resolves its binary targets, or set MPV_ROOT."
  [ -d "$SPM_ROOT" ] || infra "the SPM mpvkit artifact root '$SPM_ROOT' ($SPM_ORIGIN) is not a directory."
}

# ----------------------------------------------------------------------------
# 4. Resolve every framework, recording source + path + fingerprint.
# ----------------------------------------------------------------------------
FRAMEWORK_KEYS=(Libavformat-GPL Libavcodec-GPL Libavutil-GPL Libavdevice-GPL Libavfilter-GPL \
  Libswresample-GPL Libswscale-GPL Libssl Libcrypto Libass Libfreetype Libfribidi Libharfbuzz \
  Libshaderc_combined lcms2 Libplacebo Libdovi Libunibreak Libsmbclient gmp nettle hogweed gnutls \
  Libdav1d Libuavs3d)

is_local_key() {
  case " $LOCAL_KEYS " in (*" $1 "*) return 0 ;; (*) return 1 ;; esac
}

find_macos_slice() {  # $1 = a directory that contains (or is) an .xcframework
  find "$1" -type d -name macos-arm64_x86_64 2>/dev/null | head -n 1
}

LINK_FLAGS=()
REPORT_ROWS=()
FINGERPRINT_INPUT=""
LOCAL_COUNT=0
SPM_COUNT=0

for key in "${FRAMEWORK_KEYS[@]}"; do
  if is_local_key "$key"; then
    source_tag="LOCAL"
    container="$LOCAL_ART/$key.xcframework"
    root_for_display="$LOCAL_ART"
    [ -d "$container" ] || infra "$key is declared as a locally-built binaryTarget in $LOCAL_PKG/Package.swift, but $container is missing. The branch ships a framework this gate cannot find; it will not fall back to upstream and call the result a verdict."
  else
    source_tag="SPM"
    require_spm_root
    container="$SPM_ROOT/$key"
    root_for_display="$SPM_ROOT"
    [ -d "$container" ] || infra "$key is not built by this branch and is not present in the SPM artifact cache at $container. Build the app once so SPM resolves it, or set MPV_ROOT to a cache that has it."
  fi

  slice="$(find_macos_slice "$container")"
  [ -n "$slice" ] || infra "$key ($source_tag) has no macos-arm64_x86_64 slice under $container. This gate runs on macOS and cannot link it."
  framework_dir="$(find "$slice" -maxdepth 1 -name '*.framework' -type d | head -n 1)"
  [ -n "$framework_dir" ] || infra "$key ($source_tag) has a macos-arm64_x86_64 slice at $slice but no .framework inside it."

  framework_name="$(basename "$framework_dir" .framework)"
  binary="$framework_dir/$framework_name"
  [ -f "$binary" ] || infra "$key ($source_tag) resolved to $framework_dir but its Mach-O binary '$framework_name' is missing, so it cannot be fingerprinted or linked."

  sha="$(shasum -a 256 "$binary" | cut -d' ' -f1)"
  FINGERPRINT_INPUT+="$source_tag $key $sha"$'\n'
  REPORT_ROWS+=("$(printf '  %-6s %-20s %s  %s' "$source_tag" "$key" "${sha:0:16}" "${framework_dir#$root_for_display/}")")
  if [ "$source_tag" = "LOCAL" ]; then LOCAL_COUNT=$((LOCAL_COUNT + 1)); else SPM_COUNT=$((SPM_COUNT + 1)); fi

  LINK_FLAGS+=( -F "$(dirname "$framework_dir")" -framework "$framework_name" )
done

# MoltenVK is a static archive rather than a framework, but it is part of the
# same link set and follows the same source decision.
if is_local_key MoltenVK; then
  MOLTEN_SOURCE="LOCAL"; MOLTEN_CONTAINER="$LOCAL_ART/MoltenVK.xcframework"; MOLTEN_ROOT="$LOCAL_ART"
else
  MOLTEN_SOURCE="SPM"; require_spm_root; MOLTEN_CONTAINER="$SPM_ROOT/MoltenVK"; MOLTEN_ROOT="$SPM_ROOT"
fi
[ -d "$MOLTEN_CONTAINER" ] || infra "MoltenVK ($MOLTEN_SOURCE) not found at $MOLTEN_CONTAINER."
MOLTEN_ARCHIVE="$(find "$MOLTEN_CONTAINER" -path '*macos-arm64_x86_64/libMoltenVK.a' | head -n 1)"
[ -n "$MOLTEN_ARCHIVE" ] || infra "MoltenVK ($MOLTEN_SOURCE) has no macos-arm64_x86_64/libMoltenVK.a under $MOLTEN_CONTAINER."
MOLTEN_SHA="$(shasum -a 256 "$MOLTEN_ARCHIVE" | cut -d' ' -f1)"
FINGERPRINT_INPUT+="$MOLTEN_SOURCE MoltenVK $MOLTEN_SHA"$'\n'
REPORT_ROWS+=("$(printf '  %-6s %-20s %s  %s' "$MOLTEN_SOURCE" "MoltenVK" "${MOLTEN_SHA:0:16}" "${MOLTEN_ARCHIVE#$MOLTEN_ROOT/}")")
if [ "$MOLTEN_SOURCE" = "LOCAL" ]; then LOCAL_COUNT=$((LOCAL_COUNT + 1)); else SPM_COUNT=$((SPM_COUNT + 1)); fi

LINK_SET_FINGERPRINT="$(printf '%s' "$FINGERPRINT_INPUT" | shasum -a 256 | cut -d' ' -f1)"
TOTAL_COUNT=$((LOCAL_COUNT + SPM_COUNT))

# ----------------------------------------------------------------------------
# 5. Say out loud what is about to be tested. Every run, before any work.
# ----------------------------------------------------------------------------
echo "=============================================================================="
echo "=== MPVKIT UNDER TEST (dv-rendition-stall gate) ==============================="
echo "=============================================================================="
printf '  branch          %s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '(not a git worktree)')"
printf '  commit          %s\n' "$(git rev-parse --short HEAD 2>/dev/null || echo '(unknown)')"
printf '  project.yml     MPVKit -> %s: %s\n' "$MPVKIT_KIND" "$MPVKIT_REF"
if [ -n "$LOCAL_ART" ]; then
  printf '  package kind    LOCAL - this branch builds its own MPVKit\n'
  printf '  LOCAL root      %s\n' "$LOCAL_ART"
else
  printf '  package kind    UPSTREAM - this branch links MPVKit as published\n'
fi
if [ -n "$SPM_ROOT" ]; then
  printf '  SPM root        %s\n' "$SPM_ROOT"
  printf '  SPM root chosen %s\n' "$SPM_ORIGIN"
fi
if [ "$FORCED_SPM" = "1" ]; then
  printf '  !! OVERRIDE     VORTX_MPV_FORCE_SPM=1 - locally-built frameworks are being IGNORED\n'
fi
if [ -n "${MPV_ROOT:-}" ]; then
  printf '  !! OVERRIDE     MPV_ROOT is set; the SPM half of the link set came from it\n'
fi
echo "  ----------------------------------------------------------------------------"
echo "  SOURCE FRAMEWORK            SHA-256(16)       PATH (relative to its root)"
printf '%s\n' "${REPORT_ROWS[@]}"
echo "  ----------------------------------------------------------------------------"
printf '  link set        %d frameworks: %d from this branch, %d from the SPM cache\n' "$TOTAL_COUNT" "$LOCAL_COUNT" "$SPM_COUNT"
printf '  FINGERPRINT     %s\n' "$LINK_SET_FINGERPRINT"
echo "=============================================================================="
echo ""

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

test/dv-rendition-stall/make-fixture.sh "${FIXTURE_SECONDS:-240}"
for fixture in fixture-multiaudio.mkv fixture-mixedcodec.mkv fixture-manyaudio.mkv; do
  [ -s "/tmp/dd-dvstall/fixtures/$fixture" ] \
    || infra "fixture generation completed without a readable /tmp/dd-dvstall/fixtures/$fixture."
done

ENGINE_TRANSACTION_FLAGS=()
ENGINE_TRANSACTION_FRAMEWORKS=()
ENGINE_TRANSACTION_SOURCES=()
if [ "${ENGINE_TRANSACTION:-0}" = "1" ]; then
  ENGINE_TRANSACTION_FLAGS=( -D ENGINE_TRANSACTION_HARNESS )
  ENGINE_TRANSACTION_FRAMEWORKS=(
    -framework AVKit
    -framework CoreImage
    -framework ImageIO
    -framework UniformTypeIdentifiers
    -framework AppKit
  )
  ENGINE_TRANSACTION_SOURCES=(
    app/SourcesShared/CoreModels.swift
    app/Sources/Player/MPVPlayerDelegate.swift
    app/Sources/Player/MPVTrack.swift
    app/Sources/Player/SkipSegments.swift
    app/Sources/Player/AudioOutputMode.swift
    app/Sources/Player/PerformanceMode.swift
    app/Sources/Player/MPVProperty.swift
    app/Sources/Player/VortXRemuxResourceLoader.swift
    app/Sources/Player/AVPlayerEngine.swift
  )
  echo "  engine gate     ENABLED: actual AVPlayerEngine setAudioTrack success + rollback"
fi

mkdir -p /tmp/dd-dvstall
# macOS ships Bash 3.2, whose `set -u` treats an empty `"${array[@]}"` as an unbound variable.
# The `+` guard preserves zero arguments in stock mode and every discrete argument in engine mode.
xcrun swiftc -sdk "$SDK_PATH" \
  "${ENGINE_TRANSACTION_FLAGS[@]+"${ENGINE_TRANSACTION_FLAGS[@]}"}" \
  "${LINK_FLAGS[@]}" "$MOLTEN_ARCHIVE" \
  -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework CoreVideo \
  -framework CoreFoundation -framework CoreMedia -framework Metal -framework VideoToolbox \
  -framework Foundation -framework IOKit -framework IOSurface -framework QuartzCore \
  -framework Network "${ENGINE_TRANSACTION_FRAMEWORKS[@]+"${ENGINE_TRANSACTION_FRAMEWORKS[@]}"}" \
  -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ \
  -o /tmp/dd-dvstall/repro-harness \
  test/dv-rendition-stall/Stubs.swift \
  app/Sources/Player/DVPlaybackPolicy.swift \
  app/Sources/Player/VortXRemuxBuffer.swift \
  app/Sources/Player/MultiAudioPolicy.swift \
  app/Sources/Player/SubtitleRenditionPolicy.swift \
  app/Sources/Player/RemuxResumePolicy.swift \
  app/Sources/Player/AudioTranscodePolicy.swift \
  app/Sources/Player/VortXAudioTranscoder.swift \
  app/SourcesShared/VortXEngineProtocol.swift \
  app/Sources/Player/PGSOCRPolicy.swift \
  app/Sources/Player/VortXPGSSubtitleOCR.swift \
  app/Sources/Player/VortXMKVRemuxStream.swift \
  app/SourcesShared/VortXEngineHostPolicy.swift \
  app/Sources/Player/VortXHostedResponse.swift \
  app/Sources/Player/VortXRemuxHLSServer.swift \
  "${ENGINE_TRANSACTION_SOURCES[@]+"${ENGINE_TRANSACTION_SOURCES[@]}"}" \
  test/dv-rendition-stall/main.swift

/tmp/dd-dvstall/repro-harness 9>&-
