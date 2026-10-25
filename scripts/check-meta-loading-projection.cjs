// Actual facade publication seams; negative mutations remain in memory.
const fs = require('node:fs');
const root = process.argv[2];
const facade = fs.readFileSync(root + '/app/SourcesShared/VortxNativeCoreFacade.swift', 'utf8');
const session = fs.readFileSync(root + '/app/SourcesShared/VortxNativeSession.swift', 'utf8');
function need(ok, message) { if (!ok) throw Error(message); }
function contract(source) {
  const start = source.indexOf('if name == "Load", model == "MetaDetails", field == "meta_details" {');
  const end = source.indexOf('if name == "Load", model == "CatalogWithFilters"', start);
  need(start >= 0 && end > start, 'actual MetaDetails admission missing');
  const load = source.slice(start, end);
  for (const token of ['let previous = values[field], account = accountEpoch',
    'let profileGeneration = watchlistProfileGeneration, capturedRegistry = registryGeneration',
    'return self.lock.withLock {', '!self.closed && self.resourceRegistryValid',
    'self.accountEpoch == account', 'self.watchlistProfileGeneration == profileGeneration',
    'self.registryGeneration == capturedRegistry',
    'self.values["native_state"]?["activeProfileId"] == .string(profile)',
    'VortxMetaLoadingProjection.retainingReadyMetadata(previous: previous,',
    'incoming: incoming, ownerIsCurrent: current)', 'initial: project(loading)',
    'expectedProfileID: profile, onUpdate: { value in publish(project(value)) }', 'return [field: project(result)]']) {
    need(load.includes(token), 'actual transition binding missing: ' + token);
  }
  need(!load.includes('pendingProfileTransitions'), 'busy sync must not masquerade as a new owner');
  need(load.indexOf('let previous = values[field]') < load.indexOf('return enqueue(field'), 'capture before initial publication');
  const enqueueStart = source.indexOf('private func enqueue(_ field: String, initial: VortxJSON? = nil, replacingSelection: Bool = true,\n');
  const enqueueEnd = source.indexOf('private func enqueueMutation(', enqueueStart);
  need(enqueueStart >= 0 && enqueueEnd > enqueueStart, 'actual enqueue implementation missing');
  const enqueue = source.slice(enqueueStart, enqueueEnd);
  need(enqueue.includes('self?.publish([field: value], field: field, ticket: ticket)') &&
    enqueue.includes('self?.publish(result, field: field, ticket: ticket)'), 'partial/final publication ticket retained');
  need(enqueue.includes('self.publish([field: .object(["nativeError":') && !enqueue.includes('project('), 'enqueue catch bypasses carry');
  need(source.includes('guard !closed, generations[field] == ticket else'), 'stale load publication rejected');
  const dispatchStart = source.indexOf('func dispatch(data: Data, field: String?) -> Bool {');
  need(source.slice(dispatchStart, dispatchStart + 130).includes('lock.lock(); defer { lock.unlock() }'), 'dispatch capture is atomic');
  need(source.includes('generations = generations.filter { $0.key == "native_state" }') &&
    source.includes('values = values.filter { ["native_state", "library"].contains($0.key) }; selections = [:]'), 'owner invalidation retires resource values/tickets');
}
contract(facade);
for (const token of ['initial: project(loading)', 'publish(project(value))', 'return [field: project(result)]',
  'self.accountEpoch == account', 'self.watchlistProfileGeneration == profileGeneration',
  'self.registryGeneration == capturedRegistry', 'self.resourceRegistryValid',
  'self.values["native_state"]?["activeProfileId"] == .string(profile)']) {
  const start = facade.indexOf('if name == "Load", model == "MetaDetails", field == "meta_details" {');
  const mutated = facade.slice(0, start) + facade.slice(start).replace(token, '/* removed transition fence */');
  let rejected = false;
  try { contract(mutated); } catch { rejected = true; }
  need(rejected, 'contract failed to detect mutation: ' + token);
}
const metaStart = session.indexOf('func loadMeta(request: VortxResourceRequest,');
const metaEnd = session.indexOf('func ', metaStart + 5);
need(metaStart >= 0 && metaEnd > metaStart, 'actual session metadata load missing');
// The callback is intentionally fed by a nested publication function, including its first Loading value.
const sessionLoad = session.slice(metaStart, session.indexOf('func load', metaStart + 5));
need(sessionLoad.includes('onUpdate(value)') && sessionLoad.includes('_ = try publish(logStreams: true)') &&
  sessionLoad.includes('_ = try publish(logStreams: job.1.resource == .stream)') &&
  sessionLoad.includes('guard current(name, ticket, capturedEpoch) else'), 'session partial ownership checks retained');
console.log('Meta loading projection source contracts PASS: initial/partial/final and acknowledged-owner fences');
