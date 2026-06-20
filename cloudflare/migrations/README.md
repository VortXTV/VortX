# Worker DB migrations (read before you touch production)

`api.vortx.tv` has **real, end-to-end-encrypted user accounts**. The server cannot read or reset
them, so a destructive schema change is permanent, unrecoverable data loss. Treat every change to the
live D1 (`vortx-sync`) as a one-way operation.

## Rules

1. **Never** run `DROP TABLE`, `DELETE`, or `TRUNCATE` against the remote database. `schema.sql` is
   intentionally idempotent (`CREATE TABLE IF NOT EXISTS`) and safe to re-run.
2. To add a column, append an **additive** statement here as a numbered file, e.g.
   `0001-add-foo.sql` containing `ALTER TABLE accounts ADD COLUMN foo TEXT;`. SQLite `ALTER ... ADD
   COLUMN` is additive and safe; it only errors if the column already exists, which is harmless.
3. **Back up before any remote change:**
   `npx wrangler d1 export vortx-sync --remote --output ~/vortx-backups/vortx-sync-$(date +%Y%m%d-%H%M%S).sql`
   (backups live outside the repo; they contain user emails and hashes and must never be committed).
4. Apply a migration with:
   `npx wrangler d1 execute vortx-sync --remote --file=./migrations/NNNN-name.sql`

## History

- `schema.sql` (v3) is the current full shape: `accounts`, `backups`, `pairings`. It already includes
  the columns that were added live during the v3 hardening (`session_version`, `totp_secret`,
  `totp_pending`), so a fresh database created from it matches production. No back-migration needed.
- `0001-add-family.sql` adds family / household grouping: `families`, `family_members`,
  `family_invites`. Purely additive (three new tables + indexes, all `IF NOT EXISTS`). These tables
  store server-readable relationship metadata only (who is in whose household); they hold no
  ciphertext, no wrapped keys, and no sync document, so the zero-knowledge contract is unchanged. The
  same shape is folded into `schema.sql`, so a fresh database matches a migrated one.
