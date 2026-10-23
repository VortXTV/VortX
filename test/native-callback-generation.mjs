#!/usr/bin/env node
// Compile the three actual production callback admission guards; no SDK/app build or user data.
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { resolve, join } from 'node:path';
import assert from 'node:assert/strict';

const root = resolve(new URL('..', import.meta.url).pathname);
const relative = 'app/SourcesShared/CoreBridge.swift';
const baseline = process.argv[2];
const source = baseline
  ? execFileSync('git', ['-C', root, 'show', `${baseline}:${relative}`], { encoding: 'utf8' })
  : readFileSync(join(root, relative), 'utf8');
const section = (start, end) => {
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert(a >= 0 && b > a, `missing production section ${start}`);
  return source.slice(a, b);
};
const installation = section('func installNativeSession(', 'func closeNativeSession()');
const guards = [...installation.matchAll(/guard let self, CredentialScopeRegistry\.shared\.isCurrent\(capture\),\s*self\.nativeFacadeLock\.withLock\(\{[\s\S]*?\}\)/g)].map(m => m[0]);
assert.equal(guards.length, 3, 'all actual mutation/progress/UI guards extracted');
const install = installation.match(/nativeFacadeLock\.withLock \{\s*nativeInstallGeneration = installGeneration[\s\S]*?\}/)?.[0];
assert(install);
const rotation = text => {
  const result = text.match(/nativeFacadeLock\.withLock \{ nativeInstallGeneration = UUID\(\) \}/)?.[0];
  assert(result, 'profile operation must retain old-target invalidation');
  return result;
};
const profileSwitch = rotation(section('func switchNativeProfile(', 'func rebindNativeRegistry('));
const deletion = rotation(section('func deleteNativeProfile(', 'func switchNativeProfile('));
const revoke = section('private func revokeNativeSession()', 'old?.close()');
const revokeAssignments = [...revoke.matchAll(/native(?:Install|Callback)Generation = UUID\(\)/g)].map(m => m[0]).join('\n');
assert(revokeAssignments.includes('nativeInstallGeneration'));
mkdirSync(join(root, 'app/_build'), { recursive: true });
const work = mkdtempSync(join(root, 'app/_build/native-callback-generation.'));
const swift = `import Foundation
final class Session {}
final class Facade {
    let session: Session
    init(_ session: Session) { self.session = session }
    func ownsSession(_ other: Session) -> Bool { session === other }
}
final class CredentialScopeRegistry: @unchecked Sendable {
    static let shared = CredentialScopeRegistry()
    var current = "ownerA"
    func isCurrent(_ capture: String) -> Bool { capture == current }
}
final class Bridge {
    let nativeFacadeLock = NSLock()
    var nativeInstallGeneration = UUID()
    var nativeCallbackGeneration = UUID()
    var nativeCredentialCapture: String? = "ownerA"
    var nativeFacadeStorage: Facade?
    func install(_ installGeneration: UUID, session: Session) {
        ${install}
        nativeFacadeStorage = Facade(session)
    }
    func selectProfile() { ${profileSwitch} }
    func deleteProfile() { ${deletion} }
    func revoke() { ${revokeAssignments}; nativeFacadeStorage = nil; nativeCredentialCapture = nil }
    ${guards.map((guard, i) => `func callback${i}(capture: String, installGeneration: UUID, session: Session) -> Bool {
        { [weak self] in ${guard} else { return false }; return true }()
    }`).join('\n')}
    func callbacks(capture: String, token: UUID, session: Session) -> [Bool] {
        [callback0(capture: capture, installGeneration: token, session: session),
         callback1(capture: capture, installGeneration: token, session: session),
         callback2(capture: capture, installGeneration: token, session: session)]
    }
}
@main struct Tests {
    static func main() {
        let bridge = Bridge(), session = Session(), token = UUID()
        var failures = 0, checks = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures += 1; print("FAIL " + name) }
            else { print("PASS " + name) }
        }
        func callbacks(_ expected: Bool, _ name: String, capture: String = "ownerA", generation: UUID? = nil, owner: Session? = nil) {
            for (index, value) in bridge.callbacks(capture: capture, token: generation ?? token, session: owner ?? session).enumerated() {
                check(value == expected, name + " callback" + String(index))
            }
        }
        bridge.install(token, session: session)
        callbacks(true, "initial publication")
        let oldTarget = bridge.nativeInstallGeneration
        bridge.selectProfile()
        check(bridge.nativeInstallGeneration != oldTarget, "old profile operation target invalidated")
        callbacks(true, "selected profile board/meta/streams and sync remain live")
        bridge.selectProfile()
        callbacks(true, "same profile selection remains live")
        bridge.selectProfile()
        callbacks(true, "A-B-A profile switch remains live")
        let beforeDelete = bridge.nativeInstallGeneration
        bridge.deleteProfile()
        check(bridge.nativeInstallGeneration != beforeDelete, "delete invalidates old operation target")
        callbacks(true, "profile deletion retains live facade callbacks")
        callbacks(false, "wrong session rejected", owner: Session())
        callbacks(false, "wrong install token rejected", generation: UUID())
        bridge.nativeCredentialCapture = "ownerB"
        callbacks(false, "foreign stored credential rejected")
        bridge.nativeCredentialCapture = "ownerA"
        CredentialScopeRegistry.shared.current = "ownerB"
        callbacks(false, "revoked capture rejected")
        CredentialScopeRegistry.shared.current = "ownerA"
        let replacement = UUID()
        bridge.install(replacement, session: session)
        callbacks(false, "old installation rejected")
        callbacks(true, "new installation accepted", generation: replacement)
        bridge.revoke()
        callbacks(false, "revoked facade rejected", generation: replacement)
        print("Callback admission checks: \\(checks), failures: \\(failures)")
        if failures != 0 { exit(1) }
    }
}
`;
const input = join(work, 'CallbackAdmission.swift'), output = join(work, 'callback-admission');
writeFileSync(input, swift);
writeFileSync(join(work, 'production-guards.txt'), guards.join('\n\n'));
execFileSync('xcrun', ['swiftc', '-j', '1', '-swift-version', '6', '-strict-concurrency=complete',
  '-warnings-as-errors', '-parse-as-library', '-module-cache-path', join(work, 'module-cache'), input, '-o', output], { stdio: 'inherit' });
console.log(`Retained actual production-guard extraction: ${work}`);
execFileSync(output, [], { stdio: 'inherit' });
