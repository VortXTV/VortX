# Contributing to VortX

Contributions are welcome, and the bar to clear is low. The project has merged
community pull requests within hours of them opening, and contributors are
credited by name in the release notes for the version their work ships in. This
guide covers the few things that keep that fast.

## Licensing and the CLA

VortX source code is licensed under **GPL-3.0-or-later** (see [LICENSE](LICENSE)).
The VortX name and logo are separate from the code licence and are covered by the
brand-use policy in [TRADEMARK.md](TRADEMARK.md).

Before your first contribution can be merged, we ask you to sign the project's
**Contributor License Agreement** ([CLA.md](CLA.md)). It is short and it is not
hostile:

- You keep the copyright in everything you write. The CLA does not assign or
  transfer your copyright.
- You grant the project a broad, lasting licence to use your contribution, which
  is what lets the project keep its licensing options open over time.

### How to sign

Open a pull request that adds your signed record to the bottom of [CLA.md](CLA.md),
filling in the signature block (full name, GitHub username, email, and date). One
signature covers all of your present and future contributions, so you only do this
once. If you prefer a different submission path, ask in your pull request or an
issue and the maintainer will confirm the process. An automated CLA check may be
added later; until then this manual path is the way to sign.

## Pull request mechanics

- Keep each pull request focused on one thing.
- Include before and after screenshots for anything visual. The existing pull
  requests set the pattern.
- Build against the oldest practical SDK. The CI runners lag the newest Xcode,
  and newer-only APIs have failed CI there before. The CI run on your pull
  request will tell you if you hit this.

### Commit messages

Use conventional commit titles, scoped by platform, for example:

```
feat(tvos): add a resume button to the series hero
fix(ios): stop the player straddling the previous title
chore: bump the fetch script pins
```

### No em dashes

Do not use em dashes in any prose, including code comments, commit messages,
pull request descriptions, changelog entries, and documentation. Use commas,
colons, periods, or parentheses instead.

## The Xcode project is generated

`app/project.yml` is the single source of truth for the Xcode project.
`VortX.xcodeproj` is generated from it and is gitignored, so never edit the
`.xcodeproj` directly. After changing `project.yml`, regenerate the project:

```bash
cd app && xcodegen generate
```

Commit the change to `project.yml`, not to the generated project.
