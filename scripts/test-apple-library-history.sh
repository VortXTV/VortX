#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
library_repo="$PWD"
mkdir -p app/build
library_test_dir=$(mktemp -d app/build/library-history.XXXXXX)
library_baseline_ref=844782d29a93ae51991bfadc639d50bc3619d40b
node --input-type=module - "$library_repo" "$library_baseline_ref" "$library_test_dir" <<'NODE'
import {execFileSync} from 'node:child_process';
import {readFileSync, writeFileSync, statSync} from 'node:fs';
import {createHash} from 'node:crypto';
const [root, ref, dir] = process.argv.slice(2);
const source = path => readFileSync(root + '/' + path, 'utf8');
const method = (text, marker) => {
    const start = text.indexOf(marker);
    if (start < 0) throw new Error('Missing production method ' + marker);
    let end = text.indexOf('{', start) + 1, depth = 1;
    while (depth && end < text.length) { if (text[end] === '{') depth++; if (text[end] === '}') depth--; end++; }
    if (depth) throw new Error('Unterminated production method ' + marker);
    return text.slice(start, end);
};
const models = source('app/SourcesShared/CoreModels.swift');
writeFileSync(dir + '/HistoryModels.swift', models.slice(0, models.indexOf('// MARK: Continue-Watching exact-source resume')));
writeFileSync(dir + '/HistoryJSON.swift', 'import Foundation\n' +
    method(source('app/SourcesShared/VortxResourceBridge.swift'), 'indirect enum VortxJSON:'));
writeFileSync(dir + '/HistoryAccessor.swift', 'import Foundation\nextension CoreBridge {\n' +
    method(source('app/SourcesShared/CoreBridge.swift'), '    func nativeHistorySnapshot(target:') + '\n}\n');
const baseline = execFileSync('git', ['-C', root, 'show', ref + ':app/SourcesiOS/iOSRootView.swift'], {encoding:'utf8'});
const library = baseline.slice(baseline.indexOf('struct iOSLibraryView:'));
if (!library.includes('activeFilters = [.watched]')) throw new Error('Baseline no longer routes Previously Watched through the saved grid');
writeFileSync(dir + '/BaselineLibrary.swift', 'import Foundation\nstruct BaselineIOSLibrary {\nlet core: CoreBridge\nlet profiles: ProfileStore\n' +
    method(library, '    private var libraryItems:').replace('private var', 'var') + '\n}\n');
writeFileSync(dir + '/DirectResumeHelper.swift', 'import Foundation\n@MainActor\n' +
    method(source('app/SourcesiOS/iOSRootView.swift'), 'private func iOSDirectResume(').replace('private func', 'func'));
// Only a signature adapter admits the new argument to the reviewed old body; that body deliberately
// ignores it. No baseline branch, predicate, await or side effect is replaced.
writeFileSync(dir + '/BaselineDirectResumeHelper.swift', 'import Foundation\n@MainActor\n' +
    method(baseline, 'private func iOSDirectResume(').replace('private func', 'func')
        .replace('expectedTraktSession: TraktSessionID?)', 'expectedTraktSession: TraktSessionID?, expectedIntent: HomeContinueWatchingSelection.Intent? = nil)'));
const ios = source('app/SourcesiOS/iOSRootView.swift').slice(source('app/SourcesiOS/iOSRootView.swift').indexOf('struct iOSLibraryView:'));
const tv = source('app/SourcesTV/LibraryView.swift');
for (const [text, fragment] of [[ios, 'NavigationLink(value: LibraryRoute.history)'], [ios, 'case .history: iOSPreviouslyWatchedView'],
    [ios, 'videoID: entry.item.state.videoId'], [tv, 'NavigationLink(value: Destination.history)'],
    [tv, 'case .history: historyDestination'], [tv, 'CoreContinueWatchingRow(items: cw.selection.items'],
    [ios, '.id(context)'], [ios, 'onOpen: { openLibraryWatchlist($0, context: context, autoPlay: false)'],
    [ios, 'onWatch: { openLibraryWatchlist($0, context: context, autoPlay: true)'],
    [ios, 'guard context.isCurrent(core: core, profiles: profiles) else { return }'],
    [ios, 'expectedTraktSession: provenance.traktSessionID, expectedIntent: provenance.intent'],
    [ios, 'Task {\n            guard provenance.isCurrent(traktSessionID: TraktAuth.storedSessionID) else { return }'],
    [tv, '.popToRootOnBump(TabScrollKeys.library, path: $path)']]) {
    if (!text.includes(fragment)) throw new Error('Missing real Library route/wiring: ' + fragment);
}
console.log('PASS: iOS/macOS and tvOS production Library destinations and episode wiring');
const frozenPaths = [
    'app/SourcesShared/CoreBridge.swift', 'app/SourcesShared/CoreModels.swift',
    'app/SourcesShared/VortxResourceBridge.swift', 'app/SourcesShared/PlaybackMutationOwnershipPolicy.swift',
    'app/SourcesShared/LibraryLandingSnapshot.swift', 'app/SourcesiOS/iOSRootView.swift',
    'app/SourcesTV/LibraryView.swift', 'app/Tests/LibraryLandingSnapshotTests.swift',
    'app/Tests/LibraryDirectResumeAdmissionTests.swift',
    'scripts/test-apple-library-history.sh'
];
const manifest = frozenPaths.map(path => {
    const bytes = readFileSync(root + '/' + path);
    writeFileSync(dir + '/' + path.split('/').at(-1), bytes);
    return {path, mode: (statSync(root + '/' + path).mode & 0o777).toString(8), sha256: createHash('sha256').update(bytes).digest('hex')};
});
writeFileSync(dir + '/manifest.json', JSON.stringify({baseline: ref, inputs: manifest}, null, 2));
writeFileSync(dir + '/candidate.patch', execFileSync('git', ['-C', root, 'diff', '--', ...frozenPaths]));
console.log('Frozen production and fixture inputs: ' + dir + '/manifest.json');
NODE
if [[ "$*" == "--freeze-only" ]]; then
    printf '%s\n' "Frozen review inputs without compilation: $library_test_dir"
    exit 0
fi
compile_history() {
    swiftc -parse-as-library -D VORTX_NATIVE_DATA_ENGINE "$@" \
        "$library_test_dir/HistoryModels.swift" \
        "$library_test_dir/HistoryJSON.swift" "$library_test_dir/PlaybackMutationOwnershipPolicy.swift" \
        "$library_test_dir/HistoryAccessor.swift" "$library_test_dir/LibraryLandingSnapshot.swift" \
        "$library_test_dir/LibraryLandingSnapshotTests.swift"
}
compile_history -D LIBRARY_HISTORY_BASELINE "$library_test_dir/BaselineLibrary.swift" -o "$library_test_dir/baseline"
if "$library_test_dir/baseline" > "$library_test_dir/baseline.log" 2>&1; then
    printf '%s\n' 'FAIL: saved-grid baseline unexpectedly included unsaved native history'
    exit 1
fi
rg -F 'FAIL: Previously Watched retains unsaved native history' "$library_test_dir/baseline.log"
printf '%s\n' "Verified RED production saved-grid baseline: $library_baseline_ref"
compile_history -o "$library_test_dir/history"
"$library_test_dir/history" | tee "$library_test_dir/history.log"
swiftc -parse-as-library "$library_test_dir/PlaybackMutationOwnershipPolicy.swift" \
    "$library_test_dir/BaselineDirectResumeHelper.swift" "$library_test_dir/LibraryDirectResumeAdmissionTests.swift" \
    -o "$library_test_dir/resume-baseline"
if "$library_test_dir/resume-baseline" > "$library_test_dir/resume-baseline.log" 2>&1; then
    printf '%s\n' 'FAIL: unfenced resume baseline unexpectedly rejected the late Library task'
    exit 1
fi
rg -F 'FAIL: late Task cannot borrow a new same-profile account epoch or invoke side effects' "$library_test_dir/resume-baseline.log"
printf '%s\n' "Verified RED production resume-helper baseline: $library_baseline_ref"
swiftc -parse-as-library "$library_test_dir/PlaybackMutationOwnershipPolicy.swift" \
    "$library_test_dir/DirectResumeHelper.swift" "$library_test_dir/LibraryDirectResumeAdmissionTests.swift" \
    -o "$library_test_dir/resume"
"$library_test_dir/resume" | tee "$library_test_dir/resume.log"
printf '%s\n' "Retained offline receipts: $library_test_dir"
