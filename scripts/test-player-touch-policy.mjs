// Preparation/source contracts only. No compiler, app, device, or playback is invoked.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
fs.mkdirSync(path.join(repo,'app/build'),{recursive:true});
const directory = fs.mkdtempSync(path.join(repo,'app/build/player-touch-policy.'));
const target = path.join(repo,'app/Sources/PlayerScreen.swift');
const text = fs.readFileSync(target, 'utf8');
function block(source, marker) {
  const start = source.indexOf(marker);
  if (start < 0) throw new Error('Missing production declaration: ' + marker);
  const open = source.indexOf('{', start);
  let depth = 1, end = open + 1;
  // This declaration has no string/comment brace literals; reject ambiguous extraction below.
  for (; end < source.length && depth; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  if (depth) throw new Error('Unbalanced declaration');
  return source.slice(start, end);
}
const policy = block(text, 'private struct PlayerVideoTouchPolicy<');
if (target.endsWith('PlayerScreen.swift')) {
  const view = block(text, '@MainActor private struct PlayerVideoInteractionSurface: UIViewRepresentable');
  for (const required of [
    'tap.numberOfTapsRequired = 1', 'tap.numberOfTouchesRequired = 1',
    'recognizer.cancelsTouchesInView = false', 'recognizer.delaysTouchesBegan = false',
    'recognizer.delaysTouchesEnded = false', 'view.isMultipleTouchEnabled = true',
    'coordinator.pinch?.isEnabled = pinchEnabled && !locked',
    'coordinator.onTap = onTap', 'coordinator.onPinch = onPinch',
    'ownership.consumeTap(tapCycle)', 'ownership.consumePinch(pinchCycle)',
    'ownership.invalidate()', 'view.activate = nil',
  ]) if (!view.includes(required)) throw new Error('Missing interaction contract: ' + required);
  if (view.includes('require(toFail:') || view.includes('.exclusively(')) {
    throw new Error('Tap regained a pinch-failure dependency');
  }
}
const fixture = fs.readFileSync(path.join(repo,'app/Tests/PlayerVideoTouchPolicyTests.swift'), 'utf8');
fs.writeFileSync(path.join(directory, 'ExtractedTouchFixture.swift'), policy + '\n\n' + fixture);
const sha256 = value => crypto.createHash('sha256').update(value).digest('hex');
fs.writeFileSync(path.join(directory, 'extraction-receipt.json'), JSON.stringify({
  source: path.resolve(target), sourceSHA256: sha256(text), policySHA256: sha256(policy),
  fixtureSHA256: sha256(fixture), integratedProduction: target.endsWith('PlayerScreen.swift'),
  compiled: false, limitations: 'Policy/event delivery and source wiring, not UIKit synthesized-touch recognition or device performance',
  compiler: ['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
    '-parse-as-library', path.join(directory, 'ExtractedTouchFixture.swift'), '-o', path.join(directory, 'touch-policy-fixture')]
}, null, 2) + '\n');
console.log('Prepared only: ' + directory);

const receipt = JSON.parse(fs.readFileSync(path.join(directory,'extraction-receipt.json'),'utf8'));
const result=spawnSync(receipt.compiler[0],receipt.compiler.slice(1),{encoding:'utf8'});
fs.writeFileSync(path.join(directory,'compiler.log'),(result.stdout??'')+(result.stderr??''));
if(result.status!==0){process.stderr.write(result.stderr??'');process.exit(1);}
const run=spawnSync(path.join(directory,'touch-policy-fixture'),[],{encoding:'utf8'});
fs.writeFileSync(path.join(directory,'runtime.log'),(run.stdout??'')+(run.stderr??''));
const sourceUnchanged=sha256(fs.readFileSync(target,'utf8'))===receipt.sourceSHA256;
fs.writeFileSync(path.join(directory,'result-receipt.json'),JSON.stringify({compilerExit:result.status,runtimeExit:run.status,sourceUnchanged,passed:run.status===0&&sourceUnchanged},null,2)+'\n');
process.stdout.write(run.stdout??'');if(run.status!==0||!sourceUnchanged)process.exit(1);

