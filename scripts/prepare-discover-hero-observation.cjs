'use strict';

// Capture/extract/verify only. No process launch, compiler, app, network or preferences.
// A separately reviewed root-owned parent supplies the fresh retained app/build directory.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const verify = process.argv.length === 4 && process.argv[3] === '--verify';
if (!(process.argv.length === 3 || verify)) {
  throw Error('Usage: node prepare-discover-hero-observation.cjs <fresh-retained-directory> [--verify]');
}
const root = fs.realpathSync(process.cwd());
const output = fs.realpathSync(process.argv[2]);
if (!output.startsWith(path.join(root, 'app', 'build') + path.sep)) throw Error('Expected retained app/build directory');
const inputs = [
  'app/SourcesiOS/iOSRootView.swift',
  'app/SourcesiOS/FeaturedHeroModel.swift',
  'app/SourcesiOS/FeaturedHeroView.swift',
  'app/Tests/Fixtures/DiscoverHeroObservationTests.swift.in',
  'scripts/prepare-discover-hero-observation.cjs',
];
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const manifestPath = path.join(output, 'source-manifest.json');
const generatedPath = 'DiscoverHeroObservationExtract.swift';
const fragmentsPath = 'source-fragments.json';
if (verify) {
  const saved = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  if (saved.version !== 1 || saved.root !== root || JSON.stringify(saved.inputs.map(x => x.path)) !== JSON.stringify(inputs)) {
    throw Error('Wrong source manifest');
  }
  for (const entry of saved.inputs) {
    if (digest(fs.readFileSync(path.join(root, entry.path))) !== entry.sha256
      || digest(fs.readFileSync(path.join(output, 'source-evidence', entry.path))) !== entry.sha256) {
      throw Error('Owning/captured source changed: ' + entry.path);
    }
  }
  if (saved.generated.path !== generatedPath || saved.fragments.path !== fragmentsPath
    || digest(fs.readFileSync(path.join(output, generatedPath))) !== saved.generated.sha256
    || digest(fs.readFileSync(path.join(output, fragmentsPath))) !== saved.fragments.sha256) {
    throw Error('Generated source or exact extracted fragments changed');
  }
  console.log('Exact owning, captured, generated and fragment hashes match');
  process.exit(0);
}
if (fs.readdirSync(output).length !== 0) throw Error('Preparation requires a fresh empty retained directory');

// Capture every owning buffer BEFORE any extraction. Never extract from mutable rereads.
const captured = inputs.map(relative => ({ path: relative, bytes: fs.readFileSync(path.join(root, relative)) }));
const texts = new Map(captured.map(entry => [entry.path, entry.bytes.toString('utf8')]));
function unique(source, needle) {
  const at = source.indexOf(needle);
  if (at < 0 || source.indexOf(needle, at + needle.length) >= 0) throw Error('Missing/ambiguous anchor: ' + needle);
  return at;
}
function between(source, start, end) {
  const a = unique(source, start), b = unique(source, end);
  if (b <= a) throw Error('Reordered anchors');
  return source.slice(a, b);
}
function replaceUnique(source, needle, replacement) {
  const at = unique(source, needle);
  return source.slice(0, at) + replacement + source.slice(at + needle.length);
}
const beforeHash = '99bb9f253a64497cd90ebef6caaf5618237fdd66f7a41ed4a732cd502e4b3b28';
const afterHash = '93a3d22086ab2f7290073094b432cdd5ba7b8fb4641dc5e7d84710d09f44f4a3';
const rootSource = texts.get(inputs[0]), model = texts.get(inputs[1]), leaf = texts.get(inputs[2]);
const actualRootHash = digest(captured[0].bytes);
if (![beforeHash, afterHash].includes(actualRootHash)) throw Error('Root source is not the pinned before/after candidate; review drift');
if (digest(captured[1].bytes) !== 'f16ce7db95c812662a845ff741a1d291594fbea5c6cbebf615aa1a35ed897424'
  || digest(captured[2].bytes) !== '6a217f678781aee036f2543a58acb0c18da0d2cd8a1dff1db43957859f9fcb39') {
  throw Error('Model/leaf source changed outside this ownership slice');
}
const discoverStart = 'struct iOSDiscoverView: View {';
const discoverEnd = '\n// MARK: - Discover filter panel (iOS / macOS)';
const discover = between(rootSource, discoverStart, discoverEnd);
const oldBinding = '    @StateObject private var hero = FeaturedHeroModel()';
const newBinding = '    @StateObject private var heroOwner = DiscoverHeroOwner()';
const newAlias = '    private var hero: FeaturedHeroModel { heroOwner.model }';
const isolated = actualRootHash === afterHash;
const expectedBinding = isolated ? newBinding : oldBinding;
const bindingAt = unique(discover, expectedBinding + '\n');
const binding = discover.slice(bindingAt, bindingAt + expectedBinding.length);
const declaration = /^    @StateObject private var (hero|heroOwner) = ([A-Za-z][A-Za-z0-9]*\(\))$/.exec(binding);
if (!declaration) throw Error('Ownership declaration no longer matches the admitted source shape');
let owner = '', alias = '', normalizedRoot = rootSource, normalizedDiscover = discover;
if (isolated) {
  const insertion = between(rootSource,
    '/// Retains Discover\'s hero for the view identity without forwarding its output publications.\n',
    '/// Discover, driven by the stremio-core engine (CatalogWithFilters):');
  const ownerStart = '@MainActor\nprivate final class DiscoverHeroOwner: ObservableObject {';
  owner = insertion.slice(unique(insertion, ownerStart)).trimEnd();
  alias = discover.slice(unique(discover, newAlias), unique(discover, newAlias) + newAlias.length);
  normalizedDiscover = replaceUnique(discover, newBinding + '\n' + newAlias, oldBinding);
  normalizedRoot = replaceUnique(rootSource, insertion, '');
  // Replace within the exact Discover scope, never the matching Home/Library declarations.
  normalizedRoot = replaceUnique(normalizedRoot, discover, normalizedDiscover);
} else if (discover.includes('heroOwner') || rootSource.includes('class DiscoverHeroOwner')) {
  throw Error('Unexpected owner in the pinned direct-observation baseline');
}
if (digest(normalizedRoot) !== beforeHash
  || digest(normalizedDiscover + '\n') !== '2ced8545f4cd94e54ec6fc69b26bfa75d3460eae169d727a7de93d99947dd36f') {
  throw Error('Full-file/two-region conservation failed; lifecycle, callbacks and body must be byte-identical');
}

// The collaborator represents these three actual published outputs, not real hero work.
const published = [
  '    @Published private(set) var hero: FeaturedHeroItem?',
  '    @Published private(set) var pageCount = 0',
  '    @Published private(set) var page = 0',
];
for (const line of published) unique(model, line + '\n');
if ((model.match(/@Published/g) || []).length !== 3) throw Error('Published output surface changed');
unique(leaf, '    @ObservedObject var model: FeaturedHeroModel\n');
for (const member of ['hero', 'pageCount', 'page']) {
  if (!new RegExp('\\bmodel\\.' + member + '\\b').test(leaf)) throw Error('Leaf no longer consumes model.' + member);
}
unique(discover, 'FeaturedHeroView(model: hero, onOpen: { path.append($0) })');
unique(discover, '.scrollDismissesHeroRotation(model: hero)');
const retainedBinding = binding.replace('@StateObject private var ', 'private let ');
let generated = texts.get(inputs[3]);
for (const [marker, replacement] of [
  ['/* PRODUCTION_DISCOVER_OWNER */', owner],
  ['/* PRODUCTION_DISCOVER_BINDING */', retainedBinding],
  ['/* PRODUCTION_DISCOVER_ALIAS */', alias],
  ['/* PRODUCTION_DISCOVER_SUBJECT */', declaration[1]],
]) generated = replaceUnique(generated, marker, replacement);
const fragments = JSON.stringify({
  mode: isolated ? 'isolated-owner' : 'direct-model', owner, stateObjectBinding: binding, computedHeroAccessor: alias,
  probeBinding: retainedBinding, observationSubject: declaration[1], publishedModelDeclarations: published,
  leafSubscription: '@ObservedObject var model: FeaturedHeroModel',
  normalizedRootSHA256: digest(normalizedRoot), normalizedDiscoverSHA256: digest(normalizedDiscover + '\n'),
  seam: 'StateObject becomes a retained field only in this probe; deterministic model collaborator, real Combine; not SwiftUI scheduling',
}, null, 2) + '\n';
for (const entry of captured) {
  if (!fs.readFileSync(path.join(root, entry.path)).equals(entry.bytes)) throw Error('Owning source changed during extraction: ' + entry.path);
}
for (const entry of captured) {
  const target = path.join(output, 'source-evidence', entry.path);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, entry.bytes, { flag: 'wx' });
}
fs.writeFileSync(path.join(output, generatedPath), generated, { flag: 'wx' });
fs.writeFileSync(path.join(output, fragmentsPath), fragments, { flag: 'wx' });
fs.writeFileSync(manifestPath, JSON.stringify({
  version: 1, root, mode: isolated ? 'isolated-owner' : 'direct-model',
  inputs: captured.map(entry => ({ path: entry.path, sha256: digest(entry.bytes) })),
  generated: { path: generatedPath, sha256: digest(generated) },
  fragments: { path: fragmentsPath, sha256: digest(fragments) },
  admission: 'source-unit Combine graph only; no real model lifecycle, SwiftUI, preferences, app or SDK build',
}, null, 2) + '\n', { flag: 'wx' });
console.log('Retained exact source and publisher-graph fixture; no compiler or process launched');
