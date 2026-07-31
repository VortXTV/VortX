#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

fail() {
  echo "fetch-server-deps-integrity.test: $*" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local literal="$2"
  grep -Fq -- "${literal}" "${file}" ||
    fail "missing required contract in ${file}: ${literal}"
}

require_count() {
  local file="$1"
  local literal="$2"
  local expected="$3"
  local actual
  actual="$(grep -Fc -- "${literal}" "${file}" || true)"
  [ "${actual}" -eq "${expected}" ] ||
    fail "expected ${expected} occurrences in ${file}, found ${actual}: ${literal}"
}

require_before() {
  local file="$1"
  local earlier="$2"
  local later="$3"
  local earlier_line
  local later_line
  require_literal "${file}" "${earlier}"
  require_literal "${file}" "${later}"
  earlier_line="$(grep -nF -- "${earlier}" "${file}" | head -1 | cut -d: -f1)"
  later_line="$(grep -nF -- "${later}" "${file}" | head -1 | cut -d: -f1)"
  [ "${earlier_line}" -lt "${later_line}" ] ||
    fail "contract must precede use in ${file}: ${earlier}"
}

require_all_before() {
  local file="$1"
  local earlier="$2"
  local later="$3"
  local last_earlier_line
  local first_later_line
  require_literal "${file}" "${earlier}"
  require_literal "${file}" "${later}"
  last_earlier_line="$(grep -nF -- "${earlier}" "${file}" | tail -1 | cut -d: -f1)"
  first_later_line="$(grep -nF -- "${later}" "${file}" | head -1 | cut -d: -f1)"
  [ "${last_earlier_line}" -lt "${first_later_line}" ] ||
    fail "every integrity check must precede use in ${file}: ${earlier}"
}

check_contract() {
  local root="$1"
  local desktop_workflow="${root}/.github/workflows/desktop.yml"
  local security_workflow="${root}/.github/workflows/security.yml"
  local fetch_script="${root}/desktop/scripts/fetch-server-deps.sh"

  require_literal "${desktop_workflow}" 'node-version: "22.18.0"'
  require_literal "${desktop_workflow}" 'toolchain: 1.97.1'
  require_literal "${security_workflow}" 'toolchain: 1.97.1'

  require_literal "${desktop_workflow}" 'e87ee0815d109282fdda73e34c2361d64d02b0ffaea3674b18f1fd1f6a687dcf'
  require_literal "${desktop_workflow}" '1da16a46fa5e058ae740e7c35ed0d36d86cb869ac9cc8a5fd9a1847d7978d99a'
  require_count "${desktop_workflow}" 'sha256sum -c -' 2
  require_all_before "${desktop_workflow}" \
    'sha256sum -c -' \
    'chmod +x linuxdeploy.AppImage linuxdeploy-plugin-appimage'
  require_all_before "${desktop_workflow}" \
    'sha256sum -c -' \
    './linuxdeploy.AppImage --appdir AppDir'

  require_literal "${fetch_script}" \
    'darwin-arm64) NODE_SHA256="9e92ce1032455a9cc419fe71e908b27ae477799371b45a0844eedb02279922a4"'
  require_literal "${fetch_script}" \
    'darwin-x64) NODE_SHA256="c5497dd17c8875b53712edaf99052f961013cedc203964583fc0cfc0aaf93581"'
  require_literal "${fetch_script}" \
    'linux-arm64) NODE_SHA256="73cd297378572e0bc9dfc187c5ec8cca8d43aee6a596c10ebea1ed5f9ec682b6"'
  require_literal "${fetch_script}" \
    'linux-x64) NODE_SHA256="259e5a8bf2e15ecece65bd2a47153262eda71c0b2c9700d5e703ce4951572784"'
  require_literal "${fetch_script}" \
    'win-x64) NODE_SHA256="56e5aacdeee7168871721b75819ccacf2367de8761b78eaceacdecd41e04ca03"'
  require_literal "${fetch_script}" \
    'darwin-arm64) NODE_BINARY_SHA256="b4ccefa930e8a436b611b7cf4c73ef4c1905662197e3a243cb66fc49cd008adf"'
  require_literal "${fetch_script}" \
    'darwin-x64) NODE_BINARY_SHA256="81449ea83ebcf4b0ef1361a45803da80434db97f5d91b5cfcd3a3eae221f9f9f"'
  require_literal "${fetch_script}" \
    'linux-arm64) NODE_BINARY_SHA256="d0750f6ce0fe5c5432a228809ede96a7656af83c9ac03646d44df34875020f20"'
  require_literal "${fetch_script}" \
    'linux-x64) NODE_BINARY_SHA256="9292f9a3bb76f55338b4d34024bb0ca92c47986f12f6182fc5d992dd4a0b80ed"'
  require_literal "${fetch_script}" \
    'win-x64) NODE_BINARY_SHA256="06c1dec1b428927d6ff01c8f5882f119ec13b61ac77483760aa7fba215c72cf5"'
  require_literal "${fetch_script}" \
    'SERVER_JS_4_21_0_SHA256="82175d7982bce864df071df93b4b3d567a401e65881a8ac579d7db0ce71dafd7"'
  require_literal "${fetch_script}" \
    'STREMIOX_NODE_VERSION=${NODE_VERSION} requires STREMIOX_NODE_SHA256 and STREMIOX_NODE_BINARY_SHA256'
  require_literal "${fetch_script}" 'STREMIO_SERVER_VERSION=${SERVER_VERSION} requires STREMIO_SERVER_SHA256'
  require_literal "${fetch_script}" 'trap cleanup_temp_paths EXIT'
  require_literal "${fetch_script}" 'verify_sha256 "${TMP}/node.${NODE_EXT}" "${NODE_SHA256}"'
  require_literal "${fetch_script}" \
    'verify_sha256 "${NODE_DEST}" "${NODE_BINARY_SHA256}" "Node binary ${NODE_VERSION} ${NODE_PLATFORM}"'
  require_literal "${fetch_script}" \
    'verify_sha256 "${EXTRACTED_NODE}" "${NODE_BINARY_SHA256}"'
  require_literal "${fetch_script}" \
    'verify_sha256 "${NODE_DEST}" "${NODE_BINARY_SHA256}" "staged Node binary ${NODE_VERSION} ${NODE_PLATFORM}"'
  require_literal "${fetch_script}" 'verify_sha256 "${TMP_SERVER}" "${SERVER_SHA256}"'
  require_literal "${fetch_script}" 'verify_sha256 "${SERVER_DEST}" "${SERVER_SHA256}"'
  require_before "${fetch_script}" \
    'verify_sha256 "${NODE_DEST}" "${NODE_BINARY_SHA256}" "Node binary ${NODE_VERSION} ${NODE_PLATFORM}"' \
    'NODE_ACTUAL_VERSION="$("${NODE_DEST}" --version 2>/dev/null)"'
  require_before "${fetch_script}" \
    'verify_sha256 "${TMP}/node.${NODE_EXT}" "${NODE_SHA256}"' \
    'unzip -q "${TMP}/node.${NODE_EXT}"'
  require_before "${fetch_script}" \
    'verify_sha256 "${TMP}/node.${NODE_EXT}" "${NODE_SHA256}"' \
    'tar -xzf "${TMP}/node.${NODE_EXT}"'
  require_before "${fetch_script}" \
    'verify_sha256 "${TMP_SERVER}" "${SERVER_SHA256}"' \
    'mv "${TMP_SERVER}" "${SERVER_DEST}"'
  require_count "${fetch_script}" 'TEMP_PATHS+=(' 4
}

copy_contract_fixture() {
  local destination="$1"
  mkdir -p \
    "${destination}/.github/workflows" \
    "${destination}/desktop/scripts"
  cp "${PROJECT_ROOT}/.github/workflows/desktop.yml" \
    "${destination}/.github/workflows/desktop.yml"
  cp "${PROJECT_ROOT}/.github/workflows/security.yml" \
    "${destination}/.github/workflows/security.yml"
  cp "${PROJECT_ROOT}/desktop/scripts/fetch-server-deps.sh" \
    "${destination}/desktop/scripts/fetch-server-deps.sh"
}

mutate_literal() {
  local file="$1"
  local literal="$2"
  local output="${file}.mutated"
  awk -v literal="${literal}" '
    {
      if (!changed) {
        position = index($0, literal)
        if (position > 0) {
          $0 = substr($0, 1, position - 1) "MUTATED" substr($0, position + length(literal))
          changed = 1
        }
      }
      print
    }
    END {
      if (!changed) {
        exit 2
      }
    }
  ' "${file}" > "${output}" || fail "could not mutate ${literal}"
  mv "${output}" "${file}"
}

assert_mutation_rejected() {
  local relative_file="$1"
  local literal="$2"
  local fixture
  fixture="$(mktemp -d)"
  copy_contract_fixture "${fixture}"
  mutate_literal "${fixture}/${relative_file}" "${literal}"
  if (check_contract "${fixture}") >/dev/null 2>&1; then
    rm -rf "${fixture}"
    fail "contract accepted mutation in ${relative_file}: ${literal}"
  fi
  rm -rf "${fixture}"
}

move_linuxdeploy_checks_after_execution() {
  local file="$1"
  local output="${file}.mutated"
  awk '
    /^[[:space:]]*printf .*\\$/ {
      first = $0
      if ((getline second) <= 0 || (getline third) <= 0) {
        exit 2
      }
      if (third ~ /sha256sum -c -/) {
        held = held first ORS second ORS third ORS
        moved++
        next
      }
      print first
      print second
      print third
      next
    }
    {
      print
      if ($0 ~ /--desktop-file "\$desktop_file" --icon-file "\$icon" --output appimage/) {
        printf "%s", held
        held = ""
      }
    }
    END {
      if (moved != 2 || held != "") {
        exit 2
      }
    }
  ' "${file}" > "${output}" ||
    fail "could not move linuxdeploy integrity checks after execution"
  mv "${output}" "${file}"
}

assert_reordered_checks_rejected() {
  local fixture
  fixture="$(mktemp -d)"
  copy_contract_fixture "${fixture}"
  move_linuxdeploy_checks_after_execution "${fixture}/.github/workflows/desktop.yml"
  if (check_contract "${fixture}") >/dev/null 2>&1; then
    rm -rf "${fixture}"
    fail "contract accepted linuxdeploy checksum commands after chmod/execution"
  fi
  rm -rf "${fixture}"
}

make_runtime_sandbox() {
  local sandbox="$1"
  mkdir -p \
    "${sandbox}/project/desktop/scripts" \
    "${sandbox}/project/desktop/src-tauri/resources" \
    "${sandbox}/fakebin"
  cp "${PROJECT_ROOT}/desktop/scripts/fetch-server-deps.sh" \
    "${sandbox}/project/desktop/scripts/fetch-server-deps.sh"

  cat > "${sandbox}/fakebin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -s) printf '%s\n' Linux ;;
  -m) printf '%s\n' x86_64 ;;
  *) printf '%s\n' Linux ;;
esac
EOF
  cat > "${sandbox}/fakebin/curl" <<'EOF'
#!/bin/sh
printf 'called\n' > "${TEST_CURL_MARKER:?}"
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      shift
      output="$1"
      ;;
  esac
  shift
done
[ -n "${output}" ] || exit 2
printf 'tampered archive\n' > "${output}"
if [ "${TEST_CURL_FAIL:-0}" = "1" ]; then
  exit 22
fi
EOF
  cat > "${sandbox}/fakebin/tar" <<'EOF'
#!/bin/sh
printf 'called\n' > "${TEST_UNPACK_MARKER:?}"
exit 90
EOF
  cp "${sandbox}/fakebin/tar" "${sandbox}/fakebin/unzip"
  chmod +x "${sandbox}/fakebin/"*
}

stage_trusted_node_stub() {
  local sandbox="$1"
  local node="${sandbox}/project/desktop/src-tauri/resources/node-linux-x64"
  cat > "${node}" <<'EOF'
#!/bin/sh
printf '%s\n' v20.18.1
EOF
  chmod +x "${node}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${node}" | awk '{print $1}'
  else
    shasum -a 256 "${node}" | awk '{print $1}'
  fi
}

test_node_mismatch_stops_before_unpack() {
  local sandbox
  local output
  sandbox="$(mktemp -d)"
  make_runtime_sandbox "${sandbox}"
  output="${sandbox}/output"
  if PATH="${sandbox}/fakebin:/usr/bin:/bin" \
      TEST_CURL_MARKER="${sandbox}/curl-called" \
      TEST_UNPACK_MARKER="${sandbox}/unpack-called" \
      "${sandbox}/project/desktop/scripts/fetch-server-deps.sh" >"${output}" 2>&1; then
    rm -rf "${sandbox}"
    fail "tampered Node archive was accepted"
  fi
  grep -Fq 'Node v20.18.1 linux-x64 checksum mismatch' "${output}" ||
    fail "Node mismatch did not report the failed integrity gate"
  [ -f "${sandbox}/curl-called" ] || fail "Node mismatch fixture did not reach the download"
  [ ! -e "${sandbox}/unpack-called" ] || fail "tampered Node archive reached an unpacker"
  [ ! -e "${sandbox}/project/desktop/src-tauri/resources/node-linux-x64" ] ||
    fail "tampered Node archive produced a staged runtime"
  rm -rf "${sandbox}"
}

test_hostile_staged_node_is_never_executed() {
  local sandbox
  local resources
  local output
  sandbox="$(mktemp -d)"
  make_runtime_sandbox "${sandbox}"
  resources="${sandbox}/project/desktop/src-tauri/resources"
  cat > "${resources}/node-linux-x64" <<'EOF'
#!/bin/sh
printf 'executed\n' > "${TEST_NODE_EXEC_MARKER:?}"
printf '%s\n' v20.18.1
EOF
  chmod +x "${resources}/node-linux-x64"
  output="${sandbox}/output"
  if PATH="${sandbox}/fakebin:/usr/bin:/bin" \
      TEST_CURL_MARKER="${sandbox}/curl-called" \
      TEST_UNPACK_MARKER="${sandbox}/unpack-called" \
      TEST_NODE_EXEC_MARKER="${sandbox}/node-executed" \
      "${sandbox}/project/desktop/scripts/fetch-server-deps.sh" >"${output}" 2>&1; then
    rm -rf "${sandbox}"
    fail "hostile staged Node executable was accepted"
  fi
  grep -Fq 'Node binary v20.18.1 linux-x64 checksum mismatch' "${output}" ||
    fail "hostile staged Node did not report its binary checksum failure"
  [ ! -e "${sandbox}/node-executed" ] || fail "hostile staged Node was executed before byte verification"
  [ ! -e "${sandbox}/curl-called" ] || fail "hostile staged Node unexpectedly reached curl"
  [ ! -e "${resources}/node-linux-x64" ] || fail "hostile staged Node was not removed"
  rm -rf "${sandbox}"
}

test_checksumless_overrides_stop_before_download() {
  local sandbox
  local output
  sandbox="$(mktemp -d)"
  make_runtime_sandbox "${sandbox}"
  output="${sandbox}/node-output"
  if PATH="${sandbox}/fakebin:/usr/bin:/bin" \
      TEST_CURL_MARKER="${sandbox}/curl-called" \
      TEST_UNPACK_MARKER="${sandbox}/unpack-called" \
      STREMIOX_NODE_VERSION="v99.0.0" \
      "${sandbox}/project/desktop/scripts/fetch-server-deps.sh" >"${output}" 2>&1; then
    rm -rf "${sandbox}"
    fail "checksumless Node version override was accepted"
  fi
  grep -Fq 'requires STREMIOX_NODE_SHA256' "${output}" ||
    fail "checksumless Node override did not explain the required checksum"
  [ ! -e "${sandbox}/curl-called" ] || fail "checksumless Node override reached curl"

  output="${sandbox}/server-output"
  if PATH="${sandbox}/fakebin:/usr/bin:/bin" \
      TEST_CURL_MARKER="${sandbox}/curl-called" \
      TEST_UNPACK_MARKER="${sandbox}/unpack-called" \
      STREMIO_SERVER_VERSION="99.0.0" \
      "${sandbox}/project/desktop/scripts/fetch-server-deps.sh" >"${output}" 2>&1; then
    rm -rf "${sandbox}"
    fail "checksumless server version override was accepted"
  fi
  grep -Fq 'requires STREMIO_SERVER_SHA256' "${output}" ||
    fail "checksumless server override did not explain the required checksum"
  [ ! -e "${sandbox}/curl-called" ] || fail "checksumless server override reached curl"
  rm -rf "${sandbox}"
}

test_local_server_copy_is_verified() {
  local sandbox
  local resources
  local stremio_app
  local node_sha
  local output
  sandbox="$(mktemp -d)"
  make_runtime_sandbox "${sandbox}"
  resources="${sandbox}/project/desktop/src-tauri/resources"
  stremio_app="${sandbox}/Stremio.app"
  mkdir -p "${stremio_app}/Contents/MacOS"
  printf 'tampered local server\n' > "${stremio_app}/Contents/MacOS/server.js"
  node_sha="$(stage_trusted_node_stub "${sandbox}")"
  output="${sandbox}/output"
  if PATH="${sandbox}/fakebin:/usr/bin:/bin" \
      TEST_CURL_MARKER="${sandbox}/curl-called" \
      TEST_UNPACK_MARKER="${sandbox}/unpack-called" \
      STREMIOX_NODE_BINARY_SHA256="${node_sha}" \
      STREMIO_APP="${stremio_app}" \
      "${sandbox}/project/desktop/scripts/fetch-server-deps.sh" >"${output}" 2>&1; then
    rm -rf "${sandbox}"
    fail "tampered local server.js was accepted"
  fi
  grep -Fq 'server.js v4.21.0 checksum mismatch' "${output}" ||
    fail "local server.js mismatch did not report the failed integrity gate"
  [ ! -e "${sandbox}/curl-called" ] || fail "local server.js fixture unexpectedly reached curl"
  [ ! -e "${resources}/server.cjs" ] || fail "tampered local server.js was staged"
  rm -rf "${sandbox}"
}

test_server_curl_failure_cleans_temp_file() {
  local sandbox
  local node_sha
  local output
  sandbox="$(mktemp -d)"
  make_runtime_sandbox "${sandbox}"
  mkdir -p "${sandbox}/tmp"
  # Keep an installed Stremio on a developer Mac from bypassing this curl-failure fixture.
  mutate_literal \
    "${sandbox}/project/desktop/scripts/fetch-server-deps.sh" \
    '"/Applications/Stremio.app"'
  chmod +x "${sandbox}/project/desktop/scripts/fetch-server-deps.sh"
  node_sha="$(stage_trusted_node_stub "${sandbox}")"
  output="${sandbox}/output"
  if PATH="${sandbox}/fakebin:/usr/bin:/bin" \
      TMPDIR="${sandbox}/tmp" \
      TEST_CURL_FAIL=1 \
      TEST_CURL_MARKER="${sandbox}/curl-called" \
      TEST_UNPACK_MARKER="${sandbox}/unpack-called" \
      STREMIOX_NODE_BINARY_SHA256="${node_sha}" \
      "${sandbox}/project/desktop/scripts/fetch-server-deps.sh" >"${output}" 2>&1; then
    rm -rf "${sandbox}"
    fail "server curl-failure fixture unexpectedly succeeded"
  fi
  [ -e "${sandbox}/curl-called" ] || fail "server curl-failure fixture did not reach curl"
  if find "${sandbox}/tmp" -mindepth 1 -print -quit | grep -q .; then
    rm -rf "${sandbox}"
    fail "server curl failure leaked its mktemp file"
  fi
  rm -rf "${sandbox}"
}

check_contract "${PROJECT_ROOT}"

assert_mutation_rejected '.github/workflows/desktop.yml' 'node-version: "22.18.0"'
assert_mutation_rejected '.github/workflows/desktop.yml' 'toolchain: 1.97.1'
assert_mutation_rejected '.github/workflows/security.yml' 'toolchain: 1.97.1'
assert_mutation_rejected '.github/workflows/desktop.yml' \
  'e87ee0815d109282fdda73e34c2361d64d02b0ffaea3674b18f1fd1f6a687dcf'
assert_mutation_rejected '.github/workflows/desktop.yml' \
  '1da16a46fa5e058ae740e7c35ed0d36d86cb869ac9cc8a5fd9a1847d7978d99a'
assert_mutation_rejected '.github/workflows/desktop.yml' 'sha256sum -c -'
assert_reordered_checks_rejected
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  '9e92ce1032455a9cc419fe71e908b27ae477799371b45a0844eedb02279922a4'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  'c5497dd17c8875b53712edaf99052f961013cedc203964583fc0cfc0aaf93581'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  '73cd297378572e0bc9dfc187c5ec8cca8d43aee6a596c10ebea1ed5f9ec682b6'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  '259e5a8bf2e15ecece65bd2a47153262eda71c0b2c9700d5e703ce4951572784'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  '56e5aacdeee7168871721b75819ccacf2367de8761b78eaceacdecd41e04ca03'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  'b4ccefa930e8a436b611b7cf4c73ef4c1905662197e3a243cb66fc49cd008adf'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  '81449ea83ebcf4b0ef1361a45803da80434db97f5d91b5cfcd3a3eae221f9f9f'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  'd0750f6ce0fe5c5432a228809ede96a7656af83c9ac03646d44df34875020f20'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  '9292f9a3bb76f55338b4d34024bb0ca92c47986f12f6182fc5d992dd4a0b80ed'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  '06c1dec1b428927d6ff01c8f5882f119ec13b61ac77483760aa7fba215c72cf5'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  '82175d7982bce864df071df93b4b3d567a401e65881a8ac579d7db0ce71dafd7'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  'STREMIOX_NODE_VERSION=${NODE_VERSION} requires STREMIOX_NODE_SHA256 and STREMIOX_NODE_BINARY_SHA256'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  'STREMIO_SERVER_VERSION=${SERVER_VERSION} requires STREMIO_SERVER_SHA256'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  'verify_sha256 "${TMP}/node.${NODE_EXT}" "${NODE_SHA256}"'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  'verify_sha256 "${NODE_DEST}" "${NODE_BINARY_SHA256}" "Node binary ${NODE_VERSION} ${NODE_PLATFORM}"'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  'verify_sha256 "${EXTRACTED_NODE}" "${NODE_BINARY_SHA256}"'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  'verify_sha256 "${TMP_SERVER}" "${SERVER_SHA256}"'
assert_mutation_rejected 'desktop/scripts/fetch-server-deps.sh' \
  'verify_sha256 "${SERVER_DEST}" "${SERVER_SHA256}"'

test_node_mismatch_stops_before_unpack
test_hostile_staged_node_is_never_executed
test_checksumless_overrides_stop_before_download
test_local_server_copy_is_verified
test_server_curl_failure_cleans_temp_file

echo "fetch-server-deps-integrity.test: PASS"
