/**
 * VortX sync service v3 (Cloudflare Worker + D1) — END TO END ENCRYPTED.
 *
 * Login is email + password + a unique case-insensitive username, with QR login. But the server (and
 * any future self-hosted federation node) is a blind store: it only ever holds the email/username, a
 * per-account KDF salt, a hash of the client's auth verifier, the data key wrapped under the password
 * key and the recovery key, and the ciphertext sync document. It can never derive the password or the
 * data key, so it can never read user data.
 *
 * CLIENT CRYPTO CONTRACT (implemented identically by the website and the app):
 *   masterKey     = PBKDF2-SHA256(password, salt=kdfSalt, iters=kdfIters, 256 bits)
 *   authVerifier  = base64(PBKDF2-SHA256(masterKey, salt=utf8(password), iters=1, 256))   // sent to log in
 *   dataKey       = random 32 bytes (minted once at signup)
 *   wrappedKeyPw  = base64(AES-256-GCM(dataKey, key=masterKey))                            // combined iv|ct|tag
 *   recoveryCode  = strong random shown once (>=128 bits); recoveryKey = PBKDF2(recoveryCode, kdfSalt, iters)
 *   wrappedKeyRec = base64(AES-256-GCM(dataKey, key=recoveryKey))
 *   recVerifier   = base64(PBKDF2-SHA256(recoveryKey, salt=utf8(recoveryCode), iters=1, 256))
 *   document      = base64(AES-256-GCM(syncDocJSON, key=dataKey))                          // the synced state
 * The server hashes authVerifier / recVerifier again (server salt) before storing, so a DB leak does
 * not reveal even the verifiers.
 */

interface EmailMessage {
  to: string;
  from: { email: string; name?: string };
  subject: string;
  html: string;
  text: string;
}
export interface Env {
  DB: D1Database;
  SESSION_SECRET: string;
  RL: { limit(opts: { key: string }): Promise<{ success: boolean }> };
  EMAIL?: { send(msg: EmailMessage): Promise<unknown> }; // Cloudflare Email Sending binding (optional so dry-runs/tests work)
}

const PAIR_TTL_MS = 10 * 60 * 1000;
const SESSION_TTL_MS = 120 * 24 * 60 * 60 * 1000;
const USERNAME_COOLDOWN_MS = 90 * 24 * 60 * 60 * 1000; // 3 months
const SERVER_ITERS = 100_000; // re-hash of the (already high-entropy) client verifiers
const DEFAULT_KDF_ITERS = 210_000;
const MAX_DOC = 1024 * 1024;
const MAX_FIELD = 8192;

const te = new TextEncoder();
const td = new TextDecoder();
const enc = (s: string) => te.encode(s);

// CORS is locked to the production site plus this project's own preview/dev origins. The API is
// Bearer-authenticated and a foreign origin starts with no token, so reflecting an allowed origin
// here cannot leak data; it just lets preview deploys and local dev be tested. Anything else gets
// the production origin back, which the browser rejects for a mismatched caller.
function allowedOrigin(origin: string | null): string {
  if (!origin) return "https://vortx.tv";
  if (origin === "https://vortx.tv") return origin;
  if (/^https:\/\/[a-z0-9-]+\.(vortx-site|vortx)\.pages\.dev$/.test(origin)) return origin;
  if (/^http:\/\/(localhost|127\.0\.0\.1):\d+$/.test(origin)) return origin;
  return "https://vortx.tv";
}
function cors(): Record<string, string> {
  return {
    "access-control-allow-origin": "https://vortx.tv", // overridden per-request in fetch() via allowedOrigin
    "access-control-allow-methods": "GET,PUT,POST,OPTIONS",
    "access-control-allow-headers": "content-type,authorization",
    "access-control-max-age": "86400",
    "cache-control": "no-store", // API responses (sync state, account) must never be cached stale
  };
}
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json", ...cors() } });
const noContent = (status: number) => new Response(null, { status, headers: cors() });

function b64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}
function unb64(str: string): Uint8Array {
  const bin = atob(str);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function b64url(bytes: Uint8Array): string {
  return b64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function pbkdf2(value: string, salt: Uint8Array, iters: number): Promise<string> {
  const km = await crypto.subtle.importKey("raw", enc(value), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", salt: salt as BufferSource, iterations: iters, hash: "SHA-256" }, km, 256);
  return b64(new Uint8Array(bits));
}
function ctEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function hmacKey(secret: string) {
  return crypto.subtle.importKey("raw", enc(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}
// Session tokens carry a session_version (v). Changing the password or recovering increments the
// account's session_version, which invalidates every previously issued token (H-1), since verifySession
// rejects a token whose v no longer matches the stored value.
async function makeSession(accountId: string, env: Env, version = 0): Promise<string> {
  const payload = b64url(enc(JSON.stringify({ a: accountId, v: version, exp: Date.now() + SESSION_TTL_MS })));
  const sig = b64url(new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(env.SESSION_SECRET), enc(payload))));
  return `${payload}.${sig}`;
}
async function accountSessionVersion(id: string, env: Env): Promise<number> {
  const r = await env.DB.prepare("SELECT session_version FROM accounts WHERE id = ?").bind(id).first<{ session_version: number }>();
  return r ? (r.session_version ?? 0) : -1; // -1 (deleted account) never matches a token's v
}
async function verifySession(token: string | null, env: Env): Promise<string | null> {
  if (!token) return null;
  const [payload, sig] = token.split(".");
  if (!payload || !sig) return null;
  let sigBytes: Uint8Array;
  try { sigBytes = unb64(sig.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (sig.length % 4)) % 4)); } catch { return null; }
  const ok = await crypto.subtle.verify("HMAC", await hmacKey(env.SESSION_SECRET), sigBytes as BufferSource, enc(payload));
  if (!ok) return null;
  try {
    const dec = td.decode(unb64(payload.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (payload.length % 4)) % 4)));
    const { a, v, exp } = JSON.parse(dec);
    if (typeof a !== "string" || typeof exp !== "number" || exp <= Date.now()) return null;
    const sv = await accountSessionVersion(a, env);
    return sv >= 0 && (typeof v === "number" ? v : -1) === sv ? a : null;
  } catch { return null; }
}
async function requireAuth(req: Request, env: Env): Promise<string | null> {
  const h = req.headers.get("authorization");
  return verifySession(h && h.startsWith("Bearer ") ? h.slice(7) : null, env);
}

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const USERNAME_RE = /^[a-zA-Z0-9_]{3,20}$/;
const isStr = (v: unknown, max = MAX_FIELD): v is string => typeof v === "string" && v.length > 0 && v.length <= max;
const b64Len = (s: string): number => { try { return unb64(s).length; } catch { return -1; } };

// Endpoints worth throttling per-IP: credential checks, account creation, and the Stremio proxy (C-1, H-2, H-3).
const RL_PATHS = new Set([
  "/v1/auth/login", "/v1/auth/register", "/v1/auth/prelogin",
  "/v1/auth/recover-start", "/v1/auth/recover-complete", "/v1/auth/change-password",
  "/v1/auth/2fa/activate", "/v1/auth/2fa/disable",
  "/v1/qr/authorize", "/v1/connect/stremio", "/v1/addon/manifest",
]);
async function readJSON(req: Request): Promise<Record<string, unknown> | null> {
  try { const b = await req.json(); return b && typeof b === "object" ? (b as Record<string, unknown>) : null; } catch { return null; }
}
function pub(row: { id: string; email: string; username_display: string; username_changed_at?: number }) {
  return { id: row.id, email: row.email, username: row.username_display, usernameChangedAt: row.username_changed_at ?? 0 };
}

// --- Transactional email (Cloudflare Email Sending). Best-effort: a send failure is logged and
// swallowed so it can never break an auth flow. All interpolated values are server-controlled or
// validated (usernames are [a-zA-Z0-9_]), so the templates are safe. ---
const MAIL_FROM = { email: "welcome@vortx.tv", name: "VortX" };
function emailHtml(heading: string, lines: string[], note?: string): string {
  const body = lines.map((l) => `<p style="margin:0 0 14px;color:#cbb38c;font-size:15px;line-height:1.6">${l}</p>`).join("");
  const noteHtml = note
    ? `<p style="margin:20px 0 0;padding:12px 14px;background:#0f0d0a;border:1px solid rgba(253,246,227,.1);border-radius:10px;color:#998163;font-size:13px;line-height:1.55">${note}</p>`
    : "";
  return `<!doctype html><html><body style="margin:0;background:#0b0907;padding:30px 16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif">`
    + `<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center">`
    + `<table role="presentation" width="100%" style="max-width:480px" cellpadding="0" cellspacing="0">`
    + `<tr><td style="padding:0 4px 20px"><span style="font-weight:800;font-size:22px;letter-spacing:-.5px;color:#f59e0b">VortX</span></td></tr>`
    + `<tr><td style="background:linear-gradient(180deg,#18140d,#13100a);border:1px solid rgba(253,246,227,.08);border-radius:18px;padding:30px 28px">`
    + `<h1 style="margin:0 0 16px;font-weight:800;font-size:21px;letter-spacing:-.4px;color:#fdf6e3">${heading}</h1>${body}${noteHtml}</td></tr>`
    + `<tr><td style="padding:18px 4px 0;color:#6b5d47;font-size:12px;line-height:1.5">VortX is end to end encrypted, so we can never read your data. You received this because of activity on your VortX account.</td></tr>`
    + `</table></td></tr></table></body></html>`;
}
function emailText(heading: string, lines: string[], note?: string): string {
  return `VortX\n\n${heading}\n\n${lines.join("\n\n")}${note ? "\n\n" + note : ""}\n\nVortX is end to end encrypted, so we can never read your data.`;
}
async function sendMail(env: Env, to: string, subject: string, heading: string, lines: string[], note?: string): Promise<void> {
  if (!env.EMAIL) return;
  try {
    await env.EMAIL.send({ to, from: MAIL_FROM, subject, html: emailHtml(heading, lines, note), text: emailText(heading, lines, note) });
  } catch (e) { console.error("email send failed:", e); }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const res = await route(request, env);
    const out = new Response(res.body, res);
    out.headers.set("access-control-allow-origin", allowedOrigin(request.headers.get("Origin")));
    out.headers.append("vary", "Origin");
    return out;
  },
};

async function route(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") return noContent(204);
    const url = new URL(request.url);
    const p = url.pathname, m = request.method;
    try {
      if (env.RL && m === "POST" && RL_PATHS.has(p)) {
        const ip = request.headers.get("CF-Connecting-IP") || "unknown";
        const { success } = await env.RL.limit({ key: `${p}:${ip}` });
        if (!success) return json({ error: "rate_limited" }, 429);
      }
      if (p === "/" || p === "/health") return json({ ok: true, service: "vortx-sync", v: 3 });
      if (p === "/v1/auth/prelogin" && m === "POST") return prelogin(request, env);
      if (p === "/v1/auth/register" && m === "POST") return register(request, env);
      if (p === "/v1/auth/login" && m === "POST") return login(request, env);
      if (p === "/v1/auth/me" && m === "GET") return me(request, env);
      if (p === "/v1/auth/change-username" && m === "POST") return changeUsername(request, env);
      if (p === "/v1/auth/check-username" && m === "POST") return checkUsername(request, env);
      if (p === "/v1/auth/recover-start" && m === "POST") return recoverStart(request, env);
      if (p === "/v1/auth/recover-complete" && m === "POST") return recoverComplete(request, env);
      if (p === "/v1/auth/change-password" && m === "POST") return changePassword(request, env);
      if (p === "/v1/auth/2fa/enroll" && m === "POST") return twofaEnroll(request, env);
      if (p === "/v1/auth/2fa/activate" && m === "POST") return twofaActivate(request, env);
      if (p === "/v1/auth/2fa/disable" && m === "POST") return twofaDisable(request, env);
      if (p === "/v1/connect/stremio" && m === "POST") return connectStremio(request, env);
      if (p === "/v1/addon/manifest" && m === "POST") return addonManifest(request, env);
      if (p === "/v1/qr/start" && m === "POST") return qrStart(request, env);
      if (p === "/v1/qr/authorize" && m === "POST") return qrAuthorize(request, env);
      if (p === "/v1/qr/status" && m === "GET") return qrStatus(url, env);
      if (p === "/v1/backup" && m === "PUT") return backupPut(request, env);
      if (p === "/v1/backup" && m === "GET") return backupGet(request, env);
      return noContent(404);
    } catch (err) {
      console.error("unhandled", err);
      return json({ error: "internal" }, 500);
    }
}

// Non-revealing salt for unknown logins, so prelogin can't enumerate accounts.
async function decoySalt(login: string, env: Env): Promise<string> {
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(env.SESSION_SECRET), enc("salt:" + login)));
  return b64(mac.slice(0, 16));
}

async function prelogin(req: Request, env: Env): Promise<Response> {
  const b = await readJSON(req);
  const loginId = isStr(b?.login, 254) ? (b!.login as string).trim().toLowerCase() : "";
  if (!loginId) return json({ error: "bad_request" }, 400);
  const row = await env.DB.prepare("SELECT kdf_salt, kdf_iters FROM accounts WHERE email = ? OR username = ?")
    .bind(loginId, loginId).first<{ kdf_salt: string; kdf_iters: number }>();
  if (row) return json({ kdfSalt: row.kdf_salt, kdfIters: row.kdf_iters });
  return json({ kdfSalt: await decoySalt(loginId, env), kdfIters: DEFAULT_KDF_ITERS });
}

async function register(req: Request, env: Env): Promise<Response> {
  const b = await readJSON(req);
  const email = isStr(b?.email, 254) ? (b!.email as string).trim().toLowerCase() : "";
  const username = isStr(b?.username, 20) ? (b!.username as string).trim() : "";
  const kdfSalt = isStr(b?.kdfSalt) ? (b!.kdfSalt as string) : "";
  const kdfIters = typeof b?.kdfIters === "number" ? b!.kdfIters as number : 0;
  const authVerifier = isStr(b?.authVerifier) ? (b!.authVerifier as string) : "";
  const wrappedKeyPw = isStr(b?.wrappedKeyPassword) ? (b!.wrappedKeyPassword as string) : "";
  const wrappedKeyRec = isStr(b?.wrappedKeyRecovery) ? (b!.wrappedKeyRecovery as string) : "";
  const recVerifier = isStr(b?.recVerifier) ? (b!.recVerifier as string) : "";
  if (!EMAIL_RE.test(email)) return json({ error: "invalid_email" }, 400);
  if (!USERNAME_RE.test(username)) return json({ error: "invalid_username" }, 400);
  // Validate the crypto fields decode to the expected sizes, so a buggy client can't weaken the account (L-5).
  if (b64Len(kdfSalt) < 16 || kdfIters < 100_000 || b64Len(authVerifier) !== 32 || !wrappedKeyPw) return json({ error: "bad_request" }, 400);

  const unameLower = username.toLowerCase();
  const clash = await env.DB.prepare("SELECT email, username FROM accounts WHERE email = ? OR username = ?")
    .bind(email, unameLower).first<{ email: string; username: string }>();
  if (clash) return json({ error: clash.email === email ? "email_taken" : "username_taken" }, 409);

  const authSalt = crypto.getRandomValues(new Uint8Array(16));
  const recSalt = crypto.getRandomValues(new Uint8Array(16));
  const id = crypto.randomUUID();
  await env.DB.prepare(
    `INSERT INTO accounts (id, email, username, username_display, username_changed_at, kdf_salt, kdf_iters,
       auth_salt, auth_hash, rec_verifier_hash, rec_verifier_salt, wrapped_key_pw, wrapped_key_rec, created_at)
     VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
  ).bind(
    id, email, unameLower, username, 0, kdfSalt, Math.trunc(kdfIters),
    b64(authSalt), await pbkdf2(authVerifier, authSalt, SERVER_ITERS),
    recVerifier ? await pbkdf2(recVerifier, recSalt, SERVER_ITERS) : null, recVerifier ? b64(recSalt) : null,
    wrappedKeyPw, wrappedKeyRec || null, Date.now(),
  ).run();

  await sendMail(env, email, "Welcome to VortX", `Welcome, @${username}.`, [
    "Your VortX account is ready. Your profiles, library, add-ons, and settings can now sync across every device, end to end encrypted.",
    "Your password is the key that unlocks your data on each device, so keep it somewhere safe.",
  ], "Save your recovery code somewhere safe and offline. If you forget your password and have no device signed in, it is the only way back, and we cannot reset it for you.");

  return json({ token: await makeSession(id, env), account: { id, email, username } });
}

async function login(req: Request, env: Env): Promise<Response> {
  const b = await readJSON(req);
  const loginId = isStr(b?.login, 254) ? (b!.login as string).trim().toLowerCase() : "";
  const authVerifier = isStr(b?.authVerifier) ? (b!.authVerifier as string) : "";
  if (!loginId || !authVerifier) return json({ error: "bad_request" }, 400);
  const row = await env.DB.prepare(
    "SELECT id, email, username_display, auth_salt, auth_hash, wrapped_key_pw, kdf_salt, kdf_iters, totp_secret, session_version FROM accounts WHERE email = ? OR username = ?",
  ).bind(loginId, loginId).first<any>();
  const salt = row ? unb64(row.auth_salt) : new Uint8Array(16);
  const computed = await pbkdf2(authVerifier, salt, SERVER_ITERS);
  if (!row || !ctEqual(computed, row.auth_hash)) return json({ error: "invalid_credentials" }, 401);
  if (row.totp_secret) {
    const totp = isStr(b?.totp, 8) ? (b!.totp as string).trim() : "";
    if (!totp) return json({ error: "totp_required" }, 401);
    if (!(await verifyTotp(row.totp_secret, totp))) return json({ error: "invalid_totp" }, 401);
  }
  return json({
    token: await makeSession(row.id, env, row.session_version ?? 0),
    account: pub(row),
    wrappedKeyPassword: row.wrapped_key_pw,
    kdfSalt: row.kdf_salt,
    kdfIters: row.kdf_iters,
  });
}

async function me(req: Request, env: Env): Promise<Response> {
  const id = await requireAuth(req, env);
  if (!id) return json({ error: "unauthorized" }, 401);
  const row = await env.DB.prepare("SELECT id, email, username_display, username_changed_at, totp_secret FROM accounts WHERE id = ?")
    .bind(id).first<any>();
  if (!row) return json({ error: "unauthorized" }, 401);
  return json({ account: { ...pub(row), twoFactorEnabled: !!row.totp_secret } });
}

async function checkUsername(req: Request, env: Env): Promise<Response> {
  const b = await readJSON(req);
  const username = isStr(b?.username, 20) ? (b!.username as string).trim() : "";
  if (!USERNAME_RE.test(username)) return json({ available: false, reason: "invalid" });
  const taken = await env.DB.prepare("SELECT 1 FROM accounts WHERE username = ?").bind(username.toLowerCase()).first();
  return json({ available: !taken });
}

async function changeUsername(req: Request, env: Env): Promise<Response> {
  const id = await requireAuth(req, env);
  if (!id) return json({ error: "unauthorized" }, 401);
  const b = await readJSON(req);
  const username = isStr(b?.username, 20) ? (b!.username as string).trim() : "";
  if (!USERNAME_RE.test(username)) return json({ error: "invalid_username" }, 400);
  const acct = await env.DB.prepare("SELECT username, username_changed_at, created_at FROM accounts WHERE id = ?")
    .bind(id).first<{ username: string; username_changed_at: number; created_at: number }>();
  if (!acct) return json({ error: "unauthorized" }, 401);
  // The first change is always allowed (changed_at == 0); the 3-month cooldown applies only between changes.
  const changing = acct.username.toLowerCase() !== username.toLowerCase();
  if (changing && acct.username_changed_at > 0 && Date.now() - acct.username_changed_at < USERNAME_COOLDOWN_MS) {
    const days = Math.ceil((USERNAME_COOLDOWN_MS - (Date.now() - acct.username_changed_at)) / 86400000);
    return json({ error: "cooldown", daysLeft: days }, 429);
  }
  const taken = await env.DB.prepare("SELECT 1 FROM accounts WHERE username = ? AND id != ?")
    .bind(username.toLowerCase(), id).first();
  if (taken) return json({ error: "username_taken" }, 409);
  await env.DB.prepare("UPDATE accounts SET username = ?, username_display = ?, username_changed_at = ? WHERE id = ?")
    .bind(username.toLowerCase(), username, Date.now(), id).run();
  return json({ ok: true, username });
}

async function recoverStart(req: Request, env: Env): Promise<Response> {
  const b = await readJSON(req);
  const email = isStr(b?.email, 254) ? (b!.email as string).trim().toLowerCase() : "";
  if (!EMAIL_RE.test(email)) return json({ error: "bad_request" }, 400);
  const row = await env.DB.prepare("SELECT kdf_salt, kdf_iters, wrapped_key_rec, rec_verifier_hash FROM accounts WHERE email = ?")
    .bind(email).first<any>();
  if (!row || !row.wrapped_key_rec || !row.rec_verifier_hash) {
    return json({ kdfSalt: await decoySalt(email, env), kdfIters: DEFAULT_KDF_ITERS, wrappedKeyRecovery: null });
  }
  return json({ kdfSalt: row.kdf_salt, kdfIters: row.kdf_iters, wrappedKeyRecovery: row.wrapped_key_rec });
}

async function recoverComplete(req: Request, env: Env): Promise<Response> {
  const b = await readJSON(req);
  const email = isStr(b?.email, 254) ? (b!.email as string).trim().toLowerCase() : "";
  const recVerifier = isStr(b?.recVerifier) ? (b!.recVerifier as string) : "";
  const newAuthVerifier = isStr(b?.newAuthVerifier) ? (b!.newAuthVerifier as string) : "";
  const newWrappedKeyPw = isStr(b?.newWrappedKeyPassword) ? (b!.newWrappedKeyPassword as string) : "";
  // kdf_salt is NOT rotated: it also derives the recovery key, so rotating it would orphan wrapped_key_rec (M-4).
  if (!EMAIL_RE.test(email) || !recVerifier || b64Len(newAuthVerifier) !== 32 || !newWrappedKeyPw) {
    return json({ error: "bad_request" }, 400);
  }
  const row = await env.DB.prepare("SELECT id, email, username_display, rec_verifier_salt, rec_verifier_hash FROM accounts WHERE email = ?")
    .bind(email).first<any>();
  if (!row || !row.rec_verifier_hash) return json({ error: "invalid_recovery" }, 401);
  const computed = await pbkdf2(recVerifier, unb64(row.rec_verifier_salt), SERVER_ITERS);
  if (!ctEqual(computed, row.rec_verifier_hash)) return json({ error: "invalid_recovery" }, 401);
  const authSalt = crypto.getRandomValues(new Uint8Array(16));
  // Recovery clears 2FA (a lost authenticator can't lock the user out; the recovery code is the strong factor)
  // and bumps session_version, invalidating any token an attacker may hold (H-1).
  await env.DB.prepare("UPDATE accounts SET auth_salt = ?, auth_hash = ?, wrapped_key_pw = ?, totp_secret = NULL, totp_pending = NULL, session_version = session_version + 1 WHERE id = ?")
    .bind(b64(authSalt), await pbkdf2(newAuthVerifier, authSalt, SERVER_ITERS), newWrappedKeyPw, row.id).run();
  await sendMail(env, row.email, "Your VortX password was reset", "Your password was reset with your recovery code", [
    "Your VortX password was just reset using your recovery code, and you were signed out everywhere else.",
    "Two-factor authentication was turned off as part of recovery. If you use it, re-enable it from your dashboard.",
    "If this was not you, reset your password again immediately.",
  ]);
  return json({ token: await makeSession(row.id, env, await accountSessionVersion(row.id, env)), account: pub(row) });
}

// --- Change password (logged in): client re-derives the key from the new password and re-wraps the data key ---
async function changePassword(req: Request, env: Env): Promise<Response> {
  const id = await requireAuth(req, env);
  if (!id) return json({ error: "unauthorized" }, 401);
  const b = await readJSON(req);
  const oldAuthVerifier = isStr(b?.oldAuthVerifier) ? (b!.oldAuthVerifier as string) : "";
  const newAuthVerifier = isStr(b?.newAuthVerifier) ? (b!.newAuthVerifier as string) : "";
  const newWrappedKeyPw = isStr(b?.newWrappedKeyPassword) ? (b!.newWrappedKeyPassword as string) : "";
  // kdf_salt is kept (it also derives the recovery key); the new master key is derived from the SAME salt (M-4).
  if (!oldAuthVerifier || b64Len(newAuthVerifier) !== 32 || !newWrappedKeyPw) return json({ error: "bad_request" }, 400);
  const row = await env.DB.prepare("SELECT email, auth_salt, auth_hash FROM accounts WHERE id = ?").bind(id).first<any>();
  if (!row) return json({ error: "unauthorized" }, 401);
  if (!ctEqual(await pbkdf2(oldAuthVerifier, unb64(row.auth_salt), SERVER_ITERS), row.auth_hash)) return json({ error: "invalid_credentials" }, 401);
  const authSalt = crypto.getRandomValues(new Uint8Array(16));
  // Bump session_version to revoke other sessions (H-1), then hand back a fresh token for THIS device.
  await env.DB.prepare("UPDATE accounts SET auth_salt = ?, auth_hash = ?, wrapped_key_pw = ?, session_version = session_version + 1 WHERE id = ?")
    .bind(b64(authSalt), await pbkdf2(newAuthVerifier, authSalt, SERVER_ITERS), newWrappedKeyPw, id).run();
  await sendMail(env, row.email, "Your VortX password was changed", "Your password was changed", [
    "The password on your VortX account was just changed, and other signed-in sessions were signed out.",
    "If this was you, no action is needed. If it was not you, recover your account now with your recovery code and set a new password.",
  ]);
  return json({ token: await makeSession(id, env, await accountSessionVersion(id, env)) });
}

// --- 2FA (TOTP, RFC 6238: SHA-1, 6 digits, 30s window) ---
function base32Encode(bytes: Uint8Array): string {
  const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = 0, value = 0, out = "";
  for (const b of bytes) { value = (value << 8) | b; bits += 8; while (bits >= 5) { out += A[(value >>> (bits - 5)) & 31]; bits -= 5; } }
  if (bits > 0) out += A[(value << (5 - bits)) & 31];
  return out;
}
function base32Decode(s: string): Uint8Array {
  const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  const clean = s.toUpperCase().replace(/[^A-Z2-7]/g, "");
  let bits = 0, value = 0; const out: number[] = [];
  for (const ch of clean) { value = (value << 5) | A.indexOf(ch); bits += 5; if (bits >= 8) { out.push((value >>> (bits - 8)) & 0xff); bits -= 8; } }
  return new Uint8Array(out);
}
async function hotp(secretB32: string, counter: number): Promise<string> {
  const buf = new ArrayBuffer(8);
  const view = new DataView(buf);
  view.setUint32(0, Math.floor(counter / 0x100000000));
  view.setUint32(4, counter >>> 0);
  const key = await crypto.subtle.importKey("raw", base32Decode(secretB32) as BufferSource, { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, buf));
  const off = mac[mac.length - 1] & 0x0f;
  const bin = ((mac[off] & 0x7f) << 24) | (mac[off + 1] << 16) | (mac[off + 2] << 8) | mac[off + 3];
  return (bin % 1_000_000).toString().padStart(6, "0");
}
async function verifyTotp(secretB32: string, code: string): Promise<boolean> {
  if (!/^\d{6}$/.test(code)) return false;
  const step = Math.floor(Date.now() / 30000);
  for (const w of [-1, 0, 1]) if (ctEqual(await hotp(secretB32, step + w), code)) return true;
  return false;
}

async function twofaEnroll(req: Request, env: Env): Promise<Response> {
  const id = await requireAuth(req, env);
  if (!id) return json({ error: "unauthorized" }, 401);
  const row = await env.DB.prepare("SELECT email, totp_secret FROM accounts WHERE id = ?").bind(id).first<any>();
  if (!row) return json({ error: "unauthorized" }, 401);
  if (row.totp_secret) return json({ error: "already_enabled" }, 409);
  const secret = base32Encode(crypto.getRandomValues(new Uint8Array(20)));
  await env.DB.prepare("UPDATE accounts SET totp_pending = ? WHERE id = ?").bind(secret, id).run();
  const uri = `otpauth://totp/VortX:${encodeURIComponent(row.email)}?secret=${secret}&issuer=VortX&algorithm=SHA1&digits=6&period=30`;
  return json({ secret, otpauth: uri });
}
async function twofaActivate(req: Request, env: Env): Promise<Response> {
  const id = await requireAuth(req, env);
  if (!id) return json({ error: "unauthorized" }, 401);
  const b = await readJSON(req);
  const code = isStr(b?.code, 8) ? (b!.code as string).trim() : "";
  const row = await env.DB.prepare("SELECT email, totp_pending FROM accounts WHERE id = ?").bind(id).first<any>();
  if (!row?.totp_pending) return json({ error: "no_pending" }, 400);
  if (!(await verifyTotp(row.totp_pending, code))) return json({ error: "invalid_code" }, 401);
  await env.DB.prepare("UPDATE accounts SET totp_secret = totp_pending, totp_pending = NULL WHERE id = ?").bind(id).run();
  await sendMail(env, row.email, "Two-factor is on for your VortX account", "Two-factor authentication enabled", [
    "An authenticator app was just added to your VortX account. You will need a code from it the next time you sign in.",
    "If this was not you, disable it and change your password right away.",
  ]);
  return json({ ok: true });
}
async function twofaDisable(req: Request, env: Env): Promise<Response> {
  const id = await requireAuth(req, env);
  if (!id) return json({ error: "unauthorized" }, 401);
  const b = await readJSON(req);
  const code = isStr(b?.code, 8) ? (b!.code as string).trim() : "";
  const row = await env.DB.prepare("SELECT email, totp_secret FROM accounts WHERE id = ?").bind(id).first<any>();
  if (!row?.totp_secret) return json({ error: "not_enabled" }, 400);
  if (!(await verifyTotp(row.totp_secret, code))) return json({ error: "invalid_code" }, 401);
  await env.DB.prepare("UPDATE accounts SET totp_secret = NULL, totp_pending = NULL WHERE id = ?").bind(id).run();
  await sendMail(env, row.email, "Two-factor is off for your VortX account", "Two-factor authentication disabled", [
    "Two-factor authentication was just turned off for your VortX account.",
    "If this was not you, turn it back on and change your password right away.",
  ]);
  return json({ ok: true });
}

// --- Connect Stremio: proxy api.strem.io to pull the user's add-ons + library (browser CORS blocks
// it directly). The Stremio password is used ONCE to get an authKey and is never stored or logged.
// Requires a VortX session (Bearer), so only a signed-in VortX user can call it. The dashboard then
// encrypts the returned data into the user's E2E sync document.
async function connectStremio(req: Request, env: Env): Promise<Response> {
  const accountId = await requireAuth(req, env);
  if (!accountId) return json({ error: "unauthorized" }, 401);
  const b = await readJSON(req);
  const email = isStr(b?.email, 254) ? (b!.email as string).trim() : "";
  const password = isStr(b?.password, 200) ? (b!.password as string) : "";
  if (!email || !password) return json({ error: "bad_request" }, 400);

  const SAPI = "https://api.strem.io/api";
  const sjson = (path: string, body: unknown) =>
    fetch(`${SAPI}/${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) })
      .then((r) => r.json().catch(() => null));

  const login: any = await sjson("login", { email, password });
  const authKey: string | undefined = login?.result?.authKey;
  if (!authKey) {
    return json({ error: login?.error?.wrongEmail ? "no_such_stremio_account" : "wrong_credentials" }, 401);
  }

  const [addonsJson, libJson]: any[] = await Promise.all([
    sjson("addonCollectionGet", { authKey, update: true }),
    sjson("datastoreGet", { authKey, collection: "libraryItem", all: true }),
  ]);
  const addons = (addonsJson?.result?.addons ?? [])
    .map((a: any) => ({ transportUrl: a.transportUrl, name: a.manifest?.name, types: a.manifest?.types }))
    .filter((a: any) => a.transportUrl);
  const library = (Array.isArray(libJson?.result) ? libJson.result : [])
    .filter((it: any) => it && !it.removed && it._id)
    .map((it: any) => ({
      id: it._id, name: it.name, type: it.type, poster: it.poster,
      t: it.state?.timeOffset ?? 0, d: it.state?.duration ?? 0, // for Continue Watching on the dashboard
    }));
  // authKey is intentionally NOT returned or stored; this is a one-time import.
  return json({ ok: true, email, addons, library });
}

// --- Add-on manifest proxy: the dashboard's add-on manager pastes a manifest URL; the browser
// cannot fetch it directly (the site CSP locks connect-src to api.vortx.tv, and add-on hosts vary
// on CORS). The Worker fetches and validates it. Requires a VortX session, is rate-limited, and
// refuses private / loopback hosts (basic SSRF guard) since it makes an outbound request on the
// caller's behalf. It returns only parsed manifest fields, never the raw response. ---
const PRIVATE_HOST_RE = /^(localhost|0\.0\.0\.0|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|\[?::1\]?|.*\.local|.*\.internal)$/i;
function normalizeManifestUrl(raw: string): string | null {
  let u = raw.trim();
  if (!u) return null;
  u = u.replace(/^stremio:\/\//i, "https://");
  if (!/^https?:\/\//i.test(u)) u = "https://" + u;
  let url: URL;
  try { url = new URL(u); } catch { return null; }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  if (PRIVATE_HOST_RE.test(url.hostname)) return null;
  if (!/\/manifest\.json$/i.test(url.pathname)) url.pathname = url.pathname.replace(/\/+$/, "") + "/manifest.json";
  url.hash = "";
  return url.toString();
}
async function addonManifest(req: Request, env: Env): Promise<Response> {
  const accountId = await requireAuth(req, env);
  if (!accountId) return json({ error: "unauthorized" }, 401);
  const b = await readJSON(req);
  const transportUrl = normalizeManifestUrl(isStr(b?.url, 2048) ? (b!.url as string) : "");
  if (!transportUrl) return json({ error: "invalid_url" }, 400);

  let res: Response;
  try {
    res = await fetch(transportUrl, { headers: { accept: "application/json" }, redirect: "follow", signal: AbortSignal.timeout(8000) });
  } catch { return json({ error: "unreachable" }, 502); }
  if (!res.ok) return json({ error: "not_a_manifest", status: res.status }, 502);
  let mf: any;
  try { mf = await res.json(); } catch { return json({ error: "not_a_manifest" }, 502); }
  if (!mf || typeof mf !== "object" || !mf.id || (!mf.name && !Array.isArray(mf.types))) return json({ error: "not_a_manifest" }, 502);

  const str = (v: unknown, max: number) => (typeof v === "string" ? v.slice(0, max) : undefined);
  return json({
    addon: {
      transportUrl,
      name: str(mf.name, 120) ?? transportUrl,
      types: Array.isArray(mf.types) ? mf.types.slice(0, 12).map((t: unknown) => String(t)) : [],
      version: str(mf.version, 24),
      description: str(mf.description, 300),
      logo: typeof mf.logo === "string" && /^https:\/\//i.test(mf.logo) ? mf.logo : undefined,
      configurable: !!(mf.behaviorHints && (mf.behaviorHints.configurable || mf.behaviorHints.configurationRequired)),
    },
  });
}

// --- QR login (data key handed to the joining device, wrapped to its ephemeral X25519 key) ---
function code8(): string {
  const a = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const buf = crypto.getRandomValues(new Uint8Array(8));
  let out = "";
  for (const x of buf) out += a[x % a.length];
  return out;
}
async function qrStart(req: Request, env: Env): Promise<Response> {
  const b = await readJSON(req);
  const devicePublicKey = isStr(b?.devicePublicKey) ? (b!.devicePublicKey as string) : "";
  if (!devicePublicKey) return json({ error: "bad_request" }, 400);
  const pairingID = crypto.randomUUID(), code = code8(), now = Date.now();
  await env.DB.prepare("INSERT INTO pairings (pairing_id, code, device_pubkey, expires_at, created_at) VALUES (?,?,?,?,?)")
    .bind(pairingID, code, devicePublicKey, now + PAIR_TTL_MS, now).run();
  return json({ pairingID, code, devicePublicKey, expiresAt: now + PAIR_TTL_MS });
}
async function qrAuthorize(req: Request, env: Env): Promise<Response> {
  const accountId = await requireAuth(req, env);
  if (!accountId) return json({ error: "unauthorized" }, 401);
  const b = await readJSON(req);
  const code = isStr(b?.code, 16) ? (b!.code as string).trim().toUpperCase() : "";
  const wrappedPayload = isStr(b?.wrappedPayload) ? (b!.wrappedPayload as string) : "";
  if (!code || !wrappedPayload) return json({ error: "bad_request" }, 400);
  const row = await env.DB.prepare("SELECT pairing_id, expires_at FROM pairings WHERE code = ? AND account_id IS NULL")
    .bind(code).first<{ pairing_id: string; expires_at: number }>();
  if (!row) return noContent(404);
  if (row.expires_at < Date.now()) return noContent(410);
  const sv = await accountSessionVersion(accountId, env);
  await env.DB.prepare("UPDATE pairings SET account_id = ?, session = ?, payload = ? WHERE pairing_id = ?")
    .bind(accountId, await makeSession(accountId, env, sv), wrappedPayload, row.pairing_id).run();
  return noContent(200);
}
async function qrStatus(url: URL, env: Env): Promise<Response> {
  const id = url.searchParams.get("id");
  if (!isStr(id)) return json({ error: "bad_request" }, 400);
  const row = await env.DB.prepare("SELECT session, payload, expires_at FROM pairings WHERE pairing_id = ?")
    .bind(id).first<{ session: string | null; payload: string | null; expires_at: number }>();
  if (!row) return noContent(404);
  if (row.expires_at < Date.now()) return noContent(410);
  if (!row.session) return json({ pending: true });
  await env.DB.prepare("DELETE FROM pairings WHERE pairing_id = ?").bind(id).run();
  return json({ token: row.session, payload: row.payload });
}

// --- sync document (ciphertext only; the server cannot read it) ---
async function backupPut(req: Request, env: Env): Promise<Response> {
  const id = await requireAuth(req, env);
  if (!id) return json({ error: "unauthorized" }, 401);
  const b = await readJSON(req);
  const document = isStr(b?.document, MAX_DOC) ? (b!.document as string) : "";
  const version = b?.version;
  if (!document || typeof version !== "number" || !Number.isFinite(version)) return json({ error: "bad_request" }, 400);
  const res = await env.DB.prepare(
    `INSERT INTO backups (account_id, document, version, updated_at) VALUES (?1,?2,?3,?4)
     ON CONFLICT(account_id) DO UPDATE SET document = excluded.document, version = excluded.version, updated_at = excluded.updated_at
     WHERE excluded.version > backups.version`,
  ).bind(id, document, Math.trunc(version), Date.now()).run();
  // accepted=false means a newer version already won (last-writer-wins); the client should re-fetch and merge (M-5).
  return json({ ok: true, accepted: (res.meta?.changes ?? 1) > 0 });
}
async function backupGet(req: Request, env: Env): Promise<Response> {
  const id = await requireAuth(req, env);
  if (!id) return json({ error: "unauthorized" }, 401);
  const row = await env.DB.prepare("SELECT document, version FROM backups WHERE account_id = ?")
    .bind(id).first<{ document: string; version: number }>();
  if (!row) return noContent(404);
  return json({ document: row.document, version: row.version });
}
