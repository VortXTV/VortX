-- Migration 0001: family / household grouping.
--
-- ADDITIVE and NON-DESTRUCTIVE. Creates three new tables and their indexes; touches nothing that
-- exists. Safe to run against the live `vortx-sync` database and safe to re-run (every statement is
-- IF NOT EXISTS). No DROP / DELETE / TRUNCATE. Back up first (see migrations/README.md).
--
-- These tables hold server-readable RELATIONSHIP metadata ONLY. No ciphertext, no wrapped keys, no
-- sync document, the zero-knowledge contract is unchanged. Apply with:
--   npx wrangler d1 execute vortx-sync --remote --file=./migrations/0001-add-family.sql

CREATE TABLE IF NOT EXISTS families (
  id               TEXT PRIMARY KEY,
  name             TEXT NOT NULL,
  owner_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_families_owner ON families (owner_account_id);

CREATE TABLE IF NOT EXISTS family_members (
  family_id  TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL UNIQUE REFERENCES accounts(id) ON DELETE CASCADE,
  role       TEXT NOT NULL DEFAULT 'member',
  joined_at  INTEGER NOT NULL,
  PRIMARY KEY (family_id, account_id)
);
CREATE INDEX IF NOT EXISTS idx_family_members_family ON family_members (family_id);

CREATE TABLE IF NOT EXISTS family_invites (
  family_id  TEXT PRIMARY KEY REFERENCES families(id) ON DELETE CASCADE,
  code_hash  TEXT    NOT NULL,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_family_invites_expires ON family_invites (expires_at);
