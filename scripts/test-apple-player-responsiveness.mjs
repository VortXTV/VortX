#!/usr/bin/env node
// Exact production extraction: no application build, player, socket, GPU or account activity.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
const root = process.cwd();
const output = process.argv[2];
if (!output || !path.isAbsolute(output) || !fs.statSync(output).isDirectory()) throw new Error('Pass an existing absolute receipt directory');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
function slice(text, first, next) {
  const a = text.indexOf(first), b = text.indexOf(next, a);
  if (a < 0 || b < 0) throw new Error('Production marker not found: ' + first);
  return text.slice(a, b);
}
const renderer = read('app/Sources/Player/SubtitleCueRenderer.swift');
const parser = slice(renderer, '/// One ceiling', '/// Downloads external subtitle bytes');
const subtitleMethod = slice(read('app/Sources/Player/AVPlayerEngine.swift'),
  '    func addExternalSubtitle(url: String, title: String, lang: String,', '\n    /// Stop rendering the external overlay subtitle.');
if (subtitleMethod.split('SubtitleCueRenderer.parse(data: data)').length !== 2) throw new Error('Expected one production parser call');
const subtitle = read('app/Tests/SubtitleBackgroundParsingContractTests.swift').replace('    // __PRODUCTION_ADD_EXTERNAL_SUBTITLE__',
  subtitleMethod.replace('SubtitleCueRenderer.parse(data: data)', 'ControlledSubtitleParser.parse(data: data)'));
const completion = text => slice(text, '        player.captureFrameJPEGData(maxWidth: 480) { data in', '\n    }\n\n    /// Wall-clock');
const capture = read('app/Tests/CaptureDecodeSchedulingContractTests.swift')
  .replace('        // __PRODUCTION_TV_CAPTURE_COMPLETION__', completion(read('app/SourcesTV/TVPlayerView.swift')))
  .replace('        // __PRODUCTION_IOS_CAPTURE_COMPLETION__', completion(read('app/Sources/PlayerScreen.swift')));
const fetcher = slice(renderer, 'enum SubtitleFileFetcher', '\n#if canImport(UIKit)');
// Only local URLs are exercised. A transport stub traps any accidental network attempt.
const transport = `enum PinnedHTTPClient {
struct Limits: Sendable { var maximumBodyBytes = 0; var maximumStreamBytes = 0; var maximumWireBytes = 0; var timeout: TimeInterval = 0 }
struct Request: Sendable { let url: URL }
struct Response: Sendable { let statusCode: Int; let body: Data }
static func execute(_ request: Request, limits: Limits) async throws -> Response { preconditionFailure("No network in local-file fixture") }
}`;
const fetch = `${parser}\n${fetcher}\n${transport}\n${read('app/Tests/SubtitleLocalFileBudgetContractTests.swift')}`;
for (const [name, source] of [['subtitle', `${parser}\n${subtitle}`], ['capture', capture], ['local-fetch', fetch]]) {
  if (source.includes('__PRODUCTION_')) throw new Error('Unfilled production marker');
  for (const version of ['5', '6']) {
    const fixture = path.join(output, `player-responsiveness-${name}-swift${version}.swift`);
    const executable = fixture.slice(0, -6);
    fs.writeFileSync(fixture, 'import Foundation\n' + source);
    const compiled = spawnSync('xcrun', ['swiftc', '-O', '-swift-version', version, '-strict-concurrency=complete', '-parse-as-library', fixture, '-o', executable], { encoding: 'utf8' });
    process.stdout.write(compiled.stdout); process.stderr.write(compiled.stderr);
    if (compiled.status !== 0) process.exit(compiled.status ?? 1);
    const tested = spawnSync(executable, [output], { encoding: 'utf8', timeout: 30000 });
    process.stdout.write(tested.stdout); process.stderr.write(tested.stderr);
    if (tested.status !== 0) process.exit(tested.status ?? 1);
  }
}
console.log('APPLE_PLAYER_RESPONSIVENESS_CONTRACTS_GREEN');
