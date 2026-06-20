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
  totp_last_step     INTEGER,                 -- highest TOTP time-step accepted at login, so a code can't be replayed (F7)
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

-- Email send log (for the admin dashboard): one row per transactional send attempt. No PII beyond
-- the kind; never logs the recipient address or body.
CREATE TABLE IF NOT EXISTS email_sends (
  id   INTEGER PRIMARY KEY AUTOINCREMENT,
  ts   INTEGER NOT NULL,   -- epoch ms
  kind TEXT    NOT NULL,   -- short label (the email subject)
  ok   INTEGER NOT NULL    -- 1 = accepted by Cloudflare, 0 = send threw
);
CREATE INDEX IF NOT EXISTS idx_email_sends_ts ON email_sends (ts);

-- Email-based password reset (forgot password AND lost recovery code). A short-lived 6-digit code,
-- HMAC-hashed, with an attempt counter. Verifying it lets the client re-key the account into a FRESH
-- vault (the old data can't be decrypted without the old password/recovery code, so it is cleared).
CREATE TABLE IF NOT EXISTS password_resets (
  account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  code_hash  TEXT    NOT NULL,
  expires_at INTEGER NOT NULL,
  attempts   INTEGER NOT NULL DEFAULT 0
);

-- Family / household grouping. This is server-readable RELATIONSHIP metadata only (who is in whose
-- household). It is deliberately OUTSIDE the zero-knowledge layer: a family carries NO ciphertext, NO
-- wrapped keys, and NO sync document. The E2E contract is untouched, each member keeps their own data
-- key and their own backup blob; the server still cannot read any of it. A family only records that a
-- set of opaque account ids belong to the same household, so the dashboard can show a roster and the
-- product can offer household features (e.g. shared add-on suggestions) on top, without ever moving
-- one member's encrypted data to another.
CREATE TABLE IF NOT EXISTS families (
  id               TEXT PRIMARY KEY,        -- uuid
  name             TEXT NOT NULL,           -- household display name (user-supplied, length-capped)
  owner_account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, -- the account that created it
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_families_owner ON families (owner_account_id);

-- One row per (family, member). An account belongs to AT MOST ONE family: account_id is UNIQUE, so a
-- join while already in a household is rejected. Deleting an account or its family cascades the row
-- away. role is 'owner' or 'member'; the owner row mirrors families.owner_account_id.
CREATE TABLE IF NOT EXISTS family_members (
  family_id  TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL UNIQUE REFERENCES accounts(id) ON DELETE CASCADE,
  role       TEXT NOT NULL DEFAULT 'member', -- 'owner' | 'member'
  joined_at  INTEGER NOT NULL,
  PRIMARY KEY (family_id, account_id)
);
CREATE INDEX IF NOT EXISTS idx_family_members_family ON family_members (family_id);

-- Family invite codes. A short-lived join code, HMAC-hashed with SESSION_SECRET (same zero-knowledge
-- discipline as password_resets: the plaintext code lives only in the response/link the inviter shares,
-- never at rest). One pending invite per family (PRIMARY KEY family_id, upsert on re-issue). Consuming
-- an invite (a successful join) deletes the row.
CREATE TABLE IF NOT EXISTS family_invites (
  family_id  TEXT PRIMARY KEY REFERENCES families(id) ON DELETE CASCADE,
  code_hash  TEXT    NOT NULL,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_family_invites_expires ON family_invites (expires_at);
