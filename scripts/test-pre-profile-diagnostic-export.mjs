#!/usr/bin/env node
// Source availability contracts plus exact Swift control extraction; never an app build or live export.
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
process.chdir(root);
const paths = [
  'app/SourcesShared/DiagnosticLogExportButton.swift', 'app/SourcesShared/VXDiagExport.swift',
  'app/SourcesShared/ProfilesView.swift', 'app/SourcesShared/SyncSettingsView.swift',
  'app/SourcesTV/LoginView.swift', 'app/SourcesiOS/iOSSignInView.swift',
  'app/SourcesTV/BackupImportView.swift', 'app/SourcesTV/MoveSeedingNagTV.swift'
];
const sources = Object.fromEntries(await Promise.all(paths.map(async path => [path, await readFile(path, 'utf8')])));
const entry = sources[paths[0]], backend = sources[paths[1]], picker = sources[paths[2]];
function member(source, signature) {
  const start = source.indexOf(signature);
  assert(start >= 0 && source.indexOf(signature, start + signature.length) < 0, `missing/ambiguous ${signature}`);
  let depth = 0, opened = false, state = 'code', escaped = false, blockDepth = 0;
  for (let i = start; i < source.length; i++) {
    const c = source[i], next = source[i + 1];
    if (state === 'line') { if (c === '\n') state = 'code'; continue; }
    if (state === 'block') {
      if (c === '/' && next === '*') { blockDepth++; i++; }
      else if (c === '*' && next === '/') { if (--blockDepth === 0) state = 'code'; i++; }
      continue;
    }
    if (state === 'string') {
      if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') state = 'code';
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

const inset = member(picker, '.safeAreaInset(edge: .bottom)');
assert(inset.includes('DiagnosticLogExportButton()') && !inset.includes('profileAction.isRunning'));
assert(picker.indexOf('.safeAreaInset(edge: .bottom)') > picker.indexOf('.disabled(pinTarget != nil || profileAction.isRunning)'));
assert(inset.includes('.disabled(pinTarget != nil)') && inset.includes('.accessibilityHidden(pinTarget != nil)'));
// A PIN-protected profile keeps the whole-device log behind a profile unlock, except when loading failed.
assert(inset.includes('if exportAllowedBeforeProfile'));
const gate = member(picker, 'private var exportAllowedBeforeProfile: Bool');
assert(gate.includes('$0.pin != nil') && gate.includes('profileAction.errorMessage != nil') && gate.includes('accountRestoreState == .failed'));
// The shared call site also compiles in Lite/legacy shells. A lexical member extraction alone
// misses an enclosing #if that removes the whole declaration in those builds.
function requireSharedPickerMember(source, signature) {
  const offset = source.indexOf(signature);
  assert(offset >= 0, `missing ${signature}`);
  const conditions = [];
  for (const line of source.slice(0, offset).split('\n')) {
    const directive = line.match(/^\s*#(if|elseif|else|endif)\b(.*)$/);
    if (!directive) continue;
    if (directive[1] === 'if') conditions.push(directive[2]);
    else if (directive[1] === 'endif') conditions.pop();
    else if (directive[1] === 'elseif') conditions[conditions.length - 1] += directive[2];
  }
  assert(!conditions.some(condition => condition.includes('VORTX_NATIVE_DATA_ENGINE')),
    `${signature} must exist in both native and Lite/legacy shells`);
}
requireSharedPickerMember(picker, 'private var exportAllowedBeforeProfile: Bool');
requireSharedPickerMember(picker, '.safeAreaInset(edge: .bottom)');
const nativeOnlyGate = picker.replace('private var exportAllowedBeforeProfile: Bool',
  '#if VORTX_NATIVE_DATA_ENGINE\nprivate var exportAllowedBeforeProfile: Bool');
assert.throws(() => requireSharedPickerMember(nativeOnlyGate, 'private var exportAllowedBeforeProfile: Bool'),
  /must exist in both native and Lite\/legacy shells/);
for (const path of paths.slice(3)) assert(sources[path].includes('DiagnosticLogExportButton()'), `${path} missing export`);
for (const path of ['app/SourcesTV/LoginView.swift', 'app/SourcesTV/BackupImportView.swift']) {
  const scroll = member(sources[path], 'ScrollView');
  assert(scroll.includes('DiagnosticLogExportButton()'), `${path} export must remain reachable in a tall error layout`);
}
assert(member(sources[paths[3]], 'private var qrSignInSheet:').includes('DiagnosticLogExportButton()'));
const entryCode = entry.split('\n').filter(line => !line.trim().startsWith('//')).join('\n');
for (const forbidden of ['Keychain', 'CoreBridge', 'StremioAccount', 'VortXSyncManager', 'UserDefaults', '@AppStorage', 'VXProbe.enabled', 'VXProbe.logFileURL', 'consumeLogSnapshot']) {
  assert(!entryCode.includes(forbidden), `export must not depend on ${forbidden}`);
}
assert(entry.includes('FileRepresentation(exportedContentType: .plainText)') && entry.includes('VXDiagExport.exportBody().write('));
assert(entry.includes('ShareLink(item: PreProfileDiagnosticLogTransfer()'));
assert(entry.includes('preview: SharePreview("VortX diagnostic log")'));
assert(entry.includes('UUID().uuidString.lowercased()') && entry.includes('directory.appendingPathComponent("vortx-diag.log")'));
assert(member(entry, '.onDisappear').includes('session.stop()'));
assert(member(entry, '.onExitCommand').includes('dismiss()'));
assert(member(entry, '.task(id: retry)').includes('await session.prepare()'));
assert(member(backend, 'static func makeSession()').includes('VXDiagExport(presentationOwned: true)'));
assert(backend.includes('static let shared = VXDiagExport()') && backend.includes('private init(presentationOwned: Bool = false)'));
console.log('PASS pre-profile availability, lazy sanitized sharing, PIN and owned-session source contracts');

const extracts = {
  SESSION: '@MainActor\n' + member(entry, 'private final class DiagnosticLogExportSession:'),
  CANCELLATION: member(backend, 'private final class VXDiagExportStartCancellation:'),
  START: member(backend, 'func startAsync()'),
  STOP: member(backend, 'func stopOwnedSession()')
};
let fixture = await readFile('app/Tests/PreProfileDiagnosticExportTests.swift', 'utf8');
for (const [key, text] of Object.entries(extracts)) fixture = fixture.replace(`/* PRODUCTION_${key} */`, text);
assert(!fixture.includes('/* PRODUCTION_'));
await mkdir(join(root, 'app/build'), { recursive: true });
const output = await mkdtemp(join(root, 'app/build/pre-profile-diagnostic-export.'));
const swift = join(output, 'ExtractedControls.swift');
await writeFile(swift, fixture);
function run(name, command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 120_000 });
  const log = (result.stdout ?? '') + (result.stderr ?? '');
  if (log) process.stdout.write(log);
  return writeFile(join(output, `${name}.log`), log).then(() => {
    assert(!result.error, `${name}: ${result.error}`);
    assert.equal(result.status, 0, `${name} failed; retained at ${output}`);
  });
}
const binary = join(output, 'controls');
await run('compile-controls', 'xcrun', ['swiftc', '-j', '1', '-num-threads', '1', '-parse-as-library', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', swift, '-o', binary]);
await run('controls', binary, []);
for (const [name, tests, deps] of [
  ['channels', 'DiagnosticsChannelGateTests.swift', ['VXProbeRedaction.swift', 'VXDiagExportPolicy.swift']],
  ['transfer', 'VXDiagTransferPolicyTests.swift', ['VXProbeRedaction.swift', 'VXDiagExportPolicy.swift']],
  ['redaction', 'VXProbeRedactionTests.swift', ['VXProbeRedaction.swift']]
]) {
  const exe = join(output, name);
  await run(`compile-${name}`, 'xcrun', ['swiftc', '-j', '1', '-num-threads', '1', '-warnings-as-errors', ...deps.map(p => `app/SourcesShared/${p}`), `app/Tests/${tests}`, '-o', exe]);
  await run(name, exe, []);
}
const sha = text => createHash('sha256').update(text).digest('hex');
await writeFile(join(output, 'source-receipt.json'), JSON.stringify({
  sourceRoot: root, inputs: Object.fromEntries(paths.map(path => [path, sha(sources[path])])),
  verificationInputs: Object.fromEntries(await Promise.all([
    'scripts/test-pre-profile-diagnostic-export.mjs', 'app/Tests/PreProfileDiagnosticExportTests.swift',
    'app/Tests/DiagnosticsChannelGateTests.swift', 'app/Tests/VXDiagTransferPolicyTests.swift',
    'app/Tests/VXProbeRedactionTests.swift', 'app/SourcesShared/VXProbeRedaction.swift',
    'app/SourcesShared/VXDiagExportPolicy.swift'
  ].map(async path => [path, sha(await readFile(path, 'utf8'))]))),
  extracts: Object.fromEntries(Object.entries(extracts).map(([key, text]) => [key, sha(text)])),
  methodTransformations: [], boundary: 'Exact lifecycle/startup methods; inert listener/image/observable collaborators and accelerated worker clock. Redaction/transfer are pure production policy. No account, Keychain, live cache, HTTP, UI runtime, app build or launch.'
}, null, 2) + '\n');
console.log(`Retained export checks: ${output}`);
