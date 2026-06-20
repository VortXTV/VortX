// Verifies change-password + 2FA (TOTP) against the live Worker. Run: TS=$(date +%s) node e2e-2fa-test.mjs
import { webcrypto as wc } from "node:crypto";
import crypto from "node:crypto";
const subtle = wc.subtle;
const API = "https://api.vortx.tv";
const te = new TextEncoder();
const enc = (s) => te.encode(s);
const b64 = (u8) => Buffer.from(u8).toString("base64");
const unb64 = (s) => new Uint8Array(Buffer.from(s, "base64"));
// Throwaway, policy-meeting test passwords generated per run (no hardcoded secret). Zero-knowledge service:
// it only sees PBKDF2 verifiers + AES-wrapped keys, never the plaintext.
const randPw = () => "Aa1!" + b64(wc.getRandomValues(new Uint8Array(24))).replace(/[^A-Za-z0-9]/g, "").slice(0, 16);
let pass = 0, fail = 0;
const ok = (c, m) => { (c ? pass++ : fail++); console.log("  " + (c ? "PASS" : "FAIL"), m); };

async function pbkdf2(ikm, salt, iters) {
  const km = await subtle.importKey("raw", ikm, "PBKDF2", false, ["deriveBits"]);
  return new Uint8Array(await subtle.deriveBits({ name: "PBKDF2", salt, iterations: iters, hash: "SHA-256" }, km, 256));
}
async function seal(key, pt) {
  const k = await subtle.importKey("raw", key, "AES-GCM", false, ["encrypt"]);
  const iv = wc.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv }, k, pt));
  const o = new Uint8Array(12 + ct.length); o.set(iv, 0); o.set(ct, 12); return b64(o);
}
async function open(key, s) {
  const c = unb64(s); const k = await subtle.importKey("raw", key, "AES-GCM", false, ["decrypt"]);
  return new Uint8Array(await subtle.decrypt({ name: "AES-GCM", iv: c.subarray(0, 12) }, k, c.subarray(12)));
}
const eq = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
async function post(path, body, token) {
  const h = { "content-type": "application/json" }; if (token) h.authorization = "Bearer " + token;
  const r = await fetch(API + path, { method: "POST", headers: h, body: JSON.stringify(body) });
  return { status: r.status, json: r.status !== 204 && r.headers.get("content-type")?.includes("json") ? await r.json() : null };
}
// Node TOTP mirroring the Worker (RFC 6238, SHA-1, 6 digits, 30s)
function base32Decode(s) { const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"; s = s.toUpperCase().replace(/[^A-Z2-7]/g, ""); let bits = 0, v = 0; const o = []; for (const c of s) { v = (v << 5) | A.indexOf(c); bits += 5; if (bits >= 8) { o.push((v >>> (bits - 8)) & 0xff); bits -= 8; } } return Buffer.from(o); }
function totp(secret) { const ctr = Math.floor(Date.now() / 30000); const buf = Buffer.alloc(8); buf.writeUInt32BE(Math.floor(ctr / 2 ** 32), 0); buf.writeUInt32BE(ctr >>> 0, 4); const mac = crypto.createHmac("sha1", base32Decode(secret)).update(buf).digest(); const off = mac[mac.length - 1] & 0x0f; const bin = ((mac[off] & 0x7f) << 24) | (mac[off + 1] << 16) | (mac[off + 2] << 8) | mac[off + 3]; return (bin % 1000000).toString().padStart(6, "0"); }

const ITERS = 210000;
const email = `f${process.env.TS}@vortx.tv`, username = `f${process.env.TS}`.slice(0, 18);
const firstPw = process.env.E2E_PASSWORD || randPw();
let pw = firstPw;

async function authVerifier(mk, p) { return b64(await pbkdf2(mk, enc(p), 1)); }

// register
let salt = wc.getRandomValues(new Uint8Array(16));
let mk = await pbkdf2(enc(pw), salt, ITERS);
const dataKey = wc.getRandomValues(new Uint8Array(32));
let r = await post("/v1/auth/register", { email, username, kdfSalt: b64(salt), kdfIters: ITERS, authVerifier: await authVerifier(mk, pw), wrappedKeyPassword: await seal(mk, dataKey), wrappedKeyRecovery: await seal(await pbkdf2(enc("REC"), salt, ITERS), dataKey), recVerifier: b64(await pbkdf2(await pbkdf2(enc("REC"), salt, ITERS), enc("REC"), 1)) });
let token = r.json?.token; ok(r.status === 200 && token, "register");

console.log("CHANGE PASSWORD");
const newPw = randPw();
const nMk = await pbkdf2(enc(newPw), salt, ITERS); // M-4: new master key uses the SAME kdfSalt
r = await post("/v1/auth/change-password", { oldAuthVerifier: await authVerifier(mk, pw), newAuthVerifier: await authVerifier(nMk, newPw), newWrappedKeyPassword: await seal(nMk, dataKey) }, token);
ok(r.status === 200 && r.json?.token, `change-password -> 200 + fresh token (${r.status})`);
const revokedToken = token;
token = r.json.token; // H-1: the old token is now revoked; adopt the rotated one
// H-1: the old token no longer works
r = await (async () => { const x = await fetch(API + "/v1/auth/me", { headers: { authorization: "Bearer " + revokedToken } }); return { status: x.status }; })();
ok(r.status === 401, `old token revoked after password change -> 401 (${r.status})`);
// wrong old verifier rejected (using the valid new token)
r = await post("/v1/auth/change-password", { oldAuthVerifier: "wrong", newAuthVerifier: await authVerifier(nMk, newPw), newWrappedKeyPassword: await seal(nMk, dataKey) }, token);
ok(r.status === 401, `change-password wrong old -> 401 (${r.status})`);
// login with NEW password recovers same dataKey; OLD fails
let pre = (await post("/v1/auth/prelogin", { login: email })).json;
let lmk = await pbkdf2(enc(newPw), unb64(pre.kdfSalt), pre.kdfIters);
r = await post("/v1/auth/login", { login: email, authVerifier: await authVerifier(lmk, newPw) });
const dk = r.json?.wrappedKeyPassword ? await open(lmk, r.json.wrappedKeyPassword) : null;
ok(r.status === 200 && dk && eq(dk, dataKey), "login with NEW password + same dataKey");
token = r.json.token; pw = newPw; mk = lmk;
r = await post("/v1/auth/login", { login: email, authVerifier: await authVerifier(await pbkdf2(enc(firstPw), unb64(pre.kdfSalt), pre.kdfIters), firstPw) });
ok(r.status === 401, "login with OLD password -> 401");

console.log("2FA (TOTP)");
r = await post("/v1/auth/2fa/enroll", {}, token);
const secret = r.json?.secret;
ok(r.status === 200 && secret && r.json.otpauth?.startsWith("otpauth://totp/VortX:"), "enroll -> secret + otpauth uri");
r = await post("/v1/auth/2fa/activate", { code: "000000" }, token);
ok(r.status === 401, "activate wrong code -> 401");
r = await post("/v1/auth/2fa/activate", { code: totp(secret) }, token);
ok(r.status === 200, `activate correct code -> 200 (${r.status})`);
// login now requires totp
pre = (await post("/v1/auth/prelogin", { login: email })).json;
lmk = await pbkdf2(enc(pw), unb64(pre.kdfSalt), pre.kdfIters);
r = await post("/v1/auth/login", { login: email, authVerifier: await authVerifier(lmk, pw) });
ok(r.status === 401 && r.json?.error === "totp_required", "login without totp -> totp_required");
r = await post("/v1/auth/login", { login: email, authVerifier: await authVerifier(lmk, pw), totp: "000000" });
ok(r.status === 401, "login wrong totp -> 401");
r = await post("/v1/auth/login", { login: email, authVerifier: await authVerifier(lmk, pw), totp: totp(secret) });
ok(r.status === 200 && r.json?.token, "login with correct totp -> 200");
token = r.json.token;
// me reports twoFactorEnabled
r = await (async () => { const x = await fetch(API + "/v1/auth/me", { headers: { authorization: "Bearer " + token } }); return { status: x.status, json: await x.json() }; })();
ok(r.json?.account?.twoFactorEnabled === true, "me reports twoFactorEnabled=true");
// disable
r = await post("/v1/auth/2fa/disable", { code: totp(secret) }, token);
ok(r.status === 200, "disable 2FA -> 200");
r = await post("/v1/auth/login", { login: email, authVerifier: await authVerifier(lmk, pw) });
ok(r.status === 200, "login after disable (no totp) -> 200");

console.log(`\nRESULT: ${pass} passed, ${fail} failed`);
console.log("CLEANUP_EMAIL " + email);
