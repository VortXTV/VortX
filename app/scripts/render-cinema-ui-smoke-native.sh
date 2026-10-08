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
completed_receipt="$output/simulators.completed.$$.tsv"
runtime='com.apple.CoreSimulator.SimRuntime.iOS-26-5'
bundle='com.stremiox.cinema-ui-smoke.ios'

command -v xcodegen >/dev/null || { print -u2 'xcodegen is required'; exit 1; }
command -v xcrun >/dev/null || { print -u2 'xcrun is required'; exit 1; }
mkdir -p "$output"

# A failed prior run retains the IDs it created. Refuse to overwrite that recovery receipt: a human can
# inspect or explicitly remove only those IDs, while a later renderer invocation cannot mistake them for
# fresh ownership.
[[ ! -e "$receipt" ]] || {
  print -u2 "native Cinema simulator receipt already exists; preserve or recover its exact UUIDs first: $receipt"
  exit 1
}
printf 'uuid\tname\tbundle\n' > "$receipt"

created=()
completed=false

is_uuid() {
  print -r -- "$1" | /usr/bin/grep -Eq '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'
}

cleanup() {
  local uuid
  for uuid in "${created[@]}"; do
    # Never aim simctl at arbitrary command output. Invalid data remains in the preserved receipt for
    # diagnosis, but cannot become a cleanup target.
    is_uuid "$uuid" || continue
    xcrun simctl terminate "$uuid" "$bundle" >/dev/null 2>&1 || true
    xcrun simctl shutdown "$uuid" >/dev/null 2>&1 || true
    if $completed; then
      xcrun simctl delete "$uuid"
    fi
  done
}
trap cleanup EXIT

create_owned_simulator() {
  local name="$1"
  local type="$2"
  local uuid
  if ! uuid="$(xcrun simctl create "$name" "$type" "$runtime")"; then
    print -u2 "could not create native Cinema simulator: $name"
    return 1
  fi
  # Record the exact command result before validation and before the next create. If a later command
  # fails, this is the recovery source of truth rather than a truncated/empty receipt.
  printf '%s\t%s\t%s\n' "$uuid" "$name" "$bundle" >> "$receipt"
  created+=("$uuid")
  is_uuid "$uuid" || {
    print -u2 "unexpected simulator UUID: $uuid"
    return 1
  }
  CREATED_UUID="$uuid"
}

create_or_preserve() {
  if ! create_owned_simulator "$1" "$2"; then
    # `set -e` can skip EXIT cleanup for a failed assignment in some shells. Invoke the same exact-ID
    # cleanup explicitly before exiting so the first successful create is always shut down and retained
    # in its receipt; remove the trap to avoid a duplicate cleanup pass.
    cleanup
    trap - EXIT
    exit 1
  fi
}

create_or_preserve 'Cinema UI Smoke iPhone 16 Pro' 'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro'
phone_uuid="$CREATED_UUID"
create_or_preserve 'Cinema UI Smoke iPad Pro 13 M5' 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB'
ipad_uuid="$CREATED_UUID"

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
# Complete the same exact-ID cleanup now, rather than relying on an EXIT trap that would leave an active
# recovery receipt behind after success. Verify the two device IDs have actually disappeared before moving
# the record out of the active-recovery name; a failure leaves `simulators.tsv` intact and blocks reruns.
cleanup
for uuid in "${created[@]}"; do
  is_uuid "$uuid" || continue
  if xcrun simctl list devices | /usr/bin/grep -Fq "$uuid"; then
    print -u2 "owned native Cinema simulator still exists after delete: $uuid"
    exit 1
  fi
done
mv "$receipt" "$completed_receipt"
trap - EXIT
print "ok: native Cinema UI screenshots written to $output; completed simulator receipt: $completed_receipt"
