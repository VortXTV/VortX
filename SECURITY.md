# Security Policy

## Supported versions

The latest release only. Sideloaded builds have no auto-update, so check Settings > About (the app shows a notice when a newer release exists).

## Reporting a vulnerability

Use GitHub's private vulnerability reporting (Security tab > Report a vulnerability) rather than a public issue, especially for anything touching:

- the embedded streaming server or its localhost surface
- account tokens and the keychain
- the release workflow and build verification

You will get a response in the repository within a few days. Verified reports are credited in the release notes unless you prefer otherwise.

## Verifying releases

Every release carries a `-ci` IPA built from source on GitHub's runners with a SHA-256 checksum, alongside the maintainer's build. Compare them if you want proof the binary matches the code.
