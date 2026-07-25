#!/usr/bin/env bash
#
# The ONE definition of "this commit carries proprietary VortX engine source".
#
# Shared deliberately by both guard layers so they can never drift apart:
#   .githooks/pre-push                        (local, blocks the push)
#   .github/workflows/engine-leak-guard.yml   (remote, alarms on what got through)
#
# WHY THIS EXISTS
# On 2026-07-25 a lane pushed ~90 tags to the public repo; 56 of them pointed at commits
# carrying the closed vortx-core/ tree. An earlier lane had correctly refused the same
# material. The difference was not competence, it was that the rule lived in a human
# briefing instead of in the tooling. Everything here is therefore designed to fire for
# an operator who has never heard of the rule.
#
# THE RULE IS CONTENT, NOT NAMES
# Nothing below looks at a branch or tag name. Names are exactly what failed: the refs
# that leaked were named like ordinary rescue branches. Every probe reads the actual tree
# of the actual commit being pushed.
#
# USAGE
#   scan-proprietary-engine.sh paths <commit-ish>...   # probe those commits
#   scan-proprietary-engine.sh paths -                 # commit-ish list on stdin
#   scan-proprietary-engine.sh markers <commit-ish>    # content-marker sweep of one tree
#
# OUTPUT  one violation per line, on stdout:
#   PATH    <commit> <top-level-path>
#   MARKER  <commit> <file>
#
# EXIT    0 clean   1 violations found   2 internal error (callers MUST treat as unsafe)

set -uo pipefail

# --- the rule -------------------------------------------------------------------------
#
# 1. PROPRIETARY_PATHS. Top-level tree entries that ARE the closed engine. This is the
#    load-bearing probe: it is a single tree-entry lookup per commit per path, so it costs
#    effectively nothing no matter how large the engine gets, and it cannot be fooled by
#    renaming a branch. Add a new entry here the day a new closed tree is created.
PROPRIETARY_PATHS="vortx-core stremiox-core"

# 2. Content markers. The safety net for the case the path probe cannot see: the engine
#    moved, was renamed, or was vendored under some other directory. Any file declaring
#    the proprietary SPDX license ref or carrying the closed-source header trips the guard
#    wherever it sits in the tree.
#
#    The literals are assembled from fragments on purpose. Spelled out whole, THIS file
#    would match its own scan and the guard would flag itself on every push.
MARKER_SPDX="LicenseRef-VortX""-Proprietary"
MARKER_HEADER="VortX-Proprietary:"" CLOSED SOURCE"

die() { printf 'scan-proprietary-engine: %s\n' "$*" >&2; exit 2; }

# Probe a list of commit-ish (stdin, one per line) for the proprietary top-level paths.
#
# One `git cat-file --batch-check` process handles the entire list, so the cost is one
# process spawn plus an O(1) tree-entry lookup per commit per path. Measured on the VortX
# repo: 1703 commits x 2 paths in 0.22s. Cheap enough that nobody is tempted to skip it,
# which was an explicit design constraint: a guard people route around protects nothing.
probe_paths() {
    local commits path commit rc
    commits="$(cat)"
    [ -n "$commits" ] || return 0

    # `--batch-check='%(objecttype) %(rest)'` prints "tree <label>" when the path resolves
    # and "<input> missing" when it does not, so a leading "tree"/"blob" is a hit and the
    # label carries the commit and path back out.
    {
        for path in $PROPRIETARY_PATHS; do
            printf '%s\n' "$commits" | while IFS= read -r commit; do
                [ -n "$commit" ] || continue
                printf '%s:%s %s %s\n' "$commit" "$path" "$commit" "$path"
            done
        done
    } | git cat-file --batch-check='%(objecttype) %(rest)' 2>/dev/null \
      | awk '$1 == "tree" || $1 == "blob" { print "PATH   ", $2, $3 }'

    rc=${PIPESTATUS[1]:-0}
    [ "$rc" -le 1 ] || die "git cat-file failed (rc=$rc)"
}

# Sweep one tree for the content markers.
#
# Deliberately scoped to a single tree rather than to every commit in the push: a marker
# sweep reads blob contents, which is orders of magnitude more work than a tree-entry
# lookup, and a renamed or relocated engine is visible at the tip by definition. Measured
# on the VortX repo: 0.17s for the whole tree.
probe_markers() {
    local commit="$1" rc out
    out="$(git grep -l -F -e "$MARKER_SPDX" -e "$MARKER_HEADER" "$commit" -- . 2>/dev/null)"
    rc=$?
    case "$rc" in
        0) printf '%s\n' "$out" | sed 's/^\([^:]*\):/MARKER  \1 /' ;;
        1) : ;;                       # git grep: no matches, tree is clean
        *) die "git grep failed on $commit (rc=$rc)" ;;
    esac
}

mode="${1:-}"
shift 2>/dev/null || true

# Every probe runs in a command substitution, so a `die` inside one exits the SUBSHELL,
# not this script. Capturing the status and re-raising it is what keeps an internal error
# from being read as "clean" -- silently passing on a broken probe is the one failure this
# whole file exists to prevent.
violations=""
rc=0
case "$mode" in
    paths)
        [ $# -gt 0 ] || die "usage: $0 paths <commit-ish>... | -"
        if [ "$1" = "-" ]; then
            violations="$(probe_paths)"; rc=$?
        else
            violations="$(printf '%s\n' "$@" | probe_paths)"; rc=$?
        fi
        ;;
    markers)
        [ $# -eq 1 ] || die "usage: $0 markers <commit-ish>"
        violations="$(probe_markers "$1")"; rc=$?
        ;;
    *)
        die "usage: $0 {paths|markers} ..."
        ;;
esac
[ "$rc" -eq 0 ] || exit 2

[ -n "$violations" ] || exit 0
printf '%s\n' "$violations"
exit 1
