#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

// Compile actual macOS cache/worker and show/clear methods against disposable 2x2 images.
// No app/package build, playback, network, live cache or account access.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const fixtureRoot = path.join(root, 'app/build');
fs.mkdirSync(fixtureRoot, {recursive:true});
const dir = fs.mkdtempSync(path.join(fixtureRoot, 'trickplay-local-read.'));
const source = fs.readFileSync(path.join(root, 'app/SourcesShared/ScrubThumbnails.swift'), 'utf8');
function section(start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  if (a < 0 || b <= a) throw Error('Production extraction boundary changed: ' + start);
  return source.slice(a, b);
}
const show = section('    func show(time: Double)', '    /// Heavy frame processing');
const cancel = section('    private func cancelPendingLocalRead()', '    private func cancelCommunityFetch()');
for (const required of [
  'cancelPendingLocalRead()\n        retireCommunityUploadIfNeeded()',
  'pendingLocalReadLease?.cancel()\n        communityFetchTask?.cancel()',
  'communityFetchPolicy.begin(now: ProcessInfo.processInfo.systemUptime)',
  'communityFetchPolicy.finish(now: ProcessInfo.processInfo.systemUptime, succeeded: succeeded)',
  'startCommunityFetchIfNeeded(key: key)',
]) if (!source.includes(required)) throw Error('Lifecycle/retry wiring missing: ' + required);
if (show.indexOf('cancelPendingLocalRead()') > show.indexOf('if CommunityTrickplay.isEnabled'))
  throw Error('A new scrub must retire its preceding read before any fast path');
let cache = source.slice(source.indexOf('private enum LocalTrickplayFramePolicy'), source.lastIndexOf('\n#endif'));
if (!cache.startsWith('private enum LocalTrickplayFramePolicy')) throw Error('Cache extraction changed');
// Access changes only: all production selection, I/O, decoding, queueing and lease checks remain intact.
cache = cache.replaceAll(/private (enum|struct|final class) (LocalTrickplay\w+)/g, '$1 $2')
  .replace('private let ioQueue =', 'let ioQueue =');
const harness = `
@MainActor final class PreviewHarness {
    static var localFrameCache: LocalTrickplayFrameCache!
    var image: ScrubImage?
    var previewState: PreviewState = .hidden
    var localCacheKey: String?
    var communitySheet: CommunityTrickplay.Sheet?
    enum CommunityRemotePhase { case idle, loading, settled }
    var communityRemotePhase = CommunityRemotePhase.settled
    var activeScrubTime: Double?
    var showToken = 0
    var pendingLocalReadToken: Int?
    var pendingLocalReadLease: TrickplayLocalReadLease?
    init(cache: LocalTrickplayFrameCache, key: String) {
        Self.localFrameCache = cache; localCacheKey = key
    }
${cancel}
${show}
}
// No cloud requests in this fixture. The real selection branch is compiled, with local reuse exercised.
enum CommunityTrickplay {
    static let isEnabled = false
    // Durable export is disabled in this preview-only fixture; retain the production call signature.
    static func contentKey(imdbId: String, season: Int?, episode: Int?, duration: Double) -> String? { nil }
    struct Sheet {
        func crop(at time: Double) -> ScrubImage? { nil }
        func nearestCrop(at time: Double) -> ScrubImage? { nil }
    }
}
enum PreviewState { case hidden, loading, ready, unavailable }
`;
fs.writeFileSync(path.join(dir,'cache.swift'),
  'import Foundation\nimport AppKit\nimport CryptoKit\nimport os\ntypealias ScrubImage = NSImage\n' + cache + harness);
const binary = path.join(dir,'run');
const compile = spawnSync('xcrun',['swiftc','-swift-version','6','-strict-concurrency=complete',
  '-warnings-as-errors','-num-threads','1','-j','1','-D','TRICKPLAY_E2E_POLICY_TESTING','-parse-as-library','-o',binary,
  path.join(root,'app/SourcesShared/TrickplayUploadPolicy.swift'),
  path.join(root,'app/SourcesShared/CommunityTrickplay.swift'),path.join(dir,'cache.swift'),
  path.join(root,'app/Tests/TrickplayLocalReadCancellationTests.swift')],
  {encoding:'utf8',timeout:45000,env:{...process.env,SWIFTPM_MAXIMUM_CONCURRENT_OPERATIONS:'1'}});
if(compile.status!==0){process.stderr.write(compile.stdout??'');process.stderr.write(compile.stderr??String(compile.error));process.exit(compile.status??1);}
const result = spawnSync(binary,[dir],{encoding:'utf8',timeout:10000});
process.stdout.write(result.stdout??'');process.stderr.write(result.stderr??'');
console.log('Disposable actual-cache fixtures: '+dir);
process.exit(result.status??1);
