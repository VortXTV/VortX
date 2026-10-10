#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
usenet_recovery_dir=$(mktemp -d app/build/torbox-usenet-recovery.XXXXXX)
usenet_resolver_source=app/SourcesShared/DebridResolver.swift
baseline_flags=()
if [[ $# -gt 0 ]]; then
  git show "$1:app/SourcesShared/DebridResolver.swift" > "$usenet_recovery_dir/baseline.swift"
  # Supply only an inert URLSession; preserve the baseline resolver's network/control flow.
  sed 's/init(apiKey: String) {/init(apiKey: String, session: URLSession? = nil) {/;s/self.session = TorBoxUsenetWire.makeSession()/self.session = session ?? TorBoxUsenetWire.makeSession()/' \
    "$usenet_recovery_dir/baseline.swift" > "$usenet_recovery_dir/source.swift"
  usenet_resolver_source="$usenet_recovery_dir/source.swift"
  baseline_flags=(-D TORBOX_USENET_BASELINE)
fi
{
  printf '%s\n' 'import Foundation' 'import CryptoKit'
  for type in 'enum DebridProbe' 'enum DebridQuery' 'struct DebridFile' 'struct DebridEpisode' 'enum DebridError' 'enum DebridResolve' 'enum TorBoxUsenetCacheGate' 'actor TorBoxUsenetResolver'; do
    sed -n "/^$type[ :{]/,/^}/p" "$usenet_resolver_source"
  done
  sed -n '/^private extension Array {/,/^}/p' "$usenet_resolver_source"
  printf '%s\n' 'enum EpisodePlaybackIdentity {'
  for method in 'struct FileCandidate' 'struct EpisodeNumbers' 'static func provenEpisodeNumbers' 'static func pickFileOffset' 'private static func normalizedFileIdentity' 'private static func episodeMatchScore'; do
    sed -n "/^    $method[ (:]/,/^    }/p" app/SourcesShared/CoreModels.swift
  done
  printf '%s\n' '}'
} > "$usenet_recovery_dir/resolver.swift"
xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors "${baseline_flags[@]}" \
  "$usenet_recovery_dir/resolver.swift" app/SourcesShared/TorBoxUsenetWire.swift \
  app/SourcesShared/UsenetNodeClient.swift app/SourcesShared/NativeTransportPolicy.swift \
  app/SourcesShared/DebridPublicURLPolicy.swift app/Tests/TorBoxUsenetRecoveryTests.swift \
  -o "$usenet_recovery_dir/recovery"
"$usenet_recovery_dir/recovery"
