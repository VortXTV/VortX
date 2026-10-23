import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = new URL('../android/app/src/main/', import.meta.url);
const source = name => readFileSync(new URL(`kotlin/com/vortx/android/${name}`, root), 'utf8');

test('Android recovery export is reachable before Settings and behind picker admission', () => {
  assert.match(source('ui/screens/UnifiedSignInScreen.kt'), /DiagnosticLogAction\(\)/);
  assert.match(source('ui/profilepicker/ProfileSelectionSurface.kt'), /DiagnosticLogAction\(mayShare = request::allowsDiagnosticExport\)/);
  assert.match(source('ui/screens/WhosWatchingScreen.kt'), /pinTarget == null && roster\.none \{ it\.hasPin \}/);
  assert.match(source('ui/screens/WhosWatchingScreen.kt'), /pinTarget == null && store\.profiles\.none \{ it\.hasPin \}/);
});

test('a share click retains its own permission and stages off Main without probe prerequisites', () => {
  const action = source('ui/screens/DiagnosticLogAction.kt');
  assert.match(action, /val admission = currentMayShare/);
  assert.match(action, /shareDiagnosticLog\(context, admission\)/);
  assert.match(action, /finally \{ busy = false \}/);
  assert.match(action, /withContext\(Dispatchers\.IO\) \{ DiagnosticsLog\.stageExport\(context\) \}/);
  assert.doesNotMatch(action, /DiagnosticsLog\.(hasContent|probeEnabled)|nativeAccounts|VortxCore/);
  assert.match(source('ui/screens/DiagnosticsSettingsScreen.kt'), /shareDiagnosticLog\(context\)/);
});

test('selection diagnostic permission is pure local ownership, not native readiness', () => {
  const request = source('profile/ProfileSelectionRequest.kt');
  assert.match(request, /diagnosticAdmission: \(\) -> Boolean = \{ false \}/);
  const witness = request.slice(request.indexOf('diagnosticAdmission = {'));
  assert.match(witness, /ContinueWatchingOwnerGate\.serialized/);
  assert.match(witness, /currentRevision == revision/);
  assert.match(witness, /store\.selectionRevision == generation/);
  assert.match(witness, /store\.profiles === roster && store\.activeID == selected\.id/);
  assert.doesNotMatch(witness, /nativeAdmission|nativeGateway|requireCurrent/);
});

test('export keeps narrow provider paths and read-only URI handoff', () => {
  const action = source('ui/screens/DiagnosticLogAction.kt');
  assert.match(action, /FLAG_GRANT_READ_URI_PERMISSION/);
  assert.doesNotMatch(action, /FLAG_GRANT_WRITE_URI_PERMISSION/);
  assert.match(action, /ClipData\.newRawUri/);
  const paths = readFileSync(new URL('res/xml/update_file_paths.xml', root), 'utf8');
  assert.match(paths, /diagnostics-export\//);
  assert.doesNotMatch(paths, /<(?:root|external)-path|path="(?:\.|\/)"/);
});

test('only scheduled retirement is contained, and failed close never releases its writer', () => {
  assert.match(source('VortXApplication.kt'), /runNativeRetirementAttempt\(close\)/);
  const helper = source('engine/NativeRetirementDispatch.kt');
  assert.match(helper, /catch \(cancel: CancellationException\) \{\s*throw cancel/);
  assert.match(helper, /catch \(_: Exception\) \{\s*onUnconfirmed\(\)/);
  assert.doesNotMatch(helper, /catch[^\n]*(?:Throwable|Error)|retired\.remove/);
  const coordinator = source('engine/NativeAccountCoordinator.kt');
  assert.match(coordinator, /dispose \{ old\.session\.close\(\); retired\.remove\(old\.session\) \}/);
  assert.match(coordinator, /prior\.close\(\); retired\.remove\(prior\)/);
});
