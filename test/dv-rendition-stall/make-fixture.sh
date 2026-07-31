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
srt "$OUT/sub-ger.srt" "German" "$DUR"
srt "$OUT/sub-spa.srt" "Spanish" "$DUR"
srt "$OUT/sub-ita.srt" "Italian" "$DUR"

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

# Fixture C (fixture-manyaudio.mkv): the CEO's build 191 field shape - FIVE decodable audio tracks in
# FOUR different codecs, one language each (so the pre-fix same-codec alternate rule qualifies NOTHING and
# the master carries exactly one URI-less audio row: "audio says the language name but no options"), plus
# FIVE text subtitle tracks. This is the fixture the real-AVPlayer selection gate drives.
if [ ! -f "$OUT/fixture-manyaudio.mkv" ]; then
  "$FFMPEG" -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=640x360:rate=24:duration=$DUR" \
    -f lavfi -i "sine=frequency=440:duration=$DUR" \
    -f lavfi -i "sine=frequency=550:duration=$DUR" \
    -f lavfi -i "sine=frequency=660:duration=$DUR" \
    -f lavfi -i "sine=frequency=770:duration=$DUR" \
    -f lavfi -i "sine=frequency=880:duration=$DUR" \
    -i "$OUT/sub-eng.srt" -i "$OUT/sub-fre.srt" -i "$OUT/sub-ger.srt" \
    -i "$OUT/sub-spa.srt" -i "$OUT/sub-ita.srt" \
    -map 0:v -map 1:a -map 2:a -map 3:a -map 4:a -map 5:a \
    -map 6:s -map 7:s -map 8:s -map 9:s -map 10:s \
    -c:v libx265 -preset ultrafast -tag:v hvc1 -x265-params "keyint=24:min-keyint=24:scenecut=0:log-level=error" -pix_fmt yuv420p \
    -c:a:0 eac3 -ar:a:0 48000 -ac:a:0 6 -b:a:0 256k -metadata:s:a:0 language=eng -metadata:s:a:0 title="English 5.1" \
    -c:a:1 ac3  -ar:a:1 48000 -ac:a:1 6 -b:a:1 448k -metadata:s:a:1 language=fre -metadata:s:a:1 title="French 5.1" \
    -c:a:2 aac  -ar:a:2 48000 -ac:a:2 2 -b:a:2 128k -metadata:s:a:2 language=ger -metadata:s:a:2 title="German 2.0" \
    -c:a:3 ac3  -ar:a:3 48000 -ac:a:3 2 -b:a:3 192k -metadata:s:a:3 language=spa -metadata:s:a:3 title="Spanish 2.0" \
    -c:a:4 aac  -ar:a:4 48000 -ac:a:4 2 -b:a:4 128k -metadata:s:a:4 language=ita -metadata:s:a:4 title="Italian 2.0" \
    -c:s srt \
    -metadata:s:s:0 language=eng -metadata:s:s:1 language=fre -metadata:s:s:2 language=ger \
    -metadata:s:s:3 language=spa -metadata:s:s:4 language=ita \
    -disposition:s:0 default \
    "$OUT/fixture-manyaudio.mkv"
fi

# Fixture D (fixture-shifted-timeline.mkv): the exact ordinary-play regression shape. The first video
# presentation/decode clock is 5.000 s instead of zero, while every primary audio track starts 250 ms after
# video. A correct fresh mount subtracts the ONE base-video origin from every mapped packet, producing video
# clock zero while retaining the audio offset. Per-stream zeroing would hide the source offset and fail the
# cross-track assertion.
if [ ! -f "$OUT/fixture-shifted-timeline.mkv" ]; then
  "$FFMPEG" -y -hide_banner -loglevel error \
    -itsoffset 5 -i "$OUT/fixture-multiaudio.mkv" \
    -itsoffset 5.255 -i "$OUT/fixture-multiaudio.mkv" \
    -map 0:v:0 -map 1:a -map 0:s \
    -c copy -copyts \
    "$OUT/fixture-shifted-timeline.mkv"
fi

# Fixture E (fixture-shifted-early-audio.mkv): video starts at 5.000 s and its selected audio begins
# 250 ms earlier. The fresh rebase must retain that negative cross-track offset without letting audio choose
# the shift, clamping the audio independently, creating a positive audio edit, or failing the mux.
if [ ! -f "$OUT/fixture-shifted-early-audio.mkv" ]; then
  "$FFMPEG" -y -hide_banner -loglevel error \
    -itsoffset 5 -i "$OUT/fixture-multiaudio.mkv" \
    -itsoffset 4.755 -i "$OUT/fixture-multiaudio.mkv" \
    -map 0:v:0 -map 1:a:0 -map 0:s \
    -c copy -copyts \
    "$OUT/fixture-shifted-early-audio.mkv"
fi

# Fixture F (fixture-shifted-nodts.mkv): one HEVC keyframe whose DTS is absent and whose PTS is 5.000 s.
# It forces the bounded fresh pre-scan to use its PTS fallback instead of a later real DTS.
if [ ! -f "$OUT/fixture-shifted-nodts.mkv" ]; then
  "$FFMPEG" -y -hide_banner -loglevel error \
    -itsoffset 5 -i "$OUT/fixture-multiaudio.mkv" \
    -map 0:v:0 -map 0:a:0 -frames:v 1 \
    -c copy -copyts \
    "$OUT/fixture-shifted-nodts.mkv"
fi

ls -la "$OUT"
