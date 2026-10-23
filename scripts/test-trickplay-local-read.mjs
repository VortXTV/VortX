#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

// Full private production queue/cache, fake image/disk timing, real disk policy tests.
// No app build, playback, accounts, network or device operations.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const fixtureRoot = path.join(root, 'app/build');
fs.mkdirSync(fixtureRoot, {recursive:true});
const dir = fs.mkdtempSync(path.join(fixtureRoot, 'trickplay-local-read.'));
const source = fs.readFileSync(path.join(root, 'app/SourcesShared/ScrubThumbnails.swift'), 'utf8');
const show = source.slice(source.indexOf('    func show(time: Double)'), source.indexOf('    func clear()'));
if (show.indexOf('cancelPendingLocalRead()') < 0 ||
    show.indexOf('cancelPendingLocalRead()') > show.indexOf('if CommunityTrickplay.isEnabled')) {
  throw Error('Newest community/memory fast path must cancel previous local read first');
}
for (const required of [
  'private var pendingLocalReadLease: TrickplayLocalReadLease?',
  'self.pendingLocalReadLease === lease',
  'cancelPendingLocalRead()\n        retireCommunityUploadIfNeeded()',
  'cancelPendingLocalRead()\n        showToken &+= 1',
  'pendingLocalReadLease?.cancel()\n        communityFetchTask?.cancel()',
]) if (!source.includes(required)) throw Error('Scrub owner lifecycle wiring missing: ' + required);
const start = source.indexOf('private final class LocalTrickplayFrameCache');
const end = source.lastIndexOf('\n#endif');
if (start < 0 || end <= start) throw Error('Production cache extraction boundaries changed');
let cache = source.slice(start,end);
// Test seams expose only the serial queue, use isolated cache directory, and
// substitute controllable disk/image fixtures. Every production cache loop,
// lease guard, nearest selection call, callback and queue operation is retained.
cache = cache.replace('private final class LocalTrickplayFrameCache', 'final class LocalTrickplayFrameCache')
  .replace('private let ioQueue =', 'let ioQueue =')
  .replace(/private lazy var cacheDirectory: URL = \{[\s\S]*?\n    \}\(\)/,
           `private lazy var cacheDirectory = URL(fileURLWithPath: "${dir}", isDirectory: true)`)
  .replaceAll('TrickplayFrameDiskStore','RecordingDiskStore');
fs.writeFileSync(path.join(dir,'cache.swift'),'import Foundation\n'+cache);
fs.copyFileSync(path.join(root,'app/Tests/TrickplayLocalReadCancellationTests.swift'),path.join(dir,'main.swift'));
const binary = path.join(dir,'run');
const compile = spawnSync('xcrun',['swiftc','-swift-version','5','-o',binary,
  path.join(root,'app/SourcesShared/TrickplayUploadPolicy.swift'),path.join(dir,'cache.swift'),path.join(dir,'main.swift')],{encoding:'utf8'});
if(compile.status!==0){process.stderr.write(compile.stdout+compile.stderr);process.exit(compile.status??1);}
const result = spawnSync(binary,[],{encoding:'utf8',timeout:15000,env:{...process.env,VORTX_SCRUB_TEST_DIRECTORY:dir}});
process.stdout.write(result.stdout);process.stderr.write(result.stderr);
console.log('Host-only scrub cancellation fixtures: '+dir);
process.exit(result.status??1);
