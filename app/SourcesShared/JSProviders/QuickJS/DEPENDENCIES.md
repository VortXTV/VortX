# Community JavaScript add-on runtime inventory

This directory contains an audited, source-built interpreter. Builds use only the checked-in files below and
never download dependencies.

| Component | Version | Source and reproducibility pin | License |
| --- | --- | --- | --- |
| QuickJS | 2025-09-13 | `https://bellard.org/quickjs/quickjs-2025-09-13.tar.xz`, archive SHA-256 `6f1f322aea3bb3a90858db85c9fe717013fde4df7dfcafe2f57e78f5bb4b4a0c`; checked-in C and header files are whitespace-normalized only, with hashes in `SHA256SUMS` | MIT, `LICENSE` |
| crypto-js resource | 4.2.0 | Checked-in resource SHA-256 `769a555de553babc35a3338f344dd7aa16260c93cea2c7db290707c90484e7cc` | MIT |
| cheerio resource | 1.0.0-rc.3 | Checked-in resource SHA-256 `b9655d15dc1341e251e32fe476c4f9b517c15ca03e25c75e7f472e29ac645959` | MIT |

Build recipe: compile `quickjs.c`, `cutils.c`, `libregexp.c`, `libunicode.c`, `dtoa.c`, and
`VortXQuickJSBridge.c` as C11 with `CONFIG_VERSION=\"2025-09-13\"`. XcodeGen applies that definition to
every Apple application target through `project.yml`.

The bridge is intentionally small and contains no provider implementation. Provider code is downloaded only
after manifest validation and is never copied into this directory.
