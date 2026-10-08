#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

for source in \
  SourcesiOS/CinemaPresentation.swift \
  SourcesiOS/iOSRootView.swift \
  SourcesiOS/iOSDetailView.swift \
  SourcesiOS/CinemaUISmokeHarness.swift \
  SourcesiOS/CinemaUISmokeRendererApp.swift \
  SourcesiOS/VortXiOSApp.swift; do
  swiftc -parse "$source"
done

for needle in \
  'CinemaFixturePosterRail' \
  'CinemaSearchResults' \
  'CinemaEpisodeRailCard' \
  'iOSStreamLabel' \
  'cinemaFixtureDisablesArtworkLoading, true' \
  'CinemaTabBarChrome' \
  '.safeAreaInset(edge: .bottom' \
  '#Preview("Cinema UI Smoke · offline")' \
  'CinemaCompactTabLabel'; do
  rg -Fq "$needle" SourcesiOS/CinemaUISmokeHarness.swift SourcesiOS/iOSRootView.swift SourcesiOS/iOSDetailView.swift SourcesiOS/CinemaPresentation.swift
done

if rg -n 'CoreBridge|StremioAccount|PlayerScreen|iOSDetailView\(' SourcesiOS/CinemaUISmokeHarness.swift >/dev/null; then
  print -u2 'smoke harness must not boot production lifecycle owners'
  exit 1
fi

for renderer_contract in \
  'CINEMA_UI_SMOKE_RENDERER' \
  'NSHostingView(rootView: root)' \
  'CINEMA_UI_SMOKE_OUTPUT' \
  'CinemaUISmokeRenderer:' \
  'PRODUCT_BUNDLE_IDENTIFIER: com.stremiox.cinema-ui-smoke' \
  'xcodebuild' \
  'cinema-phone.png' \
  'cinema-tablet.png' \
  'cinema-mac.png'; do
  rg -Fq "$renderer_contract" SourcesiOS/CinemaUISmokeRendererApp.swift project.yml scripts/render-cinema-ui-smoke.sh SourcesiOS/VortXiOSApp.swift
done

print 'ok: Cinema smoke harness is parseable, offline, and wired to production presentation components'
