#!/usr/bin/env bash
#
# Proof for the desktop embedded-server orphan fix (src-tauri/src/server.rs).
#
# The Tauri app kills its `node` child via stop() only on a GRACEFUL exit. On a crash / SIGKILL /
# Force-Quit the exit hook never runs, and the OS reparents the child (to launchd/init), where it
# keeps holding :11470 as an orphan — the same gap the macOS Swift app was hardened against.
#
# The fix lives in the `-r` preload built by write_preload(): a parent-death watchdog that exits the
# child once its parent pid changes (i.e. it has been reparented). This harness reconstructs the EXACT
# preload write_preload() emits (loopback pin + watchdog) and simulates the crash — spawn the child
# under a parent, SIGKILL the *parent only* — asserting the child does NOT outlive its parent.
#
# Two cases:
#   1. NO watchdog   -> reproduces the leak (child orphaned, port still held)  [RED]
#   2. WITH watchdog -> child self-exits, port released within the poll window [GREEN]
#
# (Twin of app/scripts/verify-node-orphan-watchdog.sh; the watchdog JS is byte-identical. The cargo
# test `write_preload_carries_the_parent_death_watchdog` separately proves the REAL write_preload
# output contains this exact snippet with the format! braces resolved.)
#
# Usage: desktop/scripts/verify-node-orphan-watchdog.sh

set -u

PORT=11470
POLL_TIMEOUT=4

# --- pick a node runtime: prefer the bundled one, else PATH node ------------------
NODE=""
for cand in src-tauri/resources/node-darwin-arm64 src-tauri/resources/node-* ; do
  [ -x "$cand" ] && NODE="$cand" && break
done
[ -z "$NODE" ] && NODE="$(command -v node || true)"
if [ -z "$NODE" ]; then echo "FAIL: no node binary found"; exit 2; fi
echo "node runtime: $NODE ($("$NODE" --version))"

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "FAIL: port $PORT already in use; clear it before running this proof"; exit 2
fi

WORK="$(mktemp -d /tmp/stremiox-desktop-orphan.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/server.log"

# stub server.cjs: host-less listen -> the preload must pin it to 127.0.0.1
cat > "$WORK/server.cjs" <<JS
require('net').createServer().listen($PORT);
setInterval(() => {}, 1 << 30);
JS

# RED preload: no watchdog
: > "$WORK/preload-nowatch.cjs"

# GREEN preload: faithful reconstruction of write_preload() output (HOST=127.0.0.1), braces resolved.
cat > "$WORK/preload-watch.cjs" <<JS
const fs=require('fs'),L=$("$NODE" -e "process.stdout.write(JSON.stringify(process.argv[1]))" "$LOG");
const w=(t,a)=>{try{fs.appendFileSync(L,t+' '+Array.prototype.map.call(a,String).join(' ')+'\n')}catch(e){}};
process.on('uncaughtException',function(e){w('[uncaught]',[e&&e.stack||e])});
process.on('unhandledRejection',function(e){w('[rej]',[e&&e.stack||e])});
try{
  const net=require('net'),HOST="127.0.0.1",orig=net.Server.prototype.listen;
  net.Server.prototype.listen=function(){
    const a=Array.prototype.slice.call(arguments);
    if(typeof a[0]==='number' && (a.length===1 || typeof a[1]==='function')){
      const cb=a[1]; a[1]=HOST; if(cb)a[2]=cb;
      w('[bind]',['listen',a[0],'->',HOST]);
    }
    return orig.apply(this,a);
  };
  w('[boot]',['desktop preload active; bind='+HOST]);
}catch(e){w('[bind-err]',[e&&e.stack||e]);}
const PPID0=process.ppid;
setInterval(function(){if(process.ppid!==PPID0){w('[watchdog]',['parent gone; exiting']);process.exit(0);}},1000).unref();
JS

"$NODE" --check "$WORK/preload-watch.cjs" && echo "node --check: reconstructed preload is valid"

cat > "$WORK/parent.js" <<'JS'
const {spawn}=require('child_process');const fs=require('fs');
const [node,preload,server,pidfile]=process.argv.slice(2);
const c=spawn(node,['-r',preload,server],{stdio:'ignore'});
fs.writeFileSync(pidfile,String(c.pid));setInterval(()=>{},1<<30);
JS

alive() { kill -0 "$1" 2>/dev/null; }
port_held() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; }

run_case() { # $1=preload $2=label -> echoes LEAK | REAPED
  local preload="$1" label="$2" pidfile="$WORK/child.pid"; rm -f "$pidfile"
  "$NODE" "$WORK/parent.js" "$NODE" "$preload" "$WORK/server.cjs" "$pidfile" & local parent=$!
  local i=0
  while [ $i -lt 50 ] && { [ ! -s "$pidfile" ] || ! port_held; }; do sleep 0.1; i=$((i+1)); done
  local child; child="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -z "$child" ] || ! port_held; then
    kill -KILL "$parent" 2>/dev/null; [ -n "$child" ] && kill -KILL "$child" 2>/dev/null
    echo "ERROR: child never bound :$PORT for case '$label'"; return 1
  fi
  echo "  [$label] parent=$parent child=$child ppid=$(ps -o ppid= -p "$child" | tr -d ' ')  bind=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | tail -1 | awk '{print $9}')" >&2
  kill -KILL "$parent" 2>/dev/null; wait "$parent" 2>/dev/null   # crash: parent only
  local t=0
  while [ "$t" -lt "$((POLL_TIMEOUT*10))" ]; do
    if ! alive "$child" && ! port_held; then echo "REAPED"; return 0; fi
    sleep 0.1; t=$((t+1))
  done
  kill -KILL "$child" 2>/dev/null; echo "LEAK"; return 0
}

echo; echo "CASE 1 (no watchdog, expect LEAK):"
R1="$(run_case "$WORK/preload-nowatch.cjs" no-watchdog)" || { echo "$R1"; exit 2; }
echo "  result: $R1"
echo; echo "CASE 2 (watchdog, expect REAPED):"
R2="$(run_case "$WORK/preload-watch.cjs" watchdog)" || { echo "$R2"; exit 2; }
echo "  result: $R2"; echo

if port_held; then echo "FAIL: port $PORT still held after test"; exit 1; fi
if [ "$R1" = "LEAK" ] && [ "$R2" = "REAPED" ]; then
  echo "PASS: without the watchdog the child orphans and holds :$PORT;"
  echo "      with the reconstructed write_preload() output it self-exits on reparent and frees :$PORT."
  exit 0
fi
echo "FAIL: expected CASE1=LEAK CASE2=REAPED, got CASE1=$R1 CASE2=$R2"; exit 1
