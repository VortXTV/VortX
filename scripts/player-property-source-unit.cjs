'use strict';

// SOURCE PREPARATION ONLY. This module has no file/process effects.
// The method extractor, adapters, contracts, assertions and mutations below are
// conserved from the frozen handle-v1 runner. Only call boundaries are added.
const crypto = require('node:crypto');
const sha = value => crypto.createHash('sha256').update(value).digest('hex');

function methods(text, name) {
  // The audited declarations and their terminal braces have exactly four spaces.
  // This bounded extractor fails closed on missing/malformed methods; it is not a Swift parser.
  const pattern = new RegExp(`^    private func ${name}\\(`, 'gm');
  const found = [];
  for (const match of text.matchAll(pattern)) {
    const end = text.indexOf('\n    }', match.index);
    if (end < 0) throw new Error(`Missing terminal brace for ${name}`);
    let start = match.index;
    const attribute = '    @discardableResult\n';
    if (text.slice(start - attribute.length, start) === attribute) start -= attribute.length;
    found.push({ start, text: text.slice(start, end + '\n    }'.length) });
  }
  if (!found.length) throw new Error(`Missing production method ${name}`);
  return found;
}

function prepare(source, fixture, expect) {
const options = { expect };
const names = ['getDouble', 'getString', 'getFlag', 'setFlag', 'getInt', 'setString',
  'diagnosticDouble', 'diagnosticInt', 'diagnosticFlag', 'bitrateBoundedRampCeiling',
  'scheduleDiskCacheReadaheadRampStep', 'probeEnhancementLayer'];
const extracted = names.flatMap(name => methods(source, name)).sort((a, b) => a.start - b.start);
const expectedMethodCount = options.expect === 'red' ? 15 : 19;
if (extracted.length !== expectedMethodCount) {
  throw new Error(`Expected ${expectedMethodCount} exact production methods, found ${extracted.length}`);
}
const hasBorrow = name => methods(source, name).some(item =>
  item.text.split('\n')[0].includes('handle: OpaquePointer'));
const call = (name, args) => `${name}(${args}${hasBorrow(name) ? ', handle: handle' : ''})`;
// Adapters have the SAME outward fixture API. Baseline adapters call its actual legacy methods;
// candidate adapters call its actual handle overloads. No helper implementation is synthesized.
const adapters = [
  `    func borrowedString(_ handle: OpaquePointer) -> String? { ${call('getString', '"value"')} }`,
  `    func borrowedInt(_ handle: OpaquePointer) -> Int { ${call('getInt', '"value"')} }`,
  `    func borrowedFlag(_ handle: OpaquePointer) -> Bool { ${call('getFlag', '"value"')} }`,
  `    func borrowedSetString(_ handle: OpaquePointer) { ${call('setString', '"value", "written"')} }`,
  `    func borrowedProbe(_ handle: OpaquePointer) { probeEnhancementLayer(${hasBorrow('probeEnhancementLayer') ? 'handle: handle' : ''}) }`
].join('\n');
function insertOnce(text, marker, replacement) {
  if (text.split(marker).length !== 2) throw new Error(`Expected one ${marker}`);
  return text.replace(marker, replacement);
}
let unit = insertOnce(fixture, '__PRODUCTION_METHODS__', extracted.map(item => item.text).join('\n\n'));
unit = insertOnce(unit, '__BORROW_WRAPPERS__', adapters);
return { unit, adapterSource: adapters, unitSHA256: sha(unit),
  extracted: extracted.map(item => ({ sourceLine: source.slice(0, item.start).split('\n').length,
    declaration: item.text.split('\n').find(line => line.includes('func ')), sha256: sha(item.text) })) };
}

function contractResults(text) {
  const method = name => methods(text, name)[0].text;
  const loaded = text.slice(text.indexOf('                case MPV_EVENT_FILE_LOADED:'),
    text.indexOf('                case MPV_EVENT_VIDEO_RECONFIG:'));
  const probe = method('probeEnhancementLayer');
  const ramp = method('scheduleDiskCacheReadaheadRampStep');
  const bitrate = method('bitrateBoundedRampCeiling');
  const workStart = ramp.indexOf('let work = DispatchWorkItem { [weak self] in');
  const guardAt = ramp.indexOf('guard let self, let handle = self.mpv,');
  const mpvReads = ramp.match(/\bself\.mpv\b/g) ?? [];
  const nativeRampLines = ramp.split('\n').filter(line =>
    /self\.(?:diagnosticInt|diagnosticFlag|setString|bitrateBoundedRampCeiling)\(/.test(line));
  const probeCalls = probe.split('\n').filter(line => /\b(?:getInt|getString|getFlag)\(/.test(line));
  const stopStart = text.indexOf('    func stop() {');
  const stopEnd = text.indexOf('\n    deinit {', stopStart);
  const stop = text.slice(stopStart, stopEnd);
  const ordered = (body, needles) => {
    let previous = -1;
    return needles.every(needle => { const at = body.indexOf(needle, previous + 1); previous = at; return at >= 0; });
  };
  return [
    ['routing.file-loaded', loaded.includes('self.getString("path", handle: handle)')
      && loaded.includes('self.probeEnhancementLayer(handle: handle)')],
    ['routing.probe', probe.startsWith('    private func probeEnhancementLayer(handle: OpaquePointer)')
      && !/\bmpv\b/.test(probe.replace(/\/\/.*$/gm, '')) && probeCalls.length === 3
      && probeCalls.every(line => line.includes('handle: handle'))
      && probe.includes('dependentIDs.append(getInt("track-list/\\(i)/id", handle: handle))')],
    ['routing.ramp-admission', workStart >= 0 && guardAt > workStart && mpvReads.length === 1
      && !/\bmpv\b/.test(ramp.slice(0, workStart))
      && ramp.includes('self.cacheReadaheadRampGeneration == generation else { return }')
      && ramp.includes('queue.asyncAfter(')],
    ['routing.ramp-native', nativeRampLines.length === 5
      && nativeRampLines.every(line => line.includes('handle: handle'))
      && bitrate.includes('configured: Int, handle: OpaquePointer')
      && bitrate.includes('diagnosticDouble("video-bitrate", handle: handle)')
      && bitrate.includes('diagnosticDouble("audio-bitrate", handle: handle)')
      && !/\bmpv\b/.test(bitrate)],
    ['preserve.serial-stop', ordered(stop, ['invalidateLoadToken()', 'mpv = nil',
      'mpv_set_wakeup_callback(handle, nil, nil)', 'mpv_command_string(handle, "quit")',
      'queue.async {', 'mpv_terminate_destroy(handle)', 'relay?.release()'])
      && !stop.includes('.sync')],
    ['preserve.callback-guards', loaded.includes('guard let loadedToken = self.callbackLoadToken(requiresLoadedFile: true) else { break }')
      && text.includes('Unmanaged<WakeupRelay>.fromOpaque(ctx).takeUnretainedValue().controller?.readEvents()')
      && text.includes('callbackToken: capturedToken, activeToken: self.activeLoadToken')
      && text.includes('guard let self, self.mpv != nil,')]
  ];
}

function accept(source, expect, execution, out) {
const options = { expect };
const contracts = contractResults(source);
const contractFailures = contracts.filter(([, passed]) => !passed).map(([name]) => name);
if (execution.error || execution.signal) throw new Error(`Runtime failed outside assertions: ${out}/run.log`);
const summary = execution.stdout.match(/^CHECKS=(\d+) FAILURES=(\d+)$/m);
const failedNames = [...execution.stdout.matchAll(/^FAIL (.+)$/gm)].map(match => match[1]);
if (!summary || Number(summary[1]) !== 29 || Number(summary[2]) !== failedNames.length) {
  throw new Error(`Unexpected source-unit assertion accounting: ${out}/run.log`);
}
const expectedRed = ['getDouble', 'getString', 'getFlag', 'getInt', 'setFlag', 'setString'].map(name => `single-read.${name}`)
  .concat(['getString', 'getInt', 'getFlag', 'setString', 'probe'].map(name => `borrowed.${name}`))
  .concat(['ramp.growth-one-admission', 'ramp.backoff-one-admission']).sort();
const expectedRedContracts = ['routing.file-loaded', 'routing.probe', 'routing.ramp-admission', 'routing.ramp-native'].sort();
const equal = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());
if (options.expect === 'red') {
  if (execution.status !== 1 || !equal(failedNames, expectedRed) || !equal(contractFailures, expectedRedContracts)) {
    throw new Error(`RED differed from the 13 helper/ramp assertions and 4 source-contract failures: ${out}`);
  }
} else if (execution.status !== 0 || failedNames.length || contractFailures.length) {
  throw new Error(`GREEN failed: assertions=${failedNames.join(',')} contracts=${contractFailures.join(',')}; ${out}`);
}

// Negative routing controls apply only to an accepted candidate, never to baseline compile setup.
const controls = [];
if (options.expect === 'green') {
  const mutations = [
    ['routing.file-loaded', 'self.getString("path", handle: handle)', 'self.getString("path")'],
    ['routing.probe', 'getInt("track-list/count", handle: handle)', 'getInt("track-list/count")'],
    ['routing.ramp-admission', '        let work = DispatchWorkItem { [weak self] in\n            // Borrow only after this work starts;',
      '        let capturedHandle = mpv\n        let work = DispatchWorkItem { [weak self] in\n            // Borrow only after this work starts;'],
    ['routing.ramp-native', 'self.setString("cache-secs", String(next), handle: handle)', 'self.setString("cache-secs", String(next))']
  ];
  for (const [name, from, to] of mutations) {
    if (!source.includes(from)) throw new Error(`Missing negative-control anchor ${name}`);
    let mutated = source.replace(from, to);
    if (name === 'routing.ramp-admission') {
      mutated = mutated.replace('guard let self, let handle = self.mpv,', 'guard let self, let handle = capturedHandle,');
    }
    const detected = contractResults(mutated).some(([actual, passed]) => actual === name && !passed);
    controls.push([name, detected]);
    if (!detected) throw new Error(`Source-contract negative control escaped: ${name}`);
  }
}
const result = { expected: options.expect, behaviorChecks: 29, behaviorFailures: failedNames,
  sourceContractChecks: contracts.length, sourceContractFailures: contractFailures,
  negativeControlChecks: controls.length, controls, output: out };
return result;
}

module.exports = { prepare, accept };
