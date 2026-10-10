#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

xcrun swiftc -frontend -parse app/SourcesiOS/iOSDetailView.swift
xcrun swiftc -frontend -parse app/SourcesiOS/FeaturedHeroView.swift

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/vortx-cinematic-backdrop.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

xcrun swiftc -parse-as-library -warnings-as-errors \
  app/SourcesShared/PosterImageLoader.swift \
  app/SourcesShared/HeroArtworkQualityPolicy.swift \
  app/Tests/CinematicBackdropImageTests.swift \
  -framework SwiftUI -framework AppKit -framework ImageIO -framework CoreGraphics \
  -o "$build_dir/cinematic-backdrop-tests"
"$build_dir/cinematic-backdrop-tests"

print 'ok: cinematic backdrop source and bounded ImageIO/cache checks passed'
