# VortX feed edge

This worker is the tracked source for the three public release-feed routes:

- `/altstore.json`
- `/vortx-altstore.json`
- `/appcast.json`

The release workflow first stages a signed, content-addressed generation while the GitHub release
is still a draft. Staging stores a unique receipt by release ID and does not affect public routes.
After the release is published, the workflow promotes that exact generation through the serialized
coordinator and verifies public asset bytes, source bytes, compatibility bytes, and appcast metadata.
Rollback requires both the current generation and the trusted restore generation.

`RELEASE_FEED_RECEIPT_SECRET` is a Cloudflare secret and must also be supplied to the protected
release environment. It is never committed. `LASTGOOD` stores staged generations, the active
generation, and exact rollback snapshots. Android is `null` until a signed artifact with a signer,
build, URL, size, and digest is added to the release contract.

Deploy from the immutable VortX commit that contains this directory. Record the Cloudflare version
ID before changing the route mapping, then verify all three routes with and without query strings.
