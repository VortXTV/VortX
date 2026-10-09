#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
cw_repo_root="$PWD"
mkdir -p app/build
cw_build_dir=$(mktemp -d app/build/home-cw-selection.XXXXXX)
cw_inputs=(
    app/Tests/HomeContinueWatchingFixtureStubs.swift
    app/SourcesShared/PlaybackMutationOwnershipPolicy.swift
    app/SourcesShared/ExternalSyncSessionPolicy.swift
    app/SourcesShared/TraktScrobbleProgressPolicy.swift
    app/SourcesShared/TraktArtworkPolicy.swift
    app/SourcesShared/TraktContinueWatchingFold.swift
    app/SourcesShared/TraktPlaybackShadow.swift
    app/SourcesShared/HomeContinueWatchingSelection.swift
    app/Tests/HomeContinueWatchingSelectionTests.swift
)

# RED uses the exact pre-fix TV and iOS selection property bodies, extracted from
# the reviewed parent commit. The same production shadow and fixture snapshot run.
cw_baseline_ref="${CW_BASELINE_REF:-01a0ec988205781d345d94ec2c30a65d1f1bca8c}"
node --input-type=module - "$cw_repo_root" "$cw_baseline_ref" "$cw_build_dir/BaselineSelection.swift" <<'NODE'
import {execFileSync} from 'node:child_process';
import {writeFileSync} from 'node:fs';
const [root, ref, output] = process.argv.slice(2);
const paths = [['TV', 'app/SourcesTV/HomeView.swift'], ['IOS', 'app/SourcesiOS/iOSRootView.swift']];
let fixture = 'import Foundation\n';
for (const [surface, path] of paths) {
    const source = execFileSync('git', ['-C', root, 'show', `${ref}:${path}`], {encoding:'utf8'});
    const start = source.indexOf('private var continueWatchingSelection:');
    if (start < 0) throw new Error(`Missing reviewed ${surface} selection`);
    const brace = source.indexOf('{', start);
    let end = brace + 1, depth = 1;
    for (; depth && end < source.length; end++) {
        if (source[end] === '{') depth++;
        if (source[end] === '}') depth--;
    }
    if (depth) throw new Error(`Unterminated reviewed ${surface} selection`);
    fixture += `struct Baseline${surface}HomeSelection {\nlet core: CoreBridge\nlet profiles: ProfileStore\nlet traktContinueWatchingRevision = 0\n`;
    fixture += source.slice(start, end).replace('private var', 'var') + '\n}\n';
}
writeFileSync(output, fixture);
NODE
swiftc -parse-as-library -D CW_BASELINE "${cw_inputs[@]}" "$cw_build_dir/BaselineSelection.swift" -o "$cw_build_dir/baseline"
if "$cw_build_dir/baseline" > "$cw_build_dir/baseline.log" 2>&1; then
    printf '%s\n' 'FAIL: reviewed baseline unexpectedly retained native Trakt selection'
    exit 1
fi
rg -F 'FAIL: native TV retains the selected Trakt source' "$cw_build_dir/baseline.log"
rg -F 'FAIL: native iOS/macOS retains the selected Trakt source' "$cw_build_dir/baseline.log"
printf '%s\n' "Verified RED baseline: $cw_baseline_ref"

swiftc -parse-as-library "${cw_inputs[@]}" -o "$cw_build_dir/selection"
"$cw_build_dir/selection" "$cw_repo_root" | tee "$cw_build_dir/selection.log"
printf '%s\n' "Retained offline receipts: $cw_build_dir"
