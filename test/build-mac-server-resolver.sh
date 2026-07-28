#!/usr/bin/env bash
set -euo pipefail

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vortx-mac-server-resolver.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

REPO="$ROOT/repo"
ENGINE_HOME="$ROOT/engine-home"
FAKE_BIN="$ROOT/bin"
mkdir -p "$REPO/scripts" "$ENGINE_HOME/.cargo" "$ENGINE_HOME/vortx-engine/vortx-core/crates/streaming-server" "$FAKE_BIN"
cp scripts/build-mac-server.sh "$REPO/scripts/build-mac-server.sh"
: > "$ENGINE_HOME/.cargo/env"
: > "$ENGINE_HOME/vortx-engine/vortx-core/crates/streaming-server/Cargo.toml"

cat > "$FAKE_BIN/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

EXPECTED="build --release -p vortx-streaming-server --target aarch64-apple-darwin"
if [ "$*" != "$EXPECTED" ]; then
    echo "unexpected cargo invocation: $*" >&2
    exit 1
fi

OUT="target/aarch64-apple-darwin/release/vortx-streaming-server"
mkdir -p "$(dirname "$OUT")"
printf '#!/usr/bin/env bash\nexit 0\n' > "$OUT"
chmod +x "$OUT"
EOF
chmod +x "$FAKE_BIN/cargo"

SUCCESS_LOG="$ROOT/success.log"
SUCCESS_ERROR_LOG="$ROOT/success-error.log"
if ! HOME="$ENGINE_HOME" PATH="$FAKE_BIN:$PATH" bash "$REPO/scripts/build-mac-server.sh" > "$SUCCESS_LOG" 2> "$SUCCESS_ERROR_LOG"; then
    cat "$SUCCESS_LOG" >&2
    cat "$SUCCESS_ERROR_LOG" >&2
    exit 1
fi
grep -Fq "engine workspace: $ENGINE_HOME/vortx-engine/vortx-core" "$SUCCESS_LOG"
test -x "$REPO/app/Vendor/vortx-streaming-server"

MISSING_REPO="$ROOT/missing-repo"
MISSING_HOME="$ROOT/missing-home"
mkdir -p "$MISSING_REPO/scripts" "$MISSING_HOME"
cp scripts/build-mac-server.sh "$MISSING_REPO/scripts/build-mac-server.sh"

FAILURE_LOG="$ROOT/failure.log"
set +e
HOME="$MISSING_HOME" PATH="$FAKE_BIN:$PATH" bash "$MISSING_REPO/scripts/build-mac-server.sh" > /dev/null 2> "$FAILURE_LOG"
STATUS=$?
set -e

if [ "$STATUS" -eq 0 ]; then
    echo "missing engine checkout unexpectedly resolved" >&2
    exit 1
fi

grep -Fq 'git clone https://github.com/VortXTV/vortx-core.git ~/vortx-engine' "$FAILURE_LOG"
if grep -Fq "$MISSING_HOME/vortx-core" "$FAILURE_LOG"; then
    echo "failure diagnostic still advertises the invalid direct checkout" >&2
    exit 1
fi
if grep -Fq "vortx-engine-backup" "$FAILURE_LOG"; then
    echo "failure diagnostic still advertises the stale backup" >&2
    exit 1
fi

echo "build-mac-server resolver checks passed"
