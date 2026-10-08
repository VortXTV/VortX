#!/bin/zsh
set -euo pipefail

# Builds and screenshots an entirely separate iOS fixture bundle. It never launches the installed VortX
# app. Each simulator is created by this script with an exact generated UUID, recorded below, and deleted
# only after every requested screenshot is written successfully. A failed run leaves the exact UUID receipt
# intact for an explicit, recoverable retry; it never performs broad simulator cleanup.
root="${0:A:h:h}"
spec="$root/CinemaUISmokeIOSRenderer.yml"
project="$root/CinemaUISmokeIOSRenderer.xcodeproj"
derived="${CINEMA_UI_SMOKE_IOS_DERIVED_DATA:-$root/build/cinema-ui-smoke-ios-derived}"
output="${CINEMA_UI_SMOKE_IOS_OUTPUT:-$root/build/cinema-ui-smoke-ios-png}"
receipt="$output/simulators.tsv"
runtime='com.apple.CoreSimulator.SimRuntime.iOS-26-5'
bundle='com.stremiox.cinema-ui-smoke.ios'

command -v xcodegen >/dev/null || { print -u2 'xcodegen is required'; exit 1; }
command -v xcrun >/dev/null || { print -u2 'xcrun is required'; exit 1; }
mkdir -p "$output"
print -r -- $'uuid\tname\tbundle' > "$receipt"

create_owned_simulator() {
  local name="$1"
  local type="$2"
  local uuid
  uuid="$(xcrun simctl create "$name" "$type" "$runtime")"
  print -r -- "$uuid" | /usr/bin/grep -Eq '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$' || {
    print -u2 "unexpected simulator UUID: $uuid"
    exit 1
  }
  print -r -- "$uuid\t$name\t$bundle" >> "$receipt"
  print "$uuid"
}

phone_uuid="$(create_owned_simulator 'Cinema UI Smoke iPhone 16 Pro' 'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro')"
ipad_uuid="$(create_owned_simulator 'Cinema UI Smoke iPad Pro 13 M5' 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB')"
created=("$phone_uuid" "$ipad_uuid")
completed=false

cleanup() {
  local uuid
  for uuid in "${created[@]}"; do
    xcrun simctl terminate "$uuid" "$bundle" >/dev/null 2>&1 || true
    xcrun simctl shutdown "$uuid" >/dev/null 2>&1 || true
    if $completed; then
      xcrun simctl delete "$uuid"
    fi
  done
}
trap cleanup EXIT

xcodegen generate --spec "$spec" --project "$root"
xcodebuild \
  -jobs 1 \
  -arch arm64 \
  -sdk iphonesimulator \
  -project "$project" \
  -scheme CinemaUISmokeIOSRenderer \
  -configuration Debug \
  -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  SWIFT_COMPILATION_MODE=singlefile \
  build

renderer="$derived/Build/Products/Debug-iphonesimulator/CinemaUISmokeIOSRenderer.app"
[[ -d "$renderer" ]] || { print -u2 "renderer bundle missing: $renderer"; exit 1; }

render_device() {
  local kind="$1"
  local uuid="$2"
  local surface
  xcrun simctl boot "$uuid"
  xcrun simctl bootstatus "$uuid" -b
  xcrun simctl install "$uuid" "$renderer"
  for surface in home search quickView episodeSources; do
    SIMCTL_CHILD_CINEMA_UI_SMOKE_SURFACE="$surface" \
      xcrun simctl launch --terminate-running-process "$uuid" "$bundle" >/dev/null
    # Allow the fixture scene and, for Quick View, the real SwiftUI sheet presentation to settle.
    sleep 1
    xcrun simctl io "$uuid" screenshot "$output/cinema-ios-$kind-$surface.png"
    [[ -s "$output/cinema-ios-$kind-$surface.png" ]] || { print -u2 "missing native screenshot: $kind/$surface"; exit 1; }
  done
}

render_device phone "$phone_uuid"
render_device ipad "$ipad_uuid"
completed=true
print "ok: native Cinema UI screenshots written to $output; owned simulator UUIDs recorded in $receipt"
