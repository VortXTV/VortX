#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tv_queue_repo="$PWD"
mkdir -p app/build
tv_queue_dir=$(mktemp -d app/build/tv-download-queue.XXXXXX)
node --input-type=module - "$tv_queue_repo" "$tv_queue_dir" <<'NODE'
import {execFileSync} from 'node:child_process';
import {readFileSync, writeFileSync, statSync} from 'node:fs';
import {createHash} from 'node:crypto';
const [root, dir] = process.argv.slice(2);
const paths = ['app/SourcesTV/TVDownloadsView.swift', 'app/SourcesShared/TVDownloadQueuePresentationPolicy.swift',
    'app/Tests/TVDownloadQueuePresentationTests.swift', 'scripts/test-tv-download-queue-presentation.sh',
    'app/SourcesShared/DownloadManager.swift', 'app/SourcesShared/DownloadModels.swift',
    'app/SourcesShared/DownloadStore.swift', 'app/SourcesShared/CoreModels.swift'];
const read = path => readFileSync(root + '/' + path, 'utf8');
const block = (text, marker) => {
    const start = text.indexOf(marker);
    if (start < 0) throw new Error('Missing actual source: ' + marker);
    let end = text.indexOf('{', start) + 1, depth = 1;
    for (; depth && end < text.length; end++) { if (text[end] === '{') depth++; if (text[end] === '}') depth--; }
    if (depth) throw new Error('Unterminated actual source: ' + marker);
    return text.slice(start, end);
};
const manager = read('app/SourcesShared/DownloadManager.swift');
const declaration = marker => manager.split('\n').find(line => line.includes(marker));
const methods = ['private static func clampConcurrency(', 'func setMaxConcurrentDownloads(',
    'func orderedQueuedRecords()', 'func moveQueuedEarlier(', 'func moveQueuedLater(',
    'private func reorderQueued(', 'private func fillAvailableSlots()'].map(marker => block(manager, marker));
const production = `import Foundation
${manager.slice(manager.indexOf('enum DownloadStartDisposition:'), manager.indexOf('enum DownloadSourceClassification:'))}
enum EpisodePlaybackIdentity {
${block(read('app/SourcesShared/CoreModels.swift'), 'static func usesSeriesLifecycle(type:')}
}
${block(read('app/SourcesShared/DownloadStore.swift'), 'struct DownloadGroup:')}
// Inert actor-bound transfer/index dependencies. No production starter, URLSession or native lease runs.
@MainActor final class FixtureDownloadManager {
    let store = QueueFixtureStore()
    var maxConcurrentDownloads = FixtureDownloadManager.defaultMaxConcurrent
    var queueOrder: [UUID] = []
    var schedulerCoordinator = DownloadSchedulerCoordinator()
    var activeWeight = 0
    var startedIDs: [UUID] = []
    ${['static let concurrencyRange', 'private static let defaultMaxConcurrent', 'static let maxConcurrentDefaultsKey', 'static let queueOrderDefaultsKey'].map(declaration).join('\n')}
    private func transport(for record: DownloadRecord) -> DownloadSchedulerCoordinator.Transport { .byte }
    private func startQueued(_ record: DownloadRecord) -> DownloadStartDisposition {
        startedIDs.append(record.id)
        store.update(id: record.id) { $0.state = .downloading }
        activeWeight += 1
        return .started
    }
    ${methods.join('\n')}
}
`;
writeFileSync(dir + '/ActualQueueMethods.swift', production);
const baseline = '94dd93635277f94a608c97ed7fd732a2057ad35d';
const original = execFileSync('git', ['-C', root, 'show', baseline + ':app/SourcesTV/TVDownloadsView.swift'], {encoding:'utf8'});
if (original.includes('manager.moveQueuedEarlier') || original.includes('manager.setMaxConcurrentDownloads')
    || original.includes('@ObservedObject private var manager')) throw new Error('Original queue UI gap changed');
if (block(original, 'private func play(') !== block(read(paths[0]), 'private func play(')) throw new Error('Local playback behavior changed');
writeFileSync(dir + '/BaselineTVDownloadsView.swift', original);
console.log('SOURCE ONLY: original94 TV surface lacks observable capacity/priority controls; local-play method unchanged. No full behavioral RED is claimed.');
const inputs = paths.map(path => {
    const bytes = readFileSync(root + '/' + path);
    writeFileSync(dir + '/' + path.split('/').at(-1), bytes);
    return {path, mode: (statSync(root + '/' + path).mode & 0o777).toString(8), sha256: createHash('sha256').update(bytes).digest('hex')};
});
writeFileSync(dir + '/manifest.json', JSON.stringify({baseline, inputs}, null, 2));
console.log('Frozen queue source/test inputs: ' + dir + '/manifest.json');
NODE
if [[ "$*" == "--freeze-only" ]]; then
    printf '%s\n' "Review freeze without compiler: $tv_queue_dir"
    exit 0
fi
swiftc -parse-as-library "$tv_queue_dir/ActualQueueMethods.swift" "$tv_queue_dir/DownloadModels.swift" \
    "$tv_queue_dir/TVDownloadQueuePresentationPolicy.swift" "$tv_queue_dir/TVDownloadQueuePresentationTests.swift" \
    -o "$tv_queue_dir/queue-tests"
"$tv_queue_dir/queue-tests" "$tv_queue_dir/TVDownloadsView.swift" | tee "$tv_queue_dir/queue-tests.log"
printf '%s\n' "Retained offline TV queue receipts: $tv_queue_dir"
