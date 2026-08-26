# Third-party notices

VortX builds on the components below. Each is owned by its respective authors and used under its own license. VortX claims no ownership of any of them.

- **stremio-core** (Stremio, MIT). The Rust engine the Apple TV app runs on, compiled into the app. https://github.com/Stremio/stremio-core
- **stremio-web** (Stremio, open-source, see its repository for the license). The web interface the iPhone and iPad app hosts. https://github.com/Stremio/stremio-web
- **server.js**, Stremio's streaming server (Stremio, proprietary). Stremio distributes it for free inside their own apps. It is bundled in the released IPAs unmodified, VortX claims no rights to it, and replacing it with an open-source streaming server is on the roadmap. https://www.stremio.com/
- **MPVKit / mpv / libplacebo / FFmpeg**. The MPVKit-GPL build is used, under the GPL, which is why this project is GPL-3.0. VortX no longer consumes MPVKit's published binaries: it builds them from pinned upstream sources so Dolby Vision Profile 7 enhancement-layer playback works, which needs mpv and libplacebo commits that are not yet in any release. The exact pins (mpv `8c67647b5005`, libplacebo `4c426e4668`, FFmpeg `6e85193417` on `release/9.0`), the build changes, and the script that reproduces the whole thing are in `scripts/build-mpvkit-dvfel.sh` and `scripts/mpvkit-dvfel.patch`. mpv is GPL-2.0-or-later (built with `-Dgpl=true`), libplacebo is LGPL-2.1-or-later, FFmpeg is GPL-2.0-or-later as configured here. https://github.com/mpvkit/MPVKit, https://github.com/mpv-player/mpv, https://code.videolan.org/videolan/libplacebo
- **nodejs-mobile** (MIT, plus the Node.js license). The embedded runtime that hosts the streaming server. https://github.com/nodejs-mobile/nodejs-mobile
- **Coil** (Apache-2.0). Image loading for the Android app's poster/backdrop art (`io.coil-kt.coil3`). https://github.com/coil-kt/coil
- **Lora** (SIL Open Font License 1.1). The bundled serif typeface for the Android app's hero/screen-title
  type and wordmark (`android/app/src/main/res/font/`), standing in for the Apple apps' New York/Iowan Old
  Style serif — the closest OFL match available for bundling. https://fonts.google.com/specimen/Lora,
  full license text: https://openfontlicense.org/
- **libmpv-android** (Jarne Demeulemeester, MIT). The Android libmpv JNI glue (`android/mpv-seam/`)
  is forked from this project at tag v1.0.0 and patched to carry `mpv_event_end_file` reason/error
  to Kotlin (audit W1-B); the fork's provenance and exact deltas are documented in
  `android/mpv-seam/README.md`, and its MIT license text ships as `android/mpv-seam/LICENSE`. The
  heavy mpv/ffmpeg binaries the glue drives still come from the `dev.jdtech.mpv:libmpv` artifact
  built from that same project's buildscripts (GPL, full flavor only). The vendored
  `android/mpv-seam/src/main/cpp/include/mpv/*.h` client-API headers come from mpv v0.41.0 (ISC).
  https://github.com/jarnedemeulemeester/libmpv-android

If you are a rights holder and want something changed or removed, open an issue and it will be handled promptly.
