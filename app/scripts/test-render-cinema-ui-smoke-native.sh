#!/bin/zsh
set -euo pipefail

# Shell-fixture tests for the native renderer's simulator ownership protocol. They replace xcrun/Xcode
# with local commands and therefore create no simulator, launch no app, and build no native product.
root="${0:A:h:h}"
renderer="$root/scripts/render-cinema-ui-smoke-native.sh"
tmp="$(mktemp -d /tmp/cinema-ios-smoke-script.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
fakebin="$tmp/fakebin"
mkdir -p "$fakebin"

cat > "$fakebin/xcodegen" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$fakebin/xcodebuild" <<'EOF'
#!/bin/sh
mkdir -p "$CINEMA_UI_SMOKE_IOS_DERIVED_DATA/Build/Products/Debug-iphonesimulator/CinemaUISmokeIOSRenderer.app"
exit 0
EOF
cat > "$fakebin/xcrun" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$FIXTURE_CALLS"
if [ "$1" = simctl ] && [ "$2" = create ]; then
  count=0
  [ -f "$FIXTURE_CREATE_COUNT" ] && count=$(cat "$FIXTURE_CREATE_COUNT")
  count=$((count + 1))
  printf '%s' "$count" > "$FIXTURE_CREATE_COUNT"
  if [ "${FIXTURE_MODE:-success}" = second-create-fails ] && [ "$count" -eq 2 ]; then
    exit 42
  fi
  if [ "$count" -eq 1 ]; then
    printf '%s\n' '11111111-1111-1111-1111-111111111111'
  else
    printf '%s\n' '22222222-2222-2222-2222-222222222222'
  fi
  exit 0
fi
if [ "$1" = simctl ] && [ "$2" = io ] && [ "$4" = screenshot ]; then
  printf x > "$5"
fi
exit 0
EOF
chmod +x "$fakebin/xcodegen" "$fakebin/xcodebuild" "$fakebin/xcrun"

run_fixture() {
  local name="$1"
  local mode="$2"
  local output="$tmp/$name/output"
  local derived="$tmp/$name/derived"
  local calls="$tmp/$name/calls"
  local creates="$tmp/$name/creates"
  mkdir -p "$output"
  rm -f "$creates"
  PATH="$fakebin:$PATH" \
    FIXTURE_MODE="$mode" \
    FIXTURE_CALLS="$calls" \
    FIXTURE_CREATE_COUNT="$creates" \
    CINEMA_UI_SMOKE_IOS_OUTPUT="$output" \
    CINEMA_UI_SMOKE_IOS_DERIVED_DATA="$derived" \
    zsh "$renderer"
}

# Never overwrite a prior failure receipt, and do not even invoke fake xcrun in that case.
prior="$tmp/prior/output"
mkdir -p "$prior"
printf 'uuid\tname\tbundle\nold\tfailed run\tcom.stremiox.cinema-ui-smoke.ios\n' > "$prior/simulators.tsv"
set +e
run_fixture prior success
result=$?
set -e
if [[ "$result" -eq 0 ]]; then
  print -u2 'expected prior receipt invocation to fail'
  exit 1
fi
[[ "$(cat "$prior/simulators.tsv")" == $'uuid\tname\tbundle\nold\tfailed run\tcom.stremiox.cinema-ui-smoke.ios' ]]
[[ ! -e "$tmp/prior/calls" ]]

# If the second create fails, the first UUID is already recorded and gets only terminate/shutdown;
# it is not deleted because that receipt is the intentional recovery path.
set +e
run_fixture second-create-fails second-create-fails
result=$?
set -e
if [[ "$result" -eq 0 ]]; then
  print -u2 'expected second simulator creation to fail'
  exit 1
fi
second_receipt="$tmp/second-create-fails/output/simulators.tsv"
awk -F $'\t' 'NR == 2 && $1 == "11111111-1111-1111-1111-111111111111" && $2 == "Cinema UI Smoke iPhone 16 Pro" && $3 == "com.stremiox.cinema-ui-smoke.ios" { found = 1 } END { exit found ? 0 : 1 }' "$second_receipt"
rg -Fq 'simctl terminate 11111111-1111-1111-1111-111111111111 com.stremiox.cinema-ui-smoke.ios' "$tmp/second-create-fails/calls"
rg -Fq 'simctl shutdown 11111111-1111-1111-1111-111111111111' "$tmp/second-create-fails/calls"
if rg -Fq 'simctl delete 11111111-1111-1111-1111-111111111111' "$tmp/second-create-fails/calls"; then
  print -u2 'failed fixture must preserve its only created UUID'
  exit 1
fi

# A successful fixture has three actual TSV fields per record and deletes only its two generated UUIDs.
run_fixture success success
success_receipt="$(print -l "$tmp/success/output"/simulators.completed.*.tsv)"
[[ ! -e "$tmp/success/output/simulators.tsv" ]]
awk -F $'\t' '
  NR == 1 { if (NF != 3) bad = 1; next }
  { if (NF != 3 || $3 != "com.stremiox.cinema-ui-smoke.ios") bad = 1; records += 1 }
  END { exit (bad || records != 2) ? 1 : 0 }
' "$success_receipt"
for uuid in 11111111-1111-1111-1111-111111111111 22222222-2222-2222-2222-222222222222; do
  rg -Fq "simctl delete $uuid" "$tmp/success/calls"
done
for kind in phone ipad; do
  for surface in home search quickView episodeSources; do
    [[ -s "$tmp/success/output/cinema-ios-$kind-$surface.png" ]]
  done
done

# A completed receipt is archived, not treated as an active failed run. The exact same output directory
# can therefore produce a fresh device pair without touching the old receipt or any user simulator.
run_fixture success success
completed_receipts=("$tmp/success/output"/simulators.completed.*.tsv(N))
[[ "${#completed_receipts[@]}" -eq 2 ]]
[[ ! -e "$tmp/success/output/simulators.tsv" ]]
print 'ok: native Cinema renderer simulator ownership fixtures pass'
