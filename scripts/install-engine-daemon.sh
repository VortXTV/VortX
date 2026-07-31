#!/bin/bash
#
# Install (or remove) the VortX engine host as a macOS LaunchAgent.
#
# WHAT THIS GIVES YOU. A VortX engine server that starts when you log in, keeps running with no window and no
# dock icon, survives a crash, and serves your Apple TV whether or not you ever open the VortX app. It is the
# same binary the app is, run with --engine-daemon, which is how a great many macOS background services ship
# and means the server and the app can never drift apart in version or behaviour.
#
# A LaunchAgent, not a LaunchDaemon, and that is deliberate. The engine reads the logged-in user's VortX
# settings, their paired-device tokens and their Application Support spool. A LaunchDaemon runs as root before
# anyone logs in and would have access to none of it, so it would serve an empty configuration.
#
# Usage:
#   ./scripts/install-engine-daemon.sh                 install, using /Applications/VortX.app
#   ./scripts/install-engine-daemon.sh /path/VortX.app install, using an explicit app bundle
#   ./scripts/install-engine-daemon.sh --uninstall     stop and remove
#   ./scripts/install-engine-daemon.sh --status        show whether it is loaded and running

set -euo pipefail

LABEL="tv.vortx.engine"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOGDIR="$HOME/Library/Logs/VortX"
UID_NUM="$(id -u)"

status() {
  echo "label:  ${LABEL}"
  echo "plist:  ${PLIST}"
  if [ -f "$PLIST" ]; then echo "state:  installed"; else echo "state:  not installed"; fi
  launchctl print "gui/${UID_NUM}/${LABEL}" 2>/dev/null | sed -n '1,12p' || echo "runtime: not loaded"
  echo
  echo "logs:   ${LOGDIR}/engine.log"
  echo "        ${LOGDIR}/engine.err.log"
}

uninstall() {
  launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
  rm -f "$PLIST"
  echo "VortX engine daemon removed. Your pairings and settings are untouched."
  echo "The app's own 'Act as the engine for this network' toggle still works."
}

case "${1:-}" in
  --uninstall|-u) uninstall; exit 0 ;;
  --status|-s)    status;    exit 0 ;;
esac

APP="${1:-/Applications/VortX.app}"
BIN="${APP}/Contents/MacOS/VortX"

if [ ! -x "$BIN" ]; then
  echo "error: no VortX executable at ${BIN}" >&2
  echo "Pass the path to VortX.app, for example:" >&2
  echo "  ./scripts/install-engine-daemon.sh ~/Applications/VortX.app" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$LOGDIR"

# KeepAlive with SuccessfulExit=false, not a bare "true": the daemon exits 70 when its control port cannot be
# bound, and that is a configuration error a human has to fix. Restarting into it forever would spin, bury the
# real message under thousands of duplicates, and burn a core doing it. A clean exit 0 (a deliberate stop) is
# also left alone for the same reason.
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${BIN}</string>
		<string>--engine-daemon</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Adaptive</string>
	<key>StandardOutPath</key>
	<string>${LOGDIR}/engine.log</string>
	<key>StandardErrorPath</key>
	<string>${LOGDIR}/engine.err.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>VORTX_ENGINE_DAEMON</key>
		<string>1</string>
	</dict>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "$PLIST"
launchctl kickstart -k "gui/${UID_NUM}/${LABEL}"

echo "VortX engine daemon installed and started."
echo
echo "  app:    ${APP}"
echo "  logs:   ${LOGDIR}/engine.err.log"
echo "  config: ~/Library/Application Support/VortX/engine.json   (optional)"
echo
echo "Optional config file, every key optional:"
echo '  { "name": "Studio Mac", "port": 11471, "retainFullTimeline": true }'
echo
echo "Next: open VortX on this Mac, turn on pairing to get a 6 digit code, then pair the Apple TV."
echo "Pairing needs the app once. After that the daemon serves on its own."
echo
sleep 1
tail -n 12 "${LOGDIR}/engine.err.log" 2>/dev/null || true
