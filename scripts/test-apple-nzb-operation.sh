#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
nzb_operation_dir=$(mktemp -d app/build/apple-nzb-operation.XXXXXX)
baseline_flag=()
additional_sources=()
warm_baseline=""
fallback_baseline=""
if [[ ${1:-} == --warm-baseline ]]; then
  warm_baseline=$2
  shift 2
fi
if [[ ${1:-} == --fallback-baseline ]]; then
  fallback_baseline=$2
  shift 2
fi
if [[ $# -gt 0 ]]; then
  git show "$1:app/SourcesShared/UsenetNodeClient.swift" > "$nzb_operation_dir/client.swift"
  baseline_flag=(-D NZB_OPERATION_BASELINE)
else
  cp app/SourcesShared/UsenetNodeClient.swift "$nzb_operation_dir/client.swift"
  baseline_flag=(-D NZB_OPERATION_FIXTURE)
  if [[ -n $warm_baseline ]]; then baseline_flag+=(-D NZB_WARM_CAPTURE_BASELINE); fi
  {
    printf '%s\n' 'import Foundation'
    sed -n '/^enum UsenetLocalResolver {/,/^\/\/ MARK: - Settings screen/p' app/SourcesShared/UsenetProvider.swift | sed '$d'
    sed -n '/^struct DebridPlaybackRef: /,/^}/p' app/SourcesShared/DebridResolver.swift
    printf '%s\n' 'actor CoordinatorFixture {' \
      'static let resolveTimeout: Duration = .seconds(5)' \
      'static let shared = CoordinatorFixture()' \
      'let warmGate: FixtureWarmGate?; let failureGate: FixtureWarmGate?; let savedServers: [UsenetProviderServer]' \
      'init(warmGate: FixtureWarmGate? = nil, failureGate: FixtureWarmGate? = nil, savedServers: [UsenetProviderServer] = []) { self.warmGate = warmGate; self.failureGate = failureGate; self.savedServers = savedServers }' \
      'func warmIfNeeded() async { await warmGate?.wait() }' \
      'var hasUsenetResolver: Bool { get async { true } }' \
      'var torboxUsenet: FixtureCloudResolver? { FixtureCloudResolver.shared }' \
      'func recordBreakerFailure(_ error: Error, provider: String, sourceID: String, phase: ProviderCircuitBreaker.Phase) async {}' \
      'func currentAuthorityCapture() -> CredentialScopeRegistry.Capture? { CredentialScopeRegistry.shared.capture() }' \
      'var latestCredentialRevision: Int { 0 }' \
      'func isCurrent(_ capture: CredentialScopeRegistry.Capture, revision: Int) -> Bool { CredentialScopeRegistry.shared.isCurrent(capture) }' \
      'func runProvider<T: Sendable>(capture: CredentialScopeRegistry.Capture, revision: Int, operation: @Sendable () async throws -> T) async throws -> T { do { return try await operation() } catch { await failureGate?.wait(); throw error } }'
    if [[ -n $warm_baseline ]]; then
      # Original actor entry/signature, warm-before-capture order, and local-create block, not a
      # simulation of the new ownership policy. Other provider branches are inert fixture seams.
      sed -n '/    func resolvedPlaybackRef(/,/        let selectionEpisode = episode.map/p' "$warm_baseline" | sed '$d'
      printf '%s\n' 'let selectionEpisode = episode; let nzb = stream.usenetURLs[0]'
      awk '/    func resolvedPlaybackRef\(/ { in_method = 1 }
           in_method && /            await warmIfNeeded\(\)/ { remaining = 3 }
           remaining { print; remaining--; if (remaining == 0) exit }' "$warm_baseline"
    else
      if [[ -n $fallback_baseline ]]; then
        # Old worker, with only the new argument's shape added (unused). No owner checks supplied.
        sed -n '/    func resolveUsenet(nzbUrl:/,/^    }/p' "$fallback_baseline" \
          | sed '1s/) async throws -> URL {/, inheritedNativeOwner: UsenetLocalResolver.NativeOwner? = nil) async throws -> URL {/'
      else
        sed -n '/    func resolveUsenet(nzbUrl:/,/^    }/p' app/SourcesShared/DebridResolver.swift
      fi
      sed -n '/    enum ExplicitUsenetResolution:/,/^    }/p' app/SourcesShared/DebridResolver.swift
      sed -n '/    func resolveExplicitUsenetPlayback(/,/^    }/p' app/SourcesShared/DebridResolver.swift
      sed -n '/    @MainActor func recoverUsenetPlayback(/,/^    }/p' app/SourcesShared/DebridResolver.swift
      sed -n '/    @MainActor func resolvedPlaybackRef(/,/^    }/p' app/SourcesShared/DebridResolver.swift
      sed -n '/    private func warmNativeUsenet(/,/^    }/p' app/SourcesShared/DebridResolver.swift
      sed -n '/    private func resolvePlaybackRef(/,/        let selectionEpisode = episode.map/p' app/SourcesShared/DebridResolver.swift | sed '$d'
      printf '%s\n' 'let selectionEpisode = episode; let nzb = stream.usenetURLs[0]' \
        'if true {' 'var nativeFallbackOwner: UsenetLocalResolver.NativeOwner?'
      sed -n '/            let ownsNativeAttempt = nativeOwner.requiresNativeAuthority/,/            let usenetRevision = latestCredentialRevision/p' \
        app/SourcesShared/DebridResolver.swift \
        | sed '/^[[:space:]]*#else$/,/^[[:space:]]*#endif$/d; /^[[:space:]]*#if/d; /^[[:space:]]*#endif/d'
      sed -n '/            let resumingCloudJob = /,/            if resumingCloudJob,/p' app/SourcesShared/DebridResolver.swift
    fi
    if [[ -n $warm_baseline ]]; then
      printf '%s\n' 'let usenetSavedServers = savedServers' 'do {'
      sed -n '/                    let nativeOwnerIsCurrent = /,/usenetRoute: local.route, nativeUsenetLease: local.nativeLease)/p' "$warm_baseline"
      printf '%s\n' '}' 'return nil' '} catch { return nil }' '}' '}'
    else
      # Actual local result/error and cloud fallback, including the inherited-owner worker.
      sed -n '/            let torBoxHasItCached = confirmedUsenetURLs/,/        \/\/ Raw torrent only:/p' \
        app/SourcesShared/DebridResolver.swift | sed '$d; /^[[:space:]]*#endif/d; s/UsenetProviderStore.loadEnabledServers(ownerCapture: usenetCapture)/savedServers/'
      printf '%s\n' 'return nil' '}' '}'
    fi
  } > "$nzb_operation_dir/resolver.swift"
  additional_sources=("$nzb_operation_dir/resolver.swift" app/Tests/AppleNZBOwnerFixture.swift
    app/SourcesShared/UsenetStreamValidation.swift app/SourcesShared/UsenetProviderConfiguration.swift
    app/SourcesShared/UsenetRoutingPolicy.swift)
fi
{
  printf '%s\n' 'import Foundation' 'final class PlaybackHooks {'
  if [[ $# -gt 0 ]]; then
    printf '%s\n' 'struct Reference { let nativeUsenetLease: UsenetNodeClient.OperationLease? }'
  else
    printf '%s\n' 'typealias Reference = DebridPlaybackRef'
  fi
  printf '%s\n' 'struct Pending { let debridRef: Reference? }' \
    'var curDebridRef: Reference?' 'var pendingAdvance: Pending?' \
    'func replacementCallback() -> (UsenetNodeClient.OperationLease?) -> Void {'
  if [[ $# -gt 0 ]]; then
    printf '%s\n' 'return { _ in }'
  else
    sed -n '/.onChange(of: curDebridRef?.nativeUsenetLease)/,/^        }/p' app/Sources/PlayerScreen.swift \
      | sed '1s/.*{ \[/return { [/'
  fi
  printf '%s\n' '}'
  for method in presentTerminalLoadFailure leavePlayback; do
    printf 'func %s() {\n' "$method"
    if [[ $# -eq 0 ]]; then
      sed -n "/func $method()/,/^    }/p" app/Sources/PlayerScreen.swift \
        | sed -n '/nativeUsenetLease?.close()/p'
    fi
    printf '%s\n' '}'
  done
  printf '%s\n' '}'
} > "$nzb_operation_dir/hooks.swift"
# TV and handheld hooks must remain byte-for-byte equivalent in lease behavior.
if [[ $# -eq 0 ]]; then
  for method in presentTerminalLoadFailure leavePlayback; do
    diff -u \
      <(sed -n "/func $method()/,/^    }/p" app/Sources/PlayerScreen.swift | sed -n '/nativeUsenetLease?.close()/p') \
      <(sed -n "/func $method()/,/^    }/p" app/SourcesTV/TVPlayerView.swift | sed -n '/nativeUsenetLease?.close()/p')
  done
  diff -u \
    <(sed -n '/.onChange(of: curDebridRef?.nativeUsenetLease)/,/^        }/p' app/Sources/PlayerScreen.swift) \
    <(sed -n '/.onChange(of: curDebridRef?.nativeUsenetLease)/,/^        }/p' app/SourcesTV/TVPlayerView.swift)
fi
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors "${baseline_flag[@]}" \
  app/SourcesShared/NativeTransportPolicy.swift "$nzb_operation_dir/client.swift" \
  "$nzb_operation_dir/hooks.swift" "${additional_sources[@]}" app/Tests/AppleNZBOperationTests.swift -o "$nzb_operation_dir/operation"
python3 test/apple-nzb-operation-http.py "$nzb_operation_dir/operation"
