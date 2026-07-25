#!/usr/bin/env bash
#
# Points this clone's git hooks at the tracked .githooks/ directory.
#
# Run by scripts/fetch-server-deps.sh, which the README documents as the first command
# after cloning, so a fresh clone is guarded without anyone having to be told. Safe and
# silent to re-run; it only prints when it changes something or finds a problem.
#
#   scripts/install-git-hooks.sh          install (idempotent)
#   scripts/install-git-hooks.sh --check  report status only, never write
#
# WHY core.hooksPath AND NOT .git/hooks/
# 1. .git/hooks/ is untracked, so a copied-in hook silently rots as the guard evolves and
#    is absent in every fresh clone. A tracked directory ships with the code.
# 2. core.hooksPath lives in the shared config, so all ~120 VortX worktrees inherit it
#    from one install instead of needing 120 copies.
#
# WHY AN ABSOLUTE PATH
# git resolves a relative core.hooksPath against the working tree of whichever worktree is
# pushing. A branch created before the guard existed has no .githooks/ checked out, so a
# relative path would leave exactly the old rescue branches that caused the incident
# unguarded. An absolute path into one current checkout guards every branch, including
# branches that predate the guard.

set -euo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_CHECKOUT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Prefer the main worktree: it outlives the throwaway worktrees this repo creates by the
# dozen, and a hooksPath pointing into a deleted worktree fails silently, which is the one
# outcome this guard must never have.
MAIN_CHECKOUT=""
if common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    candidate="$(dirname "$common_dir")"
    [ -x "$candidate/.githooks/pre-push" ] && MAIN_CHECKOUT="$candidate"
fi

HOOKS_DIR="${MAIN_CHECKOUT:-$SELF_CHECKOUT}/.githooks"

if [ ! -x "$HOOKS_DIR/pre-push" ]; then
    echo "install-git-hooks: no executable pre-push at $HOOKS_DIR" >&2
    exit 1
fi

CURRENT="$(git config --get core.hooksPath 2>/dev/null || true)"

if [ "$CURRENT" = "$HOOKS_DIR" ]; then
    [ "$CHECK_ONLY" -eq 1 ] && echo "git hooks: installed ($HOOKS_DIR)"
    exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "git hooks: NOT installed (core.hooksPath='${CURRENT:-unset}', expected '$HOOKS_DIR')" >&2
    echo "           run scripts/install-git-hooks.sh" >&2
    exit 1
fi

git config core.hooksPath "$HOOKS_DIR"
echo "git hooks installed: core.hooksPath -> $HOOKS_DIR"
echo "  pre-push blocks proprietary engine source from reaching a public remote."
