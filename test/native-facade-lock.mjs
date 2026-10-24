#!/usr/bin/env node
// Exact declaration extraction only; no SDK, Session, app container, network or checkpoint lane.
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { resolve, join } from 'node:path';
const require = createRequire(import.meta.url);
const { extractDeclaration } = require('./xperience-harness-inputs.cjs');
assert.equal(process.argv.length, 4);
assert.equal(process.argv[2], '--extract');
const output = resolve(process.argv[3]);
const root = resolve(new URL('..', import.meta.url).pathname);
const hash = value => createHash('sha256').update(value).digest('hex');
const paths = {
  facade: 'app/SourcesShared/VortxNativeCoreFacade.swift',
  fifo: 'app/SourcesShared/VortxNativeFIFOAdmission.swift',
  runtime: 'app/SourcesShared/VortxNativeRuntime.swift',
  json: 'app/SourcesShared/VortxResourceBridge.swift',
  authority: 'app/SourcesShared/VortxNativeHostFieldMutation.swift',
  fixture: 'app/Tests/VortxNativeFacadeLockTests.swift',
};
const source = Object.fromEntries(await Promise.all(Object.entries(paths)
  .map(async ([key, path]) => [key, await readFile(join(root, path), 'utf8')])));
const slices = [];
function declaration(key, marker) {
  const text = extractDeclaration(source[key], marker);
  slices.push({ path: paths[key], marker, sourceSHA256: hash(source[key]), declarationSHA256: hash(text) });
  return text;
}
function property(key, expected) {
  const lines = source[key].split('\n').filter(line => line.trim() === expected);
  assert.equal(lines.length, 1, 'unique actual property ' + expected);
  const text = lines[0];
  slices.push({ path: paths[key], marker: expected, sourceSHA256: hash(source[key]), declarationSHA256: hash(text) });
  return text;
}
function region(key, begin, end) {
  assert.equal(source[key].split(begin).length, 2, 'unique actual region start ' + begin);
  assert.equal(source[key].split(end).length, 2, 'unique actual region end ' + end);
  const start = source[key].indexOf(begin), finish = source[key].indexOf(end, start + begin.length);
  assert(finish > start, 'ordered actual region ' + begin);
  const text = source[key].slice(start, finish).trimEnd();
  slices.push({ path: paths[key], marker: begin, endMarker: end, sourceSHA256: hash(source[key]), declarationSHA256: hash(text) });
  return text;
}
const lock = declaration('facade', 'final class VortxNativeFacadeLock:');
assert(!lock.includes('@unchecked'), 'lock must retain its checked Sendable declaration');
assert.match(source.facade, /private let lock: VortxNativeFacadeLock\b/);
const initializer = declaration('facade', 'private init(session:');
assert.match(initializer, /let lock = VortxNativeFacadeLock\(\)/);
assert.match(initializer, /self\.lock = lock; self\.mutationFIFO = VortxNativeFIFOAdmission\(lock: lock\)/);
const sourceEvent = declaration('facade', 'struct SourceEvent: Sendable {');
assert.match(sourceEvent, /let producer: VortxNativeCoreFacade/);
assert.match(sourceEvent, /self\.sourceID = producer\.sourceID/);
assert(!sourceEvent.includes('@unchecked'), 'source carrier must add no unchecked conformance');
assert.match(initializer, /sourceChangedDelivery = \{ \[weak self\] fields, receipt in\s*guard let self else \{ return nil \}\s*let event = SourceEvent\(producer: self, kind: \.changed\(legacyFields: fields, receipt: receipt\)\)/);
assert.match(initializer, /sourceAcceptedDelivery = \{ \[weak self\] progressOnly in\s*guard let self else \{ return nil \}\s*let event = SourceEvent\(producer: self, kind: progressOnly \? \.progressAccepted : \.mutationAccepted\)/);
assert.equal((initializer.match(/return \{ sourceEvent\(event\) \}/g) ?? []).length, 2, 'both builders return retained original envelopes without invoking the client');
assert.match(source.fifo, /private let lock: any NSLocking & Sendable\b/);
assert.match(source.fifo, /init\(lock: any NSLocking & Sendable\)/);
const makeReceipt = declaration('facade', 'private func makeChangeReceipt(');
assert.match(makeReceipt, /guard !closed, let profile = string\(values\["native_state"\]\?\["activeProfileId"\]\) else \{ return nil \}/);
assert.match(makeReceipt, /values: values\.filter \{ Self\.presentationFields\.contains\(\$0\.key\) \}/);
assert.match(makeReceipt, /accountGeneration: accountEpoch, profileGeneration: watchlistProfileGeneration/);
assert.match(makeReceipt, /resources: resourceSelections, resourceValues: resourceValueTasks/);
const stage = declaration('facade', 'private func stageChanged(');
assert.match(stage, /private func stageChanged\(_ legacyFields: \[String\], receipt: ChangeReceipt\?\)/);
assert.match(stage, /guard receipt != nil \|\| !legacyFields\.isEmpty else \{ return \}/);
assert.match(stage, /let legacy = changed, owned = ownedChange/);
assert.match(stage, /lock\.withLock \{\s*let legacy = changed, owned = ownedChange\s*let source = sourceChangedDelivery\?\(legacyFields, receipt\)/);
assert.match(stage, /lock\.afterOutermostUnlock \{\s*source\?\(\)\s*if let receipt \{ owned\?\(receipt\) \}\s*if !legacyFields\.isEmpty \{ legacy\(legacyFields\) \}\s*\}/);
const ackStage = declaration('facade', 'private func stageAccepted(');
assert.match(ackStage, /lock\.withLock \{\s*let source = sourceAcceptedDelivery\?\(progressOnly\)/);
assert.match(ackStage, /lock\.afterOutermostUnlock \{\s*source\?\(\)\s*legacy\(\)\s*\}/);
assert(!/\b(?:closed|isAvailable)\b/.test(ackStage), 'historical ACK notifications must not gain a new availability filter');
assert(!ackStage.includes('makeChangeReceipt(') && !/\bvalues\b/.test(ackStage), 'ACK source origin is not a current-state snapshot');
assert(!stage.includes('SourceEvent('), 'the private original-producer builder owns typed carrier creation, not this RAM-worker seam');
assert(!stage.includes('makeChangeReceipt('), 'delivery must use the original transaction receipt, never mint a replacement');
assert(!/\bvalues\b/.test(stage), 'delivery must not rebuild an owned snapshot from current cache values');
const publish = declaration('facade', 'private func publish(');
const registry = declaration('facade', 'func rebindRegistry(');
const mutation = declaration('facade', 'private func enqueueMutation(');
for (const [name, body] of Object.entries({ resourcePublish: publish, registryRebind: registry, acknowledgedMutation: mutation })) {
  assert.equal((body.match(/\bstageChanged\(/g) ?? []).length, 1, name + ' stages exactly one delivery site');
  assert(!/\b(?:self\.)?changed\s*\(/.test(body), name + ' must not call changed directly');
  assert(!/\b(?:self\.)?ownedChange\s*\??\s*\(/.test(body), name + ' must not call ownedChange directly');
}
const resourceDelivery = publish.indexOf('stageChanged(changedFields.sorted(), receipt: ownedFields.isEmpty ? nil : makeChangeReceipt(ownedFields))');
const resourceTask = publish.indexOf('resourceValueTasks[$0.key] = ticket');
assert(resourceTask >= 0 && resourceDelivery > resourceTask
  && resourceDelivery < publish.lastIndexOf('lock.unlock()'),
  'resource values/tasks and original receipt are captured before the local unlock');
const accepted = registry.indexOf('let accepted = lock.withLock');
const registryDelivery = registry.indexOf('stageChanged(["ctx"], receipt: makeChangeReceipt(["ctx"]))', accepted);
const registryEnd = registry.indexOf('\n        }\n        guard accepted else', accepted);
assert(accepted >= 0 && registryDelivery > accepted && registryEnd > registryDelivery,
  'registry receipt capture and stage stay within the original accepted transaction');
const ack = mutation.indexOf('let publication = try self.lock.withLock { () -> (fields: [String: VortxJSON], changed: [String], receipt: ChangeReceipt?)? in');
const installation = mutation.indexOf('fields.forEach { self.values[$0.key] = $0.value }', ack);
const receiptCapture = mutation.indexOf('return (fields, changed, changed.isEmpty ? nil : self.makeChangeReceipt(changed))', installation);
const ackEnd = mutation.indexOf('\n                }\n                // FIFO intents', receiptCapture);
const release = mutation.indexOf('if profileTransition { self.lock.withLock { self.pendingProfileTransitions -= 1 }; transitionReleased = true }', ackEnd);
const delivery = mutation.indexOf('if let publication { self.stageChanged(publication.changed, receipt: publication.receipt) }', release);
const publicationGuard = mutation.indexOf('guard publication != nil', delivery);
assert(ack >= 0 && installation > ack && receiptCapture > installation && ackEnd > receiptCapture
  && release > ackEnd && delivery > release && publicationGuard > delivery,
  'ACK installs state and captures its original receipt under F, then releases pending profile before staged delivery');
assert.equal((mutation.match(/\bmakeChangeReceipt\(/g) ?? []).length, 1, 'ACK receipt is captured once, only in its original publication transaction');
assert(mutation.includes('defer { if profileTransition && !transitionReleased { self.lock.withLock { self.pendingProfileTransitions -= 1 } } }'),
  'failure/cancellation fallback must retain the original unreleased-transition decrement');
assert.equal((mutation.match(/pendingProfileTransitions -= 1/g) ?? []).length, 2,
  'normal ACK release and unreleased-transition fallback are both retained');
const progressACK = mutation.indexOf('self.stageAccepted(progressOnly: true, legacy: progressAccepted)', publicationGuard);
const mutationACK = mutation.indexOf('self.stageAccepted(progressOnly: false, legacy: self.mutationAccepted)', publicationGuard);
const completion = mutation.indexOf('completion?(.success(document))', publicationGuard);
assert(progressACK > publicationGuard && mutationACK > publicationGuard && completion > progressACK && completion > mutationACK);
assert(mutation.includes('if type == "report_progress", hostEdits.isEmpty, !websiteChanged, let progressAccepted = self.progressAccepted {'));
assert(mutation.includes('} else if !["get_state", "merge_native_sync", "bind_sync_scope"].contains(type) || !hostEdits.isEmpty || websiteChanged {'));
const declarations = [
  declaration('runtime', 'enum VortxNativeError:'),
  declaration('authority', 'protocol VortxMutationAuthority:'),
  declaration('json', 'indirect enum VortxJSON:'),
  declaration('facade', 'struct VortxLibraryMembership:'),
  lock,
].join('\n\n');
const receiptSupport = [
  declaration('facade', 'struct ChangeReceipt: Sendable {'),
  region('facade', '    let sourceID = UUID()\n', '    struct RegistryBinding:'),
  property('facade', 'private var registryGeneration = UUID()'),
  property('facade', 'private var accountEpoch = UUID()'),
  property('facade', 'private var watchlistProfileGeneration = UUID()'),
  property('facade', 'private var sourceChangedDelivery: (@Sendable ([String], ChangeReceipt?) -> (@Sendable () -> Void)?)?'),
  property('facade', 'private let ownedChange: (@Sendable (ChangeReceipt) -> Void)?'),
].join('\n\n');
const workerMethods = [
  makeReceipt, stage, publish,
  declaration('facade', 'private func string('),
  declaration('facade', 'private func metaWithPlayback('),
  declaration('facade', 'private func externalMetadataFingerprint('),
  declaration('facade', 'private func observeExternalMetadata('),
].join('\n\n');
function replaceOnce(text, marker, value) {
  assert.equal(text.split(marker).length, 2, 'unique fixture marker ' + marker);
  return text.replace(marker, value);
}
let combined = replaceOnce(source.fixture, '// PRODUCTION_DECLARATIONS', declarations);
combined = replaceOnce(combined, '// PRODUCTION_RECEIPT_SUPPORT', receiptSupport);
combined = replaceOnce(combined, '// PRODUCTION_WORKER_METHODS', workerMethods);
await writeFile(join(output, 'Combined.swift'), combined, { flag: 'wx' });
await writeFile(join(output, 'FIFO.swift'), source.fifo, { flag: 'wx' });
await writeFile(join(output, 'source-binding.json'), JSON.stringify({
  format: 'vortx-facade-lock-worker-v3',
  sourceHEAD: process.env.VORTX_FACADE_LOCK_SOURCE_HEAD ?? 'unprovided',
  wholeSourceHashes: Object.fromEntries(Object.entries(paths).map(([key, path]) => [path, hash(source[key])])),
  slices,
  generated: { combinedSHA256: hash(combined), fifoSHA256: hash(source.fifo) },
  sourceOnlyProducerChecks: ['registryRebind', 'acknowledgedMutation', 'originalTypedSourceBuilders'],
  runtimeProducer: 'exact private publish, makeChangeReceipt and stageChanged in explicit RAM worker',
  boundary: [
    'Whole production FIFO and lock declarations; existing 14 FIFO XCTest cases unchanged',
    'Nine synchronous lock/publication worker tests retained; one checks generic source-delivery staging then owned/legacy timing',
    'Real nested ChangeReceipt and exact receipt support state/build/delivery declarations; no fake production receipt',
    'Generic RAM source-delivery builder only; typed SourceEvent and original Facade construction are source contracts here, not executed producer identity proof',
    'No actual app facade, Session task chain, ABI, credential, source-lock release, live owner acceptance, durability or consumer freshness claim',
    'ACK original-transaction capture, pending-profile release and delivery ordering are source contracts, not executed ACK runtime',
    'Insertion order applies to one outer-lock queued batch; unlocked batches can interleave or reenter',
  ],
}, null, 2) + '\n', { flag: 'wx' });
