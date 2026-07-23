#!/usr/bin/env bash
# =============================================================================
# make-fixture.sh - synthesize the multi-audio + multi-subtitle MKV fixtures the
# DV rendition/stall repro harness drives through the REAL remux + HLS server.
#
# Fixture A (fixture-multiaudio.mkv): HEVC hvc1 (1s GOP) + THREE audio tracks
#   (E-AC-3 5.1 eng, E-AC-3 5.1 fre - a qualifying same-codec alternate pair -
#   plus AC-3 stereo spa) + TWO SRT text subtitle tracks (eng, fre) with a cue
#   every 2 seconds for the whole runtime, so every startup-window WebVTT
#   segment must carry at least one cue.
# Fixture B (fixture-mixedcodec.mkv): HEVC + E-AC-3 eng + AC-3 fre only (NO
#   same-codec alternate), the CEO's field shape (truehd,eac3,dts,ac3 - exactly
#   one decodable codec per language) that yields audio=0 masters today.
#
# Media artifacts stay under /tmp/dd-dvstall/fixtures - never in the repo.
# =============================================================================
set -euo pipefail
FFMPEG=/opt/homebrew/bin/ffmpeg
OUT=/tmp/dd-dvstall/fixtures
DUR="${1:-240}"
mkdir -p "$OUT"

srt() { # srt <path> <label> <duration>
  local path="$1" label="$2" dur="$3"
  : > "$path"
  local i=0 idx=1
  while [ "$i" -lt "$dur" ]; do
    local s0=$(printf "%02d:%02d:%02d,000" $((i/3600)) $(((i/60)%60)) $((i%60)))
    local e=$((i+2)); [ "$e" -gt "$dur" ] && e="$dur"
    local s1=$(printf "%02d:%02d:%02d,500" $((e/3600)) $(((e/60)%60)) $((e%60)))
    printf "%d\n%s --> %s\n%s cue %d\n\n" "$idx" "$s0" "$s1" "$label" "$idx" >> "$path"
    i=$((i+2)); idx=$((idx+1))
  done
}

srt "$OUT/sub-eng.srt" "English" "$DUR"
srt "$OUT/sub-fre.srt" "French" "$DUR"

if [ ! -f "$OUT/fixture-multiaudio.mkv" ]; then
  "$FFMPEG" -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=640x360:rate=24:duration=$DUR" \
    -f lavfi -i "sine=frequency=440:duration=$DUR" \
    -f lavfi -i "sine=frequency=550:duration=$DUR" \
    -f lavfi -i "sine=frequency=660:duration=$DUR" \
    -i "$OUT/sub-eng.srt" -i "$OUT/sub-fre.srt" \
    -map 0:v -map 1:a -map 2:a -map 3:a -map 4:s -map 5:s \
    -c:v libx265 -preset ultrafast -tag:v hvc1 -x265-params "keyint=24:min-keyint=24:scenecut=0:log-level=error" -pix_fmt yuv420p \
    -c:a:0 eac3 -ar:a:0 48000 -ac:a:0 6 -b:a:0 256k -metadata:s:a:0 language=eng -metadata:s:a:0 title="English 5.1" \
    -c:a:1 eac3 -ar:a:1 48000 -ac:a:1 6 -b:a:1 256k -metadata:s:a:1 language=fre -metadata:s:a:1 title="French 5.1" \
    -c:a:2 ac3  -ar:a:2 48000 -ac:a:2 2 -b:a:2 192k -metadata:s:a:2 language=spa -metadata:s:a:2 title="Spanish 2.0" \
    -c:s srt -metadata:s:s:0 language=eng -metadata:s:s:1 language=fre \
    -disposition:s:0 default \
    "$OUT/fixture-multiaudio.mkv"
fi

if [ ! -f "$OUT/fixture-mixedcodec.mkv" ]; then
  "$FFMPEG" -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=640x360:rate=24:duration=$DUR" \
    -f lavfi -i "sine=frequency=440:duration=$DUR" \
    -f lavfi -i "sine=frequency=550:duration=$DUR" \
    -i "$OUT/sub-eng.srt" \
    -map 0:v -map 1:a -map 2:a -map 3:s \
    -c:v libx265 -preset ultrafast -tag:v hvc1 -x265-params "keyint=24:min-keyint=24:scenecut=0:log-level=error" -pix_fmt yuv420p \
    -c:a:0 eac3 -ar:a:0 48000 -ac:a:0 6 -b:a:0 256k -metadata:s:a:0 language=eng -metadata:s:a:0 title="English 5.1" \
    -c:a:1 ac3  -ar:a:1 48000 -ac:a:1 6 -b:a:1 256k -metadata:s:a:1 language=fre -metadata:s:a:1 title="French 5.1" \
    -c:s srt -metadata:s:s:0 language=eng \
    "$OUT/fixture-mixedcodec.mkv"
fi

ls -la "$OUT"
