# Security Policy

## Reporting a vulnerability

Please report security issues **privately** using GitHub's "Report a vulnerability" button on the
[Security tab](https://github.com/mamaclapper/StremioX/security/advisories), not in a public issue. I
will acknowledge it and work on a fix.

## Scope

StremioX is an independent, unsigned, sideloaded app. In scope:

- The app's own code: the Apple TV and iPhone/iPad clients, the Swift-to-Rust engine bridge, and the
  embedded-server wiring.
- Handling of the Stremio account token, which is stored in the device Keychain.

Out of scope:

- Stremio's own components that the app bundles or hosts (stremio-web, the proprietary `server.js`, the
  streaming server). Report those to Stremio.
- The addons you install. Those are third-party; report to their authors.
- The IPAs being unsigned and re-signed by the user. That is by design (see the README).

## Supported versions

Only the latest release is supported. Please update before reporting.

## What the app does with your data

It talks to Stremio's official API to sign in, to the addons you install, and to whichever streaming
server you point it at. It adds no analytics and no telemetry. The sign-in token stays on the device
(Keychain) and only ever goes to Stremio's API. See the README's "Security and privacy" section.
