#!/usr/bin/env bash
# audit-bundle-symlinks.sh — fail-closed checker for unsafe symlinks inside a built .app.
#
# WHY THIS EXISTS
#   A symlink `app/Resources/fonts/fonts -> /Users/daksh/vortx/app/Resources/fonts`
#   (an ABSOLUTE path on the build machine, pointing back at its own parent through
#   the case-insensitive `vortx`/`VortX` alias) was copied verbatim into every Release
#   bundle produced on that machine: VortXTV, VortXTVLite, VortXiOSNative and VortXMac.
#   Consequences:
#     * `simctl install` refuses such a bundle outright ("invalid symlink at .../fonts/fonts"),
#       so simulator verification was impossible.
#     * every sideload IPA / DMG shipped an absolute link embedding the developer's home
#       directory — a privacy leak and an App Store review risk.
#   Device sideloads tolerated it, which is exactly why it survived undetected for 12 days.
#   This checker turns that class of defect into a hard, visible CI failure.
#
# THE PREDICATE — why "no symlinks at all" is WRONG, and what the correct rule is.
#   Legitimate RELATIVE symlinks exist inside real macOS bundles, most notably in
#   versioned frameworks:
#       Foo.framework/Versions/Current -> A
#       Foo.framework/Resources        -> Versions/Current/Resources
#       Foo.framework/Headers          -> Versions/Current/Headers
#       Foo.framework/Foo              -> Versions/Current/Foo
#   A blanket "no symlinks" rule would turn every macOS (VortXMac) build red. So we do NOT
#   ban symlinks. We ban the three properties an app-bundle symlink must never have:
#
#     (1) ABSOLUTE target   — readlink() begins with "/". No legitimate in-bundle symlink is
#                             absolute; a valid framework link is always relative to its parent.
#                             This is the LOAD-BEARING check: on a case-insensitive dev machine
#                             the offending fonts link actually RESOLVES (vortx==VortX exists),
#                             so it is neither dangling nor, from that machine's view, escaping —
#                             absolute is the only property that catches it everywhere.
#     (2) DANGLING          — the target does not exist ( `[ -e ]` dereferences the whole chain ).
#                             On the CI runner the fonts link's `/Users/daksh/...` target is absent,
#                             so it is also dangling there; caught here as a backstop.
#     (3) ESCAPES the bundle — the fully-resolved real path lands outside the bundle root. A bundle
#                             must be self-contained; a relative `../../..`-style link that climbs
#                             out is just as unshippable as an absolute one.
#
#   Order matters: (1) is checked FIRST so the dev-machine case (absolute link that happens to
#   resolve to an existing, in-tree path via the vortx/VortX alias) is still reported.
#
#   A symlink that is relative, resolves to an existing target, and stays inside the bundle root
#   is ACCEPTED. That is precisely the framework-internal case, verified against a real VortXMac
#   build (see the department report accompanying this change).
#
# USAGE
#   audit-bundle-symlinks.sh <path> [<path> ...]
#     <path> may be:
#       * a built *.app bundle                (scanned in full, recursively)
#       * a directory containing *.app bundles (e.g. an IPA Payload/ or a CI out/ dir; each found
#                                               *.app is scanned)
#       * any other directory                  (scanned as-is, treated as a single bundle root)
#   Exit 0 if every inspected symlink is safe; non-zero (1) on the first bundle that contains an
#   unsafe symlink, after listing every offending link and its target.
set -euo pipefail

PROG="$(basename "$0")"

die_usage() {
    echo "usage: $PROG <path-to-.app-or-dir> [<path> ...]" >&2
    exit 2
}

[ "$#" -ge 1 ] || die_usage

# Canonicalize a path (resolve symlinks + /tmp->/private/tmp) without requiring the LEAF to exist.
# The bundle root itself always exists, so plain realpath is fine for roots.
canonical_root() {
    realpath "$1"
}

# is_within <child-real> <parent-real> — 0 if child == parent or lives under parent/.
is_within() {
    case "$1" in
        "$2") return 0 ;;
        "$2"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Scan a single bundle root. Echoes findings; returns 0 if clean, 1 if any unsafe symlink found.
scan_bundle() {
    local bundle="$1"
    local root inspected=0 bad=0 link raw real

    if [ ! -d "$bundle" ]; then
        echo "::error::$PROG: not a directory: $bundle" >&2
        return 1
    fi
    root="$(canonical_root "$bundle")"
    echo "auditing bundle: $bundle"

    # -print0 + read -d '' so bundle/link names with spaces survive. The loop runs in THIS shell
    # (process substitution, not a pipe) so the counters persist after it.
    while IFS= read -r -d '' link; do
        inspected=$((inspected + 1))
        raw="$(readlink "$link")"

        # (1) absolute target — always illegal inside a bundle.
        case "$raw" in
            /*)
                echo "::error::unsafe symlink (absolute target): '$link' -> '$raw'" >&2
                bad=$((bad + 1))
                continue
                ;;
        esac

        # (2) dangling — target does not exist (dereferences the full chain).
        if [ ! -e "$link" ]; then
            echo "::error::unsafe symlink (dangling target): '$link' -> '$raw'" >&2
            bad=$((bad + 1))
            continue
        fi

        # (3) escapes the bundle — resolved real path is not inside the bundle root.
        real="$(realpath "$link")"
        if ! is_within "$real" "$root"; then
            echo "::error::unsafe symlink (escapes bundle): '$link' -> '$raw' (resolves to '$real', outside '$root')" >&2
            bad=$((bad + 1))
            continue
        fi
    done < <(find "$bundle" -type l -print0)

    if [ "$bad" -gt 0 ]; then
        echo "FAIL: $bundle — $bad unsafe symlink(s) of $inspected inspected" >&2
        return 1
    fi
    echo "OK: $bundle — $inspected symlink(s) inspected, all relative and in-bundle"
    return 0
}

# Expand each argument into one or more bundle roots.
roots=()
for arg in "$@"; do
    if [ ! -d "$arg" ]; then
        echo "::error::$PROG: not a directory: $arg" >&2
        exit 2
    fi
    case "$(basename "$arg")" in
        *.app)
            # The argument is itself an .app — scan it whole (covers nested .appex/.app/frameworks).
            roots+=("$arg")
            ;;
        *)
            # A container dir: audit every *.app under it. If there are none, audit the dir itself
            # so the tool still works on an extracted Payload or an arbitrary staging tree.
            found=()
            while IFS= read -r -d '' app; do
                found+=("$app")
            done < <(find "$arg" -type d -name '*.app' -print0)
            if [ "${#found[@]}" -gt 0 ]; then
                roots+=("${found[@]}")
            else
                roots+=("$arg")
            fi
            ;;
    esac
done

status=0
for root in "${roots[@]}"; do
    if ! scan_bundle "$root"; then
        status=1
    fi
done

if [ "$status" -ne 0 ]; then
    echo "audit-bundle-symlinks: FAILED — one or more bundles contain unsafe symlinks" >&2
    exit 1
fi
echo "audit-bundle-symlinks: PASSED — ${#roots[@]} bundle(s) clean"
