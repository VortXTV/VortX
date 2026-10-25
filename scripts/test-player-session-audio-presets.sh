#!/usr/bin/env bash
set -euo pipefail
preset_script_dir="$(cd "$(dirname "$0")" && pwd)"
preset_root="$(cd "$preset_script_dir/.." && pwd)"
mkdir -p "$preset_root/app/build"
preset_receipt="$(mktemp -d "$preset_root/app/build/player-session-audio-presets.XXXXXX")"
preset_phase="input-conservation"
preset_sources=(
  "$preset_root/app/SourcesShared/PlayerSessionAudioPreset.swift"
  "$preset_root/app/Sources/Player/MPVMetalViewController.swift"
  "$preset_root/app/Sources/PlayerScreen.swift"
  "$preset_root/app/SourcesTV/TVPlayerView.swift"
  "$preset_root/app/Tests/PlayerSessionAudioPresetTests.swift"
  "$preset_root/scripts/test-player-session-audio-presets.sh"
  "$preset_root/scripts/test-apple-playback-recovery.sh"
)
preset_finish() {
  local preset_status=$?
  local preset_conservation=0
  trap - EXIT
  set +e
  shasum -a 256 "${preset_sources[@]}" > "$preset_receipt/source-after.sha256" 2> "$preset_receipt/source-after-errors.log"
  if [[ -f "$preset_receipt/source-before.sha256" ]]; then
    shasum -a 256 -c "$preset_receipt/source-before.sha256" > "$preset_receipt/source-conservation.log" 2>&1
    [[ $? -eq 0 ]] || preset_conservation=1
  else
    preset_conservation=1
  fi
  if [[ -f "$preset_receipt/generated-before.sha256" ]]; then
    shasum -a 256 "$preset_receipt/ActualSessionAudioAdapter.swift" > "$preset_receipt/generated-after.sha256"
    shasum -a 256 -c "$preset_receipt/generated-before.sha256" > "$preset_receipt/generated-conservation.log" 2>&1
    [[ $? -eq 0 ]] || preset_conservation=1
  fi
  if [[ $preset_status -eq 0 && $preset_conservation -ne 0 ]]; then preset_status=1; fi
  {
    printf 'result=%s\n' "$([[ $preset_status -eq 0 ]] && printf PASS || printf FAIL)"
    printf 'exit_status=%s\nphase=%s\nsource_or_generated_drift=%s\n' "$preset_status" "$preset_phase" "$preset_conservation"
    printf 'evidence=source-and-stubbed-native-boundary-only\n'
    printf 'no_filter_graph_audible_device_or_release_proof=true\n'
  } > "$preset_receipt/result.txt"
  printf 'Retained session audio preset receipt: %s\n' "$preset_receipt"
  cat "$preset_receipt/result.txt"
  exit "$preset_status"
}
trap preset_finish EXIT
shasum -a 256 "${preset_sources[@]}" > "$preset_receipt/source-before.sha256"
mkdir -p "$preset_receipt/module-cache"
export CLANG_MODULE_CACHE_PATH="$preset_receipt/module-cache"
export SWIFT_MODULE_CACHE_PATH="$preset_receipt/module-cache"
export OMP_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1
export SWIFTPM_MAXIMUM_CONCURRENT_OPERATIONS=1
export UV_THREADPOOL_SIZE=1
printf 'compiler_jobs=1\ncompiler_threads=1\nOMP_NUM_THREADS=1\nVECLIB_MAXIMUM_THREADS=1\nSWIFTPM_MAXIMUM_CONCURRENT_OPERATIONS=1\nUV_THREADPOOL_SIZE=1\nprivate_module_cache=%s\n' "$preset_receipt/module-cache" > "$preset_receipt/resources.txt"
preset_phase="source-contracts-and-extraction"
node --input-type=module - "$preset_root" "$preset_receipt" <<'NODE' 2>&1 | tee "$preset_receipt/source-contracts.log"
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
const [root, out] = process.argv.slice(2);
const read = path => readFileSync(resolve(root, path), 'utf8');
function declaration(source, signature) {
  const start = source.indexOf(signature);
  assert(start >= 0 && source.indexOf(signature, start + signature.length) < 0, `unique ${signature}`);
  let depth = 0, open = false, state = 'code', escaped = false;
  for (let i = start; i < source.length; i++) {
    const c = source[i], n = source[i + 1];
    if (state === 'line') { if (c === '\n') state = 'code'; continue; }
    if (state === 'block') { if (c === '*' && n === '/') { state = 'code'; i++; } continue; }
    if (state === 'string') { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') state = 'code'; continue; }
    if (c === '/' && n === '/') { state = 'line'; i++; continue; }
    if (c === '/' && n === '*') { state = 'block'; i++; continue; }
    if (c === '"') { state = 'string'; continue; }
    if (c === '{') { depth++; open = true; }
    if (c === '}' && open && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`unterminated ${signature}`);
}
const paths = ['app/SourcesShared/PlayerSessionAudioPreset.swift',
  'app/Sources/Player/MPVMetalViewController.swift', 'app/Sources/PlayerScreen.swift',
  'app/SourcesTV/TVPlayerView.swift', 'app/Tests/PlayerSessionAudioPresetTests.swift'];
const mpv = read(paths[1]);
const availability = declaration(mpv, 'func sessionAudioPresetUnavailableReason(for preset: PlayerSessionAudioPreset)');
const adapter = declaration(mpv, 'func setSessionAudioPreset(_ preset: PlayerSessionAudioPreset)');
assert(availability.length < 2000 && adapter.length < 3200, 'bounded actual native adapter');
assert(availability.includes('guard let spdif = getString("audio-spdif")') &&
  availability.includes('spdif.isEmpty ? nil') && availability.includes('requiresLoadedFile: true'), 'fail closed on missing/nonempty native bitstream state and unloaded file');
assert(adapter.includes('MPVPlaybackProfileOption(handle: handle, name: "af")') &&
  adapter.includes('snapshot.restore(handle: handle, name: "af")'), 'typed exact custom-chain rollback, not string rebuilding');
assert(adapter.includes('var status: Int32 = -1') &&
  adapter.includes('command("af", args: args.map { Optional($0) }, checkForErrors: false) { status = $0 }'),
  'native status is required; silent command absence cannot mean success');
for (const forbidden of ['UserDefaults', 'setAudioTrack(', 'setVolume(', 'setMuted(', 'setAudioDelay(', 'audio-delay', '"volume"', '"mute"']) {
  assert(!adapter.includes(forbidden), `preset adapter cannot mutate ${forbidden}`);
}
const output = declaration(mpv, 'func setAudioOutputMode(_ mode: AudioOutputMode)');
assert(output.indexOf('guard setSessionAudioPreset(.normal) else { return }') >= 0 &&
  output.indexOf('guard setSessionAudioPreset(.normal) else { return }') < output.indexOf('UserDefaults.standard.set'),
  'failed own-DSP cleanup cannot persist/arm a requested bitstream mode');
assert(output.includes('routeIsStereoOnly || routeIsAirPods'), 'preserve setup-time AirPods raw-spdif exclusion during live changes');
for (const signature of ['func setupMpv()', 'func stop()']) {
  assert(declaration(mpv, signature).includes('sessionAudioPreset = PlayerSessionAudioPresetState()'), 'native handle lifecycle resets session-only state');
}
for (const path of paths.slice(2, 4)) {
  const source = read(path);
  const rows = declaration(source, path.includes('SourcesTV') ? 'private var audioPresetRows: [OptionRow]' : 'private var audioPresetRows: [Row]');
  assert(rows.length < 2200 && rows.includes('PlayerSessionAudioPreset.allCases') &&
    rows.includes('PlayerSessionAudioPresetState.avPlayerUnavailable') &&
    rows.includes('isEnabled: unavailable == nil'), 'same shared three presets, explicit AV unavailable');
  assert(rows.includes('(coordinator.player as? MPVMetalViewController)?.setSessionAudioPreset(preset)'),
    'activation resolves current controller rather than a captured retired engine');
  const menu = declaration(source, path.includes('SourcesTV') ? 'private var optionRows: [OptionRow]' : 'private func rows(for p: Panel)');
  const start = menu.indexOf('case .audioSettings:');
  const end = menu.indexOf(path.includes('SourcesTV') ? 'case .subtitles:' : 'case .quality:', start);
  const audioSettings = menu.slice(start, end);
  assert(start >= 0 && end > start && audioSettings.length < 2600, 'bound actual audio settings case only');
  assert(audioSettings.includes('+ audioPresetRows') && audioSettings.includes('contentsOf: audioPresetRows'), 'presets reachable on both AV and MPV menus');
  if (path.includes('SourcesTV')) {
    const audio = menu.slice(menu.indexOf('case .audio:'), start);
    assert(!audio.includes('if !isAVPlayerActive'), 'AV users can reach explicit preset limitation');
    assert(rows.includes('accessibilityID: "audio.preset.\\(preset.rawValue)"'), 'stable per-preset TV focus identity');
  }
}
const fixture = `import Foundation
@MainActor final class MPVPlaybackProfileOption {
    static var allowsSnapshot = true
    static var restoreStatus: Int32 = 0
    static var restoreCount = 0
    static var names: [String] = []
    init?(handle: OpaquePointer, name: String) {
        Self.names.append(name)
        guard Self.allowsSnapshot else { return nil }
    }
    func restore(handle: OpaquePointer, name: String) -> Int32 {
        Self.names.append(name)
        Self.restoreCount += 1
        return Self.restoreStatus
    }
}
@MainActor final class AudioPresetControllerFixture {
    var mpv: OpaquePointer? = OpaquePointer(bitPattern: 1)
    var startMuted = false
    var loaded = true
    var spdif: String? = ""
    private(set) var sessionAudioPreset = PlayerSessionAudioPresetState()
    var statuses: [Int32] = []
    var calls: [[String]] = []
    func callbackLoadToken(requiresLoadedFile: Bool = false) -> Int? { loaded ? 1 : nil }
    func getString(_ name: String) -> String? { precondition(name == "audio-spdif"); return spdif }
    func command(_ command: String, args: [String?] = [], checkForErrors: Bool = true,
                 returnValueCallback: ((Int32) -> Void)? = nil) {
        guard mpv != nil else { return }
        precondition(command == "af" && !checkForErrors)
        calls.append(args.compactMap { $0 })
        returnValueCallback?(statuses.isEmpty ? 0 : statuses.removeFirst())
    }
    ${availability}
    @discardableResult
    ${adapter}
}
`;
writeFileSync(resolve(out, 'ActualSessionAudioAdapter.swift'), fixture);
writeFileSync(resolve(out, 'source-sha256.txt'), paths.map(path =>
  `${createHash('sha256').update(readFileSync(resolve(root, path))).digest('hex')}  ${resolve(root, path)}`).join('\n') + '\n');
console.log('PASS bounded actual session-audio adapters/callers; no MPV filter graph or audible/device proof claimed');
NODE
shasum -a 256 "$preset_receipt/ActualSessionAudioAdapter.swift" > "$preset_receipt/generated-before.sha256"
preset_phase="compile"
nice -n 15 xcrun swiftc -j 1 -num-threads 1 -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path "$preset_receipt/module-cache" \
  -parse-as-library "$preset_root/app/SourcesShared/PlayerSessionAudioPreset.swift" \
  "$preset_receipt/ActualSessionAudioAdapter.swift" "$preset_root/app/Tests/PlayerSessionAudioPresetTests.swift" \
  -o "$preset_receipt/checks" 2>&1 | tee "$preset_receipt/compile.log"
preset_phase="checks"
nice -n 15 "$preset_receipt/checks" 2>&1 | tee "$preset_receipt/checks.log"
preset_phase="complete"
