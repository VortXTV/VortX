#!/usr/bin/env bash
# Reproducible actual-engine source-audio gate.
#
# This uses run-repro.sh's production MPVKit resolver and fixture generator, then compiles the real
# AVPlayerEngineController and CoreModels.swift PlayerLoadToken into the standalone harness. The executable
# performs a successful physical setAudioTrack remount and a deterministic target-failure rollback.
set -euo pipefail
cd "$(dirname "$0")/../.."

readonly INFRA_EXIT=30
infra() {
  echo "[INFRA] $*" >&2
  echo "[INFRA] no engine-transaction verdict exists." >&2
  exit "$INFRA_EXIT"
}

command -v xcrun >/dev/null 2>&1 || infra "xcrun is unavailable."
[ -x test/dv-rendition-stall/make-fixture.sh ] \
  || infra "fixture generator is missing or not executable."
[ -f test/player-conformance/range-server.py ] \
  || infra "paced range-server fixture dependency is missing."

# Resolve only the artifact identity declared by this branch. An explicit MPV_ROOT remains authoritative;
# otherwise an unfamiliar package declaration fails closed instead of borrowing another checkout's cache.
if [ -z "${MPV_ROOT:-}" ]; then
  [ -f app/project.yml ] || infra "app/project.yml is missing; set MPV_ROOT explicitly."
  mpvkit_package_path="$(
    awk '
      /^  MPVKit:[[:space:]]*$/ { in_mpvkit = 1; next }
      in_mpvkit && /^    path:[[:space:]]*/ {
        sub(/^    path:[[:space:]]*/, "")
        print
        exit
      }
      in_mpvkit && /^  [^ ]/ { exit }
    ' app/project.yml
  )"
  case "$mpvkit_package_path" in
    Vendor/MPVKit-DVFEL)
      expected_artifact_identity="mpvkit-dvfel"
      ;;
    *)
      infra "unsupported MPVKit package path '${mpvkit_package_path:-missing}'; set MPV_ROOT explicitly."
      ;;
  esac

  shopt -s nullglob
  candidates=(
    "$HOME"/Library/Developer/Xcode/DerivedData/VortX-*/SourcePackages/artifacts/"$expected_artifact_identity"
  )
  shopt -u nullglob
  [ "${#candidates[@]}" -gt 0 ] \
    || infra "no VortX '$expected_artifact_identity' artifact cache was found; build the app once or set MPV_ROOT."
  MPV_ROOT="$(ls -dt "${candidates[@]}" 2>/dev/null | head -n 1)"
  export MPV_ROOT
fi
[ -d "$MPV_ROOT" ] || infra "MPV_ROOT is not a directory: $MPV_ROOT"

export ENGINE_TRANSACTION=1
export ONLY_SELECTION=1
exec test/dv-rendition-stall/run-repro.sh
