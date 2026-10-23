'use strict';
const assert = require('node:assert/strict');

const observationInputList = 'scripts/xperience-observation-swift-inputs.sh';
function observationInputs(raw) {
  const lines = raw.split(/\r?\n/).map(line => line.trim()).filter(line => line && !line.startsWith('#'));
  assert.equal(lines.shift(), 'xperience_observation_swift_inputs=(');
  assert.equal(lines.pop(), ')');
  assert(lines.length > 0 && new Set(lines).size === lines.length, 'empty or duplicated observation inputs');
  for (const line of lines) {
    assert(/^app\/SourcesShared\/[A-Za-z0-9_/-]+\.swift$/.test(line) && !line.includes('..'),
      'unreviewed observation compiler input');
  }
  return lines;
}

// Copy the exact owning declaration, never reconstruct its type, isolation or initializer.
// An older baseline without any observation call needs no invented feature property.
function observationProperty(manager) {
  const declarations = manager.match(/^    nonisolated private static let xperienceExportObservation = XperienceExportObservationFence\(\)$/gm) ?? [];
  const mentions = manager.match(/^.*(?:let|var) xperienceExportObservation.*$/gm) ?? [];
  assert(mentions.length === declarations.length && declarations.length <= 1, 'observation declaration changed or is ambiguous');
  if (manager.includes('Self.xperienceExportObservation.')) {
    assert.equal(declarations.length, 1, 'production observation call has no owning declaration');
  }
  return declarations[0] ?? '';
}

const ownerHistoryInputList = 'scripts/native-owner-history-fixture-inputs.sh';
function ownerHistoryInputs(raw) {
  const lines = raw.split(/\r?\n/).map(line => line.trim()).filter(line => line && !line.startsWith('#'));
  assert.equal(lines.shift(), 'native_owner_history_fixture_swift_inputs=(');
  assert.equal(lines.pop(), ')');
  assert(lines.length > 0 && new Set(lines).size === lines.length, 'empty or duplicated owner-history inputs');
  for (const line of lines) {
    assert(/^app\/SourcesShared\/[A-Za-z0-9_/-]+\.swift$/.test(line) && !line.includes('..'),
      'unreviewed owner-history compiler input');
  }
  return lines;
}

function extractDeclaration(source, signature) {
    const begin = source.indexOf(signature);
    if (begin < 0 || source.indexOf(signature, begin + signature.length) >= 0) throw new Error('Missing or ambiguous declaration: ' + signature);
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
    throw new Error('Unterminated declaration: ' + signature);
}

function ownerHistoryCarriers(manager) {
  const declarations = ['struct OwnerHistoryAccountPreparation: Sendable {',
    'struct OwnerHistoryPeerPreparation: Sendable {']
    .map(signature => ({ signature, bytes: extractDeclaration(manager, signature) }));
  // Keep both ACTUAL declarations in one generated file. No fileprivate initializer,
  // Sendable conformance, field, runtime method or constructor authority is rewritten.
  return { source: 'import Foundation\n\n' + declarations.map(item => item.bytes).join('\n\n') + '\n',
    declarations };
}

module.exports = { observationInputList, observationInputs, observationProperty,
  ownerHistoryInputList, ownerHistoryInputs, ownerHistoryCarriers, extractDeclaration };

if (require.main === module) {
  const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
  assert(process.argv.length === 4 && process.argv[2] === '--owner-history-carriers',
    'Usage: node test/xperience-harness-inputs.cjs --owner-history-carriers <existing-output-directory>');
  const root = path.resolve(__dirname, '..'), directory = path.resolve(process.argv[3]);
  const relative = path.relative(path.join(root, 'app/build'), directory);
  assert(relative && relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative),
    'carrier output must remain inside the existing app/build fixture directory');
  assert(fs.statSync(directory).isDirectory(), 'output directory must already exist');
  const manager = fs.readFileSync(path.join(root, 'app/SourcesShared/VortXSyncManager.swift'));
  const carriers = ownerHistoryCarriers(manager.toString('utf8'));
  const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
  fs.writeFileSync(path.join(directory, 'OwnerHistoryFixtureCarriers.swift'), carriers.source, { flag: 'wx' });
  fs.writeFileSync(path.join(directory, 'owner-history-carriers.json'), JSON.stringify({
    owner: 'app/SourcesShared/VortXSyncManager.swift', ownerSHA256: digest(manager),
    declarations: carriers.declarations.map(({ signature, bytes }) => ({ signature, sha256: digest(Buffer.from(bytes)) })),
    declarationTransformations: [], factoryExtraction: false
  }, null, 2) + '\n', { flag: 'wx' });
}
