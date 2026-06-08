# iOS native rebase plan

Replace the iPhone/iPad web-host (WKWebView hosting Stremio's live web) with a native SwiftUI client on
stremio-core, the same way the Apple TV app already works. This removes the dependency on Stremio's live
web (which broke when the hosted web changed) and gives iOS the redesigned UI for free.

## What gets reused (already built for tvOS)

- **The engine**: `StremioXCore.xcframework` (stremio-core via the serde-JSON C ABI). Now built with iOS
  slices too (`scripts/build-core-xcframework.sh`).
- **`CoreBridge`** (engine FFI bridge), **`CoreModels`** (Codable mirrors), **`Theme`** (design system),
  **`ChipButtonStyle`**, **`PlaybackMeta`**. These are platform-agnostic.
- **The libmpv player core** (`Sources/Player`, MPVKit), already shared with tvOS.
- **`StremioAccount`** + the **Keychain** token (already cross-platform).

## What is new (iOS-specific)

- Touch-adapted SwiftUI screens: Home, Discover, Library, Search, Detail, Streams, Add-ons, Settings,
  with iPhone and iPad layouts (bottom `TabView`, `NavigationStack`, poster grids, portrait + landscape,
  44pt touch targets). The tvOS screens are focus-driven and ten-foot; iOS needs its own views, but they
  pull from the same `CoreBridge` and `Theme`.
- A native iOS player screen (reusing the libmpv core) with touch controls.

## What gets removed (once parity is reached)

- `ContentView`, `StremioWebView`, and the live-web reverse-proxy in `NodeServer`. `NodeServer` stays for
  the streaming server (torrents); direct/debrid streams play through libmpv without it.

## Steps

1. **Engine for iOS.** `build-core-xcframework.sh` now builds `aarch64-apple-ios` and
   `aarch64-apple-ios-sim` (tier-2, prebuilt std, no build-std) and packs them into the xcframework. [in progress]
2. **Share the engine layer.** Move `CoreBridge`, `CoreModels`, `Theme`, `ChipButtonStyle`, `PlaybackMeta`
   (and small shared bits) into a `Shared/` group compiled into both targets; link
   `StremioXCore.xcframework` into the iOS target. Smoke test: `CoreBridge.shared.start()` +
   `schemaVersion` on iOS proves the FFI works natively.
3. **iOS app shell.** Bottom `TabView` (Home / Discover / Library / Search / Settings); sign-in seeds the
   engine (reuse `StremioAccount` + `signedInWithLegacyAuthKey`).
4. **iOS screens.** Port each surface to touch, reusing `Theme` and `CoreBridge`. Start with Home, then
   Detail + Streams, then Discover/Library/Search/Add-ons/Settings.
5. **iOS player.** Native touch player on the libmpv core; live progress + resume via the engine, same as
   tvOS.
6. **Cut over.** Once the native screens reach parity, remove the web-host and the live-web proxy.

## Notes / risks

- The design tokens (`Theme`) port directly; tvOS focus states become press/hover states on iOS.
- Portrait and landscape, safe areas, and Dynamic Type need real handling (the tvOS app never faced them).
- iPad should use wider grids and a split layout where it helps; iPhone is single-column.
- Verify on the iOS simulator (NodeMobile and the engine both have iOS-sim slices), then on device.
