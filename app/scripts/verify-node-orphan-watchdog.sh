#!/usr/bin/env bash
#
# Proof for the macOS embedded-server orphan fix (MacNodeServer.swift).
#
# The Swift app kills its `node` child cleanly on Cmd-Q via
# MacAppDelegate.applicationWillTerminate -> NodeServer.stop(). But that hook does
# NOT fire on a NON-clean exit (crash, Force Quit, SIGKILL, Xcode/CI "Stop"). In
# that case Foundation reparents the child to launchd (PPID 1) and it keeps holding
# :11470 forever -- the orphan leak observed on this machine.
#
# Foundation cannot signal the child on parent death, so the fix lives in the `-r`
# preload we already inject: a parent-death watchdog that exits the child once its
# parent pid changes (i.e. it has been reparented). This script simulates the exact
# crash path -- spawn the child under a parent, then SIGKILL the *parent only* -- and
# asserts the child does NOT outlive its parent.
#
# It runs two cases:
#   1. NO watchdog  -> reproduces the leak (child orphaned, port still held)  [RED]
#   2. WITH watchdog -> child self-exits, port released within the poll window [GREEN]
#
# Exit 0 only if case 2 passes (and case 1 demonstrably leaks, confirming the test
# actually exercises the bug). The WITH-watchdog snippet is kept byte-for-byte in
# sync with the preload built in MacNodeServer.spawn().
#
# Usage: app/scripts/verify-node-orphan-watchdog.sh

set -u

PORT=11470
POLL_TIMEOUT=4          # seconds to wait for the watchdog to reap the orphan
WATCHDOG_INTERVAL_MS=1000

# --- pick a node runtime: prefer the bundled one (faithful), else PATH node -------
NODE=""
for cand in app/build/*/Build/Products/*/StremioXMac.app/Contents/Resources/node-darwin-arm64; do
  [ -x "$cand" ] && NODE="$cand" && break
done
[ -z "$NODE" ] && NODE="$(command -v node || true)"
if [ -z "$NODE" ]; then
  echo "FAIL: no node binary found (neither bundled nor on PATH)"; exit 2
fi
echo "node runtime: $NODE ($("$NODE" --version))"

# Refuse to run if something is already on the port -- we'd misattribute it.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "FAIL: port $PORT is already in use; clear it before running this proof"; exit 2
fi

WORK="$(mktemp -d /tmp/stremiox-orphan-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# --- the stub server: bind loopback:PORT and stay up (stands in for server.js) ----
cat > "$WORK/server.js" <<JS
const net = require('net');
net.createServer().listen($PORT, '127.0.0.1');
setInterval(() => {}, 1 << 30); // keep alive
JS

# --- preload WITHOUT the watchdog (old behaviour) ---------------------------------
cat > "$WORK/preload-nowatch.js" <<'JS'
// no parent-death watchdog -- mimics the pre-fix child
JS

# --- preload WITH the watchdog (mirrors MacNodeServer.spawn()'s preload) -----------
cat > "$WORK/preload-watch.js" <<JS
const PPID0 = process.ppid;
setInterval(function(){ if (process.ppid !== PPID0) { process.exit(0); } }, $WATCHDOG_INTERVAL_MS).unref();
JS

# --- the parent: spawns the child, records its pid, then idles (killable) ----------
cat > "$WORK/parent.js" <<'JS'
const { spawn } = require('child_process');
const fs = require('fs');
const [node, preload, server, pidfile] = process.argv.slice(2);
const child = spawn(node, ['-r', preload, server], { stdio: 'ignore' });
fs.writeFileSync(pidfile, String(child.pid));
setInterval(() => {}, 1 << 30); // idle until SIGKILLed
JS

alive() { kill -0 "$1" 2>/dev/null; }
port_held() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; }

run_case() { # $1=preload file  $2=label  -> echoes "LEAK" or "REAPED"
  local preload="$1" label="$2" pidfile="$WORK/child.pid"
  rm -f "$pidfile"
  "$NODE" "$WORK/parent.js" "$NODE" "$preload" "$WORK/server.js" "$pidfile" &
  local parent=$!

  # wait for the child to come up and bind the port
  local i=0
  while [ $i -lt 50 ] && { [ ! -s "$pidfile" ] || ! port_held; }; do sleep 0.1; i=$((i+1)); done
  local child; child="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -z "$child" ] || ! port_held; then
    kill -KILL "$parent" 2>/dev/null; [ -n "$child" ] && kill -KILL "$child" 2>/dev/null
    echo "ERROR: child never bound :$PORT for case '$label'"; return 1
  fi
  echo "  [$label] parent=$parent child=$child  (child ppid=$(ps -o ppid= -p "$child" | tr -d ' '))" >&2

  # SIMULATE THE CRASH: kill the PARENT ONLY. The child reparents to launchd (PPID 1).
  kill -KILL "$parent" 2>/dev/null
  wait "$parent" 2>/dev/null

  # poll: did the child outlive its parent (orphan) or self-exit (watchdog)?
  local t=0
  while [ "$t" -lt "$((POLL_TIMEOUT*10))" ]; do
    if ! alive "$child" && ! port_held; then echo "REAPED"; return 0; fi
    sleep 0.1; t=$((t+1))
  done
  # still alive => leak. Clean it up so we don't add to the orphan pile.
  echo "  [$label] child $child still alive ppid=$(ps -o ppid= -p "$child" | tr -d ' ') -> cleaning up" >&2
  kill -KILL "$child" 2>/dev/null
  echo "LEAK"; return 0
}

echo
echo "CASE 1 (no watchdog, expect LEAK):"
R1="$(run_case "$WORK/preload-nowatch.js" no-watchdog)" || { echo "$R1"; exit 2; }
echo "  result: $R1"
echo
echo "CASE 2 (watchdog, expect REAPED):"
R2="$(run_case "$WORK/preload-watch.js" watchdog)" || { echo "$R2"; exit 2; }
echo "  result: $R2"
echo

# Final port check: nothing of ours must remain.
if port_held; then echo "FAIL: port $PORT still held after test"; exit 1; fi

if [ "$R1" = "LEAK" ] && [ "$R2" = "REAPED" ]; then
  echo "PASS: without the watchdog the child orphans and holds :$PORT;"
  echo "      with the watchdog it self-exits on reparent and releases :$PORT."
  exit 0
fi
echo "FAIL: expected CASE1=LEAK CASE2=REAPED, got CASE1=$R1 CASE2=$R2"
exit 1
