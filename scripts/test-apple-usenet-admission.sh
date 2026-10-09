#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p app/build
usenet_test_dir=$(mktemp -d app/build/apple-usenet-admission.XXXXXX)
if [[ $# -gt 0 ]]; then
  git show "$1:app/SourcesShared/CoreModels.swift" > "$usenet_test_dir/models-source.swift"
  git show "$1:app/SourcesShared/DebridPlaybackAvailability.swift" > "$usenet_test_dir/availability-source.swift"
else
  cp app/SourcesShared/CoreModels.swift "$usenet_test_dir/models-source.swift"
  cp app/SourcesShared/DebridPlaybackAvailability.swift "$usenet_test_dir/availability-source.swift"
fi
# Exercise both actual platform capability branches on the host using inert Bundle/ABI-capability doubles.
sed 's/#if os(macOS)/#if USENET_ADMISSION_MAC/g' "$usenet_test_dir/availability-source.swift" \
  > "$usenet_test_dir/availability.swift"
{
  printf '%s\n' 'import Foundation' 'enum EpisodePlaybackIdentity {'
  sed -n '/    static func playableTorrentFileIndex(/,/^    }/p' app/SourcesShared/CoreModels.swift
  printf '%s\n' '}'
  sed -n '/^struct CoreStream: /,/^\/\/ MARK: discover/p' "$usenet_test_dir/models-source.swift" | sed '$d'
  printf '%s\n' 'enum StreamRanking {'
  sed -n '/    private static func playablePairs(/,/^    }/p' app/SourcesShared/StreamRanking.swift \
    | sed 's/private static/static/'
  sed -n '/    static func best(_ groups: \[CoreStreamSourceGroup\], pin:/,/^    }/p' app/SourcesShared/StreamRanking.swift
  printf '%s\n' '}' 'func watchDisabled(loading: Bool, preparing: Bool, best: CoreStream?) -> Bool {'
  sed -n 's/^[[:space:]]*\.disabled(\(loading || preparing || best?.playableURL(isEpisode: true) == nil\))/    return \1/p' \
    app/SourcesiOS/iOSDetailView.swift
  printf '%s\n' '}'
  # The untouched coordinator's actual cached-TorBox-before-local admission expression.
  printf '%s\n' 'func coordinatorWouldAttemptLocal(stream: CoreStream, nzb: String, confirmedUsenetURLs: Set<String>?, usenetSavedServers: [UsenetProviderServer]) -> Bool {'
  sed -n '/let torBoxHasItCached = confirmedUsenetURLs?.contains(nzb) ?? false/p' app/SourcesShared/DebridResolver.swift
  printf '%s\n' 'let resumingCloudJob = false'
  sed -n 's/^[[:space:]]*if !torBoxHasItCached, !resumingCloudJob, \((.*)\) {/    return !torBoxHasItCached \&\& !resumingCloudJob \&\& \1/p' app/SourcesShared/DebridResolver.swift
  printf '%s\n' '}'
  sed -n '/^enum UsenetLocalResolver {/,/^\/\/ MARK: - Settings screen/p' app/SourcesShared/UsenetProvider.swift | sed '$d'
} > "$usenet_test_dir/production-methods.swift"
runtime_failed=0
for variant in mobile mac lite; do
  case "$variant" in
    mobile) variant_flag=USENET_ADMISSION_MOBILE ;;
    mac) variant_flag=USENET_ADMISSION_MAC ;;
    lite) variant_flag=VORTX_NO_EMBEDDED_SERVER ;;
  esac
  xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors -D "$variant_flag" \
    "$usenet_test_dir/availability.swift" "$usenet_test_dir/production-methods.swift" \
    app/SourcesShared/UsenetStreamValidation.swift app/SourcesShared/UsenetProviderConfiguration.swift \
    app/SourcesShared/UsenetRoutingPolicy.swift app/SourcesShared/NativeTransportPolicy.swift \
    app/SourcesShared/UsenetNodeClient.swift app/Tests/AppleNZBOwnerFixture.swift app/Tests/AppleUsenetAdmissionTests.swift \
    -o "$usenet_test_dir/$variant"
  "$usenet_test_dir/$variant" || runtime_failed=1
done
exit "$runtime_failed"
