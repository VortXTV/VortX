#!/usr/bin/env bash
# A throwaway Samba server for the live SMB tests, on 127.0.0.1:1445 only. Needs Docker (OrbStack works).
#   test/fixtures/smb-share.sh up     # prints VORTX_SMB_LIVE_SERVER=127.0.0.1:1445
#   test/fixtures/smb-share.sh down   # removes the container and its files
# Shares: Movies (user tester, password s3cret) and Public (guest), both read-only over the same files:
#   Test Movie (2024).mkv  5,000,000 bytes, byte i = ((i*31+7) ^ (i>>8)) & 255
#   Season 1/S01E01.mp4    100,000 bytes, byte i = (i*13) & 255
#   notes.txt, .hidden.mkv (left out of listings)
set -euo pipefail
name=vx-smb-test
dir="${TMPDIR:-/tmp}/vx-smb-share"
case "${1:-up}" in
  down) docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$dir"; exit 0 ;;
  up) ;;
  *) echo "usage: $0 up|down" >&2; exit 2 ;;
esac
mkdir -p "$dir/files/Season 1"
python3 -I - "$dir/files" <<'PY'
import sys
d = sys.argv[1]
open(d + "/Test Movie (2024).mkv", "wb").write(bytes(((i * 31 + 7) ^ (i >> 8)) & 255 for i in range(5_000_000)))
open(d + "/Season 1/S01E01.mp4", "wb").write(bytes((i * 13) & 255 for i in range(100_000)))
open(d + "/notes.txt", "w").write("not a video")
open(d + "/.hidden.mkv", "wb").write(b"x" * 10)
PY
cat > "$dir/smb.conf" <<'CONF'
[global]
server role = standalone server
map to guest = Bad User
server min protocol = SMB2
disable netbios = yes
smb ports = 445
[Movies]
path = /share
read only = yes
valid users = tester
[Public]
path = /share
read only = yes
guest ok = yes
CONF
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" -p 127.0.0.1:1445:445 -v "$dir/files":/share:ro -v "$dir/smb.conf":/etc/smbconf-test:ro alpine:3.20 \
  sh -c 'apk add --no-cache samba >/dev/null && adduser -D -H tester && printf "s3cret\ns3cret\n" | smbpasswd -a -s tester \
    && cp /etc/smbconf-test /etc/samba/smb.conf && exec smbd --foreground --no-process-group --debug-stdout' >/dev/null
for _ in $(seq 1 60); do docker logs "$name" 2>&1 | grep -q "smbd version" && break; sleep 1; done
echo "VORTX_SMB_LIVE_SERVER=127.0.0.1:1445"
