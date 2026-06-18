-- VortX sync service schema v3 (Cloudflare D1 / SQLite) — END TO END ENCRYPTED.
--
-- The server (and any future self-hosted federation node) stores ONLY: the email/username, a
-- per-account KDF salt, a hash of the client's auth verifier, the data key wrapped by the password
-- key and by the recovery key, and the ciphertext sync document. It can never derive the password
-- or the data key, so it can never read user data. All key derivation, wrapping, and the sync-doc
-- encryption happen on the client (website + app), with matching parameters.

-- SAFETY (do not remove). This file is IDEMPOTENT and NON-DESTRUCTIVE: it is safe to run against the
-- live database at any time and it NEVER drops a table. There are REAL accounts in production. A DROP
-- here is permanent, unrecoverable data loss, because the data is end to end encrypted and there is no
-- server-side reset. To add a column, append an additive `ALTER TABLE ... ADD COLUMN` (see
-- cloudflare/migrations/). NEVER put DROP TABLE / DELETE / TRUNCATE in any file run against remote D1.

CREATE TABLE IF NOT EXISTS accounts (
  id                 TEXT PRIMARY KEY,        -- uuid
  email              TEXT NOT NULL UNIQUE,    -- lowercased
  username           TEXT NOT NULL UNIQUE,    -- lowercased, case-insensitive uniqueness
  username_display   TEXT NOT NULL,           -- as typed
  username_changed_at INTEGER NOT NULL DEFAULT 0, -- epoch ms of last change (3-month cooldown)
  kdf_salt           TEXT NOT NULL,           -- base64, per-account; returned by prelogin so the client can derive its key
  kdf_iters          INTEGER NOT NULL,        -- PBKDF2 iterations the client used
  auth_salt          TEXT NOT NULL,           -- base64 salt for the server-side hash of the auth verifier
  auth_hash          TEXT NOT NULL,           -- base64 PBKDF2 of the client's auth verifier (defends a DB leak)
  rec_verifier_hash  TEXT,                    -- base64 hash of the recovery verifier (nullable)
  rec_verifier_salt  TEXT,
  wrapped_key_pw     TEXT NOT NULL,           -- data key, AES-GCM-wrapped under the password key (client)
  wrapped_key_rec    TEXT,                    -- data key, AES-GCM-wrapped under the recovery key (client)
  totp_secret        TEXT,                    -- base32 TOTP secret once 2FA is ACTIVE (null = off)
  totp_pending       TEXT,                    -- base32 secret mid-enrollment, before a code confirms it
  session_version    INTEGER NOT NULL DEFAULT 0, -- bumped on password change/recovery to revoke old tokens (H-1)
  created_at         INTEGER NOT NULL
);

-- The synced state: one ciphertext document per account (the server cannot read it). LWW by version.
CREATE TABLE IF NOT EXISTS backups (
  account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  document   TEXT    NOT NULL,   -- AES-GCM ciphertext under the account data key
  version    INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- QR login: a device shows a code; the logged-in app authorizes it; the device polls for a session.
CREATE TABLE IF NOT EXISTS pairings (
  pairing_id    TEXT PRIMARY KEY,
  code          TEXT    NOT NULL,
  device_pubkey TEXT    NOT NULL,             -- joining device's ephemeral X25519 public key (for the data-key handoff)
  account_id    TEXT,
  session       TEXT,                         -- issued session token for the joining device
  payload       TEXT,                         -- data key wrapped to device_pubkey by the authorizing app
  expires_at    INTEGER NOT NULL,
  created_at    INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_pairings_code ON pairings (code);
