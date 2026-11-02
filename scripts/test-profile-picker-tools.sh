#!/usr/bin/env bash
# Actual maintained controller and diagnostic admission, disposable file/account collaborators.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import hashlib,json,pathlib,subprocess
root=pathlib.Path.cwd()
out=root/'app/build/profile-picker-tools'
out.mkdir(parents=True,exist_ok=True)
sources=['app/SourcesShared/ProfilePickerToolsAccess.swift',
         'app/SourcesShared/ProfilePickerToolsController.swift',
         'app/Tests/ProfilePickerToolsLifecycleTests.swift']
(out/'source-sha256.json').write_text(json.dumps({p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sources},indent=2)+'\n')
# One compiler, complete concurrency checking, bounded wall time. No copied controller implementation.
compile=['nice','-n','15','swiftc','-swift-version','6','-strict-concurrency=complete',
         '-warnings-as-errors','-j','1','-num-threads','1','-parse-as-library',*sources,
         '-o',str(out/'checks')]
subprocess.run(compile,check=True,timeout=90)
subprocess.run(['nice','-n','15',str(out/'checks')],check=True,timeout=45)
# UI seams complement actual scheduled model tests and retained channel/auth policy suites.
view=(root/'app/SourcesShared/ProfilePickerToolsView.swift').read_text()
profiles=(root/'app/SourcesShared/ProfilesView.swift').read_text()
settings=(root/'app/SourcesShared/SyncSettingsView.swift').read_text()
export=(root/'app/SourcesShared/DiagnosticLogExportButton.swift').read_text()
assert '.fileImporter(isPresented:' in view and 'allowsMultipleSelection: false' in view
assert '[.folder] : [.json, .data]' in view and 'completion(request, result)' in view
assert 'ProfilePickerToolsFilePicker(request: request)' in view and '.id(request.id)' in view
assert 'Button("Back") { close() }' in view and '.interactiveDismissDisabled(true)' in view
assert '.onDisappear { controller.cancel() }' not in view
assert 'profileAction.cancel(preservingFailure: toolsRoute != nil || accountHelpNeeded)' in profiles
assert 'accountHelpDiagnosticGrant = diagnosticGrant()' in profiles
assert settings.count('DiagnosticLogExportButton(grant: exportGrant)') == 2
assert 'ShareLink(item: PreProfileDiagnosticLogTransfer(grant: grant)' in export
staging=export[export.index('FileRepresentation(exportedContentType: .plainText)'):export.index('\n#else\n@MainActor',export.index('FileRepresentation(exportedContentType: .plainText)'))]
assert staging.count('try await require(transfer.grant)') == 3
assert staging.index('try await require(transfer.grant)') < staging.index('VXDiagExport.exportBody()')
assert staging.rindex('try await require(transfer.grant)') < staging.index('return SentTransferredFile(destination)')
assert 'VortXSyncManager' not in export and 'Keychain.shared' not in export
print('PASS Tools file picker, route lifetime and async diagnostic grant staging seams')
PY
