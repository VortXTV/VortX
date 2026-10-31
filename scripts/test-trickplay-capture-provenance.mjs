#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

// Focused data-only provenance regression. No images, app, player, account or network.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
for (const relative of ['app/Sources/PlayerScreen.swift', 'app/SourcesTV/TVPlayerView.swift']) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8');
  const witness = source.indexOf('completionEvidence.recordDuration(seconds, owner: loadToken)');
  const hook = source.indexOf('scrubThumbnails.observeNativeCaptureDuration(seconds, source: source)', witness);
  const parked = source.indexOf('if name == MPVProperty.duration, let value = data as? Double,', witness);
  if (!(witness >= 0 && hook > witness && hook < parked)) throw Error('Owned duration witness missing: ' + relative);
  const start = source.indexOf('    private func captureTrickplayFrame(at time: Double)');
  const end = source.indexOf('    private func startTrickplayCaptureTimer()', start);
  const capture = source.slice(start, end);
  for (const text of ['currentSource == captureSource', 'assetSanityAttempt.isAccepted(owner: captureSource.loadToken)',
                       'captureSource: captureSource'])
    if (!capture.includes(text)) throw Error('Capture source guard missing: ' + relative + ': ' + text);
  if ((capture.match(/currentSource == captureSource/g) ?? []).length !== 2)
    throw Error('Both nil and decoded completions must fence the source: ' + relative);
}
const output = path.join(root, 'app/build');
fs.mkdirSync(output, {recursive:true});
const directory = fs.mkdtempSync(path.join(output, 'trickplay-capture-provenance.'));
const binary = path.join(directory, 'run');
const compile = spawnSync('xcrun', ['swiftc', '-swift-version', '6', '-strict-concurrency=complete',
  '-warnings-as-errors', '-num-threads', '1', '-j', '1', '-O', '-parse-as-library', '-o', binary,
  path.join(root, 'app/SourcesShared/TrickplayUploadPolicy.swift'),
  path.join(root, 'app/Tests/TrickplayCaptureProvenanceTests.swift')],
  {encoding:'utf8', timeout:45000, env:{...process.env, SWIFTPM_MAXIMUM_CONCURRENT_OPERATIONS:'1'}});
fs.writeFileSync(path.join(directory, 'compile.log'), (compile.stdout ?? '') + (compile.stderr ?? ''));
if (compile.status !== 0) {
  process.stderr.write(compile.stdout ?? ''); process.stderr.write(compile.stderr ?? String(compile.error));
  process.exit(compile.status ?? 1);
}
const result = spawnSync(binary, [directory], {encoding:'utf8', timeout:10000});
process.stdout.write(result.stdout ?? ''); process.stderr.write(result.stderr ?? '');
console.log('Disposable capture-provenance fixtures: ' + directory);
process.exit(result.status ?? 1);
