#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if (( $# > 1 )); then
  print -u2 'Usage: scripts/test-account-restore-handoff.sh [exact-source-repository-root]'
  exit 2
fi
source_root="${1:-$PWD}"
[[ -f "$source_root/app/SourcesShared/VortXSyncManager.swift" ]] || {
  print -u2 'Source root must contain app/SourcesShared/VortXSyncManager.swift'
  exit 2
}
mkdir -p app/build
receipt="$PWD/app/build/account-restore-handoff.$$.${RANDOM}"
mkdir "$receipt"

# The production method is extracted byte-for-byte. Only its surrounding state, credential/native
# dependencies, held pull/mount results and Task/backoff clock are inert fixtures. No account manager,
# app, server, Keychain, preferences store, engine, network or player is constructed.
node --input-type=module - "$source_root" "$receipt" <<'NODE'
import {readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
const root = resolve(process.argv[2]), directory = process.argv[3];
function extract(source, signature) {
  const begin = source.indexOf(signature);
  if (begin < 0 || source.indexOf(signature, begin + signature.length) >= 0)
    throw new Error(`Missing or ambiguous production declaration: ${signature}`);
  let depth = 0, opened = false, state = 'code', escaped = false;
  for (let i = begin; i < source.length; i++) {
    const c = source[i], next = source[i + 1];
    if (state === 'line') { if (c === '\n') state = 'code'; continue; }
    if (state === 'block') { if (c === '*' && next === '/') { state = 'code'; i++; } continue; }
    if (state === 'string') {
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === '"') state = 'code';
      continue;
    }
    if (c === '/' && next === '/') { state = 'line'; i++; continue; }
    if (c === '/' && next === '*') { state = 'block'; i++; continue; }
    if (c === '"') { state = 'string'; continue; }
    if (c === '{') { depth++; opened = true; }
    if (c === '}' && opened && --depth === 0) return source.slice(begin, i + 1);
  }
  throw new Error(`Unterminated production declaration: ${signature}`);
}
const managerPath = resolve(root, 'app/SourcesShared/VortXSyncManager.swift');
const source = readFileSync(managerPath, 'utf8');
const method = extract(source, 'func restoreAccountDocIfNeeded(credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil) async -> Bool');
const statePath = resolve(root, 'app/SourcesShared/MoveSeeding.swift');
const stateSource = readFileSync(statePath, 'utf8');
const state = extract(stateSource, 'enum AccountRestoreState: Equatable, Sendable');
writeFileSync(`${directory}/ProductionRestoreAccountDoc.swift`, `import Foundation
${state}
@MainActor extension RestoreManagerFixture {
    @discardableResult
    ${method}
}
`);
writeFileSync(`${directory}/source-receipt.json`, JSON.stringify({
  sourceRoot: root, sourcePath: managerPath,
  sourceSHA256: createHash('sha256').update(source).digest('hex'),
  extractedMethodSHA256: createHash('sha256').update(method).digest('hex'),
  stateSHA256: createHash('sha256').update(stateSource).digest('hex'),
  methodTransformations: [],
  fixtureDependencies: ['in-memory state', 'credential capture', 'native certification', 'held pull/mount', 'Task clock'],
}, null, 2) + '\n');
console.log(`Extracted actual restore method from ${managerPath}`);
NODE

xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -D VORTX_NATIVE_DATA_ENGINE "$receipt/ProductionRestoreAccountDoc.swift" \
  app/Tests/AccountRestoreHandoffTests.swift -o "$receipt/restore-handoff-tests"
"$receipt/restore-handoff-tests" | tee "$receipt/checks.log"
printf '%s\n' "Retained restore-handoff receipt: $receipt"
