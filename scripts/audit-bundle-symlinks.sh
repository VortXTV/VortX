#!/usr/bin/env bash
# audit-bundle-symlinks.sh : fail-closed checker for unsafe symlinks inside a built .app.
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
#       directory, a privacy leak and an App Store review risk.
#   Device sideloads tolerated it, which is why it survived undetected for twelve days.
#   This checker turns that class of defect into a hard, visible CI failure.
#
#   The exact historical invocation that created the shipping-tree link is not preserved, so
#   this checker is built against the unsafe PATTERN rather than any one command: a link-creating
#   step that does not prove its destination absent first (for example `ln -s <src> <dest>` while
#   <dest> already exists as a directory) nests a link inside that directory. The guard does not
#   depend on which tool did it; it inspects the built artifact.
#
# THE PREDICATE : why "no symlinks at all" is WRONG, and what the correct rule is.
#   Legitimate RELATIVE symlinks exist inside real macOS bundles, most notably in
#   versioned frameworks:
#       Foo.framework/Versions/Current -> A
#       Foo.framework/Resources        -> Versions/Current/Resources
#       Foo.framework/Headers          -> Versions/Current/Headers
#       Foo.framework/Foo              -> Versions/Current/Foo
#   A blanket "no symlinks" rule would turn every macOS (VortXMac) build red. So we do NOT
#   ban symlinks. We ban the properties an app-bundle symlink must never have:
#
#     (1) ABSOLUTE target   : readlink() begins with "/". No legitimate in-bundle symlink is
#                             absolute; a valid framework link is always relative to its parent.
#                             This is the LOAD-BEARING check: on a case-insensitive dev machine
#                             the offending fonts link actually RESOLVES (vortx==VortX exists),
#                             so it is neither dangling nor, from that machine's view, escaping.
#                             Absolute is the only property that catches it everywhere.
#     (2) DANGLING          : the target does not exist.
#     (3) ESCAPES the bundle at ANY hop : the link chain steps outside the bundle root even once.
#                             We check containment at EVERY hop, not only the final resolved path.
#                             A chain can leave the bundle and re-enter (relative first hop climbs
#                             out with `..`, a later absolute hop points back in); the final
#                             realpath would land inside and a final-only check would pass it, yet
#                             the artifact still contains a link that references a path outside the
#                             bundle. Per-hop containment rejects that.
#
#   Order: (1) is reported FIRST so the dev-machine case (an absolute link that happens to resolve
#   to an existing in-tree path via the vortx/VortX alias) is still named as absolute. Then the
#   chain is walked one hop at a time; each hop is resolved LEXICALLY against the link's own
#   directory (no symlink following during containment evaluation) and must stay inside the bundle
#   root. Dangling is detected when a hop's target neither exists nor is a further symlink.
#
#   A symlink that is relative, whose every hop stays inside the bundle, and whose chain ends at an
#   existing in-bundle target is ACCEPTED. That is exactly the framework-internal case, verified
#   against real shipping macOS bundles (Tailscale/Sparkle, Discord/Electron) whose versioned
#   frameworks carry genuine relative symlinks, and against a real VortXMac build.
#
# USAGE
#   audit-bundle-symlinks.sh <path> [<path> ...]
#     <path> may be:
#       * a built *.app bundle                 (scanned in full, recursively)
#       * a directory containing *.app bundles (e.g. an IPA Payload/ or a CI out/ dir; each found
#                                               *.app is scanned)
#       * any other directory                  (scanned as-is, treated as a single bundle root)
#   Exit 0 if every inspected symlink is safe; non-zero (1) on the first bundle that contains an
#   unsafe symlink, after listing every offending link and its target.
set -euo pipefail

PROG="$(basename "$0")"
MAX_HOPS=64   # cycle / excessive-depth guard for the chain walk

die_usage() {
    echo "usage: $PROG <path-to-.app-or-dir> [<path> ...]" >&2
    exit 2
}

[ "$#" -ge 1 ] || die_usage

# Purely LEXICAL normalization of an absolute path: collapse "//", ".", and ".." textually,
# WITHOUT following any symlink. This is what lets us judge containment hop by hop: we want to know
# whether the link, as named, points outside the bundle, not where the OS would eventually land.
lexical_abs() { # <absolute-path> -> normalized absolute path
    printf '%s' "$1" | /usr/bin/awk '
    {
        n = split($0, a, "/")   # a leading "/" yields a[1] == ""
        top = 0
        for (i = 1; i <= n; i++) {
            c = a[i]
            if (c == "" || c == ".") continue
            if (c == "..") { if (top > 0) top--; continue }
            stack[++top] = c
        }
        out = ""
        for (i = 1; i <= top; i++) out = out "/" stack[i]
        if (out == "") out = "/"
        printf "%s", out
    }'
}

# is_within <child> <parent> : 0 if child == parent or lives under parent/.
is_within() {
    case "$1" in
        "$2") return 0 ;;
        "$2"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Walk one symlink's chain, checking containment at every hop. Echoes a diagnostic and returns 1
# on the first violation; returns 0 if the whole chain stays inside $root and ends at a real target.
# Args: <symlink-abs-path> <canonical-root>
check_symlink_chain() {
    local start="$1" root="$2"
    local cur="$start" hops=0 tgt cand candlex dir

    while :; do
        hops=$((hops + 1))
        if [ "$hops" -gt "$MAX_HOPS" ]; then
            echo "::error::unsafe symlink (chain too deep / possible cycle): '$start'" >&2
            return 1
        fi

        tgt="$(readlink "$cur")"
        case "$tgt" in
            /*) cand="$tgt" ;;                                 # absolute hop
            *)  dir="$(dirname "$cur")"; cand="$dir/$tgt" ;;   # relative to this link's own dir
        esac
        candlex="$(lexical_abs "$cand")"

        # Containment at THIS hop.
        if ! is_within "$candlex" "$root"; then
            if [ "$hops" -eq 1 ]; then
                echo "::error::unsafe symlink (escapes bundle): '$start' -> '$tgt' (leaves '$root' at '$candlex')" >&2
            else
                echo "::error::unsafe symlink (escapes bundle mid-chain): '$start' hop $hops -> '$tgt' (leaves '$root' at '$candlex')" >&2
            fi
            return 1
        fi

        # Continue if this hop lands on another symlink; stop when it lands on a real node.
        if [ -L "$candlex" ]; then
            cur="$candlex"
            continue
        fi
        if [ -e "$candlex" ]; then
            return 0   # chain stayed inside and ends at an existing in-bundle target
        fi
        echo "::error::unsafe symlink (dangling target): '$start' -> '$tgt' (no file at '$candlex')" >&2
        return 1
    done
}

# Scan a single bundle root. Returns 0 if clean, 1 if any unsafe symlink is found.
scan_bundle() {
    local bundle="$1"
    local root inspected=0 bad=0 link raw

    if [ ! -d "$bundle" ]; then
        echo "::error::$PROG: not a directory: $bundle" >&2
        return 1
    fi
    # Canonicalize the root ONCE (resolves /tmp -> /private/tmp and any symlinked prefix), and scan
    # from that absolute path so every symlink `find` reports is itself absolute.
    root="$(realpath "$bundle")"
    echo "auditing bundle: $bundle"

    # -print0 + read -d '' so names with spaces (e.g. "Electron Framework.framework") survive. The
    # loop runs in THIS shell (process substitution, not a pipe) so the counters persist.
    while IFS= read -r -d '' link; do
        inspected=$((inspected + 1))
        raw="$(readlink "$link")"

        # (1) absolute direct target : always illegal inside a bundle, reported explicitly.
        case "$raw" in
            /*)
                echo "::error::unsafe symlink (absolute target): '$link' -> '$raw'" >&2
                bad=$((bad + 1))
                continue
                ;;
        esac

        # (2)+(3) dangling / escapes-at-any-hop, via the per-hop chain walk.
        if ! check_symlink_chain "$link" "$root"; then
            bad=$((bad + 1))
            continue
        fi
    done < <(find "$root" -type l -print0)

    if [ "$bad" -gt 0 ]; then
        echo "FAIL: $bundle : $bad unsafe symlink(s) of $inspected inspected" >&2
        return 1
    fi
    echo "OK: $bundle : $inspected symlink(s) inspected, all relative and in-bundle"
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
            # The argument is itself an .app: scan it whole (covers nested .appex/.app/frameworks).
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
    echo "audit-bundle-symlinks: FAILED, one or more bundles contain unsafe symlinks" >&2
    exit 1
fi
echo "audit-bundle-symlinks: PASSED, ${#roots[@]} bundle(s) clean"
