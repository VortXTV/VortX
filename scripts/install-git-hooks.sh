#!/usr/bin/env bash
#
# Installs the pre-push engine leak guard into this repository's GIT COMMON DIRECTORY.
#
# Run by scripts/fetch-server-deps.sh, which the README documents as the first command
# after cloning, so a fresh clone is guarded without anyone having to be told. Safe and
# silent to re-run; it only prints when it changes something or finds a problem.
#
#   scripts/install-git-hooks.sh          install (idempotent)
#   scripts/install-git-hooks.sh --check  report status only, never write
#
# WHAT IS INSTALLED, AND WHERE
#   <common-dir>/hooks/pre-push                      copy of .githooks/pre-push
#   <common-dir>/scripts/scan-proprietary-engine.sh  copy of the tracked scanner
# The sibling relationship is load-bearing: .githooks/pre-push resolves the scanner as
# "$HOOK_DIR/../scripts/scan-proprietary-engine.sh", relative to the hook's OWN location.
#
# WHY THE COMMON DIRECTORY AND NOT core.hooksPath
# core.hooksPath was the previous design, and it was a scheduled failure. It has to name
# an absolute path, and every path available to name is a checkout that can go away:
#   * a throwaway worktree vanishes the day its branch merges, and this repository creates
#     worktrees by the dozen (121 today);
#   * the main checkout's .githooks/ leaves the disk the moment the main checkout is
#     switched to any branch that predates the guard, which is routine here because the
#     incident population is ~120 legacy rescue branches.
# When the configured path dangles, git does not warn. Every push from every worktree
# succeeds at exit 0 with no output, because the setting is shared across all of them.
# The common directory is git's own default lookup, so there is no configured value left
# that can dangle at all, and it survives branch switches, `git worktree add`, and
# `git worktree remove`.
#
# core.hooksPath IS THEREFORE NOW A BYPASS, NOT A CONFIGURATION
# Any value in any scope overrides the installed hook. This script deletes it on install
# and --check FAILS if it ever reappears, in exactly the same way it fails if the installed
# files drift from the tracked sources. Drift is this guard's failure mode; the check exists
# to make drift loud.
#
# WHAT THIS DOES NOT COVER
#   * a per-worktree config.worktree value in a worktree that never runs this script;
#   * `git push --no-verify` and `git -c core.hooksPath=/dev/null push`;
#   * a machine that pushes but never builds, so never runs fetch-server-deps.sh.
# Those are why .github/workflows/engine-leak-guard.yml exists as layer 2.

set -euo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_CHECKOUT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    echo "install-git-hooks: not inside a git repository" >&2
    exit 2
fi

TARGET_HOOK="$COMMON_DIR/hooks/pre-push"
TARGET_SCANNER="$COMMON_DIR/scripts/scan-proprietary-engine.sh"
SRC_HOOK="$SELF_CHECKOUT/.githooks/pre-push"
SRC_SCANNER="$SELF_CHECKOUT/scripts/scan-proprietary-engine.sh"

for src in "$SRC_HOOK" "$SRC_SCANNER"; do
    if [ ! -r "$src" ]; then
        echo "install-git-hooks: tracked source missing: $src" >&2
        echo "                   this checkout cannot install the guard." >&2
        exit 1
    fi
done

# The effective value across system, global, local, and worktree scope. Reported with its
# origin, because "it is set somewhere" is useless without saying where.
hooks_path_origins() { git config --show-origin --get-all core.hooksPath 2>/dev/null || true; }

# --- report-only ----------------------------------------------------------------------
if [ "$CHECK_ONLY" -eq 1 ]; then
    fail=0

    configured="$(hooks_path_origins)"
    if [ -n "$configured" ]; then
        echo "git hooks: core.hooksPath is SET, which overrides the installed hook." >&2
        printf '%s\n' "$configured" | sed 's/^/           /' >&2
        echo "           A value in any scope is a bypass, not a configuration. Remove it:" >&2
        echo "             git config --unset-all core.hooksPath" >&2
        fail=1
    fi

    for pair in "$SRC_HOOK|$TARGET_HOOK" "$SRC_SCANNER|$TARGET_SCANNER"; do
        src="${pair%%|*}"; dst="${pair##*|}"
        if [ ! -f "$dst" ]; then
            echo "git hooks: NOT installed, missing $dst" >&2
            fail=1
        elif [ ! -x "$dst" ]; then
            echo "git hooks: $dst is not executable, so git will not run it" >&2
            fail=1
        elif ! cmp -s "$src" "$dst"; then
            echo "git hooks: DRIFT, $dst differs from the tracked $src" >&2
            fail=1
        fi
    done

    if [ "$fail" -ne 0 ]; then
        echo "           run scripts/install-git-hooks.sh" >&2
        exit 1
    fi

    echo "git hooks: installed and current ($TARGET_HOOK)"
    exit 0
fi

# --- install --------------------------------------------------------------------------
changed=0

mkdir -p "$COMMON_DIR/hooks" "$COMMON_DIR/scripts"

install_file() { # <src> <dst>
    if ! cmp -s "$1" "$2"; then
        cp "$1" "$2"
        changed=1
    fi
    if [ ! -x "$2" ]; then
        chmod +x "$2"
        changed=1
    fi
}

install_file "$SRC_HOOK" "$TARGET_HOOK"
install_file "$SRC_SCANNER" "$TARGET_SCANNER"

# Delete the old pointer in both writable scopes. Shared scope covers every worktree at
# once; worktree scope covers this one, which is the only per-worktree scope reachable
# from here. `--worktree` fails when extensions.worktreeConfig is unset, which is fine.
if [ -n "$(git config --get-all core.hooksPath 2>/dev/null || true)" ]; then
    git config --unset-all core.hooksPath 2>/dev/null || true
    git config --worktree --unset-all core.hooksPath 2>/dev/null || true
    changed=1
fi

leftover="$(hooks_path_origins)"
if [ -n "$leftover" ]; then
    echo "install-git-hooks: core.hooksPath survives in a scope this script cannot write:" >&2
    printf '%s\n' "$leftover" | sed 's/^/                   /' >&2
    echo "                   It overrides the hook just installed. Remove it by hand." >&2
    exit 1
fi

if [ "$changed" -eq 1 ]; then
    echo "git hooks installed: $TARGET_HOOK"
    echo "  pre-push blocks proprietary engine source from reaching a public remote."
    echo "  core.hooksPath is unset on purpose; the common directory is git's default."
fi
