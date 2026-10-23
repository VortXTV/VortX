// Exact bounded declaration extraction, plus explicit negative-control mutations of a retained
// COPY of Store/ViewModel. Never writes a tracked input or changes a production feature flag.
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const [root, output, mutant = 'baseline'] = process.argv.slice(2);
if (!root || !output) throw new Error('root and retained output are required');
const hash = value => createHash('sha256').update(value).digest('hex');
const read = file => readFileSync(path.join(root, file), 'utf8');
function section(file, start, end) {
  const source = read(file);
  if (source.split(start).length !== 2 || source.split(end).length !== 2) throw new Error('extraction marker drift');
  const first = source.indexOf(start), last = source.indexOf(end);
  if (last <= first) throw new Error('extraction range drift');
  return source.slice(first, last).trimEnd() + '\n';
}
const persistence = 'app/SourcesShared/XperienceNativePersistence.swift';
const declarations = 'import Foundation\n' + [
  section('app/SourcesShared/VortxResourceBridge.swift', 'indirect enum VortxJSON:', 'struct VortxResourceRequest:'),
  section('app/SourcesShared/VortxNativeRuntime.swift', 'enum VortxNativeError:', '/// Per-call locking plus one logical reservation'),
  section(persistence, 'enum XperienceExactEvidence {', '/// Uses exactly the current JSONSerialization document serializer'),
  section(persistence, 'struct XperienceSavedNamespace:', '/// Only installed manifest descriptors become candidates.')
].join('\n');
writeFileSync(path.join(output, 'ExactProductionDeclarations.swift'), declarations);

let store = read('app/SourcesShared/XperienceCollectionsStore.swift');
let model = read('app/SourcesShared/XperienceCollectionsViewModel.swift');
const controls = {
  'deny-own-ack': ['store', 'if let pending = pendingSave, pending.nativeSubmitted, pending.leaseID == lease.identity,',
    'if let pending = pendingSave, !pending.nativeSubmitted, pending.leaseID == lease.identity,'],
  'ignore-register-change': ['store', 'if XperienceExactEvidence.registers(current, observedRegisters) { return }',
    'if XperienceExactEvidence.registers(current, current) { return }'],
  'do-not-revoke-lifetime': ['store', 'if let lease = observedLease { core.retireNativeXperienceTarget(lease.target) }',
    '_ = observedLease'],
  'erase-successor-pending': ['store', 'defer { if pendingSave?.id == pending.id { pendingSave = nil } }',
    'defer { pendingSave = nil }'],
  'never-mark-submitted': ['store', 'pendingSave?.nativeSubmitted = true', '_ = pending.id'],
  'ignore-context-notification': ['store', 'LibraryAutoAdd.watchlistChangedNote, CoreBridge.xperienceContextChangedNote]',
    'LibraryAutoAdd.watchlistChangedNote]'],
  'do-not-cancel-ui-save': ['model', 'saveTask?.cancel(); saveTask = nil', 'saveTask = nil']
};
let activation = { mutant, activated: false };
if (mutant !== 'baseline') {
  const control = controls[mutant];
  if (!control) throw new Error('unknown negative control');
  const [owner, before, after] = control;
  const original = owner === 'store' ? store : model;
  if (original.split(before).length !== 2) throw new Error('negative control did not activate exactly once');
  const changed = original.replace(before, after);
  if (changed === original || !changed.includes(after)) throw new Error('negative control inactive');
  activation = { mutant, activated: true, owner, originalSHA256: hash(original), mutatedSHA256: hash(changed) };
  if (owner === 'store') store = changed; else model = changed;
}
writeFileSync(path.join(output, 'XperienceCollectionsStore.swift'), store);
writeFileSync(path.join(output, 'XperienceCollectionsViewModel.swift'), model);
writeFileSync(path.join(output, 'activation.json'), JSON.stringify(activation, null, 2) + '\n');
console.log(mutant === 'baseline' ? 'Exact production Store/ViewModel copies retained' : `Activated negative control: ${mutant}`);
