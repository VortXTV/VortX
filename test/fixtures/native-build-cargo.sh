#!/usr/bin/env bash
set -euo pipefail
test "$*" = 'build --locked --release -p vortx-streaming-server --target aarch64-apple-darwin'
printf '%s\n' "$*" > "${VORTX_TEST_CARGO_LOG:?}"
output="${CARGO_TARGET_DIR:-$PWD/target}/aarch64-apple-darwin/release/vortx-streaming-server"
mkdir -p "$(dirname "$output")"
printf '#!/usr/bin/env bash\nexit 0\n' > "$output"
chmod +x "$output"
