// E2E for the email-code password reset flow (/v1/auth/reset/start + /v1/auth/reset/complete).
//
// This reset is the "lost BOTH password AND recovery code" path: it can only restore ACCESS, never the
// old encrypted data. Completing it mints a FRESH, empty vault and deletes the old backup. The 6-digit
// code lives ONLY in the reset email, so an automated test cannot read it against production. This test
// therefore runs against a LOCAL wrangler dev with the env-gated test seam ALLOW_TEST_RESET_CODE=1, which
// makes reset/start echo the freshly minted code as { ok: true, _code }. The prod env never sets that var.
//
// HOW TO RUN (two terminals):
//   Terminal A (start a local Worker + local D1, with the test seam + a dev SESSION_SECRET):
//     cd cloudflare
//     printf 'SESSION_SECRET="dev-secret-not-for-prod"\nALLOW_TEST_RESET_CODE="1"\n' > .dev.vars   # gitignored
//     npx wrangler d1 execute vortx-sync --local --file=./schema.sql   # create the local tables once
//     ALLOW_TEST_RESET_CODE=1 npx wrangler dev --local
//   Terminal B (run this test against the local Worker):
//     node e2e-reset-test.mjs
//
//   BASE defaults to http://127.0.0.1:8787 (wrangler dev's default) and is overridable:
//     BASE=http://127.0.0.1:8788 node e2e-reset-test.mjs
//
// Note: the happy-path assertions (read _code, complete with the right code) REQUIRE the local-dev seam,
// because the reset code is email-only. Without ALLOW_TEST_RESET_CODE=1 the start response omits _code and
// the happy path is skipped (the non-enumeration and lockout assertions still run).

import { webcrypto as wc } from "node:crypto";
const subtle = wc.subtle;
const BASE = process.env.BASE || "http://127.0.0.1:8787";
const te = new TextEncoder();
const enc = (s) => te.encode(s);
const b64 = (u8) => Buffer.from(u8).toString("base64");
const unb64 = (s) => new Uint8Array(Buffer.from(s, "base64"));

let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log("  PASS", m); } else { fail++; console.log("  FAIL", m); } };

async function pbkdf2(ikm, salt, iters) {
  const km = await subtle.importKey("raw", ikm, "PBKDF2", false, ["deriveBits"]);
  return new Uint8Array(await subtle.deriveBits({ name: "PBKDF2", salt, iterations: iters, hash: "SHA-256" }, km, 256));
}
async function seal(keyBytes, pt) {
  const k = await subtle.importKey("raw", keyBytes, "AES-GCM", false, ["encrypt"]);
  const iv = wc.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv }, k, pt));
  const out = new Uint8Array(12 + ct.length); out.set(iv, 0); out.set(ct, 12);
  return b64(out);
}
async function post(path, body, token) {
  const h = { "content-type": "application/json" };
  if (token) h.authorization = "Bearer " + token;
  const r = await fetch(BASE + path, { method: "POST", headers: h, body: JSON.stringify(body) });
  return { status: r.status, json: r.status !== 204 && r.headers.get("content-type")?.includes("json") ? await r.json() : null };
}
const authVerifierFor = async (mk, pw) => b64(await pbkdf2(mk, enc(pw), 1));

const ITERS = 210000;
const ts = process.env.TS || Date.now();
const email = `reset+${ts}@vortx.tv`;
const username = `reset${ts}`.slice(0, 20);
const password = "Sup3r-Secret-Pw!";

// --- register a throwaway account (the standard client crypto contract) ---
const kdfSaltBytes = wc.getRandomValues(new Uint8Array(16));
const kdfSalt = b64(kdfSaltBytes);
const masterKey = await pbkdf2(enc(password), kdfSaltBytes, ITERS);
const authVerifier = await authVerifierFor(masterKey, password);
const dataKey = wc.getRandomValues(new Uint8Array(32));
const wrappedKeyPassword = await seal(masterKey, dataKey);
const recoveryCode = b64(wc.getRandomValues(new Uint8Array(16))).replace(/[^a-zA-Z0-9]/g, "").slice(0, 20);
const recoveryKey = await pbkdf2(enc(recoveryCode), kdfSaltBytes, ITERS);
const wrappedKeyRecovery = await seal(recoveryKey, dataKey);
const recVerifier = b64(await pbkdf2(recoveryKey, enc(recoveryCode), 1));

console.log(`BASE ${BASE}`);
console.log("REGISTER");
let r = await post("/v1/auth/register", { email, username, kdfSalt, kdfIters: ITERS, authVerifier, wrappedKeyPassword, wrappedKeyRecovery, recVerifier });
ok(r.status === 200 && r.json?.token, `register -> 200 + token (${r.status})`);
if (r.status !== 200) {
  console.log("  (register failed: is `wrangler dev --local` running with the schema loaded? see header)");
}

// Seed a backup, so we can later assert the reset wiped it (fresh, empty vault).
const ciphertext = await seal(dataKey, enc(JSON.stringify({ v: 1, library: [1, 2, 3] })));
let putBackup = await fetch(BASE + "/v1/backup", {
  method: "PUT",
  headers: { "content-type": "application/json", authorization: "Bearer " + r.json.token },
  body: JSON.stringify({ document: ciphertext, version: Date.now() }),
});
ok(putBackup.status === 200, `seed backup PUT -> 200 (${putBackup.status})`);

console.log("RESET/START non-enumeration");
r = await post("/v1/auth/reset/start", { login: "definitely-not-a-user-" + ts });
ok(r.status === 200 && r.json?.ok === true, `reset/start bogus login -> 200 ok (non-enumeration) (${r.status})`);
ok(r.json?._code === undefined, "reset/start bogus login -> no _code (no reset minted for a non-account)");

r = await post("/v1/auth/reset/start", { login: email });
ok(r.status === 200 && r.json?.ok === true, `reset/start real login -> 200 ok (${r.status})`);
const seam = typeof r.json?._code === "string";
ok(seam, "reset/start real login -> _code present (local test seam ALLOW_TEST_RESET_CODE=1)");
let code = r.json?._code;

// reset/start by username resolves to the same account, and the reissue cooldown means it does NOT mint a
// fresh code (so no _code echoed). This both proves username lookup works and that the cooldown holds.
r = await post("/v1/auth/reset/start", { login: username });
ok(r.status === 200 && r.json?.ok === true, `reset/start by username -> 200 ok (${r.status})`);
ok(r.json?._code === undefined, "reset/start within reissue cooldown -> no fresh code minted");

console.log("RESET/COMPLETE wrong code -> 401, then right code -> 200");
// The new credentials the client mints (fresh vault: new data key, new password key, new recovery).
const newPassword = "Even-Better-Pw2!";
// kdf_salt is NEVER rotated server-side; the new master key reuses the original kdfSaltBytes (M-4).
const newDataKey = wc.getRandomValues(new Uint8Array(32));
const newMasterKey = await pbkdf2(enc(newPassword), kdfSaltBytes, ITERS);
const newAuthVerifier = await authVerifierFor(newMasterKey, newPassword);
const newWrappedKeyPassword = await seal(newMasterKey, newDataKey);
const newRecoveryCode = b64(wc.getRandomValues(new Uint8Array(16))).replace(/[^a-zA-Z0-9]/g, "").slice(0, 20);
const newRecoveryKey = await pbkdf2(enc(newRecoveryCode), kdfSaltBytes, ITERS);
const newWrappedKeyRecovery = await seal(newRecoveryKey, newDataKey);
const newRecVerifier = b64(await pbkdf2(newRecoveryKey, enc(newRecoveryCode), 1));

const wrongCode = code === "000000" ? "111111" : "000000";
r = await post("/v1/auth/reset/complete", { login: email, code: wrongCode, authVerifier: newAuthVerifier, wrappedKeyPassword: newWrappedKeyPassword, wrappedKeyRecovery: newWrappedKeyRecovery, recVerifier: newRecVerifier });
ok(r.status === 401 && r.json?.error === "invalid_code", `reset/complete wrong code -> 401 invalid_code (${r.status})`);

if (seam) {
  // attempts is now 1 (< 5), and the code is unexpired, so the right code still completes the reset.
  r = await post("/v1/auth/reset/complete", { login: email, code, authVerifier: newAuthVerifier, wrappedKeyPassword: newWrappedKeyPassword, wrappedKeyRecovery: newWrappedKeyRecovery, recVerifier: newRecVerifier });
  ok(r.status === 200 && r.json?.token, `reset/complete right code -> 200 + fresh token (${r.status})`);
  let token = r.json?.token;

  console.log("AFTER RESET: old password fails, fresh vault is empty");
  // The OLD password no longer logs in (server re-keyed auth_hash to the new verifier).
  const pre = (await post("/v1/auth/prelogin", { login: email })).json;
  const oldMk = await pbkdf2(enc(password), unb64(pre.kdfSalt), pre.kdfIters);
  r = await post("/v1/auth/login", { login: email, authVerifier: await authVerifierFor(oldMk, password) });
  ok(r.status === 401, `login with OLD password -> 401 (${r.status})`);

  // The NEW password logs in and yields the fresh data key.
  const newMk = await pbkdf2(enc(newPassword), unb64(pre.kdfSalt), pre.kdfIters);
  r = await post("/v1/auth/login", { login: email, authVerifier: await authVerifierFor(newMk, newPassword) });
  ok(r.status === 200 && r.json?.token, `login with NEW password -> 200 (${r.status})`);
  token = r.json?.token || token;

  // The old backup (ciphertext under the OLD data key) was deleted: the vault is empty.
  const getBackup = await fetch(BASE + "/v1/backup", { headers: { authorization: "Bearer " + token } });
  ok(getBackup.status === 404, `backup GET after reset -> 404 (fresh, empty vault) (${getBackup.status})`);
} else {
  console.log("  (skipping happy-path: _code not echoed; run wrangler dev with ALLOW_TEST_RESET_CODE=1)");
}

console.log("LOCKOUT: 5 wrong attempts, then even the right code is rejected");
// A completed reset DELETES the password_resets row, so this start mints a fresh code with no cooldown.
// (If the seam is off, this still mints a fresh row, but we cannot read the right code to prove the
// "right code still locked" leg, so that final assertion is guarded by `seam`.)
r = await post("/v1/auth/reset/start", { login: email });
ok(r.status === 200 && r.json?.ok === true, `reset/start (fresh) -> 200 ok (${r.status})`);
const code2 = r.json?._code; // present only with the seam
const wrong2 = code2 === "000000" ? "111111" : "000000";
const completeWrong = () => post("/v1/auth/reset/complete", { login: email, code: wrong2, authVerifier: newAuthVerifier, wrappedKeyPassword: newWrappedKeyPassword, wrappedKeyRecovery: newWrappedKeyRecovery, recVerifier: newRecVerifier });

let all401 = true;
for (let i = 1; i <= 5; i++) {
  const x = await completeWrong();
  if (!(x.status === 401 && x.json?.error === "invalid_code")) all401 = false;
}
ok(all401, "5 wrong attempts each -> 401 invalid_code");
// 6th wrong attempt: attempts (5) >= RESET_MAX_ATTEMPTS, so it stays 401 (and does not increment further).
let sixth = await completeWrong();
ok(sixth.status === 401 && sixth.json?.error === "invalid_code", `>=5 attempts: further wrong -> still 401 (${sixth.status})`);

if (seam && code2) {
  // Lockout is enforced before the code comparison, so even the CORRECT code is now rejected.
  let locked = await post("/v1/auth/reset/complete", { login: email, code: code2, authVerifier: newAuthVerifier, wrappedKeyPassword: newWrappedKeyPassword, wrappedKeyRecovery: newWrappedKeyRecovery, recVerifier: newRecVerifier });
  ok(locked.status === 401 && locked.json?.error === "invalid_code", `right code after lockout -> still 401 (${locked.status})`);
} else {
  console.log("  (skipping right-code-after-lockout: needs the seam to know the right code)");
}

console.log(`\nRESULT: ${pass} passed, ${fail} failed`);
console.log("CLEANUP_EMAIL " + email + "  (local D1 only; nothing on api.vortx.tv)");
process.exit(fail === 0 ? 0 : 1);
