#!/usr/bin/env bash
# Complete app adapters with synthetic collaborators; no app, account or network operation.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
build_dir="$repo_root/app/build/aether-playback-boundary"
mkdir -p "$build_dir"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
  -parse-as-library -D VORTX_AETHER_ENGINE \
  app/SourcesAetherBridge/VortXAetherBridging.swift \
  app/Sources/Player/PlaybackMetadataFacts.swift \
  app/Sources/Player/AetherEngine/AetherEngineController.swift \
  app/Tests/AetherEngineControllerBehaviorTests.swift -o "$build_dir/controller-behavior"
"$build_dir/controller-behavior"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
  -parse-as-library app/SourcesAetherBridge/VortXAetherBridging.swift \
  app/SourcesAetherKit/VortXAetherBridgePlayer.swift \
  app/Tests/AetherBridgeWorkOwnershipTests.swift -o "$build_dir/bridge-ownership"
"$build_dir/bridge-ownership"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
  -parse-as-library -D VORTX_AETHER_ENGINE \
  app/SourcesAetherBridge/VortXAetherBridging.swift \
  app/Sources/Player/PlaybackMetadataFacts.swift \
  app/Sources/Player/AetherEngine/AetherEngineController.swift \
  app/SourcesAetherKit/VortXAetherBridgePlayer.swift \
  app/Tests/AetherLoadCallbackIsolationTests.swift -o "$build_dir/callback-isolation"
"$build_dir/callback-isolation"
# Test-only upstream module; never part of any application target or release input.
observation_dir="$build_dir/observation"
mkdir -p "$observation_dir"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
  -parse-as-library -emit-library -emit-module -module-name AetherEngine \
  app/Tests/AetherEngineObservationStub.swift \
  -emit-module-path "$observation_dir/AetherEngine.swiftmodule" -o "$observation_dir/libAetherEngine.dylib"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -j 1 -num-threads 1 \
  -parse-as-library -I "$observation_dir" -L "$observation_dir" -lAetherEngine \
  -Xlinker -rpath -Xlinker "$observation_dir" \
  app/SourcesAetherBridge/VortXAetherBridging.swift app/SourcesAetherKit/VortXAetherPlayer.swift \
  app/Tests/AetherPlayerObservationTests.swift -o "$observation_dir/player-observation"
"$observation_dir/player-observation"
