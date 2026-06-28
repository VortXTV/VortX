// VortX login + sync client (the webapp port of the website/app vault).
//
// ZERO-KNOWLEDGE MODEL
// --------------------
// Email + password + username, end to end encrypted. The password derives the account key on THIS
// device (PBKDF2-SHA256, 210k iterations), so the server (api.vortx.tv) and any future self-hosted
// node only ever see:
//   - an "auth verifier" (a one-iteration PBKDF2 of the master key, used to prove you know the
//     password without revealing it or the master key),
//   - "wrapped keys" (the random per-account data key, AES-GCM-encrypted under the master key and,
//     separately, under a recovery key), and
//   - opaque ciphertext (the synced backup document).
// The plaintext password, master key, recovery code, and data key NEVER leave this tab. The server
// cannot read the synced data: it stores only ciphertext and the wrapped keys, which are useless
// without the password (or the recovery code).
//
// INTEROP: the crypto here is byte-for-byte identical to the Apple app's CryptoKit code, the Tauri
// desktop client, and the website (vortx-site/src/lib/vault.ts), and is verified by the Worker's
// cloudflare/e2e-test.mjs. The API base, the iteration count, the PBKDF2 / AES-GCM parameters, and
// the wire shapes must stay in lockstep across all of them, so accounts created on one surface sign
// in on every other. Do NOT change API, ITERS, the KDF, or the seal/open framing in isolation.

const API = "https://api.vortx.tv";
const ITERS = 210_000;
const te = new TextEncoder();
const td = new TextDecoder();
const enc = (s: string): Uint8Array => te.encode(s);

/** base64-encode raw bytes (used for salts, wrapped keys, verifiers, ciphertext on the wire). */
function b64(u8: Uint8Array): string {
  let s = "";
  for (const b of u8) s += String.fromCharCode(b);
  return btoa(s);
}
/** base64-decode back to raw bytes. */
function unb64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** PBKDF2-SHA256 -> 256-bit key. The single key-stretching primitive: master key (password+kdfSalt),
 *  recovery key (recoveryCode+kdfSalt), and the 1-iteration auth/rec verifiers all go through here. */
async function pbkdf2(ikm: Uint8Array, salt: Uint8Array, iters: number): Promise<Uint8Array> {
  const km = await crypto.subtle.importKey("raw", ikm as BufferSource, "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt: salt as BufferSource, iterations: iters, hash: "SHA-256" },
    km,
    256,
  );
  return new Uint8Array(bits);
}

/** AES-GCM seal: random 12-byte IV prepended to the ciphertext (iv||ct), base64. The wrap/encrypt
 *  framing every surface agrees on. */
async function seal(key: Uint8Array, pt: Uint8Array): Promise<string> {
  const k = await crypto.subtle.importKey("raw", key as BufferSource, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, k, pt as BufferSource));
  const out = new Uint8Array(12 + ct.length);
  out.set(iv, 0);
  out.set(ct, 12);
  return b64(out);
}

/** AES-GCM open: split iv||ct, decrypt. Returns null on any failure (wrong key, tamper), so callers
 *  can treat "could not unlock" as a clean, expected outcome rather than a thrown crypto error. */
async function open(key: Uint8Array, ciphertext: string): Promise<Uint8Array | null> {
  try {
    const comb = unb64(ciphertext);
    const k = await crypto.subtle.importKey("raw", key as BufferSource, "AES-GCM", false, ["decrypt"]);
    return new Uint8Array(
      await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: comb.subarray(0, 12) as BufferSource },
        k,
        comb.subarray(12) as BufferSource,
      ),
    );
  } catch {
    return null;
  }
}

interface ApiResult {
  status: number;
  // The server replies with assorted JSON shapes per endpoint; callers narrow what they read.
  data: Record<string, unknown> | null;
}

/** Thin fetch wrapper for the JSON API. Adds the bearer token + content-type when relevant, and
 *  decodes the JSON body (skipping it on 204 / non-JSON responses). */
async function api(
  path: string,
  opts: { method?: string; body?: unknown; token?: string } = {},
): Promise<ApiResult> {
  const headers: Record<string, string> = {};
  if (opts.body !== undefined) headers["content-type"] = "application/json";
  if (opts.token) headers.authorization = "Bearer " + opts.token;
  const res = await fetch(API + path, {
    method: opts.method ?? "GET",
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
  let data: Record<string, unknown> | null = null;
  if (res.status !== 204 && res.headers.get("content-type")?.includes("json")) {
    data = (await res.json()) as Record<string, unknown>;
  }
  return { status: res.status, data };
}

/** A human-friendly but strong (128-bit) recovery code: VX-XXXX-XXXX-XXXX-XXXX-XXXX in Crockford
 *  base32. This is the only way back into encrypted data if the password is lost and no device is
 *  signed in; it is generated on-device and shown to the user exactly once. */
function makeRecoveryCode(): string {
  const A = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  let bits = "";
  for (const b of bytes) bits += b.toString(2).padStart(8, "0");
  let out = "";
  for (let i = 0; i < bits.length; i += 5) out += A[parseInt(bits.slice(i, i + 5).padEnd(5, "0"), 2)];
  return "VX-" + (out.match(/.{1,4}/g) ?? []).join("-");
}

// --- Public types -------------------------------------------------------------------------------

export interface Account {
  id: string;
  email: string;
  username: string;
  usernameChangedAt?: number;
  twoFactorEnabled?: boolean;
}
/** A live session: the bearer token, the account fields, and the decrypted data key (kept only in
 *  memory + localStorage on this device; it unlocks only THIS account's synced blob). */
export interface Session {
  token: string;
  account: Account;
  dataKey: Uint8Array;
}

// --- Session persistence ------------------------------------------------------------------------
// The token + account stay in localStorage so login survives navigation and reloads. The AES data key
// (which decrypts the WHOLE account) is kept in sessionStorage instead, so it is wiped when the tab/browser
// closes and a fresh tab re-derives it from the password/QR. This shrinks the master key's exposure to the
// lifetime of a tab (XSS or a malicious extension can no longer lift a key that persists forever). Matches
// the vortx.tv dashboard. SESSION_KEY is shared across this origin's web clients and must not change.
const SESSION_KEY = "vortx.session.v1";
const DATAKEY_KEY = "vortx.dk.v1";

export function saveSession(s: Session): void {
  try {
    localStorage.setItem(SESSION_KEY, JSON.stringify({ token: s.token, account: s.account }));
    sessionStorage.setItem(DATAKEY_KEY, b64(s.dataKey));
  } catch {
    // Private-mode / quota: the in-memory session still works for this tab.
  }
}
export function loadSession(): Session | null {
  try {
    const raw = localStorage.getItem(SESSION_KEY);
    if (!raw) return null;
    const o = JSON.parse(raw) as { token?: string; account?: Account; dataKey?: string };
    if (!o?.token || !o?.account) return null;
    let dk = sessionStorage.getItem(DATAKEY_KEY);
    // One-time migration off the legacy localStorage data key: move it to sessionStorage, then strip it
    // from localStorage so the master key no longer persists across tab closes.
    if (!dk && typeof o.dataKey === "string") {
      dk = o.dataKey;
      try {
        sessionStorage.setItem(DATAKEY_KEY, dk);
        localStorage.setItem(SESSION_KEY, JSON.stringify({ token: o.token, account: o.account }));
      } catch { /* keep the in-memory session for this tab */ }
    }
    if (!dk) return null; // token present but key gone (tab was closed): re-login to re-derive it
    return { token: o.token, account: o.account, dataKey: unb64(dk) };
  } catch {
    return null;
  }
}
export function clearSession(): void {
  try {
    localStorage.removeItem(SESSION_KEY);
    sessionStorage.removeItem(DATAKEY_KEY);
  } catch {
    // Nothing to do: a failed remove leaves a stale blob that the next load tolerates.
  }
}

// --- Key derivation helpers ---------------------------------------------------------------------

/** The master key: stretch the password under the account's kdf salt. Unlocks the password-wrapped
 *  data key and is the basis of the auth verifier. */
async function deriveMaster(password: string, kdfSalt: string, iters: number): Promise<Uint8Array> {
  return pbkdf2(enc(password), unb64(kdfSalt), iters);
}

/** Clamp a server-supplied PBKDF2 iteration count to a safe floor. A hostile / compromised prelogin
 *  returning a tiny kdfIters would collapse key stretching and enable offline brute-force of the auth
 *  verifier, so never go below ITERS. Legit accounts are always created at ITERS; a higher server value
 *  (a future migration) is honored. Not applied to the 1-iteration verifiers, which are intentional. */
function safeIters(n: unknown): number {
  return Math.max(Number(n) || 0, ITERS);
}
/** The auth verifier: a 1-iteration PBKDF2 of the master key salted by the password. Proves password
 *  knowledge to the server without ever sending the password or the master key itself. */
async function authVerifier(masterKey: Uint8Array, password: string): Promise<string> {
  return b64(await pbkdf2(masterKey, enc(password), 1));
}

// --- Registration / login -----------------------------------------------------------------------

/** Create an account. Generates the kdf salt, derives the master key, mints a random data key plus a
 *  recovery code, wraps the data key under BOTH the master key and the recovery key, and posts the
 *  verifiers + wrapped keys. Returns the live session AND the one-time recovery code (the UI must show
 *  it once and tell the user to store it offline). */
export async function register(
  email: string,
  username: string,
  password: string,
): Promise<{ session: Session; recoveryCode: string }> {
  const kdfSaltBytes = crypto.getRandomValues(new Uint8Array(16));
  const kdfSalt = b64(kdfSaltBytes);
  const masterKey = await pbkdf2(enc(password), kdfSaltBytes, ITERS);
  const dataKey = crypto.getRandomValues(new Uint8Array(32));
  const recoveryCode = makeRecoveryCode();
  const recoveryKey = await pbkdf2(enc(recoveryCode), kdfSaltBytes, ITERS);
  const body = {
    email,
    username,
    kdfSalt,
    kdfIters: ITERS,
    authVerifier: await authVerifier(masterKey, password),
    wrappedKeyPassword: await seal(masterKey, dataKey),
    wrappedKeyRecovery: await seal(recoveryKey, dataKey),
    recVerifier: b64(await pbkdf2(recoveryKey, enc(recoveryCode), 1)),
    // The plaintext recoveryCode is NEVER sent to the server (zero-knowledge): recVerifier +
    // wrappedKeyRecovery above are sufficient for the recovery protocol. The code is shown on-screen
    // once (the "created" step) for the user to copy; the welcome email tells them to save it from there.
  };
  const r = await api("/v1/auth/register", { method: "POST", body });
  if (r.status === 409) {
    throw new Error(r.data?.error === "email_taken" ? "That email is already registered." : "That username is taken.");
  }
  if (r.status !== 200) {
    throw new Error(r.data?.error === "weak_password" ? "Password must be at least 8 characters." : "Could not create the account.");
  }
  const data = r.data as { token: string; account: Account };
  return { session: { token: data.token, account: data.account, dataKey }, recoveryCode };
}

/** Thrown when the account has 2FA on and the login needs a TOTP code. The UI catches this to reveal
 *  the 6-digit field and retry with the code (instead of mislabeling it as a wrong password). */
export class TotpRequiredError extends Error {
  constructor() {
    super("totp_required");
    this.name = "TotpRequiredError";
  }
}

/** Sign in with email-or-username + password (+ optional TOTP). Pre-login fetches the account's kdf
 *  salt + iterations, the master key is derived locally, and only the auth verifier crosses the wire.
 *  On success the password-wrapped data key is unwrapped in-tab. Throws TotpRequiredError when the
 *  account needs a 2FA code so the UI can prompt for it. */
export async function login(loginId: string, password: string, totp?: string): Promise<Session> {
  const pre = await api("/v1/auth/prelogin", { method: "POST", body: { login: loginId } });
  const preData = pre.data as { kdfSalt: string; kdfIters: number } | null;
  if (!preData?.kdfSalt) throw new Error("Wrong email/username or password.");
  const masterKey = await deriveMaster(password, preData.kdfSalt, safeIters(preData.kdfIters));
  const body: Record<string, unknown> = { login: loginId, authVerifier: await authVerifier(masterKey, password) };
  if (totp) body.totp = totp.trim();
  const r = await api("/v1/auth/login", { method: "POST", body });
  if (r.status === 401) {
    if (r.data?.error === "totp_required") throw new TotpRequiredError();
    if (r.data?.error === "invalid_totp") {
      throw new Error("That 6-digit code is not right. Use the current one from your authenticator app.");
    }
    throw new Error("Wrong email/username or password.");
  }
  if (r.status !== 200) throw new Error("Could not sign in.");
  const data = r.data as { token: string; account: Account; wrappedKeyPassword: string };
  const dataKey = await open(masterKey, data.wrappedKeyPassword);
  if (!dataKey) throw new Error("Could not unlock your data.");
  return { token: data.token, account: data.account, dataKey };
}

/** Verify the stored session is still valid server-side (GET /v1/auth/me). Returns false ONLY on a
 *  definite 401 (the token was revoked/expired, e.g. a password change rotated session_version), so
 *  the app can force a clean re-login; a network blip returns true so it does not sign you out. On
 *  success it refreshes account fields (e.g. twoFactorEnabled) in place. */
export async function validateSession(session: Session): Promise<boolean> {
  let r: ApiResult;
  try {
    r = await api("/v1/auth/me", { token: session.token });
  } catch {
    return true; // network error: keep the session, don't bounce to login
  }
  if (r.status === 401) return false;
  if (r.status === 200 && r.data?.account) {
    session.account = { ...session.account, ...(r.data.account as Account) };
  }
  return true;
}

/** Live username-availability check (debounced by the UI). True = available. */
export async function checkUsername(username: string): Promise<boolean> {
  const r = await api("/v1/auth/check-username", { method: "POST", body: { username } });
  return !!r.data?.available;
}

// --- Recovery / reset ---------------------------------------------------------------------------

/** Forgot-password recovery (DATA-PRESERVING): the user still has the recovery code. Unwrap the data
 *  key with the recovery key, then re-derive a new master key from the SAME kdf salt the account
 *  already uses (so the recovery key stays valid afterwards) and re-wrap the data key under it. */
export async function recover(email: string, recoveryCode: string, newPassword: string): Promise<Session> {
  const start = await api("/v1/auth/recover-start", { method: "POST", body: { email } });
  const startData = start.data as { wrappedKeyRecovery?: string; kdfSalt: string; kdfIters: number } | null;
  if (!startData?.wrappedKeyRecovery) throw new Error("No recovery is set up for that email.");
  const recoveryKey = await pbkdf2(enc(recoveryCode.trim()), unb64(startData.kdfSalt), safeIters(startData.kdfIters));
  const dataKey = await open(recoveryKey, startData.wrappedKeyRecovery);
  if (!dataKey) throw new Error("That recovery code is not correct.");
  // Re-derive the new master key from the SAME kdfSalt the account already uses, so the recovery key
  // (also derived from kdfSalt) stays valid after this reset.
  const newMaster = await pbkdf2(enc(newPassword), unb64(startData.kdfSalt), safeIters(startData.kdfIters));
  const r = await api("/v1/auth/recover-complete", {
    method: "POST",
    body: {
      email,
      recVerifier: b64(await pbkdf2(recoveryKey, enc(recoveryCode.trim()), 1)),
      newAuthVerifier: await authVerifier(newMaster, newPassword),
      newWrappedKeyPassword: await seal(newMaster, dataKey),
    },
  });
  if (r.status !== 200) throw new Error("Recovery failed.");
  const data = r.data as { token: string; account: Account };
  return { token: data.token, account: data.account, dataKey };
}

// Email-code reset, for a user who lost BOTH their password and their recovery code. Unlike recover()
// (which still has the recovery code, so it keeps the data), this CANNOT recover the old data: with no
// old secret the old data key can't be unwrapped, so it mints a FRESH data key + a FRESH recovery code
// and the server drops the old (now-undecryptable) backup. resetStart() asks the server to email a
// 6-digit code; resetComplete() verifies it and re-keys into a fresh, empty vault.
export async function resetStart(login: string): Promise<void> {
  await api("/v1/auth/reset/start", { method: "POST", body: { login: login.trim().toLowerCase() } });
}
export async function resetComplete(
  login: string,
  code: string,
  newPassword: string,
): Promise<{ session: Session; recoveryCode: string }> {
  const loginId = login.trim().toLowerCase();
  const pre = await api("/v1/auth/prelogin", { method: "POST", body: { login: loginId } });
  const preData = pre.data as { kdfSalt: string; kdfIters: number } | null;
  if (pre.status !== 200 || !preData?.kdfSalt) throw new Error("Could not start the reset.");
  const kdfSaltBytes = unb64(preData.kdfSalt);
  const iters = safeIters(preData.kdfIters);
  // Keep the account's existing kdfSalt so the new recovery key derives consistently.
  const newMaster = await pbkdf2(enc(newPassword), kdfSaltBytes, iters);
  const dataKey = crypto.getRandomValues(new Uint8Array(32)); // fresh vault: the old data is unrecoverable
  const recoveryCode = makeRecoveryCode();
  const recoveryKey = await pbkdf2(enc(recoveryCode), kdfSaltBytes, iters);
  const r = await api("/v1/auth/reset/complete", {
    method: "POST",
    body: {
      login: loginId,
      code: code.trim(),
      authVerifier: await authVerifier(newMaster, newPassword),
      wrappedKeyPassword: await seal(newMaster, dataKey),
      wrappedKeyRecovery: await seal(recoveryKey, dataKey),
      recVerifier: b64(await pbkdf2(recoveryKey, enc(recoveryCode), 1)),
    },
  });
  if (r.status === 401) throw new Error("That reset code is wrong or expired.");
  if (r.status !== 200) throw new Error("Could not reset the password.");
  const data = r.data as { token: string; account: Account };
  return { session: { token: data.token, account: data.account, dataKey }, recoveryCode };
}

// --- Account management (signed-in) -------------------------------------------------------------

/** Change password while logged in: re-derive the key from the new password and re-wrap the data key.
 *  The change rotates session_version (revoking the old token), so adopt the fresh token to stay
 *  signed in. */
export async function changePassword(session: Session, oldPassword: string, newPassword: string): Promise<void> {
  const pre = await api("/v1/auth/prelogin", { method: "POST", body: { login: session.account.email } });
  const preData = pre.data as { kdfSalt: string; kdfIters: number } | null;
  if (!preData?.kdfSalt) throw new Error("Could not change the password.");
  const oldMaster = await deriveMaster(oldPassword, preData.kdfSalt, safeIters(preData.kdfIters));
  // Keep the account's kdfSalt so the recovery key still derives correctly afterwards.
  const newMaster = await deriveMaster(newPassword, preData.kdfSalt, safeIters(preData.kdfIters));
  const r = await api("/v1/auth/change-password", {
    method: "POST",
    token: session.token,
    body: {
      oldAuthVerifier: await authVerifier(oldMaster, oldPassword),
      newAuthVerifier: await authVerifier(newMaster, newPassword),
      newWrappedKeyPassword: await seal(newMaster, session.dataKey),
    },
  });
  if (r.status === 401) throw new Error("Current password is incorrect.");
  if (r.status !== 200) throw new Error("Could not change the password.");
  if (r.data?.token) {
    session.token = r.data.token as string;
    saveSession(session);
  }
}

/** Regenerate the recovery code while logged in (data-preserving): re-wrap the SAME data key under a
 *  fresh recovery code derived from the account's existing kdf salt, update the server, and return the
 *  new code (the server also emails it). The old code stops working. */
export async function regenerateRecoveryCode(session: Session): Promise<string> {
  const pre = await api("/v1/auth/prelogin", { method: "POST", body: { login: session.account.email } });
  const preData = pre.data as { kdfSalt: string; kdfIters: number } | null;
  if (!preData?.kdfSalt) throw new Error("Could not regenerate the recovery code.");
  const recoveryCode = makeRecoveryCode();
  const recoveryKey = await pbkdf2(enc(recoveryCode), unb64(preData.kdfSalt), safeIters(preData.kdfIters));
  const r = await api("/v1/auth/recovery/regenerate", {
    method: "POST",
    token: session.token,
    body: {
      wrappedKeyRecovery: await seal(recoveryKey, session.dataKey),
      recVerifier: b64(await pbkdf2(recoveryKey, enc(recoveryCode), 1)),
      // plaintext recoveryCode is NOT sent (zero-knowledge); shown on-screen for the user to copy.
    },
  });
  if (r.status !== 200) throw new Error("Could not regenerate the recovery code.");
  return recoveryCode;
}

// --- 2FA (authenticator / TOTP) -----------------------------------------------------------------

export async function enroll2fa(session: Session): Promise<{ secret: string; otpauth: string }> {
  const r = await api("/v1/auth/2fa/enroll", { method: "POST", token: session.token });
  if (r.status === 409) throw new Error("Two-factor is already enabled.");
  if (r.status !== 200) throw new Error("Could not start 2FA setup.");
  const data = r.data as { secret: string; otpauth: string };
  return { secret: data.secret, otpauth: data.otpauth };
}
export async function activate2fa(session: Session, code: string): Promise<void> {
  const r = await api("/v1/auth/2fa/activate", { method: "POST", token: session.token, body: { code } });
  if (r.status !== 200) throw new Error("That code is not valid. Use the current one from your app.");
  session.account.twoFactorEnabled = true;
  saveSession(session);
}
export async function disable2fa(session: Session, code: string): Promise<void> {
  const r = await api("/v1/auth/2fa/disable", { method: "POST", token: session.token, body: { code } });
  if (r.status !== 200) throw new Error("That code is not valid.");
  session.account.twoFactorEnabled = false;
  saveSession(session);
}

// --- Encrypted sync document --------------------------------------------------------------------
// The synced backup is one AES-GCM blob the server stores opaquely; only this tab (holding the data
// key) can read or write it. getSyncDoc/putSyncDoc are the decrypted read/write helpers; fetchSync
// reports status + the decoded contents for a "what is synced" view.

export interface SyncStatus {
  synced: boolean;
  version?: number;
  size?: number;
  contents?: Record<string, unknown>;
}

export async function fetchSync(session: Session): Promise<SyncStatus> {
  const r = await api("/v1/backup", { token: session.token });
  if (r.status === 404) return { synced: false };
  if (r.status !== 200) throw new Error("offline");
  const data = r.data as { document: string; version: number };
  const pt = await open(session.dataKey, data.document);
  let contents: Record<string, unknown> | undefined;
  if (pt) {
    try {
      contents = JSON.parse(td.decode(pt)) as Record<string, unknown>;
    } catch {
      // Binary / non-JSON payload: report status without contents.
    }
  }
  return {
    synced: true,
    version: data.version,
    size: Math.ceil((data.document.length * 3) / 4),
    contents,
  };
}

/** Read the decrypted sync document (the data key lives in this tab). */
export async function getSyncDoc(session: Session): Promise<Record<string, unknown>> {
  const s = await fetchSync(session);
  return (s.contents as Record<string, unknown>) ?? {};
}
/** Write the decrypted sync document back, re-encrypted under the data key. */
export async function putSyncDoc(session: Session, doc: Record<string, unknown>): Promise<void> {
  const ciphertext = await seal(session.dataKey, enc(JSON.stringify(doc)));
  const r = await api("/v1/backup", {
    method: "PUT",
    token: session.token,
    body: { document: ciphertext, version: Date.now() },
  });
  if (r.status !== 200) throw new Error("Could not save to your account.");
}

// --- QR / device sign-in (pairing) --------------------------------------------------------------
// A new device shows a QR; an already-signed-in device approves it, handing over the data key WITHOUT
// the server ever seeing it. This reuses the Apple app's PairingCrypto contract byte-for-byte: an
// ephemeral X25519 key agreement, HKDF-SHA256 (salt "vortx-pairing-salt-v1", info "vortx-pairing-v1")
// to a 32-byte AES-GCM key, sealing the 32-byte data key in the combined nonce||ct||tag framing, all
// base64url. So the same flow can later interoperate with the native app as the approver. The worker
// (/v1/qr/*) relays only ciphertext + ephemeral public keys and mints the session token on approval.

const PAIR_SALT = enc("vortx-pairing-salt-v1");
const PAIR_INFO = enc("vortx-pairing-v1");

/** base64url (no padding), matching the app's BackupCrypto.base64URL, for ephemeral pubkeys + sealed blobs. */
function b64url(u8: Uint8Array): string {
  return b64(u8).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function unb64url(s: string): Uint8Array {
  return unb64(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4));
}

/** ECDH(X25519) + HKDF-SHA256 -> the 32-byte one-time wrapping key, from our private key + the peer's
 *  raw public key (base64url). ECDH is symmetric, so wrap and unwrap derive the same key. */
async function pairWrappingKey(ourPrivate: CryptoKey, peerPubB64url: string): Promise<Uint8Array> {
  const peer = await crypto.subtle.importKey("raw", unb64url(peerPubB64url) as BufferSource, { name: "X25519" }, false, []);
  const secret = new Uint8Array(await crypto.subtle.deriveBits({ name: "X25519", public: peer }, ourPrivate, 256));
  const hk = await crypto.subtle.importKey("raw", secret as BufferSource, "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: PAIR_SALT as BufferSource, info: PAIR_INFO as BufferSource },
    hk,
    256,
  );
  return new Uint8Array(bits);
}

/** AES-GCM seal in the app's combined framing (nonce||ct||tag), base64url. */
async function sealPair(key: Uint8Array, pt: Uint8Array): Promise<string> {
  const k = await crypto.subtle.importKey("raw", key as BufferSource, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, k, pt as BufferSource));
  const out = new Uint8Array(12 + ct.length);
  out.set(iv, 0);
  out.set(ct, 12);
  return b64url(out);
}
/** AES-GCM open of a base64url combined sealed blob. Null on any failure (wrong key / tamper). */
async function openPair(key: Uint8Array, blobB64url: string): Promise<Uint8Array | null> {
  try {
    const comb = unb64url(blobB64url);
    const k = await crypto.subtle.importKey("raw", key as BufferSource, "AES-GCM", false, ["decrypt"]);
    return new Uint8Array(
      await crypto.subtle.decrypt({ name: "AES-GCM", iv: comb.subarray(0, 12) as BufferSource }, k, comb.subarray(12) as BufferSource),
    );
  } catch {
    return null;
  }
}

/** Whether this browser has the X25519 WebCrypto the QR flow needs (so the UI can hide it otherwise). */
export async function qrSupported(): Promise<boolean> {
  try {
    await crypto.subtle.generateKey({ name: "X25519" }, false, ["deriveBits"]);
    return true;
  } catch {
    return false;
  }
}

export interface QrJoin {
  pairingID: string;
  code: string;
  /** What the QR encodes: an approve deep-link a signed-in device opens. */
  approveURL: string;
  /** Kept in memory by the caller until approval; needed to unwrap the approved payload. */
  ephemeral: CryptoKeyPair;
}

/** Joiner: start a QR sign-in. Mints an ephemeral X25519 keypair, registers its public key with the
 *  worker, and returns the pairing id + the human code + the approve URL to render as a QR. */
export async function qrSignInStart(approveBase: string): Promise<QrJoin> {
  const ephemeral = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
  const pub = b64url(new Uint8Array(await crypto.subtle.exportKey("raw", ephemeral.publicKey)));
  const r = await api("/v1/qr/start", { method: "POST", body: { devicePublicKey: pub } });
  const d = r.data as { pairingID?: string; code?: string } | null;
  if (r.status !== 200 || !d?.pairingID || !d?.code) throw new Error("Could not start QR sign-in.");
  const approveURL = `${approveBase}#/approve?c=${encodeURIComponent(d.code)}&k=${encodeURIComponent(pub)}`;
  return { pairingID: d.pairingID, code: d.code, approveURL, ephemeral };
}

/** Joiner: poll once. Returns the live Session when approved, null while still pending. Throws on a
 *  definite failure (expired pairing, undecryptable payload). */
export async function qrSignInPoll(join: QrJoin): Promise<Session | null> {
  const r = await api(`/v1/qr/status?id=${encodeURIComponent(join.pairingID)}`);
  if (r.status === 410 || r.status === 404) throw new Error("This QR code expired. Generate a new one.");
  const d = r.data as { token?: string; payload?: string; pending?: boolean } | null;
  if (!d || d.pending || !d.token || !d.payload) return null; // still waiting for approval
  let parsed: { claim?: string; wrapped?: string };
  try {
    parsed = JSON.parse(d.payload) as { claim?: string; wrapped?: string };
  } catch {
    throw new Error("Sign-in failed (bad approval payload).");
  }
  if (!parsed.claim || !parsed.wrapped) throw new Error("Sign-in failed (incomplete approval).");
  const wrapKey = await pairWrappingKey(join.ephemeral.privateKey, parsed.claim);
  const dataKey = await openPair(wrapKey, parsed.wrapped);
  if (!dataKey || dataKey.length !== 32) throw new Error("Could not unlock your data from the approval.");
  // The worker minted the session token on approval; fetch the account fields it belongs to.
  const me = await api("/v1/auth/me", { token: d.token });
  const account = me.status === 200 ? (me.data?.account as Account | undefined) : undefined;
  if (!account) throw new Error("Sign-in failed (account lookup).");
  const session: Session = { token: d.token, account, dataKey };
  saveSession(session);
  return session;
}

/** Approver (signed in): wrap our data key to a joining device's published public key and authorize the
 *  pairing. `code` + `devicePublicKey` come from the QR the joining device displayed. */
export async function qrApprove(session: Session, code: string, devicePublicKey: string): Promise<void> {
  const ephemeral = (await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"])) as CryptoKeyPair;
  const claim = b64url(new Uint8Array(await crypto.subtle.exportKey("raw", ephemeral.publicKey)));
  const wrapKey = await pairWrappingKey(ephemeral.privateKey, devicePublicKey);
  const wrapped = await sealPair(wrapKey, session.dataKey);
  const r = await api("/v1/qr/authorize", {
    method: "POST",
    token: session.token,
    body: { code: code.trim().toUpperCase(), wrappedPayload: JSON.stringify({ claim, wrapped }) },
  });
  if (r.status === 404) throw new Error("That code was not found. It may have expired.");
  if (r.status === 410) throw new Error("That code has expired.");
  if (r.status !== 200) throw new Error("Could not approve the sign-in.");
}
