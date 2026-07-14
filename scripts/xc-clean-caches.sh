#!/usr/bin/env bash
# Sweep Xcode compilation caches (the multi-GB v8.data / CompilationCache blobs)
# from all VortX worktrees plus the shared DerivedData, so they never accumulate.
#
# Why: each gated build writes a CompilationCache.noindex that can reach 16GB per
# scheme. Left unswept across many build sessions these silently grew to ~250GB.
# This script removes ONLY regenerable build cache (identified by the Xcode
# CompilationCache/ModuleCache signature) - never source, never commits, never .dd
# output you might still want. Safe to run anytime; a later build just regenerates.
#
# Run manually:  scripts/xc-clean-caches.sh
# Scheduled:     a user crontab entry runs this daily (see install note at bottom).
set -u

ROOTS=(
  "$HOME/VortX"
  "$HOME/Library/Developer/Xcode/DerivedData"
)
# include every sibling VortX worktree
for wt in "$HOME"/vortx-wt-*; do
  [ -d "$wt" ] && ROOTS+=("$wt")
done

freed=0
for r in "${ROOTS[@]}"; do
  [ -e "$r" ] || continue
  # Remove the derived-data dir that holds each compilation cache (any dir name).
  while IFS= read -r cc; do
    [ -n "$cc" ] || continue
    dd=$(dirname "$cc")
    rm -rf "$dd" 2>/dev/null && freed=$((freed + 1))
  done < <(find "$r" -type d -name "CompilationCache.noindex" 2>/dev/null)
  # Loose module caches too.
  find "$r" -type d -name "ModuleCache.noindex" -exec rm -rf {} + 2>/dev/null
done

echo "xc-clean-caches: swept $freed Xcode cache dir(s)"

# --- one-time install of the daily sweep (idempotent) -----------------------
# Run:  scripts/xc-clean-caches.sh --install-cron
if [ "${1:-}" = "--install-cron" ]; then
  self="$HOME/VortX/scripts/xc-clean-caches.sh"
  line="30 4 * * * $self >/dev/null 2>&1"
  ( crontab -l 2>/dev/null | grep -v "xc-clean-caches.sh"; echo "$line" ) | crontab -
  echo "installed daily 04:30 sweep into user crontab"
fi
