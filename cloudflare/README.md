# VortX sync service

A Cloudflare Worker + D1 that backs VortX cloud sync. It is a **blind relay**: it stores only the
end-to-end-encrypted backup blob (keyed by an opaque account id) and short-lived pairing records. It
never sees plaintext, account keys, or the Stremio token.

Contract is mirrored by `app/SourcesShared/VortXSyncClient.swift`.

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/v1/pair/start` | none | Joining device publishes its ephemeral public key, gets a code |
| POST | `/v1/pair/claim` | none | Holder device wraps the account to the joiner and posts ciphertext |
| GET | `/v1/pair/status?id=` | none | Joining device polls until the wrapped account arrives (410 if expired) |
| PUT | `/v1/backup` | `X-VortX-Account` | Push sealed blob; kept only if `version` is newest (last-writer-wins) |
| GET | `/v1/backup` | `X-VortX-Account` | Pull latest sealed blob (404 if none) |

## Deploy

```bash
cd cloudflare
cp wrangler.toml.example wrangler.toml      # wrangler.toml is gitignored (holds your real database_id)
npx wrangler d1 create vortx-sync          # paste the printed database_id into wrangler.toml
npx wrangler d1 execute vortx-sync --remote --file=./schema.sql
npx wrangler deploy
# Map api.vortx.tv to the Worker (dashboard > Workers > Triggers > Custom Domains),
# then set VortXSyncClient.baseURL = https://api.vortx.tv in the app.
```

## Not yet implemented (refined-model, next chunk)

- Username/email account claim (human identity on top of the opaque id).
- An ed25519 account **signing key** for write-auth, so a known account id cannot be griefed via
  last-writer-wins overwrites.
- Per-kind blobs (profiles / settings / library / history / addons) with a **client-neutral** schema,
  so VortX can become a sync hub for other clients later.
