#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
nzb_operation_dir=$(mktemp -d app/build/apple-nzb-operation.XXXXXX)
printf 'Apple NZB operation evidence: %s\n' "$nzb_operation_dir"
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
host_arch="$(uname -m)"
case "$host_arch" in arm64|x86_64) ;; *) echo 'Unsupported host architecture' >&2; exit 2 ;; esac
host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
swift_language=6
if [[ $# -gt 0 || -n $warm_baseline || -n $fallback_baseline ]]; then
  swift_language=5
  printf '%s\n' 'Historical mixed-source compatibility run; NOT current Swift 6 migration proof.'
fi
swift_flags=(-parse-as-library -swift-version "$swift_language" -strict-concurrency=complete -warnings-as-errors
  -j 1 -num-threads 1 -target "$host_arch-apple-macosx14.0" -sdk "$host_sdk"
  -module-cache-path "$nzb_operation_dir/module-cache")
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
      'var latestCredentialRevision: UInt64 { 0 }' \
      'var lastLocalUsenetFailure: [String: String] = [:]' \
      'func isCurrent(_ capture: CredentialScopeRegistry.Capture, revision: UInt64) -> Bool { CredentialScopeRegistry.shared.isCurrent(capture) }' \
      'func runProvider<T: Sendable>(capture: CredentialScopeRegistry.Capture, revision: UInt64, operation: @Sendable () async throws -> T) async throws -> T { do { return try await operation() } catch { await failureGate?.wait(); throw error } }'
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
      sed -n '/^enum TorBoxUsenetCacheGate {/,/^}/p' app/SourcesShared/DebridResolver.swift
      sed -n '/    enum ExplicitUsenetResolution:/,/^    }/p' app/SourcesShared/DebridResolver.swift
      sed -n '/    func resolveExplicitUsenetPlayback(/,/^    }/p' app/SourcesShared/DebridResolver.swift
      sed -n '/    @MainActor func recoverUsenetPlayback(/,/^    }/p' app/SourcesShared/DebridResolver.swift
      sed -n '/    @MainActor func resolvedPlaybackRef(/,/^    }/p' app/SourcesShared/DebridResolver.swift
      sed -n '/    private func warmNativeUsenet(/,/^    }/p' app/SourcesShared/DebridResolver.swift
      sed -n '/    private func resolvePlaybackRef(/,/        let selectionEpisode = episode.map/p' app/SourcesShared/DebridResolver.swift | sed '$d'
      printf '%s\n' 'let selectionEpisode = episode; let nzb = stream.usenetURLs[0]' \
        'if true {' 'var nativeFallbackOwner: UsenetLocalResolver.NativeOwner?'
      sed -n '/            let ownsNativeAttempt = !(confirmedUsenetURLs?.contains(nzb) ?? false)/,/            let usenetRevision = latestCredentialRevision/p' \
        app/SourcesShared/DebridResolver.swift \
        | sed '/^[[:space:]]*#else$/,/^[[:space:]]*#endif$/d; /^[[:space:]]*#if/d; /^[[:space:]]*#endif/d'
      rg -Fq 'if resumingCloudJob { nativeFallbackOwner = nativeOwner }' app/SourcesShared/DebridResolver.swift
      sed -n '/            let resolverAtCapture = /,/            if resumingCloudJob { nativeFallbackOwner = nativeOwner }/p' app/SourcesShared/DebridResolver.swift
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
  printf '%s\n' 'import Foundation' '@MainActor final class PlaybackHooks {'
  if [[ $# -gt 0 ]]; then
    printf '%s\n' 'struct Reference { let nativeUsenetLease: UsenetNodeClient.OperationLease? }'
  else
    printf '%s\n' 'typealias Reference = DebridPlaybackRef'
  fi
  printf '%s\n' 'struct Pending { let debridRef: Reference? }' \
    'var curDebridRef: Reference?' 'var pendingAdvance: Pending?' \
    'func replacementCallback() -> (UsenetNodeClient.OperationLease?, UsenetNodeClient.OperationLease?) -> Void {'
  if [[ $# -gt 0 ]]; then
    printf '%s\n' 'return { _, _ in }'
  else
    sed -n '/.onValueChange(of: curDebridRef?.nativeUsenetLease)/,/^        }/p' app/Sources/PlayerScreen.swift \
      | sed '1c\
return { oldLease, newLease in'
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
# TV and handheld hooks must remain equivalent in lease behavior. Only the observed-value
# header differs: the iOS16-compatible helper supplies the previous value explicitly on newer OSes.
if [[ $# -eq 0 ]]; then
  rg -Fq '.onValueChange(of: curDebridRef?.nativeUsenetLease) { oldLease, newLease in' app/Sources/PlayerScreen.swift
  rg -Fq '.onChange(of: curDebridRef?.nativeUsenetLease) { oldLease, newLease in' app/SourcesTV/TVPlayerView.swift
  rg -Fq 'onChange(of: value, initial: false, action)' app/SourcesShared/ValueChangeObservation.swift
  rg -Fq 'onChange(of: value) { [value] newValue in action(value, newValue) }' app/SourcesShared/ValueChangeObservation.swift
  for method in presentTerminalLoadFailure leavePlayback; do
    diff -u \
      <(sed -n "/func $method()/,/^    }/p" app/Sources/PlayerScreen.swift | sed -n '/nativeUsenetLease?.close()/p') \
      <(sed -n "/func $method()/,/^    }/p" app/SourcesTV/TVPlayerView.swift | sed -n '/nativeUsenetLease?.close()/p')
  done
  diff -u \
    <(sed -n '/.onValueChange(of: curDebridRef?.nativeUsenetLease)/,/^        }/p' app/Sources/PlayerScreen.swift | sed '1d') \
    <(sed -n '/.onChange(of: curDebridRef?.nativeUsenetLease)/,/^        }/p' app/SourcesTV/TVPlayerView.swift | sed '1d')
fi
if [[ $# -eq 0 && -z $warm_baseline && -z $fallback_baseline ]]; then
  for marker in 'enum UsenetLocalResolver {' 'enum TorBoxUsenetCacheGate {' 'func resolvedPlaybackRef(' 'func recoverUsenetPlayback(' 'nativeUsenetLease: local.nativeLease'; do
    rg -Fq "$marker" "$nzb_operation_dir/resolver.swift"
  done
  rg -Fq 'let ownsNativeAttempt = !(confirmedUsenetURLs?.contains(nzb) ?? false)' "$nzb_operation_dir/resolver.swift"
  [[ $(rg -Fc 'let torBoxHasItCached = confirmedUsenetURLs?.contains(nzb) ?? false' "$nzb_operation_dir/resolver.swift") == 1 ]]
  [[ $(rg -Fc 'let resolverAtCapture = torboxUsenet' "$nzb_operation_dir/resolver.swift") == 1 ]]
  rg -Fq 'return { oldLease, newLease in' "$nzb_operation_dir/hooks.swift"
  rg -Fq 'oldLease?.close()' "$nzb_operation_dir/hooks.swift"
  rg -Fq 'UsenetProviderStore.loadEnabledServers(ownerCapture: usenetCapture)' app/SourcesShared/DebridResolver.swift
  rg -Fq 'savedServers' "$nzb_operation_dir/resolver.swift"
fi
nice -n 15 xcrun swiftc "${swift_flags[@]}" "${baseline_flag[@]}" \
  app/SourcesShared/NativeTransportPolicy.swift "$nzb_operation_dir/client.swift" \
  "$nzb_operation_dir/hooks.swift" "${additional_sources[@]}" app/Tests/AppleNZBOperationTests.swift -o "$nzb_operation_dir/operation"
python3 test/apple-nzb-operation-http.py "$nzb_operation_dir/operation"
