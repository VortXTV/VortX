#!/usr/bin/env node
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync, mkdtempSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve, join} from 'node:path';
process.chdir(resolve(import.meta.dirname, '..'));
const source = 'app/SourcesShared/VortXSyncManager.swift';
const current = readFileSync(source, 'utf8');
const manager = process.argv[2] === '--baseline-ref'
  ? execFileSync('git', ['show', `${process.argv[3]}:${source}`], {encoding: 'utf8'}) : readFileSync(source, 'utf8');
function block(text, start, end) {
  const from = text.indexOf(start), to = text.indexOf(end, from);
  assert(from >= 0 && to > from, `missing source block ${start}`);
  return text.slice(from, to + end.length);
}
const method = start => block(manager, start, '\n    }');
const json = block(readFileSync('app/SourcesShared/VortxResourceBridge.swift', 'utf8'), 'indirect enum VortxJSON:', '\n}');
const error = block(readFileSync('app/SourcesShared/VortxNativeRuntime.swift', 'utf8'), 'enum VortxNativeError:', '\n}');
const host = readFileSync('app/SourcesShared/VortxNativeHostPreferences.swift', 'utf8');
const hostLines = ['    static let maxClock:', '    struct Register:', '    static func validActor('].map(prefix => {
  const line = host.split('\n').find(value => value.startsWith(prefix)); assert(line); return line;
});
const providerStart = manager.indexOf('            providers = try persistMergedNativeProviders(providers, capture: capture)', manager.indexOf('    func syncDown('));
const providerEnd = manager.indexOf('            let mirrored = try mirrorNativeProviderKeys', providerStart);
assert(providerStart >= 0 && providerEnd > providerStart);
const methods = ['    private func mergedNativeProviderState(', '    private func mirrorNativeProviderKeys(',
  '    private func persistMergedNativeProviders(', '    private func acknowledgeNativeProviders(', '    func nativeMutationDidCommit('].map(method).join('\n')
  + '\n' + current.split('\n').find(line => line.includes('private enum PushOutcome'))
  + '\n' + block(current, '    private func pushSyncDocAt(', '\n    }');
const projection = ['            doc["nativeProviderCredentials"] =', '            doc["apiKeys"] = try mirrorNativeProviderKeys']
  .map(prefix => { const line = current.split('\n').find(line => line.startsWith(prefix)); assert(line); return line; }).join('\n');
mkdirSync('app/build', {recursive: true});
const directory = mkdtempSync('app/build/native-provider-rollback.');
const fixture = readFileSync('app/Tests/NativeProviderRollbackTests.swift', 'utf8');
const output = join(directory, 'ProductionProviderJoin.swift');
writeFileSync(output, [json, error, `struct VortxNativeHostPreferences {\n${hostLines.join('\n')}\n}`, fixture
  .replace('        /* PRODUCTION_PROVIDER_PULL_JOIN */', manager.slice(providerStart, providerEnd))
  .replace('        /* PRODUCTION_PROVIDER_EXPORT */', projection)
  .replace('    /* PRODUCTION_PROVIDER_METHODS */', methods)].join('\n'));
// Foundation-only public carrier/method extraction: no SDK, ABI library, Keychain or account.
execFileSync('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', '-j', '1', '-num-threads', '1',
  '-D', 'VORTX_NATIVE_DATA_ENGINE', 'app/SourcesShared/SyncDocumentRevisionPolicy.swift', 'app/SourcesShared/SyncBackupUploadFailure.swift',
  'app/SourcesShared/VortxNativeProviderCredentials.swift', 'app/SourcesShared/NativeForegroundSyncPolicy.swift', output,
  '-o', join(directory, 'checks')], {stdio: 'inherit'});
execFileSync(join(directory, 'checks'), [], {stdio: 'inherit'});
console.log(`Retained actual provider-pull-join fixture: ${resolve(directory)}`);
