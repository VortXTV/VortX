#!/usr/bin/env node
'use strict';
// No production body rewriting: use the maintained actual-source repair extraction and replace
// only its @main fixture with this explicitly named Apple projection oracle. No generic extras.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const base = require('./account-backup-repair-inputs.cjs');
function extract(root, directory) {
  root = fs.realpathSync(root);
  directory = fs.realpathSync(directory);
  const manifest = base.extract(root, directory);
  const old = 'app/Tests/VortxAccountBackupRepairTests.swift';
  const replacement = 'app/Tests/AccountFileProfileMaterialParityTests.swift';
  const fixture = 'android/app/src/test/resources/account-file-profile-material.json';
  const urlFixture = 'android/app/src/test/resources/account-file-addon-url-vectors.json';
  const recipe = 'test/account-file-profile-material-inputs.cjs';
  assert.equal(manifest.wholeFiles.filter(item => item === old).length, 1, 'one expected original main');
  assert.equal(manifest.compilerInputs.filter(item => item === path.join(root, old)).length, 1, 'one expected compiled main');
  manifest.wholeFiles = manifest.wholeFiles.map(item => item === old ? replacement : item);
  manifest.compilerInputs = manifest.compilerInputs.map(item => item === path.join(root, old) ? path.join(root, replacement) : item);
  delete manifest.sourceHashes[old];
  for (const relative of [replacement, fixture, urlFixture, recipe]) {
    manifest.sourceHashes[relative] = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, relative))).digest('hex');
  }
  const oracleOutput = path.join(directory, 'apple-file-addon-url-oracle.json');
  assert(!fs.existsSync(oracleOutput), 'oracle output must be new');
  manifest.runtimeArguments = [path.join(root, fixture), path.join(root, urlFixture), oracleOutput];
  manifest.oracleOutput = oracleOutput;
  manifest.scope = 'Actual Apple profile projection against shared authored Android vectors; no native dispatch/account/session proof';
  fs.writeFileSync(path.join(directory, 'inputs.json'), JSON.stringify(manifest, null, 2) + '\n');
  return manifest;
}
module.exports = { extract };
if (require.main === module) {
  assert.equal(process.argv.length, 4, 'usage: node test/account-file-profile-material-inputs.cjs ROOT EXISTING_BUILD_DIRECTORY');
  const result = extract(process.argv[2], process.argv[3]);
  process.stdout.write(JSON.stringify({scope: result.scope, runtimeArguments: result.runtimeArguments}) + '\n');
}
