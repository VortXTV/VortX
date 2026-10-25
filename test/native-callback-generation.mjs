#!/usr/bin/env node
// Compile the current production callback admission contract; no VortX app/SDK build or user data.
// The fixture uses only Foundation/os primitives and synthetic owner/session collaborators.
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
const unique = (marker, label = marker) => {
  assert.equal(source.split(marker).length - 1, 1, `missing or ambiguous production marker ${label}`);
};
const section = (start, end) => {
  unique(start);
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert(a >= 0 && b > a, `missing production section ${start}`);
  return source.slice(a, b);
};
const installation = section('func installNativeSession(', 'func closeNativeSession()');
const callback = section('@MainActor private func makeNativeSourceCallback(', '    /// Source-owned activation closes');
const lifetime = section('private struct NativeCallbackLifetime: Sendable {', '\nextension CoreBridge {');
const origin = section('    private struct NativeCallbackOrigin: Sendable {', '    /// Preserve synchronous source callback append order');
const sourcePredicate = section('@MainActor private func nativeCallbackSourceIsCurrent(',
  '    @MainActor private func nativeCallbackOriginIsCurrent(');
const originPredicate = section('@MainActor private func nativeCallbackOriginIsCurrent(',
  '    @MainActor private func makeNativeSourceCallback(');
const receiver = section('@MainActor private final class NativeCallbackReceiver {',
  '    @MainActor private func nativeCallbackSourceIsCurrent(');
const receiverGuard = receiver.match(/guard let core, event\.producer === origin\.producer,\s+event\.sourceID == origin\.producer\.sourceID,\s+core\.nativeCallbackSourceIsCurrent\(origin\) else \{ return \}/)?.[0];
assert(receiverGuard, 'actual typed receiver repeats producer/source/current-source admission');
assert(receiver.indexOf(receiverGuard) < receiver.indexOf('switch event.kind'), 'all receiver kinds share the original guard');
for (const kind of ['mutationAccepted', 'progressAccepted', 'changed']) {
  assert(receiver.includes('case .' + kind + ':'), 'actual receiver retains ' + kind + ' route');
}
assert(originPredicate.includes('nativeCallbackSourceIsCurrent(origin) && publicationStillCurrent(origin.publication)'),
  'actual UI origin also retains its original publication epoch');
assert(receiver.includes('guard core.nativeCallbackOriginIsCurrent(origin) else { return }'),
  'actual changed route rechecks original publication ownership');
assert(callback.includes('for envelope in batch { receiver.receive(envelope.event, origin: envelope.origin) }'),
  'actual callback forwards original typed source and origin');
assert(installation.includes('let callback = makeNativeSourceCallback(installation: installGeneration, credential: capture)')
  && installation.includes('progressAccepted: {}, sourceEvent: callback, changed: { _ in }'),
  'actual installation uses the shared typed callback instead of three legacy guards');
const intake = callback.match(/guard event\.sourceID == event\.producer\.sourceID,\s+CredentialScopeRegistry\.shared\.isCurrent\(credential\),\s+lifetime\.accepts\(installation, credential: credential, sourceID: event\.sourceID\) else \{ return \}/)?.[0];
assert(intake, 'actual makeNativeSourceCallback intake guard extracted');

// Keep the complete current scalar assignment/retirement segments. These include the
// read-lifetime/admission-fence calls that bracket every generation mutation.
const install = installation.match(/let installGeneration = UUID\(\)\n        let installSubtitleRetirement = nativeFacadeLock\.withLock \{[\s\S]*?        nativePlaybackReadLifetime\.completeRetirement\(installSubtitleRetirement\)/)?.[0];
assert(install, 'complete install generation/lifetime segment extracted');
const installPublication = installation.match(/let result = nativeFacadeLock\.withLock \{ \(\) -> \(Bool, VortxNativeCoreFacade\?, CredentialPublicationOutbox\.SubtitleRetirement\?\) in[\s\S]*?            return \(true, old, retirement\)\n        \}/)?.[0];
assert(installPublication, 'complete install storage/capture/lifetime bind segment extracted');
const rotation = (text, label) => {
  const result = text.match(/let subtitleRetirement = nativeFacadeLock\.withLock \{[\s\S]*?        nativePlaybackReadLifetime\.completeRetirement\(subtitleRetirement\)/)?.[0];
  assert(result, `complete ${label} retirement/generation segment extracted`);
  return result;
};
const profileSwitch = rotation(section('func switchNativeProfile(', 'func rebindNativeRegistry('), 'profile switch');
const deletion = rotation(section('func deleteNativeProfile(', 'func switchNativeProfile('), 'profile deletion');
const revoke = section('private func revokeNativeSession()', 'old?.close()');
const revokeState = revoke.match(/let retiredBridge = nativeFacadeLock\.withLock \{[\s\S]*?            return \(old, retirement\)\n        \}/)?.[0];
assert(revokeState, 'complete revoke retirement/generation segment extracted');

mkdirSync(join(root, 'app/_build'), { recursive: true });
const work = mkdtempSync(join(root, 'app/_build/native-callback-generation.'));
const swift = `import Foundation
import os

// These are scalar test collaborators only. The production lifetime, origin,
// intake guard, source-currentness predicate, and generation mutation bodies
// below are extracted verbatim from CoreBridge.swift.
struct Retirement: Sendable {}
final class NativePlaybackReadLifetime: @unchecked Sendable {
    func retire() -> Retirement { Retirement() }
    func completeRetirement(_ retirement: Retirement) { _ = retirement }
}
final class NativeMetadataAdmissionFence: @unchecked Sendable {
    func retireInstallation() {}
}
enum CredentialPublicationOutbox {
    typealias SubtitleRetirement = Retirement
}
final class CredentialScopeRegistry: @unchecked Sendable {
    enum Scope: Hashable, Sendable { case account }
    struct Capture: Equatable, Hashable, Sendable {
        let scope: Scope
        let generation: UInt64
    }
    static let shared = CredentialScopeRegistry()
    private let lock = NSLock()
    private var generation: UInt64 = 1
    func capture() -> Capture { lock.withLock { .init(scope: .account, generation: generation) } }
    func isCurrent(_ capture: Capture) -> Bool {
        lock.withLock { capture == .init(scope: .account, generation: generation) }
    }
    func retire() { lock.withLock { generation &+= 1 } }
}
final class VortxNativeCoreFacade: @unchecked Sendable {
    let sourceID: UUID
    init(sourceID: UUID = UUID()) { self.sourceID = sourceID }
}

${lifetime}

@MainActor private final class Bridge {
    struct PublicationToken: Equatable, Sendable { let epoch: UInt64 }
    ${origin}

    let nativeFacadeLock = NSLock()
    let nativePlaybackReadLifetime = NativePlaybackReadLifetime()
    let nativeMetadataAdmissionFence = NativeMetadataAdmissionFence()
    let nativeCallbackLifetime = NativeCallbackLifetime()
    var nativeFacadeStorage: VortxNativeCoreFacade?
    var nativeCredentialCapture: CredentialScopeRegistry.Capture?
    var nativeInstallGeneration = UUID()
    var nativeCallbackGeneration = UUID()
    var nativePublishedAccountGeneration: UUID?

    ${sourcePredicate}

    func install(facade: VortxNativeCoreFacade,
                 credential: CredentialScopeRegistry.Capture) -> UUID {
        ${install}
        let capture = credential
        ${installPublication}
        if let retirement = result.2 { nativePlaybackReadLifetime.completeRetirement(retirement) }
        guard result.0 else { fatalError("synthetic install publication was superseded") }
        return installGeneration
    }
    func switchProfile() {
        ${profileSwitch}
    }
    func deleteProfile() {
        ${deletion}
    }
    func revoke() {
        ${revokeState}
        _ = retiredBridge
    }
    func admits(_ event: Event, installation: UUID,
                credential: CredentialScopeRegistry.Capture) -> Bool {
        var accepted = false
        let lifetime = nativeCallbackLifetime
        let intakeCallback: () -> Void = {
            ${intake}
            accepted = true
        }
        intakeCallback()
        return accepted
    }
    func sourceIsCurrent(producer: VortxNativeCoreFacade,
                         installation: UUID,
                         credential: CredentialScopeRegistry.Capture) -> Bool {
        nativeCallbackSourceIsCurrent(.init(producer: producer, installation: installation,
            credential: credential, publication: .init(epoch: 1), playerWasActive: false))
    }
}
struct Event: Sendable {
    let producer: VortxNativeCoreFacade
    let sourceID: UUID
}

@main struct Tests {
    @MainActor static func main() {
        let bridge = Bridge()
        let facade = VortxNativeCoreFacade()
        let capture = CredentialScopeRegistry.shared.capture()
        let installation = bridge.install(facade: facade, credential: capture)
        var failures = 0, checks = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures += 1; print("FAIL " + name) }
            else { print("PASS " + name) }
        }
        func event(_ producer: VortxNativeCoreFacade,
                   sourceID: UUID?) -> Event {
            .init(producer: producer, sourceID: sourceID ?? producer.sourceID)
        }
        func accepted(_ expectedIntake: Bool, _ name: String,
                      producer: VortxNativeCoreFacade? = nil,
                      sourceID: UUID? = nil,
                      credential: CredentialScopeRegistry.Capture? = nil,
                      token: UUID? = nil,
                      sourceExpected: Bool? = nil) {
            let actualProducer = producer ?? facade
            let actualCredential = credential ?? capture
            let actualToken = token ?? installation
            let expectedSource = sourceExpected ?? expectedIntake
            check(bridge.admits(event(actualProducer, sourceID: sourceID),
                installation: actualToken, credential: actualCredential) == expectedIntake,
                name + " intake")
            check(bridge.sourceIsCurrent(producer: actualProducer, installation: actualToken,
                credential: actualCredential) == expectedSource, name + " source")
        }

        accepted(true, "initial producer publication")
        accepted(false, "wrong source ID", sourceID: UUID(), sourceExpected: true)
        let foreignProducer = VortxNativeCoreFacade()
        accepted(false, "wrong producer/session", producer: foreignProducer)
        let sameIDForeignProducer = VortxNativeCoreFacade(sourceID: facade.sourceID)
        accepted(true, "same-source-ID foreign producer reaches only intake",
            producer: sameIDForeignProducer, sourceExpected: false)
        let foreignCapture = CredentialScopeRegistry.Capture(scope: .account,
            generation: capture.generation + 100)
        accepted(false, "wrong current credential", credential: foreignCapture)
        accepted(false, "wrong installation token", token: UUID())
        bridge.nativeCredentialCapture = foreignCapture
        check(!bridge.sourceIsCurrent(producer: facade, installation: installation,
            credential: capture), "foreign stored credential rejected")
        bridge.nativeCredentialCapture = capture
        bridge.nativeFacadeStorage = nil
        accepted(true, "nil storage intake remains guarded only by source event",
            sourceExpected: false)
        bridge.nativeFacadeStorage = facade
        let admittedGeneration = bridge.nativeCallbackGeneration
        bridge.nativeCallbackGeneration = UUID()
        accepted(true, "wrong stored callback generation reaches only intake", sourceExpected: false)
        bridge.nativeCallbackGeneration = admittedGeneration

        let callbackGeneration = bridge.nativeCallbackGeneration
        let firstTarget = bridge.nativeInstallGeneration
        bridge.switchProfile()
        check(bridge.nativeInstallGeneration != firstTarget,
            "profile switch retires old install target")
        check(bridge.nativeCallbackGeneration == callbackGeneration,
            "profile switch preserves callback generation")
        accepted(true, "profile switch keeps source live")
        bridge.switchProfile()
        bridge.switchProfile()
        accepted(true, "A-B-A profile switch keeps source live")
        let deleteTarget = bridge.nativeInstallGeneration
        bridge.deleteProfile()
        check(bridge.nativeInstallGeneration != deleteTarget,
            "profile deletion retires old install target")
        check(bridge.nativeCallbackGeneration == callbackGeneration,
            "profile deletion preserves callback generation")
        accepted(true, "profile deletion keeps source live")

        let replacementFacade = VortxNativeCoreFacade()
        let replacementCapture = capture
        let replacementInstallation = bridge.install(facade: replacementFacade,
            credential: replacementCapture)
        accepted(false, "old installation rejected after reinstall",
            sourceExpected: false)
        accepted(true, "replacement installation accepted", producer: replacementFacade,
            credential: replacementCapture, token: replacementInstallation)
        accepted(false, "replacement source mismatch", producer: replacementFacade,
            sourceID: UUID(), credential: replacementCapture, token: replacementInstallation,
            sourceExpected: true)
        CredentialScopeRegistry.shared.retire()
        accepted(false, "revoked current credential", producer: replacementFacade,
            credential: replacementCapture, token: replacementInstallation)
        let freshFacade = VortxNativeCoreFacade()
        let freshCapture = CredentialScopeRegistry.shared.capture()
        let freshInstallation = bridge.install(facade: freshFacade, credential: freshCapture)
        accepted(true, "fresh installation after credential retirement",
            producer: freshFacade, credential: freshCapture, token: freshInstallation)
        bridge.revoke()
        accepted(false, "revoked storage/lifetime rejected", producer: freshFacade,
            credential: freshCapture, token: freshInstallation)

        print("Callback admission checks: \\(checks), failures: \\(failures)")
        if failures != 0 { exit(1) }
    }
}
`;
const input = join(work, 'CallbackAdmission.swift'), output = join(work, 'callback-admission');
writeFileSync(input, swift);
writeFileSync(join(work, 'production-callback-contract.txt'), [lifetime, origin, sourcePredicate, originPredicate, receiverGuard, callback, intake,
  install, installPublication, profileSwitch, deletion, revokeState].join('\n\n'));
const target = process.arch === 'arm64' ? 'arm64-apple-macosx14.0' : 'x86_64-apple-macosx14.0';
const sdk = execFileSync('xcrun', ['--sdk', 'macosx', '--show-sdk-path'], { encoding: 'utf8' }).trim();
assert(sdk.startsWith('/') && !/[\r\n]/.test(sdk), 'actual macOS SDK path required');
execFileSync('xcrun', ['swiftc', '-j', '1', '-num-threads', '1', '-swift-version', '6', '-strict-concurrency=complete',
  '-warnings-as-errors', '-parse-as-library', '-target', target, '-sdk', sdk,
  '-module-cache-path', join(work, 'module-cache'), input, '-o', output], { stdio: 'inherit' });
console.log(`Retained current callback contract extraction: ${work}`);
execFileSync(output, [], { stdio: 'inherit' });
