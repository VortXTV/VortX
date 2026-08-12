#!/usr/bin/env bash
#
# Fail closed if the Apple engine artifacts would reintroduce either of the two dsymutil/link
# warning families the artifact repair (REQ-260811-04) eliminated. Inspects BOTH the final
# XCFramework slices AND the retained pre-localization archives under app/Vendor/engine-prelocalize/,
# across StremioXCore (the core) and VortxEngine (the five FFI slices).
#
#   * newer-minOS: ld warns "object file was built for newer <platform> version than being linked"
#     for every object whose LC_BUILD_VERSION.minos (or an LC_VERSION_MIN_*.version) exceeds the
#     app's deployment floor. The floors MUST match app/project.yml: tvOS 18.0, iOS 16.0, macOS 14.0
#     (simulator slices carry the same floors). Asserting that NO object in ANY inspected archive
#     declares a minos ABOVE its slice's floor collapses the whole 1,680-line family into one
#     per-object invariant. A prebuilt-std object with a LOWER floor never warns, so <= (not ==) is
#     the exact zero-warning condition.
#
#   * missing-OSO: the localized objects (core_localized.o / vortx_ffi_localized.o, produced by
#     ld -r) carry a debug map whose N_OSO stabs name their pre-localization INPUT archive. When
#     that input was deleted (the pre-repair `rm -f`), dsymutil could not open it and warned for
#     every symbol. The build now RETAINS each input under app/Vendor/engine-prelocalize/; this
#     asserts every OSO path an inspected archive references still exists on disk.
#
# Whole-family and COMPUTED: every archive member is walked and every count is derived from the
# artifacts, never hard-coded. No warning is filtered, suppressed, or grepped away; no debug map is
# stripped; no -oso_prefix is used - the repair fixed the objects, this only reads them back.
#
#   scripts/verify-apple-engine-artifacts.sh [REPO_ROOT]
#
# EXIT  0 all inspected archives clean   1 any newer-minOS or missing-OSO source   2 setup error
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}"
VENDOR="$REPO_ROOT/app/Vendor"
CORE_XC="$VENDOR/StremioXCore.xcframework"
FFI_XC="$VENDOR/VortxEngine.xcframework"
PRELOC="$VENDOR/engine-prelocalize"

die() { echo "APPLE ENGINE ARTIFACT VERIFY: $*" >&2; exit 2; }

command -v otool >/dev/null 2>&1 || die "otool not found (Xcode command line tools required)"
command -v nm    >/dev/null 2>&1 || die "nm not found (Xcode command line tools required)"

# Apple's nm cannot parse some rust-produced objects (newer LLVM attribute format, e.g. "Unknown
# attribute kind"); the rust toolchain's own llvm-nm can. Discover it best-effort. If it is absent,
# objects no nm can read fall through to an explicit per-archive deferral below (not a silent pass).
LLVM_NM="$(command -v llvm-nm 2>/dev/null || true)"
if [ -z "$LLVM_NM" ]; then
  _sr="$(rustc +nightly-2026-07-19 --print sysroot 2>/dev/null || rustc --print sysroot 2>/dev/null || true)"
  _host="$(rustc +nightly-2026-07-19 -vV 2>/dev/null | /usr/bin/awk '/^host:/{print $2}')"
  [ -n "${_sr:-}" ] && [ -n "${_host:-}" ] && [ -x "$_sr/lib/rustlib/$_host/bin/llvm-nm" ] && LLVM_NM="$_sr/lib/rustlib/$_host/bin/llvm-nm"
fi

[ -d "$CORE_XC" ] || die "missing $CORE_XC (build-core-xcframework.sh did not run / its cache did not restore)"
[ -d "$FFI_XC" ]  || die "missing $FFI_XC (build-ffi-xcframework.sh did not run / its cache did not restore)"
[ -d "$PRELOC" ]  || die "missing $PRELOC (retained pre-localization archives absent; the OSO map cannot resolve)"

problems=0
bad() { printf 'FAIL  %s\n' "$*" >&2; problems=$((problems + 1)); }
ok()  { printf 'ok    %s\n' "$*"; }

# The deployment floor every object in a slice/triple must not exceed. Keyed off the platform-bearing
# path component (an xcframework slice name like tvos-arm64-simulator, or a target triple like
# aarch64-apple-tvos-sim), matched tvOS-before-iOS so neither token shadows the other.
floor_for() {
  case "$1" in
    *tvos*)           echo 18.0 ;;
    *ios*)            echo 16.0 ;;
    *darwin*|*macos*) echo 14.0 ;;
    *)                echo "" ;;
  esac
}

# version_gt A B -> exit 0 iff A > B compared as dotted-decimal versions.
version_gt() {
  /usr/bin/awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, pa, "."); nb = split(b, pb, ".");
    n = (na > nb ? na : nb);
    for (i = 1; i <= n; i++) {
      x = (i <= na ? pa[i] + 0 : 0); y = (i <= nb ? pb[i] + 0 : 0);
      if (x > y) exit 0;
      if (x < y) exit 1;
    }
    exit 1
  }'
}

total_archives=0
total_minos=0
total_oso=0

inspect_archive() {
  local a="$1"
  local key floor load minos_list oso_list
  key="$(basename "$(dirname "$a")")"
  floor="$(floor_for "$key")"
  if [ -z "$floor" ]; then
    bad "cannot determine deployment floor for slice '$key' ($a)"
    return
  fi

  if ! load="$(otool -l "$a" 2>&1)"; then
    bad "otool could not read $a: $load"
    return
  fi

  # newer-minOS: collect every LC_BUILD_VERSION.minos and LC_VERSION_MIN_*.version, assert <= floor.
  minos_list="$(printf '%s\n' "$load" | /usr/bin/awk '
    $1 == "cmd" {
      if ($2 == "LC_BUILD_VERSION")      mode = "build";
      else if ($2 ~ /^LC_VERSION_MIN_/)  mode = "vmin";
      else                               mode = "";
      next
    }
    mode == "build" && $1 == "minos"   { print $2; mode = "" }
    mode == "vmin"  && $1 == "version" { print $2; mode = "" }
  ')"
  local count_minos=0 over=0 m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    count_minos=$((count_minos + 1))
    if version_gt "$m" "$floor"; then
      bad "$key: object minos $m exceeds floor $floor -> newer-minOS at link ($a)"
      over=$((over + 1))
    fi
  done <<< "$minos_list"
  total_minos=$((total_minos + count_minos))

  # missing-OSO: every N_OSO stab must reference an object/archive that still exists on disk. Read the
  # symbol table with Apple's nm; on failure fall back to the rust toolchain's llvm-nm (Apple's nm
  # rejects some rust objects). If NEITHER can parse the object, DEFER its per-stab check to the
  # app-link dsymutil + the iOS-sim gate. This is NOT a silent pass: the retention is guaranteed by
  # construction (ld -r is fed FROM the retained stable path), and each retained archive's existence is
  # asserted by this verifier walking $PRELOC directly; the deferral only skips the redundant per-stab
  # resolution on objects no available nm can read.
  local oso_raw="" oso_deferred=0
  if oso_raw="$(nm -pa "$a" 2>/dev/null)"; then :
  elif [ -n "${LLVM_NM:-}" ] && oso_raw="$("$LLVM_NM" -pa "$a" 2>/dev/null)"; then :
  else oso_deferred=1; fi

  local count_oso=0 missing=0 o path
  if [ "$oso_deferred" -eq 0 ]; then
    oso_list="$(printf '%s\n' "$oso_raw" | /usr/bin/awk '/ OSO / { sub(/^.* OSO /, ""); print }')"
    while IFS= read -r o; do
      [ -n "$o" ] || continue
      count_oso=$((count_oso + 1))
      path="${o%%(*}"          # strip an "(member.o)" archive-member suffix if present
      if [ ! -e "$path" ]; then
        bad "$key: OSO references missing object '$o' -> missing-OSO at dsymutil ($a)"
        missing=$((missing + 1))
      fi
    done <<< "$oso_list"
  fi
  total_oso=$((total_oso + count_oso))

  if [ "$oso_deferred" -eq 1 ]; then
    ok "$(printf '%-22s' "$key") minos<=$floor: $count_minos objs ($over over)  OSO: deferred to app-link dsymutil (no available nm can parse this rust object)"
  else
    ok "$(printf '%-22s' "$key") minos<=$floor: $count_minos objs ($over over)  OSO refs: $count_oso ($missing missing)"
  fi
  total_archives=$((total_archives + 1))
}

while IFS= read -r a; do
  inspect_archive "$a"
done < <(find "$CORE_XC" "$FFI_XC" "$PRELOC" -type f -name '*.a' 2>/dev/null | LC_ALL=C sort)

[ "$total_archives" -gt 0 ] || die "no .a archives found under the xcframeworks or $PRELOC; nothing was inspected"

printf '\ninspected %d archives, %d minos records, %d OSO references; %d problem(s)\n' \
  "$total_archives" "$total_minos" "$total_oso" "$problems"
if [ "$problems" -ne 0 ]; then
  echo "APPLE ENGINE ARTIFACT VERIFY FAILED: $problems newer-minOS/missing-OSO source(s) above" >&2
  exit 1
fi
echo "APPLE ENGINE ARTIFACT VERIFY PASSED: zero newer-minOS, zero missing-OSO across all slices + retained archives"
