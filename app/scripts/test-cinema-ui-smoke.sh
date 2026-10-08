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
  SourcesiOS/CinemaJSProviderSourceStub.swift \
  SourcesiOS/CinemaPinnedHTTPClientStub.swift \
  SourcesiOS/CinemaCommunityStreamGatewayStub.swift \
  SourcesiOS/VortXiOSApp.swift \
  SourcesShared/WatchedIndex.swift; do
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
  rg -Fq "$renderer_contract" SourcesiOS/CinemaUISmokeRendererApp.swift project.yml scripts/render-cinema-ui-smoke.sh SourcesiOS/VortXiOSApp.swift SourcesShared/WatchedIndex.swift
done

fixture_rail="$(sed -n '/struct CinemaFixturePosterRail/,/#endif/p' SourcesiOS/iOSRootView.swift)"
[[ "$fixture_rail" == *"PosterRailBody"* && "$fixture_rail" == *"watchedIDs: []"* ]] || {
  print -u2 'fixture rail must pass an inert watched set to the shared rail body'
  exit 1
}
[[ "$fixture_rail" != *"WatchedIndex.shared"* ]] || {
  print -u2 'fixture rail must not construct WatchedIndex.shared'
  exit 1
}
rg -Fq 'preconditionFailure("Cinema UI renderer must not construct WatchedIndex.shared")' SourcesShared/WatchedIndex.swift
rg -Fq 'usesInertArtwork: true' SourcesiOS/iOSRootView.swift

# `SourceIndexClient` names this optional source even though the fixture never supplies it. The renderer
# compiles a stub instead of the QuickJS runtime, so a compile-only dependency cannot construct its store,
# touch provider cache, or create a network-capable interpreter.
stub='SourcesiOS/CinemaJSProviderSourceStub.swift'
rg -Fq '#if CINEMA_UI_SMOKE_RENDERER' "$stub"
rg -Fq 'final class JSProviderSource' "$stub"
rg -Fq 'SourceContributorSettlement' "$stub"
rg -Fq 'preconditionFailure("Cinema UI renderer must not construct JSProviderSource")' "$stub"
rg -Fq 'preconditionFailure("Cinema UI renderer must not refresh JSProviderSource")' "$stub"
if sed '/^[[:space:]]*\/\//d' "$stub" | rg -n 'JSProviderStore|JSProviderRuntime|CommunityStreamGateway|URLSession|NWConnection' >/dev/null; then
  print -u2 'Cinema JS provider stub must remain inert'
  exit 1
fi

pinned_stub='SourcesiOS/CinemaPinnedHTTPClientStub.swift'
rg -Fq '#if CINEMA_UI_SMOKE_RENDERER' "$pinned_stub"
rg -Fq 'enum PinnedHTTPClient' "$pinned_stub"
rg -Fq 'preconditionFailure("Cinema UI renderer must not execute PinnedHTTPClient")' "$pinned_stub"
if sed '/^[[:space:]]*\/\//d' "$pinned_stub" | rg -n 'URLSession|NWConnection|Network|Security|socket' >/dev/null; then
  print -u2 'Cinema pinned HTTP stub must remain inert'
  exit 1
fi

gateway_stub='SourcesiOS/CinemaCommunityStreamGatewayStub.swift'
rg -Fq '#if CINEMA_UI_SMOKE_RENDERER' "$gateway_stub"
rg -Fq 'final class CommunityStreamGateway' "$gateway_stub"
rg -Fq 'preconditionFailure("Cinema UI renderer must not resolve CommunityStreamGateway")' "$gateway_stub"
rg -Fq 'preconditionFailure("Cinema UI renderer must not register CommunityStreamGateway")' "$gateway_stub"
if sed '/^[[:space:]]*\/\//d' "$gateway_stub" | rg -n 'URLSession|NWConnection|Network|Security|socket|start\(' >/dev/null; then
  print -u2 'Cinema community gateway stub must remain inert'
  exit 1
fi

print 'ok: Cinema smoke harness is parseable, offline, and wired to production presentation components'
