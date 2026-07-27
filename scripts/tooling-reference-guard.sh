#!/usr/bin/env bash
# Refuses to let tooling references reach the public repository.
#
# WHY THIS EXISTS. The project is published under a pseudonym and deliberately does not disclose the
# tooling used to build it. That held for commit authorship, which was always correct, but leaked
# repeatedly through everything around it: twenty-one tracked source and test files referencing the
# local instructions file by name, nine branch references inside a tracked planning document, two
# commit messages, and a gitignore comment. Each was caught by hand, one at a time, after the fact,
# and one reached the default branch and is public for good.
#
# Catching them by reading is not a control. This is the control.
#
# SCOPE, and why it is drawn here. Three things are checked because three things are published:
# tracked file CONTENT, the commit MESSAGES being pushed, and the REF NAMES being pushed. Author and
# committer identity are checked too, since a stray local git config is the other way this leaks.
#
# WHAT IS DELIBERATELY ALLOWED. The ignore rules and the Xcode exclude patterns must name what they
# exclude, and removing them would cause the leak rather than prevent it. They are allowlisted by
# exact path so the guard stays loud everywhere else.
set -uo pipefail

PATTERN='\bclaude\b|\bcodex\b|\banthropic\b|\bopenai\b|\bchatgpt\b|\bcopilot\b'
ALLOWED_PATHS='^(\.gitignore|app/project\.yml|scripts/tooling-reference-guard\.sh)$'
PATTERN_NOB='claude|codex|anthropic|openai|chatgpt|copilot'
FAIL=0

say() { printf '%s\n' "$*" >&2; }

# 1. Tracked file content. One `git grep` pass over the index, not a subprocess per file: the
#    per-file loop this replaced took over two minutes on this repo, and a guard nobody waits for is
#    a guard nobody runs.
# `git grep -E` does NOT support \b word boundaries; it silently matches nothing, which made the
# first version of this guard report clean against a deliberately planted violation. PCRE (-P) does
# support them, so the content scan uses -P and falls back to a boundary-free pattern if this git
# was built without PCRE. A guard that cannot fail its own negative test is worse than no guard.
if git grep -lIiP 'claude' -- . >/dev/null 2>&1 || [ $? -le 1 ]; then
    HITS="$(git grep -lIiP "$PATTERN" -- . 2>/dev/null | grep -vE "$ALLOWED_PATHS" || true)"
else
    HITS="$(git grep -lIiE "$PATTERN_NOB" -- . 2>/dev/null | grep -vE "$ALLOWED_PATHS" || true)"
fi
if [ -n "$HITS" ]; then
    say "TOOLING REFERENCE in tracked files:"
    printf '%s\n' "$HITS" | sed 's/^/    /' >&2
    FAIL=1
fi

# 2. Tracked paths. A filename leaks as readily as its contents.
PATHHITS="$(git ls-files 2>/dev/null | grep -iE "$PATTERN" || true)"
if [ -n "$PATHHITS" ]; then
    say "TOOLING REFERENCE in tracked paths:"
    printf '%s\n' "$PATHHITS" | sed 's/^/    /' >&2
    FAIL=1
fi

# 3. Commit messages and identities in the range being pushed. RANGE defaults to whatever is not yet
#    on origin, so a pre-push hook and a CI run both get the right answer without arguments.
RANGE="${1:-}"
if [ -z "$RANGE" ]; then
    UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    [ -n "$UPSTREAM" ] && RANGE="$UPSTREAM..HEAD"
fi
if [ -n "$RANGE" ]; then
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        if git log -1 --format='%B%n%an%n%ae%n%cn%n%ce' "$h" 2>/dev/null | grep -qiE "$PATTERN"; then
            say "TOOLING REFERENCE in commit: $(git log -1 --format='%h %s' "$h" 2>/dev/null)"
            FAIL=1
        fi
        if git log -1 --format='%B' "$h" 2>/dev/null | grep -qiE '^co-authored-by|generated with'; then
            say "ATTRIBUTION TRAILER in commit: $(git log -1 --format='%h %s' "$h" 2>/dev/null)"
            FAIL=1
        fi
    done < <(git log --format='%H' "$RANGE" 2>/dev/null)
fi

# 4. The ref name itself.
CURRENT="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
if printf '%s' "$CURRENT" | grep -qiE "$PATTERN"; then
    say "TOOLING REFERENCE in the branch name: $CURRENT"
    FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
    say ""
    say "Refusing to publish. Fix the references above, or add a deliberate exception to"
    say "ALLOWED_PATHS in scripts/tooling-reference-guard.sh with a comment saying why."
    exit 1
fi
echo "tooling-reference guard: clean"
