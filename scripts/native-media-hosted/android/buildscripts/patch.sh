#!/bin/bash
set -euo pipefail
shopt -s nullglob

PATCHES=(patches/*)
ROOT=$(pwd -P)

for dep_path in "${PATCHES[@]}"; do
    if [ -d "$dep_path" ]; then
        [ ! -L "$dep_path" ] || { echo 'Refusing symlinked patch directory' >&2; exit 1; }
        patches=("$dep_path"/*)
        dep=${dep_path##*/}
        cd -P "deps/$dep"
        [ "$(git rev-parse --show-toplevel)" = "$ROOT/deps/$dep" ] || {
            echo "Refusing a foreign dependency tree: $dep" >&2; exit 1;
        }
        echo "Patching $dep"
        for patch in "${patches[@]}"; do
            [ -f "$ROOT/$patch" ] && [ ! -L "$ROOT/$patch" ] || exit 1
            if git apply --check "$ROOT/$patch"; then
                git apply "$ROOT/$patch"
            elif git apply --reverse --check "$ROOT/$patch"; then
                echo "Already applied: $patch"
            else
                echo "Patch conflicts with retained source; no reset performed: $patch" >&2
                exit 1
            fi
        done
        cd "$ROOT"
    fi
done

exit 0
