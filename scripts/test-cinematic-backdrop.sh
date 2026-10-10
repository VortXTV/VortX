#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

xcrun swiftc -frontend -parse app/SourcesiOS/iOSDetailView.swift
xcrun swiftc -frontend -parse app/SourcesiOS/FeaturedHeroView.swift

build_dir="$root/app/build/cinematic-backdrop"
mkdir -p "$build_dir"

kenburns_source="$build_dir/FeaturedHeroKenBurnsLoader.swift"
{
  print -r -- 'import Foundation'
  print -r -- 'import QuartzCore'
  print -r -- '#if canImport(AppKit)'
  print -r -- 'import AppKit'
  print -r -- '#elseif canImport(UIKit)'
  print -r -- 'import UIKit'
  print -r -- '#endif'
  sed -n '/^\/\/ MARK: - Testable Ken Burns artwork loader$/,/^\/\/ The layer-hosting view:/ { /^\/\/ The layer-hosting view:/!p; }' \
    app/SourcesiOS/FeaturedHeroView.swift
} > "$kenburns_source"

xcrun swiftc -parse-as-library -warnings-as-errors \
  "$kenburns_source" \
  app/SourcesShared/PosterImageLoader.swift \
  app/SourcesShared/HeroArtworkQualityPolicy.swift \
  app/Tests/CinematicBackdropImageTests.swift \
  -framework SwiftUI -framework AppKit -framework QuartzCore -framework ImageIO -framework CoreGraphics \
  -o "$build_dir/cinematic-backdrop-tests"
"$build_dir/cinematic-backdrop-tests"

print 'ok: cinematic backdrop source and bounded ImageIO/cache checks passed'
