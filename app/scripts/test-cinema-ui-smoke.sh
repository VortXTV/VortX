#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

for source in \
  SourcesiOS/CinemaPresentation.swift \
  SourcesiOS/iOSRootView.swift \
  SourcesiOS/iOSDetailView.swift \
  SourcesiOS/CinemaUISmokeHarness.swift; do
  swiftc -parse "$source"
done

for needle in \
  'CinemaFixturePosterRail' \
  'CinemaSearchResults' \
  'CinemaEpisodeRailCard' \
  'iOSStreamLabel' \
  'disablesArtworkLoading = true' \
  'disablesArtworkLoading = false' \
  '#Preview("Cinema UI Smoke · offline")' \
  'Color.clear.frame(height: 72)'; do
  rg -Fq "$needle" SourcesiOS/CinemaUISmokeHarness.swift SourcesiOS/iOSRootView.swift SourcesiOS/iOSDetailView.swift SourcesiOS/CinemaPresentation.swift
done

if rg -n 'CoreBridge|StremioAccount|PlayerScreen|iOSDetailView\(' SourcesiOS/CinemaUISmokeHarness.swift >/dev/null; then
  print -u2 'smoke harness must not boot production lifecycle owners'
  exit 1
fi

print 'ok: Cinema smoke harness is parseable, offline, and wired to production presentation components'
