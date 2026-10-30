#!/bin/zsh
set -euo pipefail
if (( $# != 2 )); then
  print -u2 'Usage: test-auth-recovery.sh <exact-source-root> <scratch-directory>'
  exit 2
fi
source_root="$1"
scratch="$2"
[[ -f "$source_root/app/SourcesShared/VortXSyncManager.swift" ]] || exit 2
mkdir -p "$scratch"
node --input-type=module - "$source_root" "$scratch" "$(dirname "$0")/AuthRecoveryTests.swift" <<'NODE'
import {readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
const root = resolve(process.argv[2]), out = resolve(process.argv[3]);
function extract(source, signature) {
  const start = source.indexOf(signature);
  if (start < 0 || source.indexOf(signature, start + signature.length) >= 0)
    throw new Error(`Missing or ambiguous production declaration: ${signature}`);
  let depth = 0, opened = false, state = 'code', escaped = false;
  for (let i = start; i < source.length; i++) {
    const c = source[i], n = source[i + 1];
    if (state === 'line') { if (c === '\n') state = 'code'; continue; }
    if (state === 'block') { if (c === '*' && n === '/') { state = 'code'; i++; } continue; }
    if (state === 'string') {
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === '"') state = 'code';
      continue;
    }
    if (c === '/' && n === '/') { state = 'line'; i++; continue; }
    if (c === '/' && n === '*') { state = 'block'; i++; continue; }
    if (c === '"') { state = 'string'; continue; }
    if (c === '{') { depth++; opened = true; }
    if (c === '}' && opened && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`Unterminated declaration: ${signature}`);
}
const managerPath = resolve(root, 'app/SourcesShared/VortXSyncManager.swift');
const manager = readFileSync(managerPath, 'utf8');
const statePath = resolve(root, 'app/SourcesShared/MoveSeeding.swift');
const stateSource = readFileSync(statePath, 'utf8');
const expected = {
  manager: '8c41d90d0040a82a34e46816df759c366dc2bfbcccd0262594c1c9d8e40320d8',
  state: '7f5da321223973f4eec2f1c4af4cbceabc7cdf6902d9daed69654c0f12064fe5',
};
const actual = {
  manager: createHash('sha256').update(manager).digest('hex'),
  state: createHash('sha256').update(stateSource).digest('hex'),
};
if (actual.manager !== expected.manager || actual.state !== expected.state)
  throw new Error(`Source pin mismatch: ${JSON.stringify(actual)}`);
const extracted = {
  state: extract(stateSource, 'enum AccountRestoreState: Equatable, Sendable'),
  pullCase: extract(manager, 'private enum VersionedPull'),
  documentVersion: extract(manager, 'private static func documentVersion(_ raw: Any?) -> Int?'),
  reconnect: extract(manager, 'var accountReconnectRequired: Bool'),
  reconnectForCapture: extract(manager, 'private func accountReconnectRequired(for capture: CredentialScopeRegistry.Capture)'),
  clearReconnect: extract(manager, 'private func clearAccountReconnectFailure(for capture: CredentialScopeRegistry.Capture)'),
  pull: extract(manager, 'private func pullDocVersionedResult(credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil,'),
  adopt: extract(manager, 'private func adopt(\n        token: String,\n        account acct: [String: Any],\n        dataKey: Data,'),
  restore: extract(manager, 'func restoreAccountDocIfNeeded(credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil) async -> Bool'),
};
const testsPath = resolve(process.argv[4]);
const testSource = readFileSync(testsPath, 'utf8');
const tests = testSource.replace(/^import Foundation\s*/, '');
const generated = `import Foundation\n${extracted.state}\n${extracted.pullCase}\n@MainActor extension AuthRecoveryFixture {\n${extracted.documentVersion}\n${extracted.reconnect}\n${extracted.reconnectForCapture}\n${extracted.clearReconnect}\n${extracted.pull}\n${extracted.adopt}\n${extracted.restore}\n}\n${tests}`;
writeFileSync(resolve(out, 'ProductionAuthRecovery.swift'), generated);
writeFileSync(resolve(out, 'source-receipt.json'), JSON.stringify({
  sourceRoot: root,
  productionPath: managerPath,
  productionSHA256: actual.manager,
  moveSeedingSHA256: actual.state,
  fixtureSHA256: createHash('sha256').update(testSource).digest('hex'),
  extractedSHA256: Object.fromEntries(Object.entries(extracted).map(([key, value]) => [key, createHash('sha256').update(value).digest('hex')])),
  transformations: [],
  fixtureReplaces: ['HTTP transport result producer', 'credential registry storage', 'native ingress/decryption and apply acknowledgements', 'owner acquisition/retry boundary', 'persist/Keychain certification result'],
  fixtureDoesNotReplace: ['production HTTP status classification', 'production reconnect marker fencing', 'production restore retry and ready-state logic'],
}, null, 2) + '\n');
NODE
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
  "$scratch/ProductionAuthRecovery.swift" \
  -o "$scratch/auth-recovery-tests"
"$scratch/auth-recovery-tests"
