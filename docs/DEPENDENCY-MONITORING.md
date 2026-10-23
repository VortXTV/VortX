# Dependency inventory and update monitoring

Release notifications and dependency upgrades are separate operations. Monitoring
must never install a package, change a source pin, weaken verification, or deploy
a service. An available upstream version is not proof that its replacement is
compatible with the product's codec, licensing, compiler and SDK requirements.

## Inventory layers

Record all of the following, retaining the distinction between declarations,
resolved lockfiles and actual shipped binary provenance:

- Direct and transitive Rust, JavaScript and Android dependencies.
- Native player wrapper, mpv, FFmpeg, libplacebo and every bundled C/C++ library.
- Media3, Android SDK/NDK, Apple SDKs and system-owned frameworks such as AVKit.
- Compiler, language, build and package-manager toolchains; CI actions/images.
- All first-party apps, desktop/web surfaces and backend repositories, including
  private repositories without publishing their source or private package names.

Do not count reference-only checkouts or historical build artifacts as installed
components. Canonical and integration checkouts may have different lockfiles;
record both contexts rather than silently selecting the newer one as shipping.

## Source and registry checker

`scripts/dependency-health.py` reads an operator-owned JSON configuration containing
`repositories` (label/path/role) and optional explicit `components`. It inventories
current Git-tracked and nonignored source manifests without running package
installation, lifecycle scripts, Cargo resolution or Gradle builds. Cache/build
and retained source-evidence trees are excluded; real vendored source is included.

The current adapters cover npm JSON locks, pnpm v9, Cargo registry locks/manifests,
Gradle catalogs and GitHub Actions, with bounded read-only upstream metadata
queries. Maven BOM-managed coordinates are still monitored for releases even
when their current resolved version is unknown. GitHub SHA/fork pins require
review, not automatic replacement by a numerically newer tag. Unsupported formats,
missing locks, native/system adapters and unresolved Android runtime graphs remain
explicit coverage gaps until reconciled. **A report with gaps is not a complete
audit and cannot be described as every component being up to date.**

Only public registry identities may be queried publicly. npm origin/scope settings
and local first-party names must be respected; credentials and private registry
URLs must not be included in the report. GitHub metadata reads use existing CLI
authentication without extracting or printing a token.
Maven coordinates and Gradle plugin identities require explicit corroborated
`public_maven_names` and `public_plugin_names` configuration lists before public
queries. Unknown/private coordinates become generic gaps, not registry probes.

Example (substitute existing authorized local paths):

```sh
python3 scripts/dependency-health.py --config /absolute/local/config.json \
  --report /absolute/local/new-report.json --journal /absolute/local/new-journal.jsonl \
  --previous /absolute/local/previous-report.json --workers 4
```

Use fresh output paths. Reports and journals are immutable evidence; the checker
refuses to overwrite them. `--inventory-only` avoids all registry calls.
`--reuse-journal` is only for recovering an interrupted same-session check: it
retains the original observation time and reuses successful observations at most
two hours old. A normal daily refresh must not use it to skip fresh checks.

## Daily notifications

The owner's requested schedule is **00:00 GMT/UTC every day**, not local midnight.
At the current Asia/Kolkata host timezone this is 05:30 IST. This is a separate,
explicitly authorized alert task; it must not resume older repair/release tasks or
change other tasks' state.

Refresh discovery before each run. Compare every successful component's complete
release-version set with its last successful observation, not only the single
latest version. Include maintenance releases on old major branches, patch/minor/
major versions and prerelease/RC versions, clearly labelled. Never silently apply
major/prerelease changes to production. Highlight security releases and provide
official upstream links, current source/resolved version and affected surfaces.

Report every newly observed release, newly tracked component and verification
failure. Keep a complete readable report when a notification would otherwise
truncate; do not report only a top-N selection. Do not erase successful cursors
when a source manifest or registry becomes temporarily unavailable. A fully
successful unchanged run can remain quiet. Monitoring failure is not an all-clear.

The local automation's activation alone does not prove full coverage or delivery;
retain real inventory/query/test evidence and keep remaining adapters visible.
