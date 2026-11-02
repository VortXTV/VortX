#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$PWD/app/build/profile-picker-account"
mkdir -p "$build_dir"
swift_flags=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1)
swiftc "${swift_flags[@]}" -parse-as-library -typecheck \
  app/SourcesShared/ProfilePickerAccountControls.swift \
  app/Tests/ProfilePickerAccountControlsFixture.swift
swiftc "${swift_flags[@]}" -parse-as-library \
  app/SourcesShared/ProfileMutationPresentation.swift app/Tests/ProfileMutationPresentationTests.swift \
  -o "$build_dir/profile-presentation"
"$build_dir/profile-presentation"
python3 - "$build_dir" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path.cwd()
source = root / 'app/SourcesShared/ProfilePickerAccountControls.swift'
text = source.read_text()
start = '            Button("Sign out", role: .destructive) {\n'
end = '            Button("Cancel", role: .cancel) {'
assert text.count(start) == text.count(end) == 1
body = text.split(start, 1)[1].split(end, 1)[0]
assert body.endswith('            }\n')
body = body[:-len('            }\n')]
out = pathlib.Path(sys.argv[1])
(out / 'extraction.json').write_text(json.dumps({'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'bodySHA256': hashlib.sha256(body.encode()).hexdigest(), 'normalizations': 0}, indent=2) + '\n')
fixture = '''import Foundation
@MainActor final class CredentialScopeRegistry {
    static let shared = CredentialScopeRegistry()
    struct Capture: Equatable, Sendable { let generation: Int }
    var generation = 1
    func capture() -> Capture { Capture(generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool { capture.generation == generation }
}
@MainActor final class Sync {
    struct Account { let id: String }
    var isSignedIn = true
    var account: Account? = Account(id: "A")
    var signOuts = 0
    func signOut() { signOuts += 1 }
}
@MainActor final class Harness {
    let sync = Sync()
    var signOutAccountID: String? = "A"
    var signOutCredential: CredentialScopeRegistry.Capture? = CredentialScopeRegistry.shared.capture()
    var beforeConfirmedSignOut: () -> Void = {}
    func confirm() {
''' + body + '''
    }
}
@main enum Runner {
    @MainActor static func main() {
        let authority = CredentialScopeRegistry.shared
        let current = Harness(); current.confirm()
        precondition(current.sync.signOuts == 1 && current.signOutCredential == nil && current.signOutAccountID == nil)
        let accountChanged = Harness(); accountChanged.sync.account = .init(id: "B"); accountChanged.confirm()
        precondition(accountChanged.sync.signOuts == 0)
        let sameAccountNewEpoch = Harness(); authority.generation += 1; sameAccountNewEpoch.confirm()
        precondition(sameAccountNewEpoch.sync.signOuts == 0)
        let changedDuringRetirement = Harness()
        changedDuringRetirement.beforeConfirmedSignOut = { authority.generation += 1 }
        changedDuringRetirement.confirm(); precondition(changedDuringRetirement.sync.signOuts == 0)
        let signedOut = Harness(); signedOut.sync.isSignedIn = false; signedOut.confirm()
        precondition(signedOut.sync.signOuts == 0)
        let absentCapture = Harness(); absentCapture.signOutCredential = nil; absentCapture.confirm()
        precondition(absentCapture.sync.signOuts == 0)
        let changedAccountDuringRetirement = Harness()
        changedAccountDuringRetirement.beforeConfirmedSignOut = { [weak changedAccountDuringRetirement] in
            changedAccountDuringRetirement?.sync.account = .init(id: "B")
        }
        changedAccountDuringRetirement.confirm(); precondition(changedAccountDuringRetirement.sync.signOuts == 0)
        print("PASS: 7 actual sign-out handler ownership schedules")
    }
}
'''
(out / 'SignOutHandler.swift').write_text(fixture)
PY
swiftc "${swift_flags[@]}" -parse-as-library "$build_dir/SignOutHandler.swift" -o "$build_dir/sign-out-handler"
"$build_dir/sign-out-handler"
