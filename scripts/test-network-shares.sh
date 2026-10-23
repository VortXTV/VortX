#!/usr/bin/env bash
# Network shares (WebDAV and web folders): address rules, credential scoping, listing parsers, and the
# client against a local fixture server (never the network).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
dir=$(mktemp -d app/build/network-shares.XXXXXX)
server_pid=""
cleanup() { [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null; rm -rf "$dir"; }
trap cleanup EXIT
xcrun swiftc -parse-as-library -warnings-as-errors app/SourcesShared/NetworkShares.swift \
  app/Tests/NetworkSharesTests.swift -o "$dir/shares"
"$dir/shares"
xcrun swiftc -parse-as-library -warnings-as-errors app/SourcesShared/NetworkShares.swift app/SourcesShared/NetworkShareClient.swift \
  app/Tests/NetworkShareClientLiveTests.swift -o "$dir/client"
python3 -I test/fixtures/network-share-server.py > "$dir/port.txt" &
server_pid=$!
for _ in $(seq 1 50); do [[ -s "$dir/port.txt" ]] && break; sleep 0.1; done
"$dir/client" "$(head -1 "$dir/port.txt")"

# SMB: the shim's declarations must match the pinned libsmbclient.h, and the client must link and run
# against the shipped library. Both read MPVKit's cached release archives; nothing is downloaded.
cache="$HOME/Library/Caches/org.swift.swiftpm/artifacts"
smb_zip=$(ls -d "$cache"/*libsmbclient_build_releases_download_4_15_13*_Libsmbclient_xcframework_zip 2>/dev/null | head -1 || true)
if [[ -z "$smb_zip" ]]; then
  echo "SKIP  SMB header and link checks: MPVKit's libsmbclient archive is not in the SwiftPM cache"
  exit 0
fi
mkdir -p "$dir/smb"
(cd "$dir/smb" && unzip -q -o "$smb_zip" "*/macos-arm64_x86_64/*" && for n in gnutls nettle hogweed gmp; do
  z=$(ls -d "$cache"/*gnutls_build*_${n}_xcframework_zip | head -1); unzip -q -o "$z" "*/macos-arm64_x86_64/*"; done)
python3 - "$dir/smb/Libsmbclient.xcframework/macos-arm64_x86_64/Libsmbclient.framework/Headers/samba-4.0/libsmbclient.h" \
  app/SourcesShared/SMB/VortXSMBShim.h <<'PY'
import re, sys
norm = lambda text: re.sub(r"\s+", " ", re.sub(r"/\*.*?\*/", " ", text, flags=re.S)).strip()
header = norm(open(sys.argv[1]).read())
shim = norm(re.sub(r"//[^\n]*", "", open(sys.argv[2]).read()))
decls = [d.strip() + ";" for d in re.split(r";", shim.split("#define VORTX_SMB_SHIM_H", 1)[1].rsplit("#endif", 1)[0]) if d.strip()]
missing = [d for d in decls if d not in header and not d.startswith("struct smbc_dirent")]
fields = ["unsigned int smbc_type;", "unsigned int dirlen;", "unsigned int commentlen;", "char *comment;", "unsigned int namelen;", "char name[1];"]
order = [header.find(f) for f in fields]
if missing or -1 in order or order != sorted(order):
    print("FAIL  shim drifted from libsmbclient.h:", missing or "smbc_dirent layout"); sys.exit(1)
print(f"PASS  all {len(decls)} shim declarations match the pinned libsmbclient.h")
PY
frameworks=()
for n in Libsmbclient gnutls nettle hogweed gmp; do frameworks+=(-F "$dir/smb/$n.xcframework/macos-arm64_x86_64" -framework "$n"); done
xcrun swiftc -parse-as-library -import-objc-header app/SourcesShared/SMB/VortXSMBShim.h app/SourcesShared/NetworkShares.swift \
  app/SourcesShared/NetworkShareClient.swift app/SourcesShared/SMB/NetworkShareSMB.swift app/Tests/NetworkShareSMBLinkTests.swift \
  "${frameworks[@]}" -lresolv -liconv -lz -framework Security -framework CoreFoundation -o "$dir/smb-link"
"$dir/smb-link"
# Against a real Samba server when one is running (test/fixtures/smb-share.sh prints the address).
if [[ -n "${VORTX_SMB_LIVE_SERVER:-}" ]]; then
  xcrun swiftc -parse-as-library -import-objc-header app/SourcesShared/SMB/VortXSMBShim.h app/SourcesShared/NetworkShares.swift \
    app/SourcesShared/NetworkShareClient.swift app/SourcesShared/SMB/NetworkShareSMB.swift app/Tests/NetworkShareSMBLiveTests.swift \
    "${frameworks[@]}" -lresolv -liconv -lz -framework Security -framework CoreFoundation -o "$dir/smb-live"
  "$dir/smb-live"
fi
