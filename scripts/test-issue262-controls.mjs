#!/usr/bin/env node
// Exact production control extraction; inert Swift fixtures only, never an app/package build.
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp } from 'node:fs/promises';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
process.chdir(root);
const args = process.argv.slice(2);
let baselineRef = null, selectedMode = 'all';
for (let index = 0; index < args.length; index += 2) {
  const option = args[index], value = args[index + 1];
  assert(value !== undefined, `missing value for ${option}`);
  if (option === '--baseline-ref') { assert.equal(baselineRef, null); baselineRef = value; }
  else if (option === '--mode') { assert(['native', 'legacy', 'all'].includes(value)); selectedMode = value; }
  else { assert.fail(`unknown option ${option}`); }
}
const modes = selectedMode === 'all' ? ['native', 'legacy'] : [selectedMode];
const read = path => baselineRef !== null
  ? execFileSync('git', ['show', `${baselineRef}:${path}`], { encoding: 'utf8' })
  : readFile(path, 'utf8');
const paths = {
  qr: 'app/SourcesShared/LinkLoginView.swift', account: 'app/SourcesShared/StremioAccount.swift',
  manager: 'app/SourcesShared/VortXSyncManager.swift', settings: 'app/SourcesShared/SyncSettingsView.swift',
  backup: 'app/SourcesTV/BackupExportView.swift', card: 'app/SourcesShared/StremioConnectCard.swift',
  tvLogin: 'app/SourcesTV/LoginView.swift', iosLogin: 'app/SourcesiOS/iOSSignInView.swift'
};
const inputs = Object.fromEntries(await Promise.all(Object.entries(paths).map(async ([key, path]) => [key, await read(path)])));
function member(source, signature) {
  const markerStart = source.indexOf(signature);
  assert(markerStart >= 0 && source.indexOf(signature, markerStart + signature.length) < 0, `missing/ambiguous ${signature}`);
  let start = source.lastIndexOf('\n', markerStart - 1) + 1;
  // Actor/availability attributes are part of the production declaration, not fixture decoration.
  while (start > 0) {
    const previousStart = source.lastIndexOf('\n', start - 2) + 1;
    if (!source.slice(previousStart, start).trim().startsWith('@')) break;
    start = previousStart;
  }
  let depth = 0, opened = false, state = 'code', escaped = false, blockDepth = 0;
  for (let i = markerStart; i < source.length; i++) {
    const c = source[i], next = source[i + 1];
    if (state === 'line') { if (c === '\n') state = 'code'; continue; }
    if (state === 'block') {
      if (c === '/' && next === '*') { blockDepth++; i++; }
      else if (c === '*' && next === '/') { if (--blockDepth === 0) state = 'code'; i++; }
      continue;
    }
    if (state === 'string') {
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === '"') state = 'code';
      continue;
    }
    if (c === '/' && next === '/') { state = 'line'; i++; continue; }
    if (c === '/' && next === '*') { state = 'block'; blockDepth = 1; i++; continue; }
    if (c === '"') { state = 'string'; continue; }
    if (c === '{') { opened = true; depth++; }
    if (c === '}' && opened && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`unterminated ${signature}`);
}
function nativeActive(source) {
  const stack = []; let active = true; const result = [];
  for (const line of source.split('\n')) {
    const token = line.trim();
    if (token.startsWith('#if ')) {
      const condition = token.slice(4);
      assert(['VORTX_NATIVE_DATA_ENGINE', '!VORTX_NATIVE_DATA_ENGINE'].includes(condition), `unhandled UI condition ${condition}`);
      const value = condition === 'VORTX_NATIVE_DATA_ENGINE';
      stack.push({ parent: active, value }); active = active && value;
    } else if (token === '#else') {
      const top = stack.at(-1); assert(top); active = top.parent && !top.value;
    } else if (token === '#endif') { const top = stack.pop(); assert(top); active = top.parent; }
    else if (active) result.push(line);
  }
  assert.equal(stack.length, 0);
  return result.join('\n');
}
// Only inspect the alert body, not unrelated platform-specific sheet/form code.
for (const [key, start, end] of [
  ['settings', '.alert("Sync conflict"', '\n        .task'],
  ['backup', '.alert("This account already has data"', '\n    private func start()']
]) {
  const source = inputs[key], lower = source.indexOf(start), upper = source.indexOf(end, lower);
  assert(lower >= 0 && upper > lower);
  const active = nativeActive(source.slice(lower, upper));
  assert(!active.includes('keepThisDeviceOverridingAccount()'), `${key} native conflict exposes unsupported override`);
  assert(active.includes('mergeBoth()') && active.includes('useAccountData()'), `${key} loses supported choices`);
}
const extracted = {
  qr: ['private func start()', 'private func stop()'].map(s => member(inputs.qr, s)).join('\n'),
  account: ['private struct AuthOperationContext:', 'private func captureAuthOperationContext()',
    'private func beginAuthOperation()', 'private func authOperationStillCurrent(',
    'func captureLinkLoginAdmission()', 'func reloadForActiveProfile(', 'enum LinkSignInOutcome:', 'func signInWithAuthKey(',
    'func retryCurrentConnection()']
    .map(s => member(inputs.account, s)).join('\n'),
  override: member(inputs.manager, '@discardableResult func keepThisDeviceOverridingAccount()'),
  tv: member(inputs.tvLogin, 'private func handleStremioSignIn('),
  ios: member(inputs.iosLogin, 'private func handleStremioSignIn('),
  card: ['private func handleStremioSignIn(', 'private func refreshStremioImport()', 'private func cancelStremioImport()']
    .map(s => member(inputs.card, s)).join('\n')
};
for (const key of ['card', 'tvLogin', 'iosLogin']) {
  const observer = key === 'tvLogin' ? '.onChange' : '.onValueChange';
  const boundaryCallback = member(inputs[key], observer + '(of: account.credentialBoundaryGeneration)');
  assert(boundaryCallback.includes('handleStremioSignIn(signedIn: account.isSignedIn)'), `${key} needs a wired true-to-true retry success event`);
  const signedCallback = member(inputs[key], key === 'iosLogin'
    ? '.onValueChange(of: account.isSignedIn)' : '.onReceive(account.$isSignedIn)');
  assert(signedCallback.includes('handleStremioSignIn(signedIn: signedIn)'), `${key} must preserve incoming published value`);
}
assert(inputs.card.includes('if connecting {') && inputs.card.includes('} else if account.isSignedIn {'), 'partial card must keep retry UI mounted');
assert(inputs.card.includes('Button("Retry connection")') && inputs.card.includes('if let warning = account.signInError'), 'partial saved connection needs a visible warning and retry');
const signedInCard = inputs.card.slice(inputs.card.indexOf('} else if account.isSignedIn {'), inputs.card.indexOf('\n            } else {', inputs.card.indexOf('} else if account.isSignedIn {')));
assert(signedInCard.includes('"Refresh Stremio import"') && signedInCard.includes('refreshStremioImport()'), 'saved connection needs an explicit import action after its in-memory warning is lost');
assert(inputs.card.includes('.onDisappear { cancelStremioImport() }'), 'unmounted import control must retire its original task');
const template = await readFile('app/Tests/Issue262ControlTests.swift', 'utf8');
let combined = template;
for (const [key, source] of Object.entries(extracted)) {
  const marker = `/* PRODUCTION_${key.toUpperCase()} */`;
  assert(combined.includes(marker)); combined = combined.replace(marker, source);
}
assert(inputs.qr.includes('.disabled(busy || signingIn)'), 'refresh must not overlap credential installation');
await mkdir('app/build', { recursive: true });
const directory = await mkdtemp(join(root, 'app/build/issue262-controls.'));
const swift = join(directory, 'Combined.swift');
await writeFile(swift, combined);
await writeFile(join(directory, 'source-receipt.json'), JSON.stringify({
  sourceRoot: root, baseline: baselineRef, modes,
  inputs: Object.fromEntries(Object.entries(inputs).map(([key, source]) => [paths[key], createHash('sha256').update(source).digest('hex')])),
  extracts: Object.fromEntries(Object.entries(extracted).map(([key, source]) => [key, createHash('sha256').update(source).digest('hex')])),
  methodTransformations: [],
  boundary: 'Exact methods, inert dependency graph and accelerated polling clock. No native SDK, Keychain, defaults, HTTP, UI runtime, app build, installation or launch.'
}, null, 2) + '\n');
for (const mode of modes) {
  const output = join(directory, `${mode}-controls`);
  execFileSync('xcrun', ['swiftc', '-j', '1', '-num-threads', '1', '-swift-version', '6', '-parse-as-library', '-strict-concurrency=complete',
    '-warnings-as-errors', ...(mode === 'native' ? ['-D', 'VORTX_NATIVE_DATA_ENGINE'] : []), swift, '-o', output], { stdio: 'inherit' });
  const result = spawnSync(output, [], { encoding: 'utf8' });
  const log = (result.stdout ?? '') + (result.stderr ?? '');
  await writeFile(join(directory, `${mode}.log`), log); process.stdout.write(log);
  assert.equal(result.signal, null); assert.equal(result.status, 0, `${mode} control fixture failed`);
}
console.log(`Retained #262 control receipts: ${directory}`);
