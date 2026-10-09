#!/usr/bin/env bash
# Sourced by artifact builders. Resolve the private native workspace without a home-directory
# checkout or a copied public-repository snapshot. Explicit CI checkouts remain supported.
resolve_native_engine() { # <app-repo> <required-crate>
    local app_repo="$1" required_crate="$2" candidate canonical_app common engine_path
    local candidates=()
    if [[ -n "${VORTX_ENGINE_DIR:-}" ]]; then
        candidates=("$VORTX_ENGINE_DIR")
    else
        candidates=("$app_repo/vortx-core" "$app_repo/../vortx-core/vortx-core")
        # A registered app worktree shares the canonical repository's .git. Discover its sibling
        # engine instead of assuming the worktree's parent directory contains another checkout.
        if common=$(git -C "$app_repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
            canonical_app=$(cd "$common/.." && pwd -P)
            candidates+=("$canonical_app/../vortx-core/vortx-core")
        fi
    fi
    for candidate in "${candidates[@]}"; do
        [[ -f "$candidate/Cargo.toml" && -f "$candidate/crates/$required_crate/Cargo.toml" ]] || continue
        engine_path=$(cd "$candidate" && pwd -P)
        if [[ "$app_repo" == /Users/daksh/VortXTV/* && "$engine_path" != /Users/daksh/VortXTV/* ]]; then
            echo "ERROR: native engine workspace escapes /Users/daksh/VortXTV: $engine_path" >&2
            return 1
        fi
        printf '%s\n' "$engine_path"
        return 0
    done
    echo "ERROR: no native workspace with crates/$required_crate/Cargo.toml; set VORTX_ENGINE_DIR to the existing private vortx-core/vortx-core workspace." >&2
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    resolve_native_engine "${1:?app repository required}" "${2:?crate required}"
fi
