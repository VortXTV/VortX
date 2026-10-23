import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
const supervisorSHA = 'c83153feedd91bee93000305604d68772d4b7164716749f0a04605bbb2253f62';
const hash = x => crypto.createHash('sha256').update(x).digest('hex');
function inside(base, value) {
  const r = path.relative(base, value);
  return r !== '' && r !== '..' && !r.startsWith('../') && !path.isAbsolute(r);
}
function one(s, marker) {
  const i = s.indexOf(marker);
  if (i < 0 || s.indexOf(marker, i + marker.length) >= 0) throw Error('Missing/ambiguous marker: ' + marker);
  return i;
}
function declaration(s, marker) {
  const i = one(s, marker), end = s.indexOf('\n}\n', i);
  if (end < 0) throw Error('Missing top-level end: ' + marker);
  return s.slice(i, end + 3);
}
function generate(repoArg, runArg, runnerArg) {
  const [repo, run, runner] = [repoArg, runArg, runnerArg].map(x => fs.realpathSync(x));
  if (!inside(path.join(repo, 'app/build'), run) || !inside(repo, runner)) {
    throw Error('Unexpected repository/run boundary');
  }
  const inputs = [], outputs = [], extracts = [], transforms = [];
  function read(p) {
    p = fs.realpathSync(p);
    if (!inside(repo, p)) throw Error('Source outside repository');
    const bytes = fs.readFileSync(p); inputs.push({path:p, sha256:hash(bytes)});
    return bytes.toString('utf8');
  }
  function write(name, source) {
    const p = path.join(run, name); fs.writeFileSync(p, source, {flag:'wx'});
    outputs.push({path:p, sha256:hash(source)});
  }
  const donor = name => read(path.join(repo, 'app/SourcesShared', name));
  const selected = (source, marker) => {
    const text = declaration(source, marker);
    extracts.push({declaration:marker, sha256:hash(text)}); return text;
  };
  read(runner); read(fileURLToPath(import.meta.url));
  read(path.join(repo, 'test/curation-defaults/pinned-fixtures.sha256'));
  if (hash(read(path.join(repo, 'test/mpv-bounded-child.mjs'))) !== supervisorSHA) throw Error('Supervisor drift');
  const json = selected(donor('VortxResourceBridge.swift'), 'indirect enum VortxJSON:');
  const error = selected(donor('VortxNativeRuntime.swift'), 'enum VortxNativeError:');
  const clockSource = donor('SourceIndexClient.swift');
  const clock = ['struct SourceIndexLifecycleSnapshot:', 'struct SourceIndexLifecycleTransition:',
    'enum SourceIndexLifecycleClock {'].map(marker => selected(clockSource, marker)).join('\n');
  const preferences = donor('VortxNativeHostPreferences.swift');
  const start = one(preferences, '    static let forYouPrefix = "forYou."');
  const vStart = one(preferences, '    static func validateForYouField(');
  const end = preferences.indexOf('\n    }\n', vStart);
  if (end < 0 || vStart < start) throw Error('Host-validator boundary drift');
  const validator = preferences.slice(start, end + 7);
  extracts.push({declaration:'ForYou validator', sha256:hash(validator)});
  write('ExactDeclarations.swift', 'import Foundation\n' + json + '\n' + error + '\n' + clock +
    '\nenum VortxNativeHostPreferences {\n' + validator + '}\n');
  for (const name of ['ForYouInterests.swift', 'VortxNativeHostFieldMutation.swift',
      'VortxNativeBootstrapArchive.swift', 'CurationCollection.swift', 'CurationDocument.swift',
      'VortXEdgeAuth.swift', 'CurationDefaultsFeed.swift', 'CurationDefaultsModel.swift']) write(name, donor(name));
  const transport = donor('AuthenticatedHTTPTransport.swift');
  write('AuthenticatedHTTPTransport.swift', transport);
  const before = '    static let shared = AuthenticatedHTTPTransport()';
  const after = '    static let shared = AuthenticatedHTTPTransport(protocolClasses: [DefaultsURLProtocol.self])';
  one(transport, before);
  const injected = transport.replace(before, after);
  transforms.push({declaration:'Runtime-only shared transport constructor injection', before, after,
    inputSHA256:hash(transport), outputSHA256:hash(injected)});
  write('AuthenticatedHTTPTransport.injected.swift', injected);
  for (const name of ['CurationDefaultsTests.swift', 'CurationDefaultsClientTests.swift']) {
    write(name, read(path.join(repo, 'app/Tests', name)));
  }
  write('AppSurfaces.swift', read(path.join(repo, 'test/curation-defaults/fixtures/AppSurfaces.swift')));
  write('Main.swift', read(path.join(repo, 'test/curation-defaults/Main.swift')));
  fs.writeFileSync(path.join(run, 'manifest.json'), JSON.stringify({schema:1, repo, run, supervisorSHA, inputs, outputs, extracts, transforms,
    proof:'Full defaults Feed/Model, original XCTest assertions, real signer/transport and raw public-base validator',
    excluded:['real app globals/RemoteConfig/account/MOAT issuance','production starter fallback/Discover loaders',
      'production signing-key material','network or live backend/provider','workerd/deployment',
      'Store/native checkpoint/profile persistence','SwiftUI rendering/device/full app/release']}, null, 2)+'\n', {flag:'wx'});
}
function verify(arg) {
  const run = fs.realpathSync(arg);
  const m = JSON.parse(fs.readFileSync(path.join(run, 'manifest.json'), 'utf8'));
  const repo = fs.realpathSync(m.repo);
  if (m.schema !== 1 || m.supervisorSHA !== supervisorSHA || m.run !== run
      || !inside(path.join(repo, 'app/build'), run)) throw Error('Manifest contract drift');
  for (const e of [...m.inputs, ...m.outputs]) {
    const actual = fs.realpathSync(e.path);
    if (!inside(repo, actual) || hash(fs.readFileSync(actual)) !== e.sha256) throw Error('Source drift: '+e.path);
  }
}
try {
  const [op, ...args] = process.argv.slice(2);
  if (op === 'generate' && args.length === 3) generate(...args);
  else if (op === 'verify' && args.length === 1) verify(args[0]);
  else throw Error('Usage: generate REPO RUN RUNNER | verify RUN');
} catch(e) { process.stderr.write(String(e.message ?? e)+'\n'); process.exitCode=90; }
