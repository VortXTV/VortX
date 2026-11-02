#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$PWD/app/build/account-authentication-lifecycle"
mkdir -p "$build_dir"
python3 - "$build_dir" <<'PY'
import hashlib, json, pathlib, sys
root=pathlib.Path.cwd()
out=pathlib.Path(sys.argv[1])
paths={
    'settings':'app/SourcesShared/SyncSettingsView.swift',
    'profiles':'app/SourcesShared/ProfilesView.swift',
    'touch':'app/SourcesiOS/iOSSignInView.swift',
    'manager':'app/SourcesShared/VortXSyncManager.swift',
    'tvroot':'app/SourcesTV/RootTabView.swift',
    'touchroot':'app/SourcesiOS/iOSRootView.swift',
}
sources={key:(root/path).read_text() for key,path in paths.items()}
def method(key, marker):
    text=sources[key]
    assert text.count(marker)==1, (key,marker)
    start=text.index(marker)
    end=text.index('\n    }\n',start)+len('\n    }')
    return text[start:end]
extracts={
    'PRODUCTION_SUBMIT':method('settings','    private func submit() {'),
    'PRODUCTION_HANDLE':method('settings','    private func handle(_ result: VortXSyncManager.AuthResult, attempt: UUID) {'),
    'PRODUCTION_COMPLETE':method('settings','    private func completeAuthentication(acknowledgingCode: Bool = false) {'),
    'PRODUCTION_SYNC_NOW':method('settings','    private func syncNow() {'),
    'PRODUCTION_RESOLVE_CONFLICT':method('settings','    private func resolveConflict(_ decision: AccountActionLease,'),
    'PRODUCTION_REVIEW_CONFLICT':method('settings','    private func reviewConflict(_ decision: AccountActionLease) {'),
    'PRODUCTION_CANCEL_CONFLICT':method('settings','    private func cancelConflict(_ decision: AccountActionLease) {'),
    'PRODUCTION_OPEN_QR':method('settings','    private func openQR() {'),
    'PRODUCTION_COMPLETE_QR':method('settings','    private func completeQR(attempt: UUID) {'),
    'PRODUCTION_CANCEL_QR':method('settings','    private func cancelQR(attempt: UUID) {'),
    'PRODUCTION_RECOVERY_DISMISS':method('profiles','    private func dismissIfAllowed() {'),
    'PRODUCTION_TOUCH_DISMISS':method('touch','    private func dismissIfAllowed() {'),
    'PRODUCTION_TV_ROOT_BINDING':method('tvroot','    private var pickerPresented: Binding<Bool> {'),
    'PRODUCTION_TOUCH_ROOT_BINDING':method('touchroot','    private var pickerPresented: Binding<Bool> {'),
}
owed='    private var pickerOwed: Bool {'
assert sources['touchroot'].count(owed)==1
extracts['PRODUCTION_TOUCH_ROOT_OWED']=next(line for line in sources['touchroot'].splitlines() if line.startswith(owed))
scope_start='.onReceive(NotificationCenter.default.publisher(for: VortXSyncManager.credentialScopeDidChangeNote)) { _ in\n'
settings=sources['settings']; assert settings.count(scope_start)==1
scope=settings.index(scope_start)+len(scope_start)
extracts['PRODUCTION_SCOPE_RESET']=settings[scope:settings.index('\n        }',scope)]
manager=sources['manager']
start='        // Issue UI ownership before returning across the await boundary.'
end='        // Reconciliation is decided by the UI after sign-in'
assert manager.count(start)==manager.count(end)==1
extracts['PRODUCTION_MANAGER_RECEIPT']=manager[manager.index(start):manager.index(end)]
template=(root/'app/Tests/AccountAuthenticationLifecycleTests.swift').read_text()
for name, body in extracts.items():
    marker='/* '+name+' */'
    assert template.count(marker)==1
    template=template.replace(('        ' if name=='PRODUCTION_MANAGER_RECEIPT' else '    ')+marker,body) if name!='PRODUCTION_SCOPE_RESET' else template.replace(marker,body)
assert '/* PRODUCTION_' not in template
(out/'ActualAuthenticationActions.swift').write_text(template)
manifest={'sourceSHA256':{paths[key]:hashlib.sha256(text.encode()).hexdigest() for key,text in sources.items()},
          'extractedSHA256':{key:hashlib.sha256(value.encode()).hexdigest() for key,value in extracts.items()},
          'normalizations':0}
(out/'extraction.json').write_text(json.dumps(manifest,indent=2)+'\n')
# Wiring assertions complement executable methods; they do not stand in for lifecycle checks.
settings=sources['settings']; profiles=sources['profiles']; touch=sources['touch']
assert settings.count('if diagnosticExportIsAllowed { DiagnosticLogExportButton(grant: exportGrant) }')==2
assert 'diagnosticGrant: diagnosticGrant' in profiles
assert 'accountHelpDiagnosticGrant = diagnosticGrant()' in profiles
assert 'if let diagnosticGrant { return diagnosticGrant }' in settings
assert settings.index('if let code = authentication.recoveryCodeForCurrentOwner') < settings.index('else if sync.isSignedIn')
assert 'newRecoveryCode' not in settings
assert 'diagnosticCredential.map { CredentialScopeRegistry.shared.isCurrent($0) }' in settings
assert 'accountHelpAllowsDiagnostics = exportAllowedBeforeProfile && pinTarget == nil' in profiles
assert 'accountHelpDiagnosticCredential = CredentialScopeRegistry.shared.capture()' in profiles
assert 'accountHelpAllowsDiagnostics = false\n            accountHelpDiagnosticCredential = nil' in profiles
assert 'var allowsDiagnosticExport = true' in profiles # existing unlocked-profile callers retain default
assert 'authentication: authentication)' in profiles
assert 'authentication: vortxAuthentication)' in touch
assert '.interactiveDismissDisabled(authentication.blocksDismissal)' in profiles
assert '.interactiveDismissDisabled(vortxAuthentication.blocksDismissal)' in touch
assert '.navigationBarBackButtonHidden(authentication.blocksDismissal)' in settings
assert 'onValueChange(of: vortxSync.isSignedIn)' not in touch
assert '.onValueChange(of: account.isSignedIn)' in touch
assert 'guard !showVortXEmail, !vortxAuthentication.blocksDismissal,' in touch
assert 'core.signedInWithLegacyAuthKey()' in touch
assert 'VortXAccountJoinerView(onSignedIn:' in touch
assert sources['tvroot'].count('ProfilePickerView(authentication: profileAuthentication)')==1
assert sources['touchroot'].count('ProfilePickerView(authentication: profileAuthentication)')==2
assert 'authentication: accountAuthentication)' in profiles
assert 'accountAuthentication.credentialDidChange()' in profiles
assert '.sheet(item: $qrPresentation)' in settings
assert '.onDisappear { cancelQR(attempt: presentation.id) }' in settings
assert 'resolveConflict(decision) { await sync.mergeBoth()' in settings
assert 'resolveConflict(decision) { await sync.useAccountData()' in settings
assert 'Button("Not now", role: .cancel) { cancelConflict(decision) }' in settings
assert 'Button("Review sync conflict") { reviewConflict(decision) }' in settings
print('PASS auth route diagnostics, code priority, shared parent state and distinct QR/Stremio wiring')
PY
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
  -parse-as-library app/SourcesShared/AccountAuthenticationPresentation.swift \
  "$build_dir/ActualAuthenticationActions.swift" -o "$build_dir/checks"
"$build_dir/checks"
