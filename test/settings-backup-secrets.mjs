import { createHash, randomUUID } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Standalone actual-source check, not an app/IPA build. All generated inputs and receipts stay in this
// worktree. Each executable has a fresh, embedded bundle ID and can write only its empty owned domain.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const build = join(root, 'app', 'build');
mkdirSync(build, { recursive: true });
const out = mkdtempSync(join(build, 'settings-backup-secrets.'));
const backupPath = join(root, 'app/SourcesShared/SettingsBackup.swift');
const testPath = join(root, 'app/Tests/SettingsBackupSecretsTests.swift');
const backup = readFileSync(backupPath, 'utf8');
const sharedInputs = ['CredentialScope.swift', 'Keychain.swift']
  .map(name => join(root, 'app/SourcesShared', name));
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const inputs = [backupPath, testPath, ...sharedInputs].map(path => ({
  path, sha256: digest(readFileSync(path)),
}));

function replaceOnce(source, before, after) {
  if (source.split(before).length !== 2) throw new Error(`Expected one control boundary: ${before}`);
  return source.replace(before, after);
}
const variants = [
  { name: 'current', source: backup, expected: 0, failures: [] },
  { name: 'cache-negative', source: replaceOnce(backup,
    '"vortx.addons.tmdbMetaInstalled",', ''), expected: 1,
    failures: ['T6.1', 'T6.3', 'T6.5', 'T6.7'] },
  { name: 'secret-negative', source: replaceOnce(backup,
    'static let secretKeyPrefixes: [String] = [Keychain.fallbackKeyPrefix]',
    'static let secretKeyPrefixes: [String] = []'), expected: 1,
    failures: ['T1.1', 'T1.2', 'T1.3', 'T2.1', 'T3.1', 'T3.3', 'T5.4'] },
  { name: 'invalidation-negative', source: replaceOnce(backup,
    'Keychain.invalidationKeyPrefix,', ''), expected: 1,
    failures: ['T1.5', 'T2.3', 'T3.4', 'T5.5'] },
];
const receipt = { inputs, compiler: 'xcrun swiftc -swift-version 5', variants: [], passed: false };
writeFileSync(join(out, 'receipt.json'), JSON.stringify(receipt, null, 2));
console.log(`Receipts: ${out}`);

function command(executable, args, log, env = process.env) {
  const result = spawnSync(executable, args, { cwd: root, env, encoding: 'utf8', timeout: 180_000 });
  const output = `${result.stdout ?? ''}${result.stderr ?? ''}`;
  writeFileSync(log, output);
  if (result.error || result.signal) throw new Error(`Command did not complete: ${result.error ?? result.signal}`);
  return { status: result.status, output, sha256: digest(output) };
}
try {
  for (const variant of variants) {
    const dir = join(out, variant.name);
    mkdirSync(dir);
    const bundleID = `tv.vortx.tests.settings-backup.${randomUUID()}`;
    const plist = join(dir, 'Info.plist');
    writeFileSync(plist, `<?xml version="1.0" encoding="UTF-8"?>\n` +
      `<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n` +
      `<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundleID}</string>` +
      `<key>CFBundleDisplayName</key><string>VortX isolated settings test</string></dict></plist>\n`);
    const source = join(dir, 'SettingsBackup.swift');
    const binary = join(dir, 'settings-backup-test');
    writeFileSync(source, variant.source);
    const compilation = command('xcrun', ['swiftc', '-swift-version', '5', '-o', binary,
      '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist', '-Xlinker', plist,
      source, ...sharedInputs, testPath], join(dir, 'compiler.log'));
    if (compilation.status !== 0) throw new Error(`${variant.name} compile failed; inspect ${dir}/compiler.log`);
    const absentEnv = { ...process.env };
    delete absentEnv.VORTX_SETTINGS_TEST_BUNDLE_ID;
    for (const [name, env] of [['missing-identity', absentEnv], ['wrong-identity', {
      ...absentEnv, VORTX_SETTINGS_TEST_BUNDLE_ID: `tv.vortx.tests.settings-backup.${randomUUID()}`,
    }]]) {
      const refusal = command(binary, [], join(dir, `${name}.log`), env);
      if (refusal.status !== 2 || !refusal.output.startsWith('REFUSED:')) {
        throw new Error(`${variant.name}: ${name} did not fail closed before defaults access`);
      }
    }
    const runtime = command(binary, [], join(dir, 'runtime.log'), {
      ...process.env, VORTX_SETTINGS_TEST_BUNDLE_ID: bundleID,
    });
    if (runtime.status !== variant.expected) throw new Error(`${variant.name}: unexpected exit ${runtime.status}`);
    const actualFailures = [...runtime.output.matchAll(/^  FAIL  (T\d+\.\d+)\b/gm)].map(match => match[1]);
    if (actualFailures.join(',') !== variant.failures.join(',')) {
      throw new Error(`${variant.name}: unexpected failures ${actualFailures.join(',')}`);
    }
    if (!runtime.output.includes('PASS  T7.1')) throw new Error(`${variant.name}: owned domain cleanup not verified`);
    receipt.variants.push({ name: variant.name, bundleID, expectedExit: variant.expected,
      actualExit: runtime.status, failures: actualFailures, sourceSHA256: digest(variant.source),
      binarySHA256: digest(readFileSync(binary)), compilerLogSHA256: compilation.sha256,
      runtimeLogSHA256: runtime.sha256 });
    console.log(`${variant.name}: expected exit ${variant.expected}; ${actualFailures.length} intentional failures`);
    writeFileSync(join(out, 'receipt.json'), JSON.stringify(receipt, null, 2));
  }
  receipt.passed = true;
  writeFileSync(join(out, 'receipt.json'), JSON.stringify(receipt, null, 2));
} catch (error) {
  receipt.error = String(error);
  writeFileSync(join(out, 'receipt.json'), JSON.stringify(receipt, null, 2));
  console.error(receipt.error);
  process.exitCode = 1;
}
