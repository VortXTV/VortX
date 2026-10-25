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

ruby - "$picker_repo_root" "$picker_template" "$picker_test_dir" <<'RUBY'
require 'digest'
root, template_path, out = ARGV
source_path = File.join(root, 'app/SourcesShared/ProfilesView.swift')
source = File.read(source_path)
template = File.read(template_path)

def between(source, begin_marker, end_marker)
  first = source.index(begin_marker) or raise "Missing start #{begin_marker}"
  first += begin_marker.length
  last = source.index(end_marker, first) or raise "Missing end #{end_marker}"
  source[first...last]
end

# Limit extraction to the actual picker; never use a similarly named editor callback.
picker = between(source, 'struct ProfilePickerView: View {',
                 '/// A bounded public Cinemeta')
methods = '    private func pick(_ profile: UserProfile) {' + between(picker,
  '    private func pick(_ profile: UserProfile) {', "\n}\n")
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
signin_event = between(picker, '.onValueChange(of: signInNeeded) { presented in', " }\n")

replacements = {
  '/* ACTUAL_METHODS */' => methods,
  '/* ACTUAL_PREPARING */' => preparing,
  '/* ACTUAL_RESTORE_EVENT */' => restore_event,
  '/* ACTUAL_CREDENTIAL_EVENT */' => credential_event,
  '/* ACTUAL_DISAPPEAR_EVENT */' => disappear_event,
  '/* ACTUAL_ADD_ACTION */' => add_action,
  '/* ACTUAL_EDIT_ACTION */' => edit_action,
  '/* ACTUAL_RECOVERY_ACTION */' => recovery_action,
  '/* ACTUAL_SIGNIN_EVENT */' => signin_event
}
replacements.each do |marker, value|
  raise "Missing unique marker #{marker}" unless template.scan(marker).length == 1
  template = template.sub(marker) { value }
end
raise 'Unresolved extraction marker' if template.include?('/* ACTUAL_')
File.write(File.join(out, 'NativeProfilePickerRouting.generated.swift'), template)
paths = [source_path, File.join(root, 'app/SourcesShared/NativeProfileActionPreparation.swift'),
         File.join(root, 'app/SourcesShared/ProfileMutationPresentation.swift')]
receipt = paths.map { |path| "#{Digest::SHA256.file(path).hexdigest}  #{path}" }.join("\n") + "\n"
File.write(File.join(out, 'source-sha256.txt'), receipt)
puts receipt
RUBY

xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
    -D VORTX_NATIVE_DATA_ENGINE \
    "$picker_repo_root/app/SourcesShared/NativeProfileActionPreparation.swift" \
    "$picker_repo_root/app/SourcesShared/ProfileMutationPresentation.swift" \
    "$picker_test_dir/NativeProfilePickerRouting.generated.swift" \
    -o "$picker_test_dir/profile-picker-routing" 2>&1 | tee "$picker_test_dir/compile.log"
"$picker_test_dir/profile-picker-routing" 2>&1 | tee "$picker_test_dir/test.log"
# A receipt cannot silently combine extracted methods with changed helper implementations.
shasum -a 256 -c "$picker_test_dir/source-sha256.txt"
