# Third-party notices

VortX builds on the components below. Each is owned by its respective authors and used under its own license. VortX claims no ownership of any of them.

- **stremio-core** (Stremio, MIT). The Rust engine the Apple TV app runs on, compiled into the app. https://github.com/Stremio/stremio-core
- **stremio-web** (Stremio, open-source, see its repository for the license). The web interface the iPhone and iPad app hosts. https://github.com/Stremio/stremio-web
- **server.js**, Stremio's streaming server (Stremio, proprietary). Stremio distributes it for free inside their own apps. It is bundled in the released IPAs unmodified, VortX claims no rights to it, and replacing it with an open-source streaming server is on the roadmap. https://www.stremio.com/
- **MPVKit / mpv**. The MPVKit-GPL build is used, under the GPL, which is why this project is GPL-3.0. https://github.com/mpvkit/MPVKit
- **nodejs-mobile** (MIT, plus the Node.js license). The embedded runtime that hosts the streaming server. https://github.com/nodejs-mobile/nodejs-mobile
- **Coil** (Apache-2.0). Image loading for the Android app's poster/backdrop art (`io.coil-kt.coil3`). https://github.com/coil-kt/coil
- **Lora** (SIL Open Font License 1.1). The bundled serif typeface for the Android app's hero/screen-title
  type and wordmark (`android/app/src/main/res/font/`), standing in for the Apple apps' New York/Iowan Old
  Style serif — the closest OFL match available for bundling. https://fonts.google.com/specimen/Lora,
  full license text: https://openfontlicense.org/

If you are a rights holder and want something changed or removed, open an issue and it will be handled promptly.
