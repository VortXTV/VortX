#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
run_dir=$(mktemp -d "$PWD/app/build/addon-selfhosted.XXXXXX")
node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const guard = readFileSync('app/SourcesShared/AddonURLGuard.swift', 'utf8');
const health = readFileSync('app/SourcesShared/AddonsView.swift', 'utf8');
const pairing = readFileSync('app/SourcesShared/AddonPairingProtocol.swift', 'utf8');
assert(pairing.includes('static let maxManifestURLBytes = 2048'), 'test URL cap matches production');
assert(guard.includes('context: .manifest, access: .addon(origin: url)'), 'install/preview use selected endpoint');
assert(guard.includes('access: AccessScope = .publicNetwork'), 'public resource requests remain strict');
assert(guard.includes('await validate(current, access: access)') &&
       guard.includes('await validate(finalURL, access: access)'), 'redirect/final scope retained');
assert(guard.includes('session.bytes(for: request)') && guard.includes('canAcceptBody(currentBytes:'), 'bounded transport retained');
assert(guard.includes('forHTTPHeaderField: "User-Agent"'), 'CDN-compatible UA retained for health');
assert(health.includes('access: .addon(origin: url), timeout: timeout') &&
       health.includes('static let timeout: TimeInterval = 6'), 'private health uses bounded six-second transport');
console.log('PASS self-hosted install/preview/health consumer wiring');
NODE
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -j 1 -num-threads 1 app/SourcesShared/AddonURLGuard.swift \
  app/Tests/AddonSelfHostedTests.swift -o "$run_dir/checks"
"$run_dir/checks"
printf 'Retained self-hosted checks: %s\n' "$run_dir"
