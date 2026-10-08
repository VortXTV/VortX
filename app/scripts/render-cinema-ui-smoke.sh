#!/bin/zsh
set -euo pipefail

# Deliberately not run by the source-contract test. This compiles the isolated macOS diagnostic target,
# which still links the same private MPV/Core frameworks as the native app. Run only after the active MPV
# rebuild window is clear; it does not launch the installed VortX application or any account/player flow.
root="${0:A:h:h}"
project="$root/VortX.xcodeproj"
derived="${CINEMA_UI_SMOKE_DERIVED_DATA:-$root/build/cinema-ui-smoke-derived}"
output="${CINEMA_UI_SMOKE_OUTPUT:-$root/build/cinema-ui-smoke-png}"

command -v xcodegen >/dev/null || { print -u2 'xcodegen is required'; exit 1; }
xcodegen generate --spec "$root/project.yml" --project "$project"

xcodebuild \
  -jobs 1 \
  -arch arm64 \
  -project "$project" \
  -scheme CinemaUISmokeRenderer \
  -configuration Debug \
  -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  SWIFT_COMPILATION_MODE=singlefile \
  build

renderer="$derived/Build/Products/Debug/CinemaUISmokeRenderer.app/Contents/MacOS/CinemaUISmokeRenderer"
[[ -x "$renderer" ]] || { print -u2 "renderer missing: $renderer"; exit 1; }
mkdir -p "$output"
CINEMA_UI_SMOKE_OUTPUT="$output" "$renderer"
for screenshot in "$output"/cinema-phone.png "$output"/cinema-tablet.png "$output"/cinema-mac.png; do
  [[ -s "$screenshot" ]] || { print -u2 "missing screenshot: $screenshot"; exit 1; }
done
print "ok: Cinema UI screenshots written to $output"
