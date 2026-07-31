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
#   frameworks carry genuine relative symlinks, and against a real VortXTV/VortXMac build.
#
# FAIL-CLOSED TRAVERSAL (the whole point of a safety checker)
#   A checker that certifies a tree it could not fully read is worse than no checker: it grants
#   false confidence. So enumeration itself must be fail-closed. `find` output alone is not enough,
#   because `while read; do ...; done < <(find ...)` exposes the WHILE loop's exit status, not
#   find's; a subtree find could not enter is then silently invisible. Every traversal here runs
#   find with its output captured to a file and its exit status AND stderr inspected. If any of the
#   following holds, the audit refuses to certify and exits non-zero:
#     * find exits non-zero (unreadable subtree via permissions/ACL/ownership, a directory that
#       vanished mid-walk, ENAMETOOLONG on an over-long path, and similar);
#     * find wrote anything to stderr (a per-entry error that some builds report without a non-zero
#       exit);
#     * the NUL-delimited output is truncated (does not end in a NUL), which is how a producer that
#       died mid-write shows up.
#   A symlink LOOP does not threaten this walk: find is invoked without -L/-follow, so it never
#   descends through symlinks; link cycles are separately bounded by MAX_HOPS in the chain walk.
#   A link that vanishes between enumeration and inspection is also caught (re-checked per link).
#   Principle: I inspected EVERY link, or I fail. When in doubt, fail closed.
#
# USAGE
#   audit-bundle-symlinks.sh <path> [<path> ...]
#     <path> may be:
#       * a built *.app bundle                 (scanned in full, recursively)
#       * a directory containing *.app bundles (e.g. an IPA Payload/ or a CI out/ dir; each found
#                                               *.app is scanned)
#       * any other directory                  (scanned as-is, treated as a single bundle root)
#   Exit 0 if every inspected symlink is safe; non-zero (1) on the first bundle that contains an
#   unsafe symlink OR that could not be fully traversed, after listing the specific failure.
set -euo pipefail

PROG="$(basename "$0")"
MAX_HOPS=64   # cycle / excessive-depth guard for the chain walk

# Temp files used for fail-closed traversal capture; always removed at exit.
AUDIT_TMPFILES=()
cleanup_tmpfiles() {
    if [ "${#AUDIT_TMPFILES[@]}" -gt 0 ]; then
        rm -f "${AUDIT_TMPFILES[@]}" 2>/dev/null || true
    fi
}
trap cleanup_tmpfiles EXIT

die_usage() {
    echo "usage: $PROG <path-to-.app-or-dir> [<path> ...]" >&2
    exit 2
}

[ "$#" -ge 1 ] || die_usage

# Fail-closed directory traversal. Runs `find <find-args> -print0`, capturing NUL-delimited output
# and stderr. On COMPLETE traversal it sets the global REPLY_LIST to a temp file holding the output
# and returns 0. On ANY sign of incompleteness it prints the specific failure and returns 1.
safe_find() { # <label> <find-args...>
    local label="$1"; shift
    local out err rc
    out="$(mktemp)"; err="$(mktemp)"
    AUDIT_TMPFILES+=("$out" "$err")
    find "$@" -print0 >"$out" 2>"$err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "::error::traversal FAILED for '$label' (find exit $rc); refusing to certify an unread tree:" >&2
        sed 's/^/    /' "$err" >&2
        return 1
    fi
    if [ -s "$err" ]; then
        echo "::error::traversal for '$label' produced errors; refusing to certify an unread tree:" >&2
        sed 's/^/    /' "$err" >&2
        return 1
    fi
    if [ -s "$out" ] && [ "$(tail -c1 "$out" | od -An -tx1 | tr -d ' \n')" != "00" ]; then
        echo "::error::traversal output for '$label' is truncated (missing final NUL); refusing to certify" >&2
        return 1
    fi
    REPLY_LIST="$out"
    return 0
}

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

        if ! tgt="$(readlink "$cur" 2>/dev/null)"; then
            # The link (or a link mid-chain) vanished or became unreadable during inspection.
            echo "::error::unsafe symlink (unreadable mid-inspection): '$start' at '$cur'" >&2
            return 1
        fi
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

# Scan a single bundle root. Returns 0 if clean, 1 if any unsafe symlink is found OR the tree could
# not be fully traversed.
scan_bundle() {
    local bundle="$1"
    local root inspected=0 bad=0 link raw listfile

    if [ ! -d "$bundle" ]; then
        echo "::error::$PROG: not a directory: $bundle" >&2
        return 1
    fi
    # Canonicalize the root ONCE (resolves /tmp -> /private/tmp and any symlinked prefix), and scan
    # from that absolute path so every symlink `find` reports is itself absolute.
    root="$(realpath "$bundle")"
    echo "auditing bundle: $bundle"

    # Fail-closed enumeration: if find could not read the whole tree, we do NOT certify.
    if ! safe_find "$bundle" "$root" -type l; then
        echo "FAIL: $bundle : could not fully traverse; treated as unsafe" >&2
        return 1
    fi
    listfile="$REPLY_LIST"

    # read -d '' over the captured NUL-delimited file so names with spaces (e.g. "Electron
    # Framework.framework") survive. Reading from a real file keeps the loop in THIS shell.
    while IFS= read -r -d '' link; do
        inspected=$((inspected + 1))

        # Vanished-between-enumeration-and-inspection guard.
        if [ ! -L "$link" ]; then
            echo "::error::symlink vanished between enumeration and inspection: '$link'" >&2
            bad=$((bad + 1))
            continue
        fi
        if ! raw="$(readlink "$link" 2>/dev/null)"; then
            echo "::error::unreadable symlink during inspection: '$link'" >&2
            bad=$((bad + 1))
            continue
        fi

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
    done < "$listfile"

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
            # A container dir: audit every *.app under it. This discovery is ALSO fail-closed: an
            # unreadable subtree here could hide an entire .app from the audit, so a traversal
            # failure aborts rather than silently auditing fewer bundles.
            if ! safe_find "$arg (nested .app discovery)" "$arg" -type d -name '*.app'; then
                echo "::error::$PROG: cannot enumerate .app bundles under '$arg'; refusing to proceed" >&2
                exit 1
            fi
            found=()
            while IFS= read -r -d '' app; do
                found+=("$app")
            done < "$REPLY_LIST"
            if [ "${#found[@]}" -gt 0 ]; then
                roots+=("${found[@]}")
            else
                # No nested .app: audit the dir itself so the tool still works on an extracted
                # Payload or an arbitrary staging tree.
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
    echo "audit-bundle-symlinks: FAILED, one or more bundles are unsafe or could not be fully traversed" >&2
    exit 1
fi
echo "audit-bundle-symlinks: PASSED, ${#roots[@]} bundle(s) clean"
