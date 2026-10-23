#!/usr/bin/env bash
set -euo pipefail

retry_packet_dir="$(cd "$(dirname "$0")" && pwd)"
retry_source_root="${1:?Pass the exact source repository root}"
retry_receipt_parent="${2:-$retry_source_root/app/build}"
mkdir -p "$retry_receipt_parent"
retry_test_path="$retry_packet_dir/NativeWatchedRetryTests.swift"
if [[ ! -f "$retry_test_path" ]]; then
  retry_test_path="$retry_source_root/app/Tests/NativeWatchedRetryTests.swift"
fi
test -f "$retry_source_root/app/SourcesShared/VortXSyncManager.swift"
test -f "$retry_source_root/app/Tests/AccountRestoreHandoffTests.swift"
test -f "$retry_test_path"
retry_receipt="$(mktemp -d "$retry_receipt_parent/watched-retry.XXXXXX")"

node --input-type=module - "$retry_source_root" "$retry_receipt" <<'NODE'
import {readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
const root = resolve(process.argv[2]), directory = process.argv[3];
function extract(source, signature) {
  const begin = source.indexOf(signature);
  if (begin < 0 || source.indexOf(signature, begin + signature.length) >= 0)
    throw new Error(`Missing or ambiguous declaration: ${signature}`);
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
  throw new Error(`Unterminated declaration: ${signature}`);
}
const managerPath = resolve(root, 'app/SourcesShared/VortXSyncManager.swift');
const policyPath = resolve(root, 'app/SourcesShared/NativeForegroundSyncPolicy.swift');
const statePath = resolve(root, 'app/SourcesShared/MoveSeeding.swift');
const fixturePath = resolve(root, 'app/Tests/AccountRestoreHandoffTests.swift');
const noticePath = resolve(root, 'app/SourcesShared/NativeWatchedMigrationNotice.swift');
const manager = readFileSync(managerPath, 'utf8');
const methods = [
  'func retryNativeWatchedMigration() async',
  'func retryAccountRestore() async -> Bool',
  'func restoreAccountDocIfNeeded(credentialCapture suppliedCapture: CredentialScopeRegistry.Capture? = nil) async -> Bool',
].map(signature => ({signature, bytes: extract(manager, signature)}));
const state = extract(readFileSync(statePath, 'utf8'), 'enum AccountRestoreState: Equatable, Sendable');
const backoff = extract(readFileSync(policyPath, 'utf8'), 'struct RecoveryBackoff: Equatable');
const fixtures = readFileSync(fixturePath, 'utf8');
const mainMarker = '@main @MainActor enum AccountRestoreHandoffTests';
const fixtureEnd = fixtures.indexOf(mainMarker);
if (fixtureEnd < 0 || fixtures.indexOf(mainMarker, fixtureEnd + 1) >= 0) throw new Error('Fixture boundary moved');
writeFileSync(`${directory}/RestoreDependencies.swift`, fixtures.slice(0, fixtureEnd));
writeFileSync(`${directory}/ActualRetryMethods.swift`, `import Foundation\n${state}\nenum NativeForegroundSyncPolicy {\n${backoff}\n}\n@MainActor extension RestoreManagerFixture {\n${methods.map(x => x.bytes).join('\n')}\n}\n`);
if (!readFileSync(noticePath, 'utf8').includes('await sync.retryNativeWatchedMigration()'))
  throw new Error('Saved-history notice no longer invokes the tested retry boundary');
writeFileSync(`${directory}/source-receipt.json`, JSON.stringify({sourceRoot: root,
  productionMethods: methods.map(x => ({signature: x.signature,
    sha256: createHash('sha256').update(x.bytes).digest('hex'), transformations: []})),
  inputFiles: [managerPath, policyPath, statePath, fixturePath, noticePath].map(path => ({path,
    sha256: createHash('sha256').update(readFileSync(path)).digest('hex')})),
  limitations: ['inert mount/pull dependencies', 'real restore handoff and actual retry methods',
    'no app/JNI/account/device/provider/metadata network validation'],
}, null, 2) + '\n');
console.log(`Actual methods extracted unchanged from ${managerPath}`);
NODE

nice -n 15 xcrun swiftc -j 1 -num-threads 1 -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -D VORTX_NATIVE_DATA_ENGINE "$retry_receipt/RestoreDependencies.swift" \
  "$retry_receipt/ActualRetryMethods.swift" "$retry_test_path" \
  -o "$retry_receipt/watched-retry-tests" 2>&1 | tee "$retry_receipt/compile.log"
nice -n 15 "$retry_receipt/watched-retry-tests" 2>&1 | tee "$retry_receipt/checks.log"
printf '%s\n' "Retained actual-method retry receipt: $retry_receipt"
