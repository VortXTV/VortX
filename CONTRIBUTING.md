# Contributing to StremioX

Contributions are welcome, and the bar to clear is low: the project has merged community PRs within hours of them opening. Here is what makes that fast.

## Building from source

macOS with Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and Rust nightly with rust-src. No local Stremio install needed.

```bash
./scripts/fetch-server-deps.sh        # NodeMobile, server.js, subtitle fonts (all public downloads)
./scripts/build-core-xcframework.sh   # the stremio-core engine (Rust, needs nightly + rust-src)
cd app && xcodegen generate           # then open StremioX.xcodeproj
```

The tvOS app runs fine in the Apple TV simulator. Code signing is allowed in the project so you can deploy to your own hardware from Xcode.

## Pull requests

- Branch from `main`, keep PRs focused on one thing.
- Before/after screenshots for anything visual. The existing PRs set the pattern.
- Build against the OLDEST practical SDK: GitHub's runners lag the newest Xcode, and APIs like `controlSize` have failed CI there before. If in doubt, the CI run on your PR will tell you.
- Conventional commit style for titles: `feat(tvos): ...`, `fix(tvos): ...`, `chore: ...`.

## The per-profile invariant (read this if you touch watched state)

Anything that reads or writes watch history (watched ticks, progress, resume points, Continue Watching) must respect `ProfileStore.activeUsesEngineHistory`:

- `true` (the main profile): read and write through the engine (`CoreBridge`), which syncs to the account.
- `false` (overlay profiles): read and write `ProfileStore`'s watch overlay. A non-main profile must NEVER mutate the account's library.

`DetailView` and `CoreBridge` have worked examples of both paths.

## Safety rails

- Never write app data into `libraryItem` documents or any schema field official Stremio clients parse. An early build corrupted library sync for official apps this way; `ProfileSync.swift` documents the incident.
- The release workflow builds from source for verification. Anything that affects the build must keep `scripts/` reproducible from public downloads.
