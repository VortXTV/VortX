# VortX feed edge

This worker is the tracked source for the three public release-feed routes:

- `/altstore.json`
- `/vortx-altstore.json`
- `/appcast.json`

The release workflow first binds a signed, content-addressed generation to the immutable draft
release and proves every asset through the authenticated release API. Staging stores a unique,
canonical receipt by release ID, tag, and generation and does not affect public routes. The workflow
then performs the guarded main update and edge promotion, verifies source and appcast route bytes,
and publishes the GitHub draft only as its final release write. Public asset proof and the
`release:published` workflow are read-only postchecks. Rollback requires both the current generation
and the trusted restore generation; an unverified rollback is an incident, never a success.

`RELEASE_FEED_RECEIPT_SECRET` is a Cloudflare secret and must also be supplied to the protected
release environment. It is never committed. The single `FeedCoordinator` Durable Object stores
staged generations, the active generation, exact rollback snapshots, and an append-only audit
receipt. KV is deliberately not an authority for release state. Android is `null` until a signed
artifact with a signer, build, URL, size, and digest is added to the release contract.

If a pre-Durable-Object generation must be migrated, prepare a full independently verified receipt
with `scripts/repair-release-feed.mjs`. The command only writes an unsigned local receipt unless an
operator supplies both `--execute` and the protected receipt secret. Repair is one-time: it refuses
to replace an existing durable active generation.

Deploy from the immutable VortX commit that contains this directory. Record the Cloudflare version
ID before changing the route mapping, then verify all three routes with and without query strings.
