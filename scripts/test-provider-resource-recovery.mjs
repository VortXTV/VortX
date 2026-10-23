import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

// This helper only extracts production declarations and hashes inputs. It never compiles.
const taskRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const fixtureRoot = path.join(taskRoot, 'app/Tests');
fs.mkdirSync(path.join(taskRoot, 'app/build'), {recursive:true});
const runRoot = fs.mkdtempSync(path.join(taskRoot, 'app/build/provider-resource-recovery.'));
const mode = process.argv[2] ?? 'current';
if (!['baseline', 'current'].includes(mode)) throw new Error('Expected baseline or current');
const baseline = '952f7b7e12e102f4b2acaea480e2906a47f5ad24';
const baselinePins = {
  'app/SourcesShared/CoreModels.swift': '7fab7bbf5ef23264686f04170ef486b246e0fa7e42135039b7a927dccd4a31ce',
  'app/SourcesShared/AppleCWSeasonRolloverPolicy.swift': 'a563b7a1c83f6e097c853554ddcee3264b17c856e023f45546002f5b4d698b12',
  'app/SourcesShared/VortxNativeRuntime.swift': 'abd6a0583f07395cf6d6a9bbc977c3589e38f0169b4a514fb97b1a91c58c1f7b',
  'app/SourcesShared/VortxResourceBridge.swift': 'cbfa8e7f675ae72332eacadb9a736633543fecf0c1e01234cb17d6ca5c170df6',
  'app/SourcesShared/VortxResourceProjection.swift': 'ba065b3a6abf2405961df88648ef99c3bb4ebb5b6212219b1107cd4d99e760b0',
  'app/SourcesShared/TrailerRequest.swift': '1b8e790bf82f48e17893858c67269ab874ec5ce25c8e5acfd1a0854a1dff1b67',
  'app/SourcesShared/UsenetStreamValidation.swift': 'a5927d59520cc3f328c60aa3b93ad148544a171146af445101551e36ac41ac3a',
  'app/SourcesShared/ProfileAddonPreferences.swift': '0ce7bf9382e5414ede809ffc6ed9f1e96d2c54440fddd016480f118634196361',
  'app/SourcesShared/DetailMetaRecoveryPolicy.swift': 'd92d9fc671a25e346d6b11074f8717625d3b5cacefc73143fe94c9bfef455c6b'
};
const sources = new Map();
const read = relative => {
  if (!sources.has(relative)) sources.set(relative, mode === 'baseline'
    ? execFileSync('git', ['-C', taskRoot, 'show', `${baseline}:${relative}`], {encoding: 'utf8'})
    : fs.readFileSync(path.join(taskRoot, relative), 'utf8'));
  return sources.get(relative);
};
function declaration(source, marker) {
  const start = source.indexOf(marker);
  if (start < 0 || source.indexOf(marker, start + marker.length) >= 0) throw new Error(`Nonunique marker: ${marker}`);
  const end = source.indexOf('\n}', start);
  if (end < 0) throw new Error(`Unterminated declaration: ${marker}`);
  return source.slice(start, end + 2);
}
const modelMarkers = [
  'struct CoreCWItem:', 'struct CoreLibState:', 'struct CoreBoardState:', 'struct CoreSearchSelected:',
  'struct CoreCatalogPage:', 'struct CoreResourceRequest:', 'struct CoreResourcePath:', 'enum CoreLoadable<',
  'struct CoreMeta:', 'struct CoreMetaSelection:', 'struct CoreMetaDetails:', 'struct CoreMetaEntry:',
  'struct CoreMetaItem:', 'struct CoreMetaBehaviorHints:', 'struct CoreLink:', 'struct CoreVideo:',
  'extension Array where Element == CoreVideo {', 'extension ISO8601DateFormatter {',
  'struct CoreStreamGroup:', 'struct PlayerLoadToken:', 'struct PlayerLoadProvenanceState {',
  'enum EpisodePlaybackIdentity {', 'struct CoreStream:', 'struct CoreStreamBehaviorHints:', 'struct CoreProxyHeaders:'
];
const episodeMarkers = ['struct AppleCWSeriesEpisode:', 'struct AppleCWSeriesInventory:',
  'enum AppleCWSeriesRefreshResult:', 'enum AppleCWSeriesTerminalDecision:', 'enum AppleCWSeriesTerminalPolicy {'];
const output = path.join(runRoot, mode);
fs.mkdirSync(output, {recursive: true});
const extraction = modelMarkers.map(marker => declaration(read('app/SourcesShared/CoreModels.swift'), marker));
extraction.push(...episodeMarkers.map(marker => declaration(read('app/SourcesShared/AppleCWSeasonRolloverPolicy.swift'), marker)));
fs.writeFileSync(path.join(output, 'Models.swift'), 'import Foundation\n' + extraction.join('\n\n') + '\n');
const inputNames = ['app/SourcesShared/VortxNativeRuntime.swift', 'app/SourcesShared/VortxResourceBridge.swift',
  'app/SourcesShared/VortxResourceProjection.swift', 'app/SourcesShared/TrailerRequest.swift',
  'app/SourcesShared/UsenetStreamValidation.swift', 'app/SourcesShared/ProfileAddonPreferences.swift',
  'app/SourcesShared/DetailMetaRecoveryPolicy.swift'];
const inputs = inputNames.map(relative => {
  const target = path.join(output, path.basename(relative));
  fs.writeFileSync(target, read(relative));
  return target;
});
inputs.push(path.join(output, 'Models.swift'), path.join(fixtureRoot, 'ProviderResourceHostStubs.swift'), path.join(fixtureRoot, 'ProviderResourceRecoveryTests.swift'));
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
if (mode === 'baseline') {
  if (sources.size !== Object.keys(baselinePins).length) throw new Error('Baseline source pin roster changed');
  for (const [relative, expected] of Object.entries(baselinePins)) {
    if (sha(sources.get(relative)) !== expected) throw new Error(`Baseline hash mismatch: ${relative}`);
  }
}
fs.writeFileSync(path.join(output, 'extraction-receipt.json'), JSON.stringify({
  mode, baseline, baselinePins, sourceHead: execFileSync('git', ['-C', taskRoot, 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim(),
  models: modelMarkers, episodePolicies: episodeMarkers,
  note: 'Complete production resource models and policies extracted verbatim; complete projection/resource/runtime/trailer sources. Controlled host profile/order stubs; gateway/debrid/runtime preference paths trap. No compiler/network/app/device/account operations.',
  productionHashes: Object.fromEntries([...sources].map(([name, value]) => [name, sha(value)])),
  fixtureHashes: Object.fromEntries(['ProviderResourceHostStubs.swift', 'ProviderResourceRecoveryTests.swift'].map(name => [name, sha(fs.readFileSync(path.join(fixtureRoot, name)))])),
  compilerInputs: inputs,
  compilerArguments: ['-j', '2', '-parse-as-library', '-warnings-as-errors', ...inputs, '-o', path.join(output, 'fixture')]
}, null, 2) + '\n');
process.stdout.write(`Prepared ${mode}: ${output}\n`);

const receipt = JSON.parse(fs.readFileSync(path.join(output, 'extraction-receipt.json'), 'utf8'));
const fileSHA = name => crypto.createHash('sha256').update(fs.readFileSync(name)).digest('hex');
const inputHashes = Object.fromEntries(receipt.compilerInputs.map(name => [name, fileSHA(name)]));
const compilation = spawnSync('xcrun', ['swiftc', ...receipt.compilerArguments], {encoding: 'utf8', maxBuffer: 16 * 1024 * 1024});
const compilerLog = (compilation.stdout ?? '') + (compilation.stderr ?? '');
fs.writeFileSync(path.join(output, 'compiler.log'), compilerLog);
let runtime = null;
if (compilation.status === 0) {
  runtime = spawnSync(path.join(output, 'fixture'), mode === 'baseline' ? ['--expect-regression'] : [], {encoding: 'utf8', maxBuffer: 16 * 1024 * 1024});
  fs.writeFileSync(path.join(output, 'runtime.log'), (runtime.stdout ?? '') + (runtime.stderr ?? ''));
}
const finalInputHashes = Object.fromEntries(receipt.compilerInputs.map(name => [name, fileSHA(name)]));
const unchangedInputs = Object.entries(inputHashes).every(([name, hash]) => finalInputHashes[name] === hash);
const passed = compilation.status === 0 && runtime?.status === 0 && unchangedInputs;
const outputs = ['compiler.log', 'runtime.log', 'fixture', 'extraction-receipt.json'].filter(name => fs.existsSync(path.join(output, name)));
fs.writeFileSync(path.join(output, 'result-receipt.json'), JSON.stringify({
  mode, sourceHead: receipt.sourceHead, baseline: receipt.baseline,
  compilerArguments: ['xcrun', 'swiftc', ...receipt.compilerArguments],
  compilerExitCode: compilation.status, compilerSignal: compilation.signal,
  runtimeArguments: mode === 'baseline' ? ['--expect-regression'] : [],
  runtimeExitCode: runtime?.status ?? null, runtimeSignal: runtime?.signal ?? null,
  unchangedInputs, inputHashes, finalInputHashes,
  outputHashes: Object.fromEntries(outputs.map(name => [name, fileSHA(path.join(output, name))])),
  passed, note: 'Generated production-source fixture only. No network, app, physical device, private engine, account or playback acceptance.'
}, null, 2) + '\n');
process.stdout.write(`${mode}: compiler=${compilation.status}, runtime=${runtime?.status ?? 'not-run'}, unchangedInputs=${unchangedInputs}, accepted=${passed}\n`);
process.stdout.write((runtime?.stdout ?? compilerLog).slice(-1800));
if (!passed) process.exitCode = 1;

