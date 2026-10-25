import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import {fileURLToPath} from 'node:url';

const supervisorSHA = 'c83153feedd91bee93000305604d68772d4b7164716749f0a04605bbb2253f62';
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function inside(root, file) {
  const relative = path.relative(root, file);
  return relative !== '' && relative !== '..' && !relative.startsWith('../') && !path.isAbsolute(relative);
}
function one(source, marker) {
  const start = source.indexOf(marker);
  if (start < 0 || source.indexOf(marker, start + marker.length) >= 0) throw Error('Missing/ambiguous declaration marker: ' + marker);
  return start;
}
function declaration(source, marker) {
  const start = one(source, marker), end = source.indexOf('\n}\n', start);
  if (end < 0) throw Error('Unclosed top-level declaration: ' + marker);
  return source.slice(start, end + 3);
}
function generate(repoArgument, runArgument, runnerArgument) {
  const repo = fs.realpathSync(repoArgument), run = fs.realpathSync(runArgument);
  const runner = fs.realpathSync(runnerArgument);
  if (!inside(path.join(repo, 'app/build'), run) || !inside(repo, runner)) throw Error('Invalid repository/run boundary');
  const inputs = [], outputs = [], extracts = [], transforms = [];
  function read(file) {
    const actual = fs.realpathSync(file);
    if (!inside(repo, actual)) throw Error('Input escapes repository');
    const bytes = fs.readFileSync(actual);
    inputs.push({path: actual, sha256: hash(bytes)});
    return bytes.toString('utf8');
  }
  function write(name, text) {
    const file = path.join(run, name);
    fs.writeFileSync(file, text, {flag: 'wx'});
    outputs.push({path: file, sha256: hash(text)});
  }
  const donor = name => read(path.join(repo, 'app/SourcesShared', name));
  const proofComposer = path.join(repo, 'scripts/extract-subtitle-proof-hosts.cjs');
  read(proofComposer);
  read(path.join(repo, 'app/SourcesShared/CoreBridge.swift'));
  read(path.join(repo, 'app/SourcesShared/VortxNativeCoreFacade.swift'));
  read(path.join(repo, 'app/SourcesShared/LegacyWatchOwnership.swift'));
  const proofPath = path.join(run, 'NativeSubtitleProofHosts.swift');
  const proofRun = spawnSync(process.execPath, [proofComposer, repo, 'full-shells', proofPath], {encoding: 'utf8'});
  if (proofRun.error || proofRun.status !== 0) throw new Error('Actual subtitle proof extraction failed: ' + (proofRun.stderr || proofRun.error));
  const proofReceipt = JSON.parse(proofRun.stdout);
  outputs.push({path: proofPath, sha256: hash(fs.readFileSync(proofPath))});
  extracts.push({declaration: 'NativeSubtitleOwnerProofs', ...proofReceipt});
  read(runner); read(fileURLToPath(import.meta.url));
  read(path.join(repo, 'test/xperience-export/pinned-fixtures.sha256'));
  if (hash(read(path.join(repo, 'test/mpv-bounded-child.mjs'))) !== supervisorSHA) throw Error('Supervisor changed');
  const json = declaration(donor('VortxResourceBridge.swift'), 'indirect enum VortxJSON:');
  const error = declaration(donor('VortxNativeRuntime.swift'), 'enum VortxNativeError:');
  const keychain = declaration(donor('Keychain.swift'), 'final class KeychainFailureClosedStore:');
  const preferences = donor('VortxNativeHostPreferences.swift');
  const start = one(preferences, '    static let forYouPrefix = "forYou."');
  const validatorStart = one(preferences, '    static func validateForYouField(');
  const end = preferences.indexOf('\n    }\n', validatorStart);
  if (validatorStart < start || end < 0) throw Error('Unexpected host-validator boundary');
  const validator = preferences.slice(start, end + 7);
  for (const [name, text] of [['VortxJSON', json], ['VortxNativeError', error],
      ['KeychainFailureClosedStore', keychain], ['ForYouHostValidator', validator]]) {
    extracts.push({declaration: name, sha256: hash(text)});
  }
  write('ExactProductionDeclarations.swift', 'import Foundation\n' + json + '\n' + error + '\n'
    + keychain + '\nenum VortxNativeHostPreferences {\n' + validator + '}\n');
  // These are complete CURRENT production sources, never stored implementation afterimages.
  for (const name of ['CredentialScope.swift', 'ForYouInterests.swift', 'VortxNativeHostFieldMutation.swift',
      'VortxNativeBootstrapArchive.swift', 'AddonURLGuard.swift', 'AddonPairingProtocol.swift',
      'VortXEdgeAuth.swift', 'CurationCollection.swift', 'CurationDocument.swift', 'CurationEdit.swift',
      'XperienceCollections.swift', 'XperienceAddonBinding.swift', 'XperienceExportEndpoint.swift',
      'XperienceExportSystemKeychain.swift', 'XperienceExportHTTP.swift', 'XperienceProfileExportAdmission.swift',
      'XperienceCurationExportMapper.swift', 'XperienceCurationExportController.swift',
      'XperienceCurationExportPromptState.swift']) write(name, donor(name));
  const delivery = declaration(donor('CurationReadAuthority.swift'), 'enum CurationReadContextDelivery {');
  extracts.push({declaration: 'CurationReadContextDelivery', sha256: hash(delivery)});
  write('ExactPromptDelivery.swift', 'import Foundation\n' + delivery);
  write('AppSurfaces.swift', read(path.join(repo, 'test/xperience-export/fixtures/AppSurfaces.swift')));
  let lifecycle;
  for (const name of ['XperienceExportConnectorTests.swift', 'XperienceMapperWireEqualityTests.swift',
      'XperienceLifecycleAmendmentTests.swift', 'XperienceCurationExportPromptLifecycleTests.swift']) {
    const text = read(path.join(repo, 'app/Tests', name));
    write(name, text);
    if (name === 'XperienceLifecycleAmendmentTests.swift') lifecycle = text;
  }
  // Reuse the same synthetic helper library without invoking that suite a second time.
  const originalMain = '@main @MainActor enum XperienceLifecycleAmendmentTests {';
  one(lifecycle, originalMain);
  const library = lifecycle.replace(originalMain, '@MainActor enum XperienceLifecycleAmendmentTests {');
  transforms.push({source: 'app/Tests/XperienceLifecycleAmendmentTests.swift',
    beforeSHA256: hash(lifecycle), afterSHA256: hash(library),
    operation: 'Remove only @main for prompt helper library; no method/assertion changes'});
  write('LifecycleFixtureLibrary.swift', library);
  write('PromptMain.swift', 'import Foundation\n@main @MainActor enum PromptMain {\n'
    + ' static func main() async throws {\n'
    + '  try await XperienceCurationExportPromptLifecycleTests.run()\n'
    + '  print("PASS actual prompt lifecycle checks: \\(XperienceCurationExportPromptLifecycleTests.checks)")\n'
    + ' }\n}\n');
  const manifest = {schema: 1, createdAt: new Date().toISOString(), repo, run, supervisorSHA,
    inputs, outputs, extracts, transforms,
    systemFrameworks: ['Foundation', 'Combine', 'CryptoKit', 'Security', 'LocalAuthentication'],
    excluded: ['Store/CoreBridge/facade/native checkpoint/whole-account budget',
      'runtime Security/installed persistence/private endpoint/DNS/account delivery',
      'SwiftUI rendering/focus/app/device/signing/release']};
  fs.writeFileSync(path.join(run, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n', {flag: 'wx'});
}
function verify(runArgument) {
  const run = fs.realpathSync(runArgument);
  const manifest = JSON.parse(fs.readFileSync(path.join(run, 'manifest.json'), 'utf8'));
  const repo = fs.realpathSync(manifest.repo);
  if (manifest.schema !== 1 || manifest.supervisorSHA !== supervisorSHA
      || !inside(path.join(repo, 'app/build'), run)) throw Error('Manifest contract mismatch');
  for (const entry of [...manifest.inputs, ...manifest.outputs]) {
    const actual = fs.realpathSync(entry.path);
    if (!inside(repo, actual) || hash(fs.readFileSync(actual)) !== entry.sha256) throw Error('Source drift: ' + entry.path);
  }
}
try {
  const [command, ...args] = process.argv.slice(2);
  if (command === 'generate' && args.length === 3) generate(...args);
  else if (command === 'verify' && args.length === 1) verify(...args);
  else throw Error('Usage: generate REPO RUN RUNNER | verify RUN');
} catch (error) { process.stderr.write(String(error.message ?? error) + '\n'); process.exitCode = 90; }
