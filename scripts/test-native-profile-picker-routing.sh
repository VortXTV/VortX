#!/usr/bin/env bash
set -euo pipefail

# The optional root argument permits independent review of this test artifact before
# integration. Normal repository use needs no arguments. No app/SDK build or account I/O.
picker_script_dir="$(cd "$(dirname "$0")" && pwd)"
picker_repo_root="${1:-$(cd "$picker_script_dir/.." && pwd)}"
picker_template="$picker_script_dir/../app/Tests/NativeProfilePickerRoutingTests.swift"
test -f "$picker_repo_root/app/SourcesShared/ProfilesView.swift"
test -f "$picker_template"
mkdir -p "$picker_repo_root/app/build"
picker_test_dir="$(mktemp -d "$picker_repo_root/app/build/profile-picker-routing.XXXXXX")"
printf 'Retained synthetic picker test output: %s\n' "$picker_test_dir"

ruby - "$picker_repo_root" "$picker_template" "$picker_test_dir" "$picker_script_dir/test-native-profile-picker-routing.sh" <<'RUBY'
require 'digest'
root, template_path, out, runner_path = ARGV
source_path = File.join(root, 'app/SourcesShared/ProfilesView.swift')
source = File.read(source_path)
store_path = File.join(root, 'app/SourcesShared/Profiles.swift')
store_source = File.read(store_path)
ios_root_path = File.join(root, 'app/SourcesiOS/iOSRootView.swift')
tv_root_path = File.join(root, 'app/SourcesTV/RootTabView.swift')
template = File.read(template_path)

def between(source, begin_marker, end_marker)
  first = source.index(begin_marker) or raise "Missing start #{begin_marker}"
  first += begin_marker.length
  last = source.index(end_marker, first) or raise "Missing end #{end_marker}"
  source[first...last]
end

# Actual manual request state and eligibility; synthetic profile/account collaborators stay explicit.
store_state = '    @Published var pickedThisLaunch = false {' + between(store_source,
  '    @Published var pickedThisLaunch = false {', "    /// The ACTIVE overlay profile's private watch state")
needed = '    var needsPicker: Bool {' + between(store_source, '    var needsPicker: Bool {', "\n    }\n") + "\n    }\n"
root_dismissals = [ios_root_path, tv_root_path].map do |path|
  root_picker = between(File.read(path), '    private var pickerPresented: Binding<Bool> {', "\n    }\n")
  between(root_picker, '            set: { presented in', "\n            }\n")
end

# Limit extraction to the actual picker; never use a similarly named editor callback.
picker = between(source, 'struct ProfilePickerView: View {',
                 '/// A bounded public Cinemeta')
# Bind construction before appearance. The argument is taken from the real iOS root and required
# at both iOS/App Store call sites and the TV root; the actual initializer assignment is verbatim.
root_call_prefix = 'ProfilePickerView(authentication: profileAuthentication, pickerAdmission: '
root_argument = between(File.read(ios_root_path), root_call_prefix, ', manualPickerDismissal: ')
dismissal_prefix = root_call_prefix + root_argument + ', manualPickerDismissal: '
dismissal_argument = between(File.read(ios_root_path), dismissal_prefix, ') }')
root_call = dismissal_prefix + dismissal_argument + ')'
raise 'Missing exact iOS/Mac construction admission' unless File.read(ios_root_path).scan(root_call).length == 2
raise 'Missing exact TV construction admission' unless File.read(tv_root_path).scan(root_call).length == 1
initializer = between(picker, '    init(core: CoreBridge = .shared, authentication:', "\n    }\n")
state_initializers = initializer.lines.select { |line| line.strip.start_with?('_pickerAdmission = State(initialValue:') }
raise 'Missing unique original State admission' unless state_initializers.length == 1
dismissal_initializers = initializer.lines.select { |line| line.strip.start_with?('_manualPickerDismissal = State(initialValue:') }
raise 'Missing unique original State dismissal' unless dismissal_initializers.length == 1
raise 'Appearance must not recapture admission' if picker.include?('capturePickerAdmission()')
methods = '    private func pick(_ profile: UserProfile) {' + between(picker,
  '    private func pick(_ profile: UserProfile) {', "\n}\n")
methods += "\n" + '    private func focusDiagnosticRecovery() {' + between(picker,
  '    private func focusDiagnosticRecovery() {', "\n    }\n") + "\n    }\n"
methods += "\n" + '    private func openAccountHelp() {' + between(picker,
  '    private func openAccountHelp() {', "\n    }\n") + "\n    }\n"
for name in ['closeManualPicker()', 'diagnosticGrant() -> ProfilePickerToolsDiagnosticGrant', 'closeTools(_ id: UUID)', 'openTools()']
  signature = "    private func #{name} {"
  methods += "\n" + signature + between(picker, signature, "\n    }\n") + "\n    }\n"
end
methods += "\n" + '    private var exportAllowedBeforeProfile: Bool {' + between(picker,
  '    private var exportAllowedBeforeProfile: Bool {', "\n    }\n") + "\n    }\n"
preparing = '    private var profilesArePreparing: Bool {' + between(picker,
  '    private var profilesArePreparing: Bool {', "\n    }\n") + "\n    }"
restore_event = between(picker,
  '.onValueChange(of: nativeSync.accountRestoreState) { state in', "\n        }\n")
credential_event = between(picker,
  '.onReceive(NotificationCenter.default.publisher(for: VortXSyncManager.credentialScopeDidChangeNote)) { _ in', "\n        }\n")
disappear_event = between(picker, '.onDisappear {', "\n        }\n")
add_action = between(picker,
  'ProfilePickerActionTile(title: "Add", symbol: "plus", side: side, nameTextSize: nameTextSize) {', "\n            }\n")
edit_start = picker.index('ProfilePickerActionTile(title: isEditing ? "Done" : "Edit"') or raise 'Missing Edit'
edit_action = between(picker[edit_start..-1], 'nameTextSize: nameTextSize) {', "\n            }\n")
recovery_action = between(picker, 'Button("Account settings") {', ' }')
account_help_event = between(picker, '.onValueChange(of: accountHelpNeeded) { presented in', "\n        }\n")
signin_event = between(picker, '.onValueChange(of: signInNeeded) { presented in', " }\n")

replacements = {
  '/* ACTUAL_ROOT_PICKER_ARGUMENT */' => 'return ' + root_argument,
  '/* ACTUAL_ROOT_PICKER_DISMISSAL_ARGUMENT */' => 'return ' + dismissal_argument,
  '/* ACTUAL_PICKER_STATE_INITIALIZER */' => state_initializers.first,
  '/* ACTUAL_PICKER_DISMISSAL_INITIALIZER */' => dismissal_initializers.first,
  '/* ACTUAL_PICKER_PRESENTATION_STATE */' => store_state,
  '/* ACTUAL_PICKER_NEEDED */' => needed,
  '/* ACTUAL_IOS_PICKER_DISMISSAL */' => root_dismissals[0],
  '/* ACTUAL_TV_PICKER_DISMISSAL */' => root_dismissals[1],
  '/* ACTUAL_METHODS */' => methods,
  '/* ACTUAL_PICKER_ADMISSION */' => picker.lines.find { |line| line.start_with?('    private var pickerAdmissionPermits: Bool {') } || (raise 'Missing picker admission projection'),
  '/* ACTUAL_PREPARING */' => preparing,
  '/* ACTUAL_RESTORE_EVENT */' => restore_event,
  '/* ACTUAL_CREDENTIAL_EVENT */' => credential_event,
  '/* ACTUAL_DISAPPEAR_EVENT */' => disappear_event,
  '/* ACTUAL_ADD_ACTION */' => add_action,
  '/* ACTUAL_EDIT_ACTION */' => edit_action,
  '/* ACTUAL_RECOVERY_ACTION */' => recovery_action,
  '/* ACTUAL_SIGNIN_EVENT */' => signin_event,
  '/* ACTUAL_ACCOUNT_HELP_EVENT */' => account_help_event
}
replacements.each do |marker, value|
  raise "Missing unique marker #{marker}" unless template.scan(marker).length == 1
  template = template.sub(marker) { value }
end
raise 'Unresolved extraction marker' if template.include?('/* ACTUAL_')
File.write(File.join(out, 'NativeProfilePickerRouting.generated.swift'), template)
paths = [source_path, store_path, ios_root_path, tv_root_path, template_path, runner_path,
         File.join(root, 'app/SourcesShared/NativeProfileActionPreparation.swift'),
         File.join(root, 'app/SourcesShared/ProfileMutationPresentation.swift'),
         File.join(root, 'app/SourcesShared/ProfilePickerToolsAccess.swift')]
receipt = paths.map { |path| "#{Digest::SHA256.file(path).hexdigest}  #{path}" }.join("\n") + "\n"
File.write(File.join(out, 'source-sha256.txt'), receipt)
puts receipt
RUBY

xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
    -D VORTX_NATIVE_DATA_ENGINE \
    "$picker_repo_root/app/SourcesShared/NativeProfileActionPreparation.swift" \
    "$picker_repo_root/app/SourcesShared/ProfileMutationPresentation.swift" \
    "$picker_repo_root/app/SourcesShared/ProfilePickerToolsAccess.swift" \
    "$picker_test_dir/NativeProfilePickerRouting.generated.swift" \
    -o "$picker_test_dir/profile-picker-routing" 2>&1 | tee "$picker_test_dir/compile.log"
"$picker_test_dir/profile-picker-routing" 2>&1 | tee "$picker_test_dir/test.log"
# A receipt cannot silently combine extracted methods with changed helper implementations.
shasum -a 256 -c "$picker_test_dir/source-sha256.txt"
