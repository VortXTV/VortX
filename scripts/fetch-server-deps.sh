#!/usr/bin/env bash
# Fetches the gitignored subtitle fallback fonts the apps bundle and installs the git hooks.
# Run once after cloning. (The name is historical: the streaming server is now the VortX
# engine's, built from the engine checkout by scripts/build-ffi-xcframework.sh and
# scripts/build-mac-server.sh.)
set -euo pipefail
cd "$(dirname "$0")/.."

# --- git hooks -------------------------------------------------------------------------
# Installed here because the README documents this script as the first command after
# cloning, so the pre-push engine leak guard is live before anyone can push. Idempotent
# and silent once installed. Non-fatal on failure (a source export is not a git clone),
# but loud, because an uninstalled guard is an unguarded clone.
#
# The install now also enforces hygiene, not just presence: it deletes core.hooksPath in
# every scope it can write (any value there overrides the installed hook, so it is a bypass)
# and it refuses to report success if the installed hook or scanner has drifted from the
# tracked sources. So a failure here can mean "not installed" OR "installed but tampered
# with" OR "overridden by config", and all three leave this clone unguarded.
if ! ./scripts/install-git-hooks.sh; then
    echo "WARNING: could not install the git hooks, or the installed guard failed its" >&2
    echo "         config-scope and content checks. This clone has NO reliable protection" >&2
    echo "         against pushing proprietary engine source to a public remote." >&2
fi

# Pinned SHA256 for everything downloaded below. The fonts ship inside the apps, so
# verify them instead of trusting the transport. When replacing a vendor asset,
# recompute the matching hash (shasum -a 256 <file>).
FONTS_SHA256="11de005861655d43e53979325cdca3172951f93af566b6fc6778e6897dd53dbb"

verify_sha256() { # <file> <expected-hash> <label>
    local actual
    actual="$(shasum -a 256 "$1" | cut -d' ' -f1)"
    if [ "$actual" != "$2" ]; then
        echo "ERROR: $3 checksum mismatch" >&2
        echo "  expected: $2" >&2
        echo "  actual:   $actual" >&2
        rm -f "$1"
        exit 1
    fi
}

# --- symlink hygiene -------------------------------------------------------
# A symlink `app/Resources/fonts/fonts -> /Users/daksh/vortx/app/Resources/fonts`
# (absolute, pointing back at its own parent through the case-insensitive vortx/VortX
# alias) once got copied into every Release bundle. The exact creating invocation is not
# preserved, so this fix targets the unsafe PATTERN, not a specific command: a link-creating
# step that does not prove its destination absent first (the archetype is `ln -s <src> <dest>`
# while <dest> already exists as a directory) drops a NESTED `<dest>/<basename>` link inside
# that directory instead of replacing it.
#
# assert_no_symlinks_under() is the fail-closed gate that enforces the invariant "the fetched
# tree leaves NO symlink under app/Resources/". Nothing there is legitimately a symlink:
# fonts/ holds real .ttf/.otf files, and shaders/ + streaming-logos/ are real folders. Detection and remediation
# are deliberately kept separate: this gate DETECTS and FAILS; it does not delete. A gate that
# silently scrubbed would hide recurrence and could not prove the class is actually gone, so a
# stray link stops the fetch and names itself for a human to remove.
assert_no_symlinks_under() { # <dir> ; lists any symlink under <dir> and returns non-zero, no delete
    local dir="$1" found count=0
    [ -d "$dir" ] || return 0
    while IFS= read -r -d '' found; do
        echo "ERROR: unexpected symlink under $dir: '$found' -> '$(readlink "$found")'" >&2
        count=$((count + 1))
    done < <(find "$dir" -type l -print0)
    if [ "$count" -gt 0 ]; then
        echo "ERROR: $count symlink(s) under $dir; refusing to proceed (remove them and re-run)" >&2
        return 1
    fi
    return 0
}

# Subtitle fallback fonts (Noto Sans family, OFL 1.1) so mpv renders
#    non-Latin subtitles. Too big for git, hosted on the same vendor release.
#    v2 trims the CJK face to its practically-used coverage (BMP scripts, no
#    rare plane-2 ideographs or vertical/regional variant glyphs): 7.6 MB
#    instead of 16 MB, identical rendering for real-world subtitles.
FONTS_DIR="app/Resources/fonts"
if [ -z "$(ls "$FONTS_DIR"/*.ttf "$FONTS_DIR"/*.otf 2>/dev/null)" ]; then
    echo "Fetching subtitle fallback fonts..."
    mkdir -p "$FONTS_DIR"
    curl -sfL "https://github.com/VortXTV/VortX/releases/download/vendor-1/StremioX-subtitle-fonts-v2.zip" -o /tmp/vortx-fonts.zip
    verify_sha256 /tmp/vortx-fonts.zip "$FONTS_SHA256" "subtitle fonts"
    unzip -qo /tmp/vortx-fonts.zip -d "$FONTS_DIR"
else
    echo "Subtitle fonts already present."
fi
# The pinned font archive contains six regular font files and zero symlink entries; assert that here
# so a nested fonts/fonts left by any earlier run stops the fetch loudly instead of riding into a build.
assert_no_symlinks_under "$FONTS_DIR"

echo "Done. Fonts ready. Next: scripts/build-ffi-xcframework.sh (and scripts/build-mac-server.sh for"
echo "the Mac app) with the engine checkout, then 'xcodegen generate' in app/."

# Final fail-closed gate: the fetched tree must leave NO symlink under app/Resources/. This is the
# durable fix for the shipped fonts/fonts defect. Every path that populates app/Resources/ has run
# by now, so any symlink here would otherwise ride into the bundle via the fonts folder resource rule.
assert_no_symlinks_under app/Resources
echo "Verified: no symlinks under app/Resources/."
